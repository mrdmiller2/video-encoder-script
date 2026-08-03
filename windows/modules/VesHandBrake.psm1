# Windows port of convert-v5.0.33S.sh's HandBrake invocation
# (run_handbrake_with_progress/build_handbrake_args, lines ~2613-9512).
# Deliberately simpler than the bash version: none of the WSL-vs-native
# path-translation logic (_wsl_windows_handbrake_candidates,
# _handbrake_translate_argv) applies here -- this is already native
# Windows, so there's no Linux-path-to-Windows-path translation to do.
# HandBrakeCLI's official Windows build needs no special discovery
# beyond a normal PATH/known-location lookup (ROADMAP.md already noted
# this needs "zero porting work" for the binary itself).

if (-not (Get-Module -Name VesTrackedProcess)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTrackedProcess.psm1') -Force
}
if (-not (Get-Module -Name VesSubtitleFilter)) {
    Import-Module (Join-Path $PSScriptRoot 'VesSubtitleFilter.psm1') -Force
}
if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}

# Per-profile NVENC AV1 CQ constants -- tuning values, not logic, ported
# verbatim from bash lines ~531-560.
$script:VesNvencAv1CqByProfile = @{
    movies  = 24
    anime   = 30
    mtv     = 24
    wanime  = 24
    vintage = 24
}

function Get-VesHandBrakeCli {
    <#
    .SYNOPSIS
    Locates HandBrakeCLI.exe: explicit -Path override, else PATH lookup,
    else the common WinGet-managed install location.
    #>
    param([string]$PathOverride)
    if ($PathOverride -and (Test-Path $PathOverride)) { return $PathOverride }
    $onPath = Get-Command 'HandBrakeCLI.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $wingetLink = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\HandBrakeCLI.exe'
    if (Test-Path $wingetLink) { return $wingetLink }
    return $null
}

function Test-VesHandBrakeEncoderAvailable {
    <#
    .SYNOPSIS
    Real-encode probe through HandBrakeCLI itself (not ffmpeg) --
    per team design review (2026-08-03), HandBrake and ffmpeg can
    disagree on whether a given hardware encoder actually initializes,
    so the HandBrake-invocation path must probe through HandBrake, not
    assume VesHwDetect.psm1's ffmpeg-based probe result carries over.
    Success requires exit 0 AND non-empty valid output, never
    returncode alone.
    #>
    param(
        [Parameter(Mandatory)][string]$HandBrakeCliPath,
        [Parameter(Mandatory)][string]$SourceForProbe,
        [Parameter(Mandatory)][string]$Encoder,
        [int]$TimeoutSeconds = 60
    )
    if (-not (Test-Path $SourceForProbe)) { return $false }
    $probeOut = Join-Path ([System.IO.Path]::GetTempPath()) "ves-hbprobe-$Encoder-$PID.mkv"
    try {
        # A bounded PROBE, not a real encode -- Invoke-VesWithTimeoutRetry
        # (timeout-capable) is the right tool here, not
        # Invoke-VesTrackedProcess (deliberately unbounded, for real
        # encodes only, per its own module header).
        $args = @('-i', $SourceForProbe, '-o', $probeOut, '-f', 'mkv', '-e', $Encoder,
            '--start-at', 'seconds:0', '--stop-at', 'seconds:1')
        $result = Invoke-VesWithTimeoutRetry -FilePath $HandBrakeCliPath -ArgumentList $args -TimeoutSeconds $TimeoutSeconds -MaxRetries 0
        if ($result.TimedOut -or $result.ExitCode -ne 0) { return $false }
        return ((Test-Path $probeOut) -and (Get-Item $probeOut -Force).Length -gt 0)
    } catch {
        return $false
    } finally {
        Remove-Item $probeOut -Force -ErrorAction SilentlyContinue
    }
}

function Get-VesNvencAv1Cq {
    param([Parameter(Mandatory)][string]$Profile)
    if ($script:VesNvencAv1CqByProfile.ContainsKey($Profile)) {
        return $script:VesNvencAv1CqByProfile[$Profile]
    }
    return 24
}

function Build-VesHandBrakeArgs {
    <#
    .SYNOPSIS
    Port of build_handbrake_args(): -i/-o/-f mkv/-m/-O/-e/-q, real-
    subtitle-only handling (via VesSubtitleFilter's already-ported
    tri-state logic, not reimplemented here), optional disc title,
    video filters, audio args, encoder-tune, upscale target.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Encoder,
        [Parameter(Mandatory)][double]$Quality,
        [string]$EncoderPreset,
        [string]$EncoderTune,
        [string]$Encopts,
        [int]$DiscTitle,
        [string[]]$VideoFilterArgs = @(),
        [string[]]$AudioArgs = @('-E', 'opus', '-B', '112'),
        [switch]$HasRealSubtitles
    )
    # --json is required for HandBrakeCLI to emit parseable `Progress: {...}`
    # lines at all -- without it, progress is human-readable text, not
    # JSON (confirmed via --help and a real test on ELVIS, 2026-08-03:
    # a real encode succeeded but produced zero parseable progress lines
    # until this flag was added).
    $args = @('-i', $Source, '-o', $Destination, '-f', 'mkv', '-m', '-O', '--json', '-e', $Encoder, '-q', "$Quality")
    if ($DiscTitle) { $args += @('-t', "$DiscTitle") }
    if ($EncoderPreset) { $args += @('--encoder-preset', $EncoderPreset) }
    if ($EncoderTune) { $args += @('--encoder-tune', $EncoderTune) }
    if ($Encopts) { $args += @('--encopts', $Encopts) }
    $args += $VideoFilterArgs
    $args += $AudioArgs
    if ($HasRealSubtitles) {
        $args += @('--all-subtitles', '--subtitle-burned=none', '--subtitle-default=none')
    } else {
        $args += @('--subtitle-burned=none')
    }
    return $args
}

function Invoke-VesHandBrakeWithProgress {
    <#
    .SYNOPSIS
    Port of run_handbrake_with_progress(): runs HandBrakeCLI, parsing
    `Progress: {...}` JSON lines from its output as they arrive. Uses
    Invoke-VesTrackedProcess for PID tracking (orphan-reaper
    identification) same as the ffmpeg path in VesTwoStageEncode.psm1.

    .PARAMETER OnProgress
    Optional scriptblock invoked with the parsed progress object per
    line -- live progress requires reading output incrementally rather
    than after-the-fact (Invoke-VesTrackedProcess buffers until exit;
    live progress plumbing is a known follow-up, not yet built here --
    see ROADMAP.md).
    #>
    param(
        [Parameter(Mandatory)][string]$HandBrakeCliPath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$ErrorLogPath
    )
    $result = Invoke-VesTrackedProcess -FilePath $HandBrakeCliPath -ArgumentList $ArgumentList -ErrorLogPath $ErrorLogPath
    $progressLines = @()
    if ($result.StdOut) {
        $progressLines = $result.StdOut -split "`r?`n" | Where-Object { $_ -match '^Progress: ' }
    }
    return [PSCustomObject]@{
        ExitCode      = $result.ExitCode
        ProgressLines = $progressLines
        StdOut        = $result.StdOut
        StdErr        = $result.StdErr
    }
}

Export-ModuleMember -Function Get-VesHandBrakeCli, Test-VesHandBrakeEncoderAvailable, `
    Get-VesNvencAv1Cq, Build-VesHandBrakeArgs, Invoke-VesHandBrakeWithProgress
