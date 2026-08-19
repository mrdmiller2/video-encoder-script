# Windows port of the bash script's run_tracked_encoder/_run_capturing_stderr
# (convert-v5.0.33S.sh lines ~2817-2872). A real encode is intentionally
# UNBOUND (no timeout) -- this is not Invoke-VesWithTimeoutRetry, which is
# validation-probe-only.
#
# Deliberate deviation from the bash version, not an oversight: bash's
# _run_capturing_stderr streams stderr to the log file live (via
# `tee -a` on a process-substitution fd), so a crash mid-encode still
# leaves a partial trail. This port captures stderr via .NET Task-based
# ReadToEndAsync() and writes it out once the process exits, per the same
# reasoning documented in VesTimeoutRetry.psm1: Register-ObjectEvent-based
# "live" capture depends on PowerShell's event queue being pumped, which a
# synchronous WaitForExit() doesn't do, and was already proven to silently
# drop output in this exact runtime. A reliable end-of-run capture beats an
# unreliable live one. If genuinely live capture becomes a real requirement
# (e.g. a future heartbeat/kill-on-hang mechanism needs to inspect stderr
# WHILE the process is still running), revisit with a dedicated polling
# read loop instead of re-attempting the event-based approach.

function Invoke-VesTrackedProcess {
    <#
    .SYNOPSIS
    Launches a long-running process (an actual encode/remux pass, not a
    bounded validation probe). Returns exit code, captured stdout/stderr,
    and the process ID for caller-side tracking (future heartbeat/kill
    support, Phase 3).
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$ErrorLogPath
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
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

        $proc.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))

        $stderrContent = $stderrTask.Result
        if ($stderrContent) {
            # Best-effort only (2026-08-12 fix): this is a diagnostic
            # sidecar, not part of the encode's success/failure contract --
            # every caller already treats these stderr logs as non-fatal
            # (see VesTwoStageEncode.psm1's comment on this exact point).
            # But a bare Set-Content throws on any write failure, and an
            # uncaught exception here propagates out of this function
            # entirely, past the caller's try/finally (finally does not
            # swallow it), and up to the job-loop's own try/catch, which
            # aborts the WHOLE job -- discarding an already-fully-completed
            # real encode over nothing but a diagnostic-log write failure.
            # Found via a real production incident on RANDYJ (ex-GruntBox2):
            # every one of 36 jobs in an overnight Orville batch (~40+ hours
            # of real encoding) threw "Access to the path ... stderr.log is
            # denied" and was discarded with zero output, because icacls
            # couldn't widen this particular NAS share's ACL (Set-
            # VesEveryoneReadWrite's own self-heal also failed there, a
            # separate NAS-permission issue not fixed here) and every
            # resulting Set-Content threw. Source files were never touched
            # (this write is output-side only), but the wasted compute was
            # total. A failed diagnostic write should degrade to a warning,
            # never take down the job whose real work already succeeded.
            try {
                Set-Content -Path $ErrorLogPath -Value $stderrContent -NoNewline
            } catch {
                Write-Warning "Could not write stderr sidecar log (non-fatal, continuing): $ErrorLogPath -- $_"
            }
        }

        return [PSCustomObject]@{
            ExitCode  = $proc.ExitCode
            StdOut    = $stdoutTask.Result
            StdErr    = $stderrContent
            ProcessId = $proc.Id
        }
    } finally {
        $proc.Dispose()
    }
}

# Parses ffmpeg's own -progress <file> output (2026-08-19) -- a real fix
# for the exact gap the comment at the top of this file already flagged:
# Invoke-VesTrackedProcess's ReadToEndAsync-based stderr capture never
# exposes anything until the process exits, so -stats alone (already
# passed on both encode stages) never gave live progress on this
# platform. ffmpeg's -progress writes repeated frame=/out_time_ms=/
# speed=/progress= key-value blocks directly to its own file via ffmpeg's
# own I/O -- entirely independent of how the parent process's stdout/
# stderr are captured, so this works without touching that architecture
# at all (a dedicated polling read against a file ffmpeg itself keeps
# writing, exactly what the top-of-file comment called for instead of
# re-attempting event-based stream capture).
#
# Reads the LAST *complete* block (one ending in a "progress=" line) so a
# block ffmpeg is still mid-write on is never returned half-parsed. Also
# reports StaleSeconds (time since the file was last written) -- this is
# the actual "is it stuck" signal: CPU usage alone can't distinguish a
# genuinely slow encode (file keeps updating, just slowly) from a hung
# one (file stops updating entirely while the process is still alive).
function Get-VesFfmpegProgress {
    param(
        [Parameter(Mandatory)][string]$ProgressFile
    )
    if (-not (Test-Path -LiteralPath $ProgressFile)) {
        return [PSCustomObject]@{
            Exists       = $false
            Frame        = $null
            FpsValue     = $null
            OutTimeMs    = $null
            OutTime      = $null
            SpeedValue   = $null
            BitrateKbps  = $null
            Progress     = $null
            LastWrite    = $null
            StaleSeconds = $null
        }
    }
    $lastWrite = (Get-Item -LiteralPath $ProgressFile).LastWriteTime
    $staleSeconds = [int]((Get-Date) - $lastWrite).TotalSeconds

    # Read with FileShare.ReadWrite -- ffmpeg holds this file open for
    # writing the whole encode, and a plain Get-Content can throw "file in
    # use" against a locked handle on Windows.
    $lines = $null
    try {
        $stream = [System.IO.File]::Open($ProgressFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream)
        $lines = $reader.ReadToEnd() -split "`n"
        $reader.Close()
        $stream.Close()
    } catch {
        return [PSCustomObject]@{
            Exists = $true; Frame = $null; FpsValue = $null; OutTimeMs = $null
            OutTime = $null; SpeedValue = $null; BitrateKbps = $null; Progress = $null
            LastWrite = $lastWrite; StaleSeconds = $staleSeconds
        }
    }

    # Split into blocks on each "progress=..." terminator line, keep the
    # last COMPLETE one (a trailing partial block with no terminator yet
    # is dropped, not half-parsed).
    $blocks = @()
    $current = [ordered]@{}
    foreach ($line in $lines) {
        $line = $line.Trim()
        if (-not $line -or $line -notmatch '=') { continue }
        $parts = $line.Split('=', 2)
        $key = $parts[0]; $val = $parts[1]
        $current[$key] = $val
        if ($key -eq 'progress') {
            $blocks += , $current
            $current = [ordered]@{}
        }
    }
    if ($blocks.Count -eq 0) {
        return [PSCustomObject]@{
            Exists = $true; Frame = $null; FpsValue = $null; OutTimeMs = $null
            OutTime = $null; SpeedValue = $null; BitrateKbps = $null; Progress = $null
            LastWrite = $lastWrite; StaleSeconds = $staleSeconds
        }
    }
    $b = $blocks[-1]
    $outTimeMs = $null
    if ($b.Contains('out_time_ms') -and $b['out_time_ms'] -match '^\d+$') { $outTimeMs = [int64]$b['out_time_ms'] }
    $outTime = $null
    if ($outTimeMs) { $outTime = [TimeSpan]::FromMilliseconds($outTimeMs / 1000.0).ToString() }
    $speedVal = $null
    if ($b.Contains('speed') -and $b['speed'] -match '^([\d.]+)x?$') { $speedVal = [double]$Matches[1] }
    $bitrateKbps = $null
    if ($b.Contains('bitrate') -and $b['bitrate'] -match '^([\d.]+)kbits/s$') { $bitrateKbps = [double]$Matches[1] }

    return [PSCustomObject]@{
        Exists       = $true
        Frame        = if ($b.Contains('frame')) { $b['frame'] } else { $null }
        FpsValue     = if ($b.Contains('fps')) { $b['fps'] } else { $null }
        OutTimeMs    = $outTimeMs
        OutTime      = $outTime
        SpeedValue   = $speedVal
        BitrateKbps  = $bitrateKbps
        Progress     = if ($b.Contains('progress')) { $b['progress'] } else { $null }
        LastWrite    = $lastWrite
        StaleSeconds = $staleSeconds
    }
}

Export-ModuleMember -Function Invoke-VesTrackedProcess, Get-VesFfmpegProgress
