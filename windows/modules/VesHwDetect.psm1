# Windows port of convert-v5.0.33S.sh's hardware-encoder detection
# (detect_hw_environment/_resolve_hw_encode_priority, lines ~3125-3210).
# Fixed precedence NVIDIA > Intel QSV > AMD VCE > software, same as bash.
#
# Probes via a REAL short encode, not just listing encoders -- ffmpeg/
# HandBrake can both list an encoder that fails at runtime init (the
# same class of gap bash's own _probe_qsv_encode_available guards
# against). Per team design review (2026-08-03): probe through whichever
# tool will actually run the real job -- this module's probes are
# ffmpeg-based because this port's real encode pipeline
# (VesTwoStageEncode.psm1) is ffmpeg-based, not HandBrake (HandBrake in
# the bash version is reserved for disc sources / explicit --engine
# handbrake, and VesHandBrake.psm1's own probe function is separate and
# HandBrake-based for that path specifically).

if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}

function Test-VesHwEncoderAvailable {
    <#
    .SYNOPSIS
    Generic real-encode probe: attempts a tiny (1-frame) lavfi-source
    encode through the named ffmpeg encoder. Success requires BOTH
    exit code 0 AND non-empty valid output (mirrors bash's own
    `[ -s "$probe_out" ]` -- never trusts a returncode alone, matching
    this project's standing verify-before-trusting invariant).
    #>
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$EncoderName,
        [string[]]$ExtraArgs = @(),
        [int]$TimeoutSeconds = 30
    )
    $probeOut = Join-Path ([System.IO.Path]::GetTempPath()) "ves-hwprobe-$EncoderName-$PID.mp4"
    try {
        $args = @('-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=1',
            '-frames:v', '1', '-c:v', $EncoderName)
        $args += $ExtraArgs
        $args += $probeOut
        $result = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList $args -TimeoutSeconds $TimeoutSeconds -MaxRetries 0
        if ($result.ExitCode -ne 0) { return $false }
        return ((Test-Path $probeOut) -and (Get-Item $probeOut -Force).Length -gt 0)
    } catch {
        return $false
    } finally {
        Remove-Item $probeOut -Force -ErrorAction SilentlyContinue
    }
}

function Test-VesNvencAvailable {
    <#
    .SYNOPSIS
    Real NVENC probe for a specific codec ('hevc' or 'av1'). Per Phase 0
    findings ([[project_elvis_phase0_findings_2026_08_02]]): Turing-
    generation GPUs (e.g. ELVIS's GTX 1650, AI-PROCESSOR's Tesla T4)
    have HEVC NVENC but NOT AV1 NVENC (hardware ceiling, not fixable) --
    this function must be trusted to report that distinction correctly
    per-codec, never assumed from one codec's result.
    #>
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][ValidateSet('hevc', 'av1')][string]$Codec
    )
    $encoder = if ($Codec -eq 'hevc') { 'hevc_nvenc' } else { 'av1_nvenc' }
    return Test-VesHwEncoderAvailable -FfmpegPath $FfmpegPath -EncoderName $encoder
}

function Test-VesQsvAvailable {
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [ValidateSet('hevc', 'h264', 'av1')][string]$Codec = 'hevc'
    )
    $encoder = "${Codec}_qsv"
    return Test-VesHwEncoderAvailable -FfmpegPath $FfmpegPath -EncoderName $encoder
}

function Test-VesAmfAvailable {
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [ValidateSet('hevc', 'h264', 'av1')][string]$Codec = 'hevc'
    )
    $encoder = "${Codec}_amf"
    return Test-VesHwEncoderAvailable -FfmpegPath $FfmpegPath -EncoderName $encoder
}

function Resolve-VesHwEncodePriority {
    <#
    .SYNOPSIS
    Port of _resolve_hw_encode_priority(): fixed precedence
    NVIDIA > Intel QSV > AMD VCE > software, with override switches
    matching bash's --prefer-intel-qsv / CONVERT_PREFER_AMD_VCE.
    Returns one of: 'nvenc', 'qsv', 'amf', 'software'.
    #>
    param(
        [bool]$NvencAvailable,
        [bool]$QsvAvailable,
        [bool]$AmfAvailable,
        [switch]$PreferIntelQsv,
        [switch]$PreferAmdVce
    )
    if ($PreferIntelQsv -and $QsvAvailable) { return 'qsv' }
    if ($PreferAmdVce -and $AmfAvailable) { return 'amf' }
    if ($NvencAvailable) { return 'nvenc' }
    if ($QsvAvailable) { return 'qsv' }
    if ($AmfAvailable) { return 'amf' }
    return 'software'
}

function Test-VesFfmpegHasLibPlacebo {
    <#
    .SYNOPSIS
    Port of bash's ffmpeg_lists_filter "libplacebo" (see FF_HAS_LIBPLACEBO
    in ves-hwdetect.sh) -- a one-time capability probe so Dolby Vision
    Profile 5 sources get properly converted via libplacebo when the
    ffmpeg build actually supports it, instead of always being treated
    as unsupported. convert.ps1 never called this at all before (team
    review, 2026-08-06) -- Build-VesFfmpegVideoArgs's -FfmpegHasLibPlacebo
    param always silently defaulted to $false, so every DoVi P5 source
    was routed to the human-review path even on builds (e.g. PRINCE's)
    that do have libplacebo compiled in.
    #>
    param([Parameter(Mandatory)][string]$FfmpegPath)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegPath
    foreach ($a in @('-hide_banner', '-filters')) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(30000)) {
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit()
            return $false
        }
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        return ($stdoutTask.Result -match '(?m)^\s*\S+\s+libplacebo\s+')
    } catch {
        return $false
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

Export-ModuleMember -Function Test-VesHwEncoderAvailable, Test-VesNvencAvailable, `
    Test-VesQsvAvailable, Test-VesAmfAvailable, Resolve-VesHwEncodePriority, Test-VesFfmpegHasLibPlacebo
