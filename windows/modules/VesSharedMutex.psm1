# Windows port of convert-v5.0.33S.sh's shared cross-host mutex
# (_shared_mutex_acquire/_shared_mutex_release, lines ~5098-5173) --
# short-hold locking for a genuinely fleet-shared file (the done-log)
# that multiple machines (Linux, WSL2, macOS, and now Windows) may
# write to concurrently over the same NAS.
#
# Deliberate Windows deviation from the bash version, not an oversight:
# bash uses mkdir as the atomic acquire primitive (mkdir is atomic even
# across NFS clients with different lock-manager implementations).
# Confirmed via direct testing against the real production NAS
# (2026-08-02, see [[project_elvis_nas_smb_quirks_2026_08_02]] in
# memory) that this NAS's Samba config gives freshly-created
# directories a broken ACL that even the creating session can't write
# into -- which would break mkdir-based locking immediately (acquire
# would "succeed" by creating the lock directory, then fail writing
# the ownership token file inside it). Files created directly in an
# already-existing directory don't have this problem (proven
# repeatedly). This port therefore uses atomic exclusive FILE creation
# ([System.IO.File]::Open with FileMode.CreateNew, which throws if the
# file already exists -- the same all-or-nothing guarantee mkdir gives
# bash) as the lock primitive instead of a directory.

function Get-VesSharedMutexAge {
    param([Parameter(Mandatory)][string]$LockPath)
    try {
        $mtime = (Get-Item -LiteralPath $LockPath -Force -ErrorAction Stop).LastWriteTimeUtc
        return [int]((Get-Date).ToUniversalTime() - $mtime).TotalSeconds
    } catch {
        return -1
    }
}

function Enter-VesSharedMutex {
    <#
    .SYNOPSIS
    Port of _shared_mutex_acquire(). Blocks until the lock file is
    created, reclaiming it if stale (by wall-clock age, not a spin
    count -- same reasoning as the bash version: a real NAS stall
    inside someone else's critical section is plausible and must not
    be reclaimed out from under them just because we've been waiting a
    while). Returns an ownership token the caller must pass to
    Exit-VesSharedMutex.
    #>
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [int]$StaleSeconds = 90
    )
    # Ownership token, same reasoning as the bash version: a stale
    # ex-holder that was reclaimed while still slowly finishing its
    # critical section must not blindly delete whatever lock file
    # exists by the time it gets to Exit-VesSharedMutex -- that could
    # now belong to whoever legitimately won the reclaim.
    $myToken = "$env:COMPUTERNAME.$PID.$(Get-Random).$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $tokenBytes = [System.Text.Encoding]::UTF8.GetBytes($myToken)

    $waited = 0
    while ($true) {
        try {
            # Write the token directly to the just-opened handle rather
            # than closing and reopening via a separate WriteAllText --
            # found via direct testing (2026-08-02) that reopening a
            # file for write immediately after CreateNew+Close fails
            # with "Access is denied" on this NAS (an SMB oplock-break
            # timing issue), even though the file itself exists and is
            # otherwise writable moments later.
            $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            $fs.Write($tokenBytes, 0, $tokenBytes.Length)
            $fs.Close()
            break
        } catch [System.IO.IOException] {
            $waited++
            if ($waited % 20 -eq 0) {
                $age = Get-VesSharedMutexAge -LockPath $LockPath
                if ($age -ge $StaleSeconds) {
                    # Reclaim via rename-then-delete, matching the bash
                    # version's reasoning: renaming the lock file to a
                    # unique name is a single atomic operation, so exactly
                    # one racing waiter wins it; the loser's rename simply
                    # fails and it loops back to waiting instead of
                    # destroying the winner's brand-new lock.
                    $reclaimName = "$LockPath.reclaim.$env:COMPUTERNAME.$PID.$(Get-Random)"
                    try {
                        [System.IO.File]::Move($LockPath, $reclaimName)
                        [System.IO.File]::Delete($reclaimName)
                    } catch { }
                }
            }
            Start-Sleep -Milliseconds 100
        }
    }

    return $myToken
}

function Exit-VesSharedMutex {
    <#
    .SYNOPSIS
    Port of _shared_mutex_release(). No-ops if the lock was reclaimed
    as stale while we were still working (token mismatch) -- walking
    away instead of deleting it is the entire point of the token check.
    #>
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [string]$Token
    )
    if ($Token) {
        try {
            $current = [System.IO.File]::ReadAllText($LockPath)
            if ($current -ne $Token) { return }
        } catch { return }
    }
    try { [System.IO.File]::Delete($LockPath) } catch { }
}

function Invoke-VesSharedFileWriteWithRetry {
    <#
    .SYNOPSIS
    Runs $ScriptBlock (the actual read/modify/write work inside a
    mutex's critical section) with a short retry-on-IOException loop.

    Found via direct concurrency testing (2026-08-02, 5 real parallel
    processes hammering one shared NAS file through a proven-correct
    mutex): Enter/Exit-VesSharedMutex correctly serializes LOGICAL
    access, but the NAS's own SMB oplock-break timing can still lag
    behind that serialization by a short window when several separate
    processes on the same machine cycle open/write/close against the
    same file in quick succession -- the same underlying timing class
    already found for the staging finalize path (immediate reopen-
    after-close failing with Access Denied). The mutex is not broken;
    the raw file I/O inside the critical section still needs its own
    small resilience margin on this NAS. Only for the fleet-shared
    bookkeeping files (done-log, resume state) that must live on the
    network share as cross-machine coordination state -- encode OUTPUT
    never goes through this, it always stages locally first (see
    VesStaging.psm1) and only touches the share once, already-verified.

    Testing note: Start-Job-spawned background processes hit a
    persistent (not transient) "Access is denied" writing to this NAS
    even under the same Windows identity as the parent session and
    even with this retry wrapper -- looks like a Start-Job-specific
    process/session quirk, not a defect in the mutex or this retry
    logic (plain sequential use, and the mutex's own acquire/release/
    reclaim correctness, were all independently verified without
    Start-Job and worked cleanly). The real fleet execution model is
    Scheduled-Task-launched detached processes, not Start-Job children
    -- verify concurrency against that mechanism specifically before
    trusting multi-machine correctness in production, don't extrapolate
    from a Start-Job test.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxRetries = 5,
        [int]$RetryDelayMs = 150
    )
    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        } catch [System.IO.IOException] {
            $attempt++
            if ($attempt -gt $MaxRetries) { throw }
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }
}

Export-ModuleMember -Function Get-VesSharedMutexAge, Enter-VesSharedMutex, Exit-VesSharedMutex, Invoke-VesSharedFileWriteWithRetry
