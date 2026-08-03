# Windows port of the bash script's _run_timeout_retry wrapper
# (convert-v5.0.33S.sh, run_ffprobe/run_ffmpeg_validation call sites).
# Retries only on a genuine timeout, never on a real process failure --
# a bad file won't become good on a second attempt, but a slow NAS
# moment often clears (see ROADMAP.md item 4, pipefail-dependent idioms).

function Invoke-VesWithTimeoutRetry {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [int]$MaxRetries = 2
    )

    # Two Windows-specific pitfalls found via direct testing on ELVIS
    # (2026-08-02), both confirmed by comparing against a manual
    # ffprobe invocation that was known-good:
    #   1. Start-Process -PassThru unreliably reports .ExitCode for
    #      short-lived redirected-output processes -- reads blank even
    #      after WaitForExit() returns true. Fixed by driving
    #      System.Diagnostics.Process directly.
    #   2. Register-ObjectEvent-based async stream reading depends on
    #      PowerShell's own event queue being pumped, which a tight
    #      synchronous $proc.WaitForExit() call doesn't do -- output
    #      silently read back empty despite the process genuinely
    #      producing it. Fixed by using .NET Task-based
    #      ReadToEndAsync() instead, which has no PowerShell-event-loop
    #      dependency, and racing it against WaitForExit via
    #      [Task]::WaitAll with the same timeout.
    $attempt = 0
    while ($true) {
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

            $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
            if (-not $finished) {
                try { $proc.Kill($true) } catch { }
                $proc.WaitForExit()
                # Process is dead, so the redirected streams have hit
                # EOF -- these tasks now complete immediately.
                [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
                $attempt++
                if ($attempt -gt $MaxRetries) {
                    return [PSCustomObject]@{
                        ExitCode = 124
                        StdOut   = $stdoutTask.Result
                        StdErr   = $stderrTask.Result
                        TimedOut = $true
                    }
                }
                continue
            }

            [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))

            return [PSCustomObject]@{
                ExitCode = $proc.ExitCode
                StdOut   = $stdoutTask.Result
                StdErr   = $stderrTask.Result
                TimedOut = $false
            }
        } finally {
            $proc.Dispose()
        }
    }
}

Export-ModuleMember -Function Invoke-VesWithTimeoutRetry
