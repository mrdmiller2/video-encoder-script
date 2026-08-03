# Windows port of convert-v5.0.33S.sh's VMAF-targeted CRF search
# (resolve_crf_for_encode() and vmaf_crf_search_abav1(), lines
# ~10619-10736).
#
# Deliberately NOT ported in this pass: vmaf_crf_search_internal()'s
# bespoke ffmpeg-based search (coarse-anchor-then-bisect over sample
# clips, its own libvmaf scoring via _vmaf_score_one). The bash version
# uses ab-av1 for almost everything and only falls back to the internal
# search for AV1 grain-synthesizing profiles (anime/vintage), because
# ab-av1's own VMAF scoring can't disable synthesized grain before
# scoring (confirmed against ab-av1 GitHub issue #139, open/unfixed as
# of 0.11.4/0.11.5 -- checked, still applies). This port covers the
# ab-av1 path, which is the common case; the grain-synthesis case is
# handled by failing closed to the fixed-CRF fallback with an explicit
# warning (never a silently-uncorrected-for-grain VMAF score), tracked
# as a real gap until the internal search gets ported.
#
# Also NOT ported: the profile system that supplies VmafTarget/FixedCrf/
# SVT-or-x265 params (profile_for_source, profile_svt_params,
# profile_fixed_crf, VMAF_TARGET_* per-profile constants -- task #31).
# This module takes those as caller-supplied parameters, same layering
# as VesTwoStageEncode.psm1 taking pre-built video args.

$script:VmafCrfCache = @{}

function Get-VesVideoHeight {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $args = @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=height', '-of', 'default=noprint_wrappers=1:nokey=1', $Source)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfprobePath
    foreach ($a in $args) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    $h = 0
    [int]::TryParse($out.Trim(), [ref]$h) | Out-Null
    return $h
}

function Get-VesVmafModelForSource {
    <#
    .SYNOPSIS
    Port of vmaf_model_for_source(). 4K sources use the 4K-tuned model.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $height = Get-VesVideoHeight -Source $Source -FfprobePath $FfprobePath
    if ($height -gt 1600) {
        return 'version=vmaf_4k_v0.6.1'
    }
    return 'version=vmaf_v0.6.1neg'
}

function Invoke-VesVmafCrfSearchAbAv1 {
    <#
    .SYNOPSIS
    Port of vmaf_crf_search_abav1(). Wraps ab-av1's own crf-search
    subcommand. Returns $null on failure (caller falls back to fixed
    CRF), or an object with Crf/PredictedSize/Vmaf on success.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][ValidateSet('av1', 'hevc')][string]$Codec,
        [Parameter(Mandatory)][double]$Target,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$AbAv1Path,
        [string[]]$EncoderArgs = @(),
        [string]$VideoFilter,
        [int]$MinCrf = 15,
        [int]$MaxCrf = 45,
        [int]$SampleSeconds = 20,
        [int]$Samples = 3,
        [int]$TimeoutSeconds = 1800
    )

    $encoder = if ($Codec -eq 'av1') { 'libsvtav1' } else { 'libx265' }
    $preset = if ($Codec -eq 'av1') { '8' } else { 'medium' }

    $args = @('crf-search', '-i', $Source, '-e', $encoder, '--preset', $preset)
    $args += $EncoderArgs
    if ($VideoFilter) { $args += @('--vfilter', $VideoFilter) }
    $args += @('--min-vmaf', "$Target", '--min-crf', "$MinCrf", '--max-crf', "$MaxCrf",
        '--sample-duration', "${SampleSeconds}s", '--samples', "$Samples",
        '--vmaf', "model=$Model")

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AbAv1Path
    foreach ($a in $args) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        $proc.Start() | Out-Null
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) {
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit()
            Write-Warning "ab-av1 crf-search timed out after ${TimeoutSeconds}s for $Source"
            return $null
        }
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        if ($proc.ExitCode -ne 0) {
            return $null
        }
        $out = $stdoutTask.Result
    } finally {
        $proc.Dispose()
    }

    # Final stdout line looks like:
    # "crf 21.25 VMAF 94.19 predicted video stream size 22.47 MiB (17%) taking 60 seconds"
    $line = ($out -split "`r?`n" | Where-Object { $_ -match '^crf [0-9.]+ VMAF' } | Select-Object -Last 1)
    if (-not $line) { return $null }

    $crfMatch = [regex]::Match($line, '^crf ([0-9.]+)')
    $vmafMatch = [regex]::Match($line, 'VMAF ([0-9.]+)')
    $predMatch = [regex]::Match($line, 'predicted video stream size ([0-9.]+\s*[KMGT]iB)')

    if (-not $crfMatch.Success) { return $null }
    # CRFs can be fractional (21.25) -- round DOWN (lower CRF = safer/higher quality),
    # matching the bash version's `awk '{printf "%d", $1}'` truncation.
    $crf = [int][math]::Floor([double]$crfMatch.Groups[1].Value)

    return [PSCustomObject]@{
        Crf            = $crf
        Vmaf           = if ($vmafMatch.Success) { [double]$vmafMatch.Groups[1].Value } else { 0 }
        PredictedSize  = if ($predMatch.Success) { $predMatch.Groups[1].Value -replace '\s', '' } else { '0' }
    }
}

function Resolve-VesCrfForEncode {
    <#
    .SYNOPSIS
    Port of resolve_crf_for_encode()'s orchestration: cache lookup, the
    HDR/VMAF-disabled/no-libvmaf/dry-run fixed-CRF bypasses, then the
    ab-av1 search (falling back to FixedCrf, with an explicit warning,
    when ab-av1 can't be used for a grain-synthesizing AV1 profile --
    the internal search that would normally handle that case isn't
    ported yet).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][ValidateSet('av1', 'hevc')][string]$Codec,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][bool]$IsHdr,
        [Parameter(Mandatory)][int]$TargetHeight,
        [Parameter(Mandatory)][int]$FixedCrf,
        [double]$VmafTarget,
        [bool]$VmafDisabled = $false,
        [bool]$FfmpegHasLibVmaf = $true,
        [bool]$DryRun = $false,
        [bool]$ProfileUsesGrainSynthesis = $false,
        [string]$AbAv1Path,
        [string]$FfprobePath,
        [string[]]$EncoderArgs = @(),
        [string]$VideoFilter
    )

    $key = "${Codec}:${Profile}:${TargetHeight}:${Source}"
    if ($script:VmafCrfCache.ContainsKey($key)) {
        return $script:VmafCrfCache[$key]
    }

    if ($IsHdr -or $VmafDisabled -or -not $FfmpegHasLibVmaf) {
        if ($IsHdr) {
            Write-Host "HDR source -- fixed CRF $FixedCrf (VMAF unreliable on PQ/HLG)"
        } else {
            Write-Host "Fixed CRF $FixedCrf ($Codec, $Profile, output=${TargetHeight}p)"
        }
        $script:VmafCrfCache[$key] = $FixedCrf
        return $FixedCrf
    }

    if ($VmafTarget -le 0) {
        Write-Host "Cannot resolve VMAF target for $Source (profile undetectable/ambiguous) -- fixed CRF $FixedCrf"
        $script:VmafCrfCache[$key] = $FixedCrf
        return $FixedCrf
    }

    if ($DryRun) {
        Write-Host "[dry-run] Would VMAF-search CRF (target=$VmafTarget); reporting fixed CRF $FixedCrf"
        $script:VmafCrfCache[$key] = $FixedCrf
        return $FixedCrf
    }

    $model = Get-VesVmafModelForSource -Source $Source -FfprobePath $FfprobePath
    Write-Host "VMAF CRF search: target=$VmafTarget model=$model codec=$Codec"

    $canUseAbAv1 = ($Codec -ne 'av1') -or (-not $ProfileUsesGrainSynthesis)
    $result = $null
    if ($canUseAbAv1 -and $AbAv1Path) {
        $result = Invoke-VesVmafCrfSearchAbAv1 -Source $Source -Codec $Codec -Target $VmafTarget -Model $model `
            -AbAv1Path $AbAv1Path -EncoderArgs $EncoderArgs -VideoFilter $VideoFilter
    } elseif (-not $canUseAbAv1) {
        Write-Warning "Profile '$Profile' uses AV1 grain synthesis -- ab-av1's VMAF scoring can't account for it (upstream limitation), and the internal grain-aware search isn't ported yet -- using fixed CRF $FixedCrf instead of a potentially-wrong VMAF-searched value"
    }

    if ($null -eq $result) {
        Write-Warning "VMAF search failed or no CRF met target -- fixed CRF $FixedCrf"
        $script:VmafCrfCache[$key] = $FixedCrf
        return $FixedCrf
    }

    Write-Host "VMAF search chose CRF $($result.Crf) (sample VMAF $($result.Vmaf) >= $VmafTarget; predicted $($result.PredictedSize))"
    $script:VmafCrfCache[$key] = $result.Crf
    return $result.Crf
}

Export-ModuleMember -Function Get-VesVideoHeight, Get-VesVmafModelForSource, Invoke-VesVmafCrfSearchAbAv1, Resolve-VesCrfForEncode
