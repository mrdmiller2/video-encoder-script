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

function ConvertFrom-VesHandBrakeJsonBlock {
    <#
    .SYNOPSIS
    Parses an already-accumulated, brace-balanced multi-line JSON block
    (see Invoke-VesHandBrakeWithProgress's accumulation loop -- real
    HandBrake --json output spans multiple lines per block, e.g.
    "Progress: {" then indented fields then a closing "}" on its own
    line, confirmed via a real captured run, 2026-08-03 -- an initial
    single-line-JSON assumption was wrong). Extracts the same fields
    bash's awk reader does, tolerating nesting (HandBrake nests
    Progress/ETASeconds under a "Working"/"WorkDone" sub-object
    depending on State) by searching the whole parsed tree rather than
    assuming a fixed shape.
    #>
    param([Parameter(Mandatory)][string]$JsonText)
    try {
        $obj = $JsonText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    $state = $obj.State
    $detail = switch ($state) {
        'WORKING' { $obj.Working }
        'WORKDONE' { $obj.WorkDone }
        default { $obj }
    }
    return [PSCustomObject]@{
        State      = $state
        Percent    = if ($detail -and $null -ne $detail.Progress) { [double]$detail.Progress * 100 } else { $null }
        EtaSeconds = if ($detail -and $detail.ETASeconds) { [int]$detail.ETASeconds } else { $null }
        ErrorCode  = if ($detail -and $null -ne $detail.Error) { [int]$detail.Error } else { $null }
    }
}

function Invoke-VesHandBrakeWithProgress {
    <#
    .SYNOPSIS
    Port of run_handbrake_with_progress(): runs HandBrakeCLI, parsing
    `Progress: {...}` JSON lines AS THEY ARRIVE, not after the process
    exits. Confirmed via a real empirical spike (2026-08-03, see
    DESIGN-remaining6features.md's "Spike 2") that a plain synchronous
    $reader.ReadLine() loop delivers output incrementally on this
    runtime -- no FIFO, no separate reader process/thread needed, unlike
    bash's mkfifo+awk mechanism. Deliberately does NOT use
    Invoke-VesTrackedProcess here (that wrapper's ReadToEndAsync-based
    design is specifically buffered-until-exit, the opposite of what
    this function needs) -- drives System.Diagnostics.Process directly.

    Hard rule, not just an implementation detail: the stderr
    ReadToEndAsync() task started below must NEVER be awaited
    (.Result/.Wait()) until AFTER the stdout ReadLine() loop has fully
    finished. Awaiting it mid-loop would block on stderr completing
    (i.e. the process exiting) before stdout is ever read again,
    recreating the exact full-pipe deadlock this design exists to avoid
    -- flagged explicitly during team review after Spike 2's own script
    got this right only implicitly.

    .PARAMETER OnProgress
    Optional scriptblock invoked with each parsed Progress object
    (State/Percent/EtaSeconds/ErrorCode) as it arrives. Left to the
    caller to decide how to display it (bash hardcodes a \r-terminated
    console line; this function doesn't assume that's always wanted).
    #>
    param(
        [Parameter(Mandatory)][string]$HandBrakeCliPath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$ErrorLogPath,
        [scriptblock]$OnProgress
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HandBrakeCliPath
    # --json is required for parseable Progress lines at all -- confirmed
    # via a real test (2026-08-03) that omitting it produces human-
    # readable text instead. Build-VesHandBrakeArgs already includes it
    # in its own base args -- only add it here if the caller's
    # ArgumentList doesn't already have it, so it's never duplicated.
    $argsWithJson = @($ArgumentList)
    if ($argsWithJson -notcontains '--json') { $argsWithJson += '--json' }
    foreach ($a in $argsWithJson) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $lastState = $null
    $lastErrorCode = 0

    try {
        $proc.Start() | Out-Null
        # Started but NOT awaited here -- see this function's hard rule
        # above.
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $reader = $proc.StandardOutput
        $blockLines = $null
        $braceDepth = 0
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            if ($null -eq $blockLines) {
                # Only "Progress: {" (and other top-level "Xxx: {" blocks
                # like "Version: {") start a JSON block we care about
                # accumulating; anything else is a plain human log line.
                if ($line -match '^\w+: \{') {
                    $blockLines = New-Object System.Collections.Generic.List[string]
                    $jsonStart = $line.IndexOf('{')
                    $openingJson = $line.Substring($jsonStart)
                    $blockLines.Add($openingJson)
                    $braceDepth = ([regex]::Matches($openingJson, '\{')).Count - ([regex]::Matches($openingJson, '\}')).Count
                    $isProgressBlock = $line -match '^Progress: '
                    if ($braceDepth -le 0 -and $isProgressBlock) {
                        $progress = ConvertFrom-VesHandBrakeJsonBlock -JsonText ($blockLines -join "`n")
                        $blockLines = $null
                        if ($progress) {
                            $lastState = $progress.State
                            if ($null -ne $progress.ErrorCode) { $lastErrorCode = $progress.ErrorCode }
                            if ($OnProgress) { & $OnProgress $progress }
                        }
                    } elseif (-not $isProgressBlock) {
                        $blockLines = $null
                    }
                }
                continue
            }

            $blockLines.Add($line)
            $braceDepth += ([regex]::Matches($line, '\{')).Count - ([regex]::Matches($line, '\}')).Count
            if ($braceDepth -le 0) {
                $progress = ConvertFrom-VesHandBrakeJsonBlock -JsonText ($blockLines -join "`n")
                $blockLines = $null
                if ($progress) {
                    $lastState = $progress.State
                    if ($null -ne $progress.ErrorCode) { $lastErrorCode = $progress.ErrorCode }
                    if ($OnProgress) { & $OnProgress $progress }
                }
            }
        }

        $proc.WaitForExit()
        # Safe to await now -- the stdout loop above has already hit EOF.
        $stderrContent = $stderrTask.Result
        if ($stderrContent) {
            # Best-effort only -- same fix as VesTrackedProcess.psm1's
            # Invoke-VesTrackedProcess (2026-08-12): this is a diagnostic
            # sidecar, and a bare Set-Content throwing here would otherwise
            # take down the whole job over a failed diagnostic write, not
            # the disc-source encode/rip work that already succeeded.
            try {
                Set-Content -Path $ErrorLogPath -Value $stderrContent -NoNewline
            } catch {
                Write-Warning "Could not write stderr sidecar log (non-fatal, continuing): $ErrorLogPath -- $_"
            }
        }

        return [PSCustomObject]@{
            ExitCode      = $proc.ExitCode
            Success       = ($proc.ExitCode -eq 0 -and $lastErrorCode -eq 0)
            LastState     = $lastState
            HandBrakeError = $lastErrorCode
            ProcessId     = $proc.Id
        }
    } finally {
        $proc.Dispose()
    }
}

Export-ModuleMember -Function Get-VesHandBrakeCli, Test-VesHandBrakeEncoderAvailable, `
    Get-VesNvencAv1Cq, Build-VesHandBrakeArgs, ConvertFrom-VesHandBrakeJsonBlock, Invoke-VesHandBrakeWithProgress
