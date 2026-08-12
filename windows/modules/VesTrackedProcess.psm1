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

Export-ModuleMember -Function Invoke-VesTrackedProcess
