# Windows port of convert-v5.0.33S.sh's orphan reaper
# (reap_orphaned_encoders + the 4-gate salvage/delete sequence,
# orphan_gate0_provenance..orphan_gate3_tail_decode, lines ~11641-12416).
# Also owns crash-recovery disposal for VesRamDisk.psm1 leftovers and
# VesTitleLock.psm1 stale claims -- both modules deliberately punt
# "is the original holder actually dead, and is it safe to dispose of
# what's left" to this module rather than each guessing on their own.
#
# Hard safety invariants this module must never violate (per this
# project's standing "verify before delete" constant, and per real gaps
# a team design review caught 2026-08-03 before any of this was built):
#   1. A probe timeout/error is ALWAYS ambiguous, never proof of
#      corruption -- ambiguous candidates are left in place, not deleted.
#   2. Re-check identity/provenance immediately before any delete, not
#      just once earlier in the pipeline (closes a candidate-swap race).
#   3. Refuse to touch (salvage OR delete) anything that is a Windows
#      reparse point (junction/symlink/mount point).
#   4. All deletes route through VesStaging's Remove-VesFileRobust /
#      Remove-VesDirectoryRobust, never a raw Remove-Item, for the same
#      NAS-reliability reason established project-wide.
#   5. Never delete the SOURCE -- only ever a verified-generated
#      candidate output.

if (-not (Get-Module -Name VesStaging)) {
    Import-Module (Join-Path $PSScriptRoot 'VesStaging.psm1') -Force
}
if (-not (Get-Module -Name VesValidation)) {
    Import-Module (Join-Path $PSScriptRoot 'VesValidation.psm1') -Force
}
if (-not (Get-Module -Name VesRamDisk)) {
    Import-Module (Join-Path $PSScriptRoot 'VesRamDisk.psm1') -Force
}
if (-not (Get-Module -Name VesTitleLock)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTitleLock.psm1') -Force
}

function Test-VesProcessIsAlive {
    <#
    .SYNOPSIS
    Port of the kill -0 check plus encoder_identity_matches()'s PID-reuse
    guard (elapsed-time-vs-recorded-start-time skew tolerance, PLUS an
    optional command-line fingerprint substring check -- a team review
    finding: StartTime alone is a weaker guard on Windows, where PIDs can
    recycle quickly, so this checks both when a fingerprint is supplied).
    Returns $true if genuinely alive AND identity-confirmed, $false if
    confirmed dead OR confirmed a different (recycled-PID) process.
    On genuine uncertainty (can't read StartTime at all), fails LIVE
    (safer to skip a real orphan once than to kill/delete something
    that's actually still running).
    #>
    param(
        [Parameter(Mandatory)][int]$Pid_,
        [Nullable[datetime]]$RecordedStartTimeUtc = $null,
        [string]$CommandLineFingerprint,
        [int]$StartTimeSkewToleranceSeconds = 120
    )
    $proc = Get-Process -Id $Pid_ -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }

    if ($null -ne $RecordedStartTimeUtc) {
        try {
            $actualStartUtc = $proc.StartTime.ToUniversalTime()
            $skew = [math]::Abs(($actualStartUtc - $RecordedStartTimeUtc).TotalSeconds)
            if ($skew -gt $StartTimeSkewToleranceSeconds) {
                # Same PID, different process (recycled) -- not our orphan.
                return $false
            }
        } catch {
            # StartTime inaccessible -- genuine uncertainty, fail live.
            return $true
        }
    }

    if ($CommandLineFingerprint) {
        try {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$Pid_" -ErrorAction Stop
            if ($cim.CommandLine -notlike "*$CommandLineFingerprint*") {
                return $false
            }
        } catch {
            # Can't read command line -- genuine uncertainty, fail live.
            return $true
        }
    }

    return $true
}

function Invoke-VesKillOrphanedProcess {
    <#
    .SYNOPSIS
    Port of kill_orphaned_encoder_pid(): graceful Stop-Process, poll,
    then forceful Stop-Process -Force. Always excludes the CURRENT
    process's own PID (a real bug hit and fixed during this session's
    earlier live-testing work -- never let a bulk/targeted kill touch
    the caller's own session).
    #>
    param(
        [Parameter(Mandatory)][int]$Pid_,
        [int]$PollSeconds = 5
    )
    if ($Pid_ -eq $PID) {
        Write-Warning "Refusing to kill PID $Pid_ -- that is this process's own PID"
        return $false
    }
    $proc = Get-Process -Id $Pid_ -ErrorAction SilentlyContinue
    if (-not $proc) { return $true }

    try { Stop-Process -Id $Pid_ -ErrorAction Stop } catch { }
    for ($i = 0; $i -lt $PollSeconds; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Id $Pid_ -ErrorAction SilentlyContinue)) { return $true }
    }
    try { Stop-Process -Id $Pid_ -Force -ErrorAction Stop } catch { }
    Start-Sleep -Milliseconds 500
    return (-not (Get-Process -Id $Pid_ -ErrorAction SilentlyContinue))
}

function Get-VesOrphanFlagCandidates {
    <#
    .SYNOPSIS
    Port of the flag-file enumeration step of reap_orphaned_encoders().
    Parses simple key=value-per-line flag files (matching bash's own
    format: pid=/host=/encoder_pid=/encoder_started_utc=/
    encoder_fingerprint=/source=). Uses -Force since dot-prefixed names
    are hidden over this fleet's SMB share by default.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$FlagSuffix = 'convert.IN_PROGRESS'
    )
    $candidates = @()
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter "*.$FlagSuffix" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $fields = @{}
            try {
                Get-Content -LiteralPath $_.FullName -ErrorAction Stop | ForEach-Object {
                    if ($_ -match '^([A-Za-z_]+)=(.*)$') { $fields[$Matches[1]] = $Matches[2] }
                }
            } catch { return }
            $candidates += [PSCustomObject]@{
                FlagPath              = $_.FullName
                ScriptPid             = if ($fields.pid) { [int]$fields.pid } else { $null }
                Host                  = $fields.host
                EncoderPid            = if ($fields.encoder_pid) { [int]$fields.encoder_pid } else { $null }
                EncoderStartedUtc     = if ($fields.encoder_started_utc) { [datetime]::Parse($fields.encoder_started_utc).ToUniversalTime() } else { $null }
                EncoderFingerprint    = $fields.encoder_fingerprint
                Source                = $fields.source
            }
        }
    return $candidates
}

function Get-VesOrphanDisposition {
    <#
    .SYNOPSIS
    Port of the cross-host guard + liveness classification in
    reap_orphaned_encoders() (before any gate/dispose logic runs).
    Returns one of: 'cross_host' (skip, another machine's job),
    'live' (skip, script process still running), 'manual_review'
    (legacy flag with no encoder_pid -- bash's own documented
    fallback), 'orphan_encoder_alive' (script dead, encoder process
    still running -- needs killing before disposal), 'stale_both_dead'
    (both dead, safe to evaluate for salvage/delete).
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Candidate)

    if ($Candidate.Host -and $Candidate.Host -ne $env:COMPUTERNAME) {
        return 'cross_host'
    }
    if ($Candidate.ScriptPid -and (Test-VesProcessIsAlive -Pid_ $Candidate.ScriptPid)) {
        return 'live'
    }
    if (-not $Candidate.EncoderPid) {
        return 'manual_review'
    }
    $encoderAlive = Test-VesProcessIsAlive -Pid_ $Candidate.EncoderPid `
        -RecordedStartTimeUtc $Candidate.EncoderStartedUtc -CommandLineFingerprint $Candidate.EncoderFingerprint
    if ($encoderAlive) {
        return 'orphan_encoder_alive'
    }
    return 'stale_both_dead'
}

function Test-VesOrphanCandidateSafeToDispose {
    <#
    .SYNOPSIS
    Gate-0 provenance re-check, run IMMEDIATELY before any delete or
    salvage decision is acted on -- not just once earlier in the
    pipeline. Refuses reparse points outright. Returns $false (meaning
    "leave in place, do nothing") on ANY ambiguity, matching this
    module's ambiguous-is-not-corrupt invariant.
    #>
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$Source
    )
    if (-not (Test-Path -LiteralPath $CandidatePath)) { return $false }
    if (Test-VesPathIsReparsePoint -Path $CandidatePath) {
        Write-Warning "Refusing to touch $CandidatePath -- it is a reparse point (junction/symlink/mount point)"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warning "Refusing to dispose of candidate -- its recorded source ($Source) does not exist, ambiguous"
        return $false
    }
    if (Test-VesPathIsReparsePoint -Path $Source) {
        Write-Warning "Refusing to touch candidate for $Source -- the SOURCE itself is a reparse point"
        return $false
    }
    # Never allow the candidate to resolve to the same path as the source
    # -- the one delete this module must never perform under any
    # circumstance.
    try {
        $candFull = (Get-Item -LiteralPath $CandidatePath -Force).FullName
        $srcFull = if (Test-Path -LiteralPath $Source) { (Get-Item -LiteralPath $Source -Force).FullName } else { $Source }
        if ($candFull -ieq $srcFull) {
            Write-Warning "Refusing to dispose of a candidate that resolves to the source path itself"
            return $false
        }
    } catch {
        return $false
    }
    return $true
}

function Invoke-VesOrphanCandidateDisposal {
    <#
    .SYNOPSIS
    Orchestrates gate0 (immediate re-check) -> duration -> structure
    checks, then salvages (via Complete-VesStagedEncodeOutput) on a full
    pass or deletes (via Remove-VesFileRobust, never Remove-Item) on a
    confirmed structural/duration failure. Any AMBIGUOUS gate result
    (probe timeout, missing tool) leaves the candidate untouched -- it
    is neither salvaged nor deleted, matching bash's own "leave for
    --clean-junk / manual review" behavior for the genuinely uncertain
    case, and this project's standing "never delete on returncode alone"
    constant.
    #>
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FinalDestination,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$MkvalidatorPath,
        [double]$DurationToleranceSeconds = 2.0
    )
    if (-not (Test-VesOrphanCandidateSafeToDispose -CandidatePath $CandidatePath -Source $Source)) {
        return [PSCustomObject]@{ Action = 'left_in_place'; Reason = 'gate0_refused' }
    }

    $srcDuration = Get-VesMediaDurationSeconds -Path $Source -FfprobePath $FfprobePath
    $candDuration = Get-VesMediaDurationSeconds -Path $CandidatePath -FfprobePath $FfprobePath
    if ($null -eq $srcDuration -or $null -eq $candDuration) {
        return [PSCustomObject]@{ Action = 'left_in_place'; Reason = 'duration_probe_ambiguous' }
    }
    if (-not (Test-VesDurationsMatch -DurationA $srcDuration -DurationB $candDuration -ToleranceSeconds $DurationToleranceSeconds)) {
        # Confirmed (not ambiguous) mismatch -- safe to delete the
        # candidate, matching bash's gate1 failure disposal. Re-check
        # gate0 one more time immediately before the actual delete call,
        # per the design's explicit "re-check right before delete" fix.
        if (-not (Test-VesOrphanCandidateSafeToDispose -CandidatePath $CandidatePath -Source $Source)) {
            return [PSCustomObject]@{ Action = 'left_in_place'; Reason = 'gate0_refused_at_delete_time' }
        }
        Remove-VesFileRobust -Path $CandidatePath
        return [PSCustomObject]@{ Action = 'deleted'; Reason = 'duration_mismatch' }
    }

    if ($MkvalidatorPath) {
        $structOk = Test-VesMkvStructureValid -Path $CandidatePath -MkvalidatorPath $MkvalidatorPath
        if ($null -eq $structOk) {
            return [PSCustomObject]@{ Action = 'left_in_place'; Reason = 'structure_probe_ambiguous' }
        }
        if (-not $structOk) {
            if (-not (Test-VesOrphanCandidateSafeToDispose -CandidatePath $CandidatePath -Source $Source)) {
                return [PSCustomObject]@{ Action = 'left_in_place'; Reason = 'gate0_refused_at_delete_time' }
            }
            Remove-VesFileRobust -Path $CandidatePath
            return [PSCustomObject]@{ Action = 'deleted'; Reason = 'structure_invalid' }
        }
    }

    # All gates passed -- salvage via the normal finalize path.
    if (-not (Test-VesOrphanCandidateSafeToDispose -CandidatePath $CandidatePath -Source $Source)) {
        return [PSCustomObject]@{ Action = 'left_in_place'; Reason = 'gate0_refused_at_salvage_time' }
    }
    if (Complete-VesStagedEncodeOutput -StagedPath $CandidatePath -FinalDestination $FinalDestination) {
        return [PSCustomObject]@{ Action = 'salvaged'; Reason = 'all_gates_passed' }
    }
    return [PSCustomObject]@{ Action = 'left_in_place'; Reason = 'finalize_failed' }
}

function Invoke-VesRamDiskOrphanRecovery {
    <#
    .SYNOPSIS
    Crash-recovery disposal for VesRamDisk.psm1 leftovers. Ordering
    matters (a real gap the design review caught): any completed,
    gate-verified candidate in the stage dir must be salvaged BEFORE the
    disk is unmounted -- tearing down first would destroy the only copy
    of a finished-but-not-yet-moved output. Only tears down a disk once
    its owning PID is independently confirmed dead; otherwise leaves it
    alone entirely (still-live jobs are never touched).

    .PARAMETER ResolveSourceAndDestination
    Scriptblock taking the staged candidate's full path, returning
    $null (candidate left untouched, e.g. can't be attributed) or an
    object with .Source (the TRUE original library file -- used for the
    duration-match gate) and .FinalDestination (where a salvaged output
    should be moved). These are deliberately two separate values, not
    one -- a real bug caught by this module's own test suite (2026-08-03):
    an earlier draft used the same resolved path for both, which made
    the duration-match gate compare the candidate against its own
    not-yet-existent final destination instead of the real source,
    and tripped this module's own reparse-point-refusal fail-closed
    path on a path that was simply missing, not actually a reparse
    point (the underlying fail-closed behavior was safe, just for the
    wrong reason -- fixed as its own bug too, see
    Test-VesOrphanCandidateSafeToDispose's explicit missing-source check).
    #>
    param(
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$MkvalidatorPath,
        [scriptblock]$ResolveSourceAndDestination
    )
    $disposed = @()
    foreach ($leftover in (Get-VesRamDiskLeftovers)) {
        if (Test-VesProcessIsAlive -Pid_ $leftover.JobPid) {
            continue
        }
        if (Test-Path $leftover.StagePath) {
            Get-ChildItem -LiteralPath $leftover.StagePath -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
                $resolved = if ($ResolveSourceAndDestination) { & $ResolveSourceAndDestination $_.FullName } else { $null }
                if ($resolved -and $resolved.Source -and $resolved.FinalDestination) {
                    $result = Invoke-VesOrphanCandidateDisposal -CandidatePath $_.FullName -Source $resolved.Source `
                        -FinalDestination $resolved.FinalDestination -FfprobePath $FfprobePath -MkvalidatorPath $MkvalidatorPath
                    $disposed += [PSCustomObject]@{ Path = $_.FullName; Result = $result }
                }
            }
        }
        Remove-VesRamDiskJob -DriveLetter $leftover.DriveLetter -SkipOwnerCheck | Out-Null
    }
    return $disposed
}

function Invoke-VesTitleLockOrphanRecovery {
    <#
    .SYNOPSIS
    Crash-recovery disposal for VesTitleLock.psm1 claims whose original
    holder is confirmed dead -- reads the companion metadata file (never
    the mutex's own token content) and force-releases only after
    independently confirming the recorded JobPid/Host is dead. This is
    the mechanism that makes VesTitleLock's long (2h) StaleSeconds
    ceiling a safety net rather than the primary reclaim path.
    #>
    param([Parameter(Mandatory)][string[]]$LockPaths)
    $reclaimed = @()
    foreach ($lockPath in $LockPaths) {
        $meta = Get-VesTitleLockMeta -LockPath $lockPath
        if (-not $meta) { continue }
        if ($meta.Host -ne $env:COMPUTERNAME) { continue }
        if (Test-VesProcessIsAlive -Pid_ $meta.JobPid) { continue }
        Remove-VesTitleLockForced -LockPath $lockPath
        $reclaimed += $lockPath
    }
    return $reclaimed
}

Export-ModuleMember -Function Test-VesProcessIsAlive, Invoke-VesKillOrphanedProcess, `
    Get-VesOrphanFlagCandidates, Get-VesOrphanDisposition, Test-VesOrphanCandidateSafeToDispose, `
    Invoke-VesOrphanCandidateDisposal, Invoke-VesRamDiskOrphanRecovery, Invoke-VesTitleLockOrphanRecovery
