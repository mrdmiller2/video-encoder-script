# Windows equivalent of the bash fleet's `systemd-run --unit=...
# --uid=worker` detached-execution pattern (ROADMAP.md item 4,
# "Process/execution model"). Used constantly on the Linux side for
# real fleet jobs that must survive the SSH session that launched them.
#
# Found via direct testing (2026-08-02): a process started with
# Start-Process over an SSH-invoked PowerShell session gets KILLED when
# that SSH connection closes -- confirmed empirically (a real encode
# job's Start-Process launch showed 0 bytes ever written to its
# redirected output logs and no process alive moments after the SSH
# command returned, despite the exact same script running correctly
# and producing real output when run in the foreground). This is
# Windows OpenSSH tying spawned child processes to the SSH session's
# own Job Object, which tears down its members when the session ends --
# there is no simple flag to opt out of this from the client side.
#
# A one-shot Scheduled Task is NOT tied to the SSH session's Job Object
# and survives session teardown -- confirmed empirically the same
# session (a real ~94-minute-source encode job launched this way kept
# running, verified via live ffmpeg/ab-av1 process CPU time, well after
# the launching SSH connection had already closed). This is the
# Windows equivalent of systemd-run for this port going forward -- any
# future orchestration script that launches a real encode job on a
# remote Windows fleet member over SSH MUST use this pattern, not
# Start-Process, or the job silently dies the moment the SSH command
# that launched it returns.

function Start-VesDetachedProcess {
    <#
    .SYNOPSIS
    Launches $FilePath/$ArgumentList as a genuinely detached process via
    a one-shot Scheduled Task -- survives the launching SSH session
    closing, unlike Start-Process. Returns the task name for use with
    Get-VesDetachedProcessStatus/Stop-VesDetachedProcess.

    .PARAMETER TaskName
    Must be unique per in-flight job -- reusing a name while a prior
    task of that name is still running will unregister/replace it.
    Caller's responsibility to generate a unique name (e.g. include the
    source filename or a timestamp).

    .PARAMETER UserName
    Domain\user to run the task as (e.g. 'mce\docm'). Required because
    a Scheduled Task's own logon is a separate identity from the SSH
    session's -- see the module-level comment on why Start-Process's
    SSH-session-inherited identity isn't available here anyway.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$ArgumentString,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password,
        [int]$StartDelaySeconds = 3
    )
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute $FilePath -Argument $ArgumentString
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds($StartDelaySeconds)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -User $UserName -Password $Password -RunLevel Highest -Force | Out-Null

    return $TaskName
}

function Get-VesDetachedProcessStatus {
    <#
    .SYNOPSIS
    Returns an object describing whether the detached job is still
    running. LastTaskResult 267009 (0x41301, SCHED_S_TASK_RUNNING) means
    still in flight -- any other value means it has finished (0 =
    success; anything else is the process's own exit code or a
    scheduler-level error, both worth surfacing to the caller as-is).
    #>
    param([Parameter(Mandatory)][string]$TaskName)
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $info) {
        return [PSCustomObject]@{ Found = $false; Running = $false; LastTaskResult = $null }
    }
    $running = ($info.LastTaskResult -eq 267009)
    return [PSCustomObject]@{
        Found          = $true
        Running        = $running
        LastTaskResult = $info.LastTaskResult
        LastRunTime    = $info.LastRunTime
    }
}

function Wait-VesDetachedProcess {
    <#
    .SYNOPSIS
    Polls Get-VesDetachedProcessStatus until the task is no longer
    running or -TimeoutSeconds elapses. Returns the final status object;
    caller should check .Running to distinguish a real finish from a
    timeout.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [int]$PollIntervalSeconds = 15,
        [int]$TimeoutSeconds = 0
    )
    $waited = 0
    while ($true) {
        $status = Get-VesDetachedProcessStatus -TaskName $TaskName
        if (-not $status.Found -or -not $status.Running) { return $status }
        if ($TimeoutSeconds -gt 0 -and $waited -ge $TimeoutSeconds) { return $status }
        Start-Sleep -Seconds $PollIntervalSeconds
        $waited += $PollIntervalSeconds
    }
}

function Stop-VesDetachedProcess {
    <#
    .SYNOPSIS
    Stops a running detached job (if any) and unregisters its Scheduled
    Task entry. Does NOT kill child processes the task itself spawned
    (e.g. a real ffmpeg encode) -- Scheduled Tasks don't track process
    trees the way a Job Object does; callers that need to kill an
    in-flight encode must track and kill that PID separately (see
    VesTrackedProcess.psm1's ProcessId return value).
    #>
    param([Parameter(Mandatory)][string]$TaskName)
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Start-VesDetachedProcess, Get-VesDetachedProcessStatus, Wait-VesDetachedProcess, Stop-VesDetachedProcess
