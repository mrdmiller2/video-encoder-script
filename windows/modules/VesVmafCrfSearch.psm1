# Windows port of convert-v5.0.33S.sh's VMAF-targeted CRF search
# (resolve_crf_for_encode() and vmaf_crf_search_abav1(), lines
# ~10619-10736).
#
# Deliberately NOT ported in this pass: vmaf_crf_search_internal()'s
# bespoke ffmpeg-based search (coarse-anchor-then-bisect over sample
# clips, its own libvmaf scoring via _vmaf_score_one). The bash version
# uses ab-av1 for almost everything and only falls back to the internal
# search for AV1 grain-synthesizing profiles (anime/vintage), because
# those profiles need the project's own candidate scoring policy. As of
# v6.0.1A that policy deliberately scores grain-ON playback against the
# grainy source (not the former grain-stripped decode), so ab-av1 is still
# not used for those profiles until the internal search is ported. This port covers the
# ab-av1 path, which is the common case; the grain-synthesis case is
# handled by failing closed to the fixed-CRF fallback with an explicit
# warning (never a silently-uncorrected-for-grain VMAF score), tracked
# as a real gap until the internal search gets ported.
#
# VmafTarget/FixedCrf/SVT-or-x265 params still come in as caller-supplied
# parameters (same layering as VesTwoStageEncode.psm1 taking pre-built
# video args) -- but Resolve-VesCrfForEncode imports VesProfileDecision.psm1
# specifically to derive the grain-synthesis safety check from $Profile
# itself rather than trusting a caller-supplied override (see the
# 2026-08-02 team-review fix in that function).
#
# Deliberately NOT -Force here (found via direct testing, 2026-08-02):
# if a caller has already imported VesProfileDecision.psm1 into the
# global scope, a -Force reimport from inside THIS module's own script
# scope silently orphans the caller's already-bound functions --
# Get-Command/direct invocation of e.g. Resolve-VesHdrMode then fails
# with "term not recognized" even though Get-Module still lists it as
# exported. Only importing when not already loaded avoids clobbering
# whatever the caller already has.
if (-not (Get-Module -Name VesProfileDecision)) {
    Import-Module (Join-Path $PSScriptRoot 'VesProfileDecision.psm1') -Force
}

$script:VmafCrfCache = @{}

# Real bug found 2026-08-03, root-caused via team research (2026-08-03):
# SVT-AV1 v4.1.0-279-gd3c4cb394's SSSE3 kernel
# (Source/Lib/ASM_SSSE3/subpel_variance_ssse3.asm, an unaligned-buffer
# `mova` used only by the fast-preset lpd1/subpel-search path reached at
# preset 8+) segfaults/access-violates on pre-AVX2 CPUs. Upstream fixed
# 2026-07-18 (after our pinned snapshot); note v4.2.0 does NOT contain
# the fix either (tagged before the fix merged) -- do not assume a
# version-tag bump alone resolves this. SVT_PRESET_SEARCH=8 (bash) /
# the ab-av1 search preset here are exactly the affected value.
# Real runtime workaround (no rebuild/version change): `asm=sse3` in
# -svtav1-params forces SIMD dispatch below the buggy SSSE3 kernel.
# Team consensus (Codex + Cursor, 2026-08-03) against applying this
# fleet-wide unconditionally -- it demotes AVX2/AVX-512 machines' SIMD
# level too, a real perf cost for zero benefit on unaffected hardware.
# Instead: an empirical, one-time, sticky probe using a REAL short trim
# of actual source content (not a synthetic clip -- confirmed via this
# same investigation that a probe must exercise the genuine lpd1/subpel
# code path, which a trivial 1-frame black clip may not reach) at
# preset 8 with a direct ffmpeg invocation (bypassing ab-av1, whose own
# exit-code behavior on an internal SVT-AV1 crash isn't verified) --
# never a CPU-model/family allowlist, matching this project's other
# hardware probes (Test-VesHwEncoderAvailable, etc).
$script:VesSvtAv1Preset8Probed = $false
# One of: 'Safe' (preset 8 works as-is), 'NeedsSse3' (asm=sse3 confirmed
# to fix it -- caller must inject it), 'Broken' (crashes even with the
# workaround -- caller must not attempt an AV1 ab-av1 search at all).
$script:VesSvtAv1Preset8State = 'Safe'

function Test-VesSvtAv1Preset8Safe {
    <#
    .SYNOPSIS
    One-time, sticky, empirical probe: does this host's SVT-AV1 build
    crash at preset 8 (the ab-av1 search preset)? Runs a short (~2s)
    direct ffmpeg encode of real source content at preset 8 with
    default SIMD dispatch; on a crash-like failure, retries the same
    clip with asm=sse3 to confirm the workaround actually resolves it
    before trusting it. Caches the result for the rest of this process
    -- never re-probes.

    Real bug found in this probe itself, 2026-08-03: an earlier version
    used a single boolean to represent three real outcomes (safe /
    needs-workaround / broken-even-with-workaround), which silently
    conflated "no workaround needed" with "workaround doesn't help
    either" -- both left the flag false, so a cached re-check on a
    genuinely broken host wrongly reported "safe". Fixed by returning
    a real three-state result, cached as such.

    .OUTPUTS
    'Safe', 'NeedsSse3', or 'Broken' -- see $script:VesSvtAv1Preset8State
    doc comment above for what the caller must do for each.
    #>
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$Source,
        [int]$TimeoutSeconds = 60
    )
    if ($script:VesSvtAv1Preset8Probed) {
        return $script:VesSvtAv1Preset8State
    }
    $script:VesSvtAv1Preset8Probed = $true

    $probeOut = Join-Path ([System.IO.Path]::GetTempPath()) "ves-svtav1-probe-$PID.mkv"
    $baseArgs = @('-y', '-v', 'error', '-i', $Source, '-t', '2', '-map', '0:v:0',
        '-c:v', 'libsvtav1', '-preset', '8', '-crf', '35', '-pix_fmt', 'yuv420p10le', '-an', '-f', 'matroska')

    try {
        $default = Invoke-VesProbeFfmpegRun -FfmpegPath $FfmpegPath -Args ($baseArgs + @('-svtav1-params', 'enable-qm=1', $probeOut)) -TimeoutSeconds $TimeoutSeconds
        if ($default.Ok) {
            Write-Host 'SVT-AV1 preset-8 probe: OK, no workaround needed'
            $script:VesSvtAv1Preset8State = 'Safe'
            return $script:VesSvtAv1Preset8State
        }
        Write-Warning "SVT-AV1 preset-8 probe crashed (exitcode=$($default.ExitCode)) -- this matches a known upstream SVT-AV1 bug on pre-AVX2 CPUs (unaligned SSSE3 access in the fast-preset subpel-search path); retrying with asm=sse3 workaround"

        $withWorkaround = Invoke-VesProbeFfmpegRun -FfmpegPath $FfmpegPath -Args ($baseArgs + @('-svtav1-params', 'enable-qm=1:asm=sse3', $probeOut)) -TimeoutSeconds $TimeoutSeconds
        if ($withWorkaround.Ok) {
            Write-Warning 'SVT-AV1 preset-8 probe: asm=sse3 workaround confirmed working -- will be applied to all AV1 VMAF CRF-search encodes on this host for the rest of this run'
            $script:VesSvtAv1Preset8State = 'NeedsSse3'
            return $script:VesSvtAv1Preset8State
        }
        Write-Warning "SVT-AV1 preset-8 probe: crashed even with asm=sse3 (exitcode=$($withWorkaround.ExitCode)) -- workaround does not fix it on this host. Skipping AV1 VMAF CRF-search entirely for the rest of this run (fixed-CRF only) rather than risking further crashes"
        $script:VesSvtAv1Preset8State = 'Broken'
        return $script:VesSvtAv1Preset8State
    } finally {
        Remove-Item $probeOut -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-VesProbeFfmpegRun {
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string[]]$Args,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegPath
    foreach ($a in $Args) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
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
            return [PSCustomObject]@{ Ok = $false; ExitCode = 124 }
        }
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        # A native crash (STATUS_ACCESS_VIOLATION 0xC0000005 on Windows,
        # SIGSEGV on Linux) always surfaces as a nonzero exit code here --
        # never key on the exact negative/signed value, per team review.
        return [PSCustomObject]@{ Ok = ($proc.ExitCode -eq 0); ExitCode = $proc.ExitCode }
    } finally {
        $proc.Dispose()
    }
}

function Get-VesVideoHeight {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath,
        [int]$TimeoutSeconds = 30
    )
    # Timeout-bounded (2026-08-02) -- found a sibling probe in
    # VesDoneLog.psm1 with no timeout at all blocked its caller
    # indefinitely (with climbing memory) when the child process
    # stalled; every probe call in this port needs the same bound.
    $args = @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=height', '-of', 'default=noprint_wrappers=1:nokey=1', $Source)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfprobePath
    foreach ($a in $args) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { }
        $proc.WaitForExit()
        return 0
    }
    $stdoutTask.Wait()
    $out = $stdoutTask.Result
    # first run of digits only -- some MKVs' ffprobe output carries a trailing
    # comma ("1608,"), which int-parses to 0 (bash _source_is_uhd fix 2026-09-01).
    $m = [regex]::Match(($out -split "`n")[0], '\d+')
    $h = 0; if ($m.Success) { [int]::TryParse($m.Value, [ref]$h) | Out-Null }
    return $h
}

function Get-VesVideoWidth {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$FfprobePath, [int]$TimeoutSeconds = 30)
    $a = @('-v','error','-select_streams','v:0','-show_entries','stream=width','-of','default=noprint_wrappers=1:nokey=1',$Source)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfprobePath
    foreach ($x in $a) { $psi.ArgumentList.Add($x) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $t = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { try { $p.Kill($true) } catch {}; $p.WaitForExit(); return 0 }
    $t.Wait()
    $m = [regex]::Match(($t.Result -split "`n")[0], '\d+')
    $w = 0; if ($m.Success) { [int]::TryParse($m.Value, [ref]$w) | Out-Null }
    return $w
}

function Test-VesSourceIsUhd {
    <#
    .SYNOPSIS
    Port of bash _source_is_uhd() (v6.0.1E). Height alone misses 2.40:1 4K
    masters (3840x1600 / 3840x1608 -- height exactly 1600). Gate on
    width >= 3456 (covers 3840 + DCI 4096, clear of 2560px 1440p) OR height >= 1600.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$FfprobePath)
    $w = Get-VesVideoWidth  -Source $Source -FfprobePath $FfprobePath
    $h = Get-VesVideoHeight -Source $Source -FfprobePath $FfprobePath
    return ($w -ge 3456 -or $h -ge 1600)
}

function Get-VesVmafModelForSource {
    <#
    .SYNOPSIS
    Port of vmaf_model_for_source(). UHD sources use the 4K-tuned model.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    if (Test-VesSourceIsUhd -Source $Source -FfprobePath $FfprobePath) {
        return 'version=vmaf_4k_v0.6.1'
    }
    return 'version=vmaf_v0.6.1neg'
}

function Get-VesVmafTargetForSource {
    <#
    .SYNOPSIS
    Port of vmaf_target_for_source(). UHD -> $VMAF_TARGET_4K (95); else the
    per-profile target. Windows had used a single caller-supplied -VmafTarget
    (default 90); this brings the target values to bash parity. Env overrides:
    CONVERT_VMAF_TARGET_<PROFILE> / CONVERT_VMAF_TARGET_4K.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$Profile
    )
    if (Test-VesSourceIsUhd -Source $Source -FfprobePath $FfprobePath) {
        return [double]($env:CONVERT_VMAF_TARGET_4K    ? $env:CONVERT_VMAF_TARGET_4K    : 95.0)
    }
    # Routing-layer compound: Animation-Grain carries a relaxed target on wanime.
    if (($Source -replace '\\','/') -match '/Animation-Grain/') {
        return [double]($env:CONVERT_VMAF_TARGET_ANIMATION_GRAIN ? $env:CONVERT_VMAF_TARGET_ANIMATION_GRAIN : 92.0)
    }
    if (-not $Profile) { $Profile = Get-VesDetectedProfileForPath -Path $Source }
    $def = 94.0
    switch ($Profile) {
        'canime'  { return [double]($env:CONVERT_VMAF_TARGET_CANIME  ? $env:CONVERT_VMAF_TARGET_CANIME  : 95.0) }
        'anime'   { return [double]($env:CONVERT_VMAF_TARGET_ANIME   ? $env:CONVERT_VMAF_TARGET_ANIME   : $def) }
        'wanime'  { return [double]($env:CONVERT_VMAF_TARGET_WANIME  ? $env:CONVERT_VMAF_TARGET_WANIME  : $def) }
        'movies'  { return [double]($env:CONVERT_VMAF_TARGET         ? $env:CONVERT_VMAF_TARGET         : $def) }
        'classic' { return [double]($env:CONVERT_VMAF_TARGET_CLASSIC ? $env:CONVERT_VMAF_TARGET_CLASSIC : $def) }
        'vintage' { return [double]($env:CONVERT_VMAF_TARGET_VINTAGE ? $env:CONVERT_VMAF_TARGET_VINTAGE : $def) }
        'mtv'     { return [double]($env:CONVERT_VMAF_TARGET_MTV     ? $env:CONVERT_VMAF_TARGET_MTV     : $def) }
        'vtv'     { return [double]($env:CONVERT_VMAF_TARGET_VTV     ? $env:CONVERT_VMAF_TARGET_VTV     : $def) }
        'concert' { return [double]($env:CONVERT_VMAF_TARGET_CONCERT ? $env:CONVERT_VMAF_TARGET_CONCERT : 95.0) }
        'standup' { return [double]($env:CONVERT_VMAF_TARGET_STANDUP ? $env:CONVERT_VMAF_TARGET_STANDUP : $def) }
        'learning' { return [double]($env:CONVERT_VMAF_TARGET_LEARNING ? $env:CONVERT_VMAF_TARGET_LEARNING : $def) }
        default   { return [double]$def }
    }
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
    the internal search that would normally handle that grain-ON playback
    comparison isn't
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
        [Nullable[bool]]$ProfileUsesGrainSynthesis = $null,
        [string]$AbAv1Path,
        [string]$FfmpegPath,
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

    # Team-review fix (2026-08-02): this used to default to $false and
    # trust the caller to pass the right value -- an opt-IN safety
    # check for exactly the case (grain-synthesizing AV1 profiles) it
    # exists to guard against, meaning a caller that simply forgot the
    # flag would silently reopen the unsafe ab-av1 path. $Profile is
    # already a mandatory parameter here, so there's no reason not to
    # derive the real answer from it directly -- only trust an explicit
    # caller override if one was actually supplied.
    $grainSynthesis = if ($null -ne $ProfileUsesGrainSynthesis) { $ProfileUsesGrainSynthesis } else { Test-VesProfileUsesGrainSynthesis -Profile $Profile }
    $canUseAbAv1 = ($Codec -ne 'av1') -or (-not $grainSynthesis)
    $result = $null
    if ($canUseAbAv1 -and $Codec -eq 'av1' -and $FfmpegPath) {
        $preset8State = Test-VesSvtAv1Preset8Safe -FfmpegPath $FfmpegPath -Source $Source
        if ($preset8State -eq 'Broken') {
            Write-Warning "SVT-AV1 preset 8 crashes on this host even with the asm=sse3 workaround -- skipping AV1 VMAF CRF-search entirely (fixed CRF $FixedCrf) rather than risking a crash"
            $canUseAbAv1 = $false
        }
    }
    if ($canUseAbAv1 -and $AbAv1Path) {
        $searchEncoderArgs = $EncoderArgs
        if ($Codec -eq 'av1' -and $preset8State -eq 'NeedsSse3') {
            $searchEncoderArgs = @($EncoderArgs)
            for ($i = 0; $i -lt $searchEncoderArgs.Count - 1; $i++) {
                if ($searchEncoderArgs[$i] -eq '--svt') {
                    $searchEncoderArgs[$i + 1] = "$($searchEncoderArgs[$i + 1]):asm=sse3"
                    break
                }
            }
        }
        $result = Invoke-VesVmafCrfSearchAbAv1 -Source $Source -Codec $Codec -Target $VmafTarget -Model $model `
            -AbAv1Path $AbAv1Path -EncoderArgs $searchEncoderArgs -VideoFilter $VideoFilter
    } elseif (-not $canUseAbAv1 -and $grainSynthesis -and $Codec -eq 'av1') {
        Write-Warning "Profile '$Profile' uses AV1 grain synthesis -- the project's grain-ON internal VMAF search is not ported yet -- using fixed CRF $FixedCrf instead of a potentially-wrong VMAF-searched value"
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

function Get-VesFinalVmaf {
    <#
    .SYNOPSIS
    Port of measure_final_vmaf() -- sampled full-output VMAF for a kept
    encode (real encode, fixed-CRF fallback, or the must-eliminate remux
    floor alike), distinct from the CRF-search's candidate-CRF prediction:
    this scores the actual chosen output against the actual source. Unlike
    the bash version (which shells out to python3 to parse libvmaf's JSON
    log), this uses PowerShell's built-in ConvertFrom-Json -- no extra
    dependency needed on a Windows fleet machine. Returns $null on any
    failure (caller must treat that as "couldn't measure," never as a
    passing or failing score).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [int]$TargetHeight = 0,
        [int]$Samples = 3,
        [int]$SampleSeconds = 20,
        [int]$TimeoutSeconds = 180,
        [int]$AlignSearchFrames = 3,
        [switch]$Sequential
    )
    if (-not (Test-Path -LiteralPath $Source) -or -not (Test-Path -LiteralPath $Output)) { return $null }

    $durProbeArgs = @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', $Source)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfprobePath
    foreach ($a in $durProbeArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $dur = 0.0
    try {
        # Drain both streams concurrently like Invoke-VesProbeFfmpegRun --
        # an undrained stderr pipe can fill and block the child until the
        # timeout fires (team review, 2026-08-05: this probe was written
        # ad hoc instead of reusing that helper and missed this).
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(30000)) {
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit()
            return $null
        }
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        if (-not [double]::TryParse($stdoutTask.Result.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dur) -or $dur -le 0) {
            return $null
        }
    } finally {
        $proc.Dispose()
    }
    $durInt = [int][math]::Floor($dur)

    $nsamples = $Samples
    while ($nsamples -gt 1 -and $durInt -lt ($SampleSeconds * $nsamples * 2)) { $nsamples-- }

    $model = Get-VesVmafModelForSource -Source $Source -FfprobePath $FfprobePath
    $scaleFilter = switch ($TargetHeight) {
        720  { 'scale=1280:720:flags=lanczos:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,' }
        1080 { 'scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,' }
        default { '' }
    }
    $nThreads = [Environment]::ProcessorCount

    # Both streams are optionally normalized to Source's nominal
    # r_frame_rate via an fps= filter before comparison, ported from the
    # bash side (see ves-vmaf-crf-search.sh's matching comment for the full
    # empirical writeup): a VFR source misaligns two independent -ss seeks
    # into $Output/$Source, and libvmaf silently scores each misaligned
    # pair near 0. But forcing the filter unconditionally is NOT safe
    # (2026-08-12 correction) -- some sources have real-but-subtle frame-
    # timing irregularities while sitting at an unusual native rate where
    # avg_frame_rate exactly equals r_frame_rate anyway, and forcing fps=
    # on an already-matching stream can itself introduce resampling
    # artifacts that make the score WORSE, not better. Since misalignment
    # only ever drags a score spuriously low (never inflates it), and
    # unnecessary resampling also only ever drags it low, never invents
    # quality -- each sample window is measured BOTH ways below and the
    # higher of the two is kept, which is safe in both directions.
    $fpsFilter = ''
    $rFrameRateArgs = @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=r_frame_rate', '-of', 'default=nw=1:nk=1', $Source)
    $rfrPsi = New-Object System.Diagnostics.ProcessStartInfo
    $rfrPsi.FileName = $FfprobePath
    foreach ($a in $rFrameRateArgs) { $rfrPsi.ArgumentList.Add($a) }
    $rfrPsi.RedirectStandardOutput = $true
    $rfrPsi.RedirectStandardError = $true
    $rfrPsi.UseShellExecute = $false
    $rfrProc = [System.Diagnostics.Process]::Start($rfrPsi)
    try {
        $rfrTask = $rfrProc.StandardOutput.ReadToEndAsync()
        if ($rfrProc.WaitForExit(30000)) {
            $rfrTask.Wait()
            $rFrameRate = $rfrTask.Result.Trim()
            if ($rFrameRate -match '^\d+/\d+$') {
                $parts = $rFrameRate -split '/'
                if ([int]$parts[0] -gt 0 -and [int]$parts[1] -gt 0) {
                    $fpsFilter = "fps=$rFrameRate,"
                }
            }
        } else {
            try { $rfrProc.Kill($true) } catch { }
            $rfrProc.WaitForExit()
        }
    } finally {
        $rfrProc.Dispose()
    }

    # Task #172: ffmpeg's MKV muxer relabels Output's PTS with an offset vs
    # Source (observed 20-40ms) -- both streams below are seeked
    # independently at the SAME nominal $Start and then have their own PTS
    # zeroed (setpts=PTS-STARTPTS), so this offset can silently land the two
    # -ss seeks on different real-content frames.
    #
    # First attempt (2026-08-17) measured the Source/Output first-frame PTS
    # delta once per file and unconditionally compensated the Output-side
    # seek by it, trusting it as a fixed correction. Real-world test on
    # PRINCE disproved that: compensating by the measured offset (-ss
    # 413.979 vs uncompensated 414, a 21ms difference) scored 26.9, while
    # the SAME window uncompensated scored 72.6 -- worse, not better. A
    # follow-up controlled sweep (13-point, one frame-duration step each,
    # same file/window) showed why: the true best alignment is a sharp
    # single peak sitting at offset=0 for that window, with the score
    # collapsing by ~50 points within a single frame either side -- not
    # something a single measured delta can reliably predict, because the
    # real misalignment isn't a fixed property of the FILE, it can vary
    # window to window (frame jitter, B-frame reordering, landing near a
    # scene cut).
    #
    # Correct fix: don't guess the offset from metadata at all -- SEARCH for
    # it. For each sample window, try every whole-frame offset from
    # -AlignSearchFrames to +AlignSearchFrames (crossed with the existing
    # fpsFilter axis below, which guards a different, still-real VFR-drift
    # failure mode) and keep whichever scores highest. Misalignment can only
    # ever drag a score spuriously low, never inflate it, so taking the max
    # across every candidate is safe in every direction.
    $frameDur = 0.0
    if ($fpsFilter -match '^fps=(\d+)/(\d+),$') {
        $frameDur = [double]$Matches[2] / [double]$Matches[1]
    }

    if ($Sequential) {
        $vlogDir = [System.IO.Path]::GetTempPath()
        $vlogName = "ves-vmaf-seq-$([guid]::NewGuid().ToString('N')).json"
        $vlog = Join-Path $vlogDir $vlogName
        # Chunk-finalize VMAF must avoid independent -ss seeks on
        # multi-segment concatenated output. Keep this as a start-to-finish
        # decode, but normalize both inputs to the source rate when known so
        # broken-DTS/timing sources feed libvmaf equal-length frame streams.
        $lavfi = "[0:v]${fpsFilter}format=yuv420p10le[d];[1:v]${fpsFilter}${scaleFilter}format=yuv420p10le[r];[d][r]libvmaf=model=$model`:n_threads=$nThreads`:log_fmt=json:log_path=$vlogName"
        $ffArgs = @('-y', '-v', 'error', '-i', $Output, '-i', $Source, '-lavfi', $lavfi, '-f', 'null', '-')
        $run = Invoke-VesProbeFfmpegRun -FfmpegPath $FfmpegPath -Args $ffArgs -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $vlogDir
        if (-not $run.Ok -or -not (Test-Path -LiteralPath $vlog)) {
            Remove-Item -LiteralPath $vlog -Force -ErrorAction SilentlyContinue
            return $null
        }
        try {
            $json = Get-Content -LiteralPath $vlog -Raw | ConvertFrom-Json
            return [math]::Round([double]$json.pooled_metrics.vmaf.mean, 2)
        } catch {
            return $null
        } finally {
            Remove-Item -LiteralPath $vlog -Force -ErrorAction SilentlyContinue
        }
    }

    $measureOnce = {
        param($Start, $FilterPrefix, $Offset)
        $outStart = $Start + $Offset
        if ($outStart -lt 0) { $outStart = 0 }
        $vlogDir = [System.IO.Path]::GetTempPath()
        $vlogName = "ves-vmaf-$([guid]::NewGuid().ToString('N')).json"
        $vlog = Join-Path $vlogDir $vlogName
        # ffmpeg's filter-option parser splits on ':' -- a raw Windows path
        # (C:\Users\...\file.json) breaks log_path at the drive letter, so
        # every sample silently failed and this always returned $null (team
        # review, 2026-08-05: all three reviewers independently caught this
        # as a real bug; colon-escaping (`C\:/...`) was tried first and
        # ALSO failed against a real ffmpeg N-125907 build -- empirically
        # confirmed via a live test on PRINCE, not just inferred). Passing
        # just the bare filename with the process's working directory set
        # to the temp folder sidesteps the escaping question entirely --
        # also verified working end-to-end on PRINCE.
        $lavfi = "[0:v]${FilterPrefix}setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]${FilterPrefix}${scaleFilter}setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=$model`:n_threads=$nThreads`:log_fmt=json:log_path=$vlogName"
        $ffArgs = @('-y', '-v', 'error', '-ss', "$outStart", '-t', "$SampleSeconds", '-i', $Output,
            '-ss', "$Start", '-t', "$SampleSeconds", '-i', $Source, '-lavfi', $lavfi, '-f', 'null', '-')
        $run = Invoke-VesProbeFfmpegRun -FfmpegPath $FfmpegPath -Args $ffArgs -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $vlogDir
        if (-not $run.Ok -or -not (Test-Path -LiteralPath $vlog)) {
            Remove-Item -LiteralPath $vlog -Force -ErrorAction SilentlyContinue
            return $null
        }
        try {
            $json = Get-Content -LiteralPath $vlog -Raw | ConvertFrom-Json
            return [double]$json.pooled_metrics.vmaf.mean
        } catch {
            # Malformed/partial JSON, same as bash's python3-parse failure.
            return $null
        } finally {
            Remove-Item -LiteralPath $vlog -Force -ErrorAction SilentlyContinue
        }
    }

    $offsetVariants = @(0.0)
    if ($frameDur -gt 0.0) {
        for ($k = -$AlignSearchFrames; $k -le $AlignSearchFrames; $k++) {
            if ($k -ne 0) { $offsetVariants += ($k * $frameDur) }
        }
    }
    $filterVariants = @('')
    if ($fpsFilter) { $filterVariants += $fpsFilter }

    $vsum = 0.0
    $n = 0
    for ($i = 1; $i -le $nsamples; $i++) {
        $start = [int]([math]::Floor($durInt * (2 * $i - 1) / ($nsamples * 2)))
        $best = $null
        foreach ($off in $offsetVariants) {
            foreach ($ff in $filterVariants) {
                $vTry = & $measureOnce $start $ff $off
                if ($null -ne $vTry -and ($null -eq $best -or $vTry -gt $best)) { $best = $vTry }
            }
        }
        if ($null -eq $best) { continue }
        $vsum += $best
        $n++
    }
    if ($n -eq 0) { return $null }
    return [math]::Round($vsum / $n, 1)
}

Export-ModuleMember -Function Get-VesVideoHeight, Get-VesVideoWidth, Test-VesSourceIsUhd, Get-VesVmafTargetForSource, Get-VesVmafModelForSource, Invoke-VesVmafCrfSearchAbAv1, Resolve-VesCrfForEncode, Test-VesSvtAv1Preset8Safe, Get-VesFinalVmaf
