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
            Set-Content -Path $ErrorLogPath -Value $stderrContent -NoNewline
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

Export-ModuleMember -Function Invoke-VesTrackedProcess
