# Windows port of the bash script's run_tracked_encoder/_run_capturing_stderr
# (convert-v5.0.33S.sh lines ~2817-2872). A real encode is intentionally
# UNBOUND (no timeout) -- this is not Invoke-VesWithTimeoutRetry, which is
# validation-probe-only.
#
# Stderr capture is a synchronous polling read loop (2026-08-20), not
# Register-ObjectEvent (proven unreliable in this runtime, see
# VesTimeoutRetry.psm1) and not end-of-run ReadToEndAsync (the prior
# design here, which lost 100% of a crashed process's diagnostic output
# twice in a row on PRINCE: a hard access-violation crash (0xc0000005)
# closes the process's stdio pipes without our side ever having read the
# already-written bytes back, so ReadToEndAsync's single post-WaitForExit
# .Result came back empty both times -- there was no way to tell whether
# the encoder ever printed anything before it died). This loop calls
# ReadLineAsync() against the child's stderr, waits on each line with a
# bounded timeout so it can also poll $proc.HasExited, and appends+flushes
# every line to $ErrorLogPath as it arrives -- so whatever the process did
# manage to write before a hard crash is already durably on disk, not
# sitting in an in-memory buffer that only gets persisted on a clean exit.

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

    # Opened once, up front, so a mid-encode crash still leaves whatever
    # was already read on disk. Best-effort per-line write, matching the
    # same non-fatal-diagnostic-write reasoning as the try/catch below
    # (see the 2026-08-12 RANDYJ incident this whole pattern traces back
    # to: a failed diagnostic write must never take down a job whose real
    # encode work already succeeded/is still running).
    $logStream = $null
    try {
        $logStream = New-Object System.IO.StreamWriter($ErrorLogPath, $false)
        $logStream.AutoFlush = $true
    } catch {
        Write-Warning "Could not open stderr sidecar log for live capture (non-fatal, continuing without it): $ErrorLogPath -- $_"
    }

    try {
        $proc.Start() | Out-Null

        $stdoutBuf = New-Object System.Text.StringBuilder
        $stderrBuf = New-Object System.Text.StringBuilder
        $stdoutTask = $proc.StandardOutput.ReadLineAsync()
        $stderrTask = $proc.StandardError.ReadLineAsync()

        while ($true) {
            $pending = @($stdoutTask, $stderrTask) | Where-Object { $_ }
            if ($pending.Count -eq 0) {
                if ($proc.HasExited) { break }
                Start-Sleep -Milliseconds 200
                continue
            }
            [System.Threading.Tasks.Task]::WaitAny($pending, 500) | Out-Null

            if ($stdoutTask -and $stdoutTask.IsCompleted) {
                $line = $stdoutTask.Result
                if ($null -eq $line) {
                    $stdoutTask = $null
                } else {
                    [void]$stdoutBuf.AppendLine($line)
                    $stdoutTask = $proc.StandardOutput.ReadLineAsync()
                }
            }
            if ($stderrTask -and $stderrTask.IsCompleted) {
                $line = $stderrTask.Result
                if ($null -eq $line) {
                    $stderrTask = $null
                } else {
                    [void]$stderrBuf.AppendLine($line)
                    if ($logStream) {
                        try { $logStream.WriteLine($line) } catch { }
                    }
                    $stderrTask = $proc.StandardError.ReadLineAsync()
                }
            }
            if (-not $stdoutTask -and -not $stderrTask -and $proc.HasExited) { break }
        }
        $proc.WaitForExit()

        return [PSCustomObject]@{
            ExitCode  = $proc.ExitCode
            StdOut    = $stdoutBuf.ToString()
            StdErr    = $stderrBuf.ToString()
            ProcessId = $proc.Id
        }
    } finally {
        if ($logStream) { $logStream.Dispose() }
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
