# Windows port of convert-v5.0.33S.sh's per-title claim lock
# (place_in_progress_flag()'s .lock directory claim, lines ~2952-3010) --
# lets two fleet machines scanning the same shared library avoid both
# deciding to encode the same title.
#
# Windows deviation (deliberate, per team design review 2026-08-03, not
# an oversight): bash uses an atomic `mkdir` as its claim primitive.
# This project's own Phase 3 NAS testing found freshly-created
# DIRECTORIES get a broken ACL on this NAS's SMB share that even the
# creating session can't write into -- the exact reason
# VesSharedMutex.psm1 already moved to atomic FILE creation
# (FileMode.CreateNew) instead of mkdir. Rather than inventing a second
# locking primitive for "one more thing to atomically claim, just keyed
# per-title," this module composes VesSharedMutex's already-proven
# primitive.
#
# Team review (2026-08-03) caught a real bug in the first draft of this
# idea: VesSharedMutex.Exit does an EXACT STRING match between the
# caller's token and the lock file's raw content -- writing host=/pid=
# metadata into that same file would silently break release. Fixed:
# metadata lives in a separate companion file (never read/written by
# Enter/Exit-VesSharedMutex), and this module uses a long StaleSeconds
# (matching bash's ORPHAN_STALE_DIR_AGE_SECS ceiling) as the safety-net
# reclaim window -- prompt reclaim of a genuinely-dead holder's lock
# happens through the orphan reaper independently confirming deadness
# and force-releasing, not through a short mutex timeout.

if (-not (Get-Module -Name VesSharedMutex)) {
    Import-Module (Join-Path $PSScriptRoot 'VesSharedMutex.psm1') -Force
}

# Matches bash's ORPHAN_STALE_DIR_AGE_SECS (7200s / 2h) -- the ceiling at
# which even an unattended, un-reaped title lock will eventually be
# reclaimed by wall-clock age alone, same safety-net role as bash's.
$script:VesTitleLockStaleSeconds = 7200

function Get-VesTitleLockPath {
    <#
    .SYNOPSIS
    Deterministic lock path for a source file. Uses the full filename
    (not just the basename) so two different-extension sources sharing
    a basename in the same directory (e.g. a remux candidate) can't
    collide on the same lock path.
    #>
    param([Parameter(Mandatory)][string]$Source)
    $dir = Split-Path -Parent $Source
    $name = Split-Path -Leaf $Source
    return Join-Path $dir "$name.convert.lock"
}

function Enter-VesTitleLock {
    <#
    .SYNOPSIS
    Claims the title lock for $Source. Non-blocking by design (unlike
    Enter-VesSharedMutex's blocking wait, which is right for a short
    critical section but wrong here) -- a title already claimed by
    another machine should be skipped immediately by the caller, not
    waited on for up to 2 hours. Returns $null if already claimed
    (caller must skip this title), else a token object to pass to
    Exit-VesTitleLock.
    #>
    param([Parameter(Mandatory)][string]$Source)

    $lockPath = Get-VesTitleLockPath -Source $Source
    $metaPath = "$lockPath.meta"

    # Uses Enter-VesSharedMutexOnce (single-attempt, non-blocking), NOT
    # Enter-VesSharedMutex (blocking retry loop) -- found via a real
    # two-process race test (2026-08-03) that a separate pre-flight
    # Test-Path check followed by the blocking primitive has a race
    # window: if a second process loses that pre-flight window's race,
    # it falls into Enter-VesSharedMutex's internal retry loop and
    # queues up, silently WINNING the lock several seconds later once
    # the original holder releases -- the opposite of "skip immediately"
    # and a real behavioral divergence from bash's non-blocking
    # mkdir-based claim (which returns "claimed by another" on a lost
    # race, never queues). Enter-VesSharedMutexOnce tries exactly once
    # (plus one reclaim attempt if genuinely stale) and returns $null on
    # any contention, matching bash's semantics.
    $myToken = Enter-VesSharedMutexOnce -LockPath $lockPath -StaleSeconds $script:VesTitleLockStaleSeconds
    if (-not $myToken) { return $null }

    $meta = [PSCustomObject]@{
        Host       = $env:COMPUTERNAME
        JobPid     = $PID
        Source     = $Source
        ClaimedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try {
        ($meta | ConvertTo-Json -Compress) | Out-File -FilePath $metaPath -Encoding utf8 -Force
    } catch { }

    return [PSCustomObject]@{
        Source   = $Source
        LockPath = $lockPath
        MetaPath = $metaPath
        Token    = $myToken
    }
}

function Exit-VesTitleLock {
    <#
    .SYNOPSIS
    Releases a title lock this process holds (token-matched, via
    Exit-VesSharedMutex) and removes the companion metadata file.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Lock)
    Exit-VesSharedMutex -LockPath $Lock.LockPath -Token $Lock.Token
    try { [System.IO.File]::Delete($Lock.MetaPath) } catch { }
}

function Get-VesTitleLockMeta {
    <#
    .SYNOPSIS
    Reads a title lock's companion metadata file, for the orphan reaper
    to evaluate liveness (Host/JobPid) without touching the lock's own
    token content. Returns $null if absent or unreadable (ambiguous --
    caller must NOT treat that as proof of anything, same "never assume
    from an ambiguous read" invariant as elsewhere in this project).
    #>
    param([Parameter(Mandatory)][string]$LockPath)
    $metaPath = "$LockPath.meta"
    try {
        if (-not (Test-Path -LiteralPath $metaPath)) { return $null }
        return Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Remove-VesTitleLockForced {
    <#
    .SYNOPSIS
    Force-releases a title lock WITHOUT token matching -- for the
    orphan reaper's use only, after it has independently confirmed
    (via Get-VesTitleLockMeta + a liveness check) that the original
    holder is dead. This is not a bypass of the token-match safety
    invariant: it is a distinct, independently-verified-deadness
    deletion path, matching the design's explicit reasoning.
    #>
    param([Parameter(Mandatory)][string]$LockPath)
    try { [System.IO.File]::Delete($LockPath) } catch { }
    try { [System.IO.File]::Delete("$LockPath.meta") } catch { }
}

Export-ModuleMember -Function Get-VesTitleLockPath, Enter-VesTitleLock, Exit-VesTitleLock, `
    Get-VesTitleLockMeta, Remove-VesTitleLockForced
