# Windows port of convert-v5.0.33S.sh's job-scoped RAM disk staging
# (ramdisk_discover/create/job_start/job_teardown, lines ~4324-4780).
#
# Windows mechanism: ImDisk Toolkit's imdisk.exe (installed 2026-08-03 on
# ELVIS via an interactive console session -- GUI/driver-signing prompts
# are invisible over SSH, see [[reference_elvis_connection_2026_08_03]]).
# Confirmed via a real split-session test that ImDisk-mounted volumes are
# NOT session-scoped the way SMB/NFS drive-letter mappings are (Phase 0
# finding does not apply here) -- see
# [[project_elvis_imdisk_ramdisk_2026_08_03]]. Still, verify under the
# real VesDetachedExecution launch path before fully trusting this in
# production; don't extrapolate from one launch mechanism to another.
#
# Bash uses `trap ... EXIT` for guaranteed teardown. PowerShell has no
# exact equivalent that survives every termination path, and this
# project's real jobs run via VesDetachedExecution (Scheduled Task) --
# a hard kill/crash leaves the disk mounted with nothing to run a trap.
# Design (per team review, 2026-08-03): a best-effort try/finally in the
# calling script is the first line of defense; genuine crash recovery is
# the orphan reaper's job (Test-VesRamDiskLeftover + the owner-marker
# file written onto the disk itself), not this module's problem alone --
# see VesOrphanReaper.psm1.

if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}

# Single-host coordination only (drive-letter selection races between two
# jobs on the SAME machine) -- deliberately a plain .NET named mutex, not
# the NAS-file-based VesSharedMutex primitive, because this problem isn't
# network-shared. Named so it's visible across processes on this host.
$script:VesRamDiskLetterMutexName = 'Global\VesRamDiskLetterSelect'

function Get-VesAvailableMemoryBytes {
    <#
    .SYNOPSIS
    Port of _mem_available_bytes(). Uses currently-free physical memory,
    not total, matching the bash version's sizing basis.
    #>
    return [long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
}

function Get-VesFreeRamDiskDriveLetter {
    <#
    .SYNOPSIS
    Picks an unused drive letter, guarded by a local named mutex so two
    concurrent jobs on this host can't both select the same letter
    between the free-letter scan and the actual imdisk mount call.
    #>
    param([int]$TimeoutMs = 10000)

    $mutex = New-Object System.Threading.Mutex($false, $script:VesRamDiskLetterMutexName)
    $acquired = $mutex.WaitOne($TimeoutMs)
    if (-not $acquired) {
        throw "Could not acquire local drive-letter-selection mutex within ${TimeoutMs}ms"
    }
    try {
        $used = (Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name)
        # Prefer letters from the end of the alphabet, away from common
        # mapped-drive ranges used elsewhere in the fleet's own tooling.
        foreach ($c in [char[]]([char]'Z'..[char]'H')) {
            if ($used -notcontains "$c") {
                return "$c"
            }
        }
        throw 'No free drive letter available for RAM disk staging'
    } finally {
        $mutex.ReleaseMutex()
    }
}

function New-VesRamDiskJob {
    <#
    .SYNOPSIS
    Port of ramdisk_job_start()/ramdisk_create(). Creates a job-scoped
    RAM disk sized at $PercentOfAvailable% of currently-free memory (not
    below $MinSizeBytes, not above $MaxSizeBytes), formats NTFS, and
    writes an owner marker onto the new volume so the orphan reaper can
    later attribute (and safely dispose of) a leftover disk from a
    crashed run -- ImDisk volumes carry no ownership info of their own.

    Returns $null if creation failed for any reason (caller must fall
    back to VesStaging's local-disk staging, never fail closed on
    RAM-disk unavailability -- this mirrors CONVERT_NO_RAMDISK's
    graceful-degradation intent in bash).
    #>
    param(
        [int]$PercentOfAvailable = 40,
        [long]$MinSizeBytes = 256MB,
        [long]$MaxSizeBytes = 16GB
    )

    $avail = Get-VesAvailableMemoryBytes
    $sizeBytes = [long]($avail * $PercentOfAvailable / 100)
    if ($sizeBytes -lt $MinSizeBytes) { $sizeBytes = $MinSizeBytes }
    if ($sizeBytes -gt $MaxSizeBytes) { $sizeBytes = $MaxSizeBytes }
    if ($sizeBytes -ge $avail) {
        Write-Warning "Not enough available memory (${avail} bytes free) for a RAM disk -- skipping, caller should fall back to local-disk staging"
        return $null
    }
    $sizeMb = [math]::Round($sizeBytes / 1MB)

    $driveLetter = $null
    try {
        $driveLetter = Get-VesFreeRamDiskDriveLetter
    } catch {
        Write-Warning "RAM disk drive-letter selection failed: $($_.Exception.Message)"
        return $null
    }

    $result = Invoke-VesWithTimeoutRetry -FilePath 'imdisk.exe' `
        -ArgumentList @('-a', '-s', "${sizeMb}M", '-m', "${driveLetter}:", '-p', '/fs:ntfs /q /y') `
        -TimeoutSeconds 60 -MaxRetries 0
    if ($result.ExitCode -ne 0) {
        Write-Warning "imdisk create failed (exit $($result.ExitCode)): $($result.StdErr)"
        return $null
    }

    # Poll for the volume to actually be ready -- mount + format is not
    # guaranteed synchronous with imdisk.exe's own return.
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-Path "${driveLetter}:\") { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) {
        Write-Warning "RAM disk ${driveLetter}: did not become ready in time -- tearing down"
        Remove-VesRamDiskJob -DriveLetter $driveLetter -SkipOwnerCheck
        return $null
    }

    $ownerMarkerPath = "${driveLetter}:\.ves-owner.json"
    $owner = [PSCustomObject]@{
        JobPid     = $PID
        Host       = $env:COMPUTERNAME
        StartedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try {
        ($owner | ConvertTo-Json -Compress) | Out-File -FilePath $ownerMarkerPath -Encoding utf8 -Force
    } catch {
        Write-Warning "Could not write RAM disk owner marker -- tearing down rather than leaving an unattributable disk"
        Remove-VesRamDiskJob -DriveLetter $driveLetter -SkipOwnerCheck
        return $null
    }

    $stageDir = Join-Path "${driveLetter}:\" "stage"
    try {
        New-Item -ItemType Directory -Path $stageDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Could not create RAM disk stage subdirectory -- tearing down"
        Remove-VesRamDiskJob -DriveLetter $driveLetter -SkipOwnerCheck
        return $null
    }

    return [PSCustomObject]@{
        DriveLetter = $driveLetter
        RootPath    = "${driveLetter}:\"
        StagePath   = $stageDir
        OwnerMarker = $ownerMarkerPath
        JobPid      = $PID
    }
}

function Test-VesRamDiskOwnedByCurrentJob {
    <#
    .SYNOPSIS
    Confirms the drive at $DriveLetter is both an ImDisk volume AND
    carries this process's own owner marker, before this process tears
    it down -- a defense against a drive-letter-reuse race tearing down
    someone else's disk (letters are recycled after removal).
    #>
    param([Parameter(Mandatory)][string]$DriveLetter)
    $markerPath = "${DriveLetter}:\.ves-owner.json"
    try {
        if (-not (Test-Path $markerPath)) { return $false }
        $owner = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        return ($owner.JobPid -eq $PID -and $owner.Host -eq $env:COMPUTERNAME)
    } catch {
        return $false
    }
}

function Remove-VesRamDiskJob {
    <#
    .SYNOPSIS
    Port of ramdisk_job_teardown(). Idempotent -- tolerates "already
    gone" since teardown can be called from both the normal-exit path
    and the orphan reaper's crash-recovery path. Refuses to unmount
    unless the owner marker matches this job, UNLESS -SkipOwnerCheck is
    passed (used only by the orphan reaper, which has independently
    verified deadness of the original owner through its own liveness
    check before calling this with the switch).
    #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [switch]$SkipOwnerCheck
    )
    if (-not (Test-Path "${DriveLetter}:\")) { return $true }

    if (-not $SkipOwnerCheck -and -not (Test-VesRamDiskOwnedByCurrentJob -DriveLetter $DriveLetter)) {
        Write-Warning "Refusing to tear down ${DriveLetter}: -- owner marker does not match this job (possible drive-letter reuse race)"
        return $false
    }

    $result = Invoke-VesWithTimeoutRetry -FilePath 'imdisk.exe' `
        -ArgumentList @('-D', '-m', "${DriveLetter}:") -TimeoutSeconds 30 -MaxRetries 0
    return ($result.ExitCode -eq 0 -or -not (Test-Path "${DriveLetter}:\"))
}

function Get-VesRamDiskLeftovers {
    <#
    .SYNOPSIS
    Port of the "leftover owned ramdisk found mounted already" crash-
    recovery branch of ramdisk_job_start(). Enumerates currently-mounted
    ImDisk volumes carrying this project's owner-marker convention, for
    the orphan reaper to evaluate (never disposed of directly by this
    function -- liveness checking and disposal ordering belong to
    VesOrphanReaper.psm1, not here).
    #>
    $leftovers = @()
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $markerPath = "$($drive.Name):\.ves-owner.json"
        if (Test-Path $markerPath -ErrorAction SilentlyContinue) {
            try {
                $owner = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
                $leftovers += [PSCustomObject]@{
                    DriveLetter = $drive.Name
                    JobPid      = $owner.JobPid
                    Host        = $owner.Host
                    StartedUtc  = $owner.StartedUtc
                    StagePath   = Join-Path "$($drive.Name):\" 'stage'
                }
            } catch { }
        }
    }
    # Deliberately a plain "return $leftovers", not a comma-wrapped one --
    # see VesOrphanReaper.psm1's Get-VesOrphanFlagCandidates comment for
    # the full explanation: a comma-wrap fixes direct-assignment
    # scalar-collapse for a 1-element result but BREAKS direct piping for
    # a 2+-element result (confirmed via a real reproduced bug). Wrap
    # with @(...) at the CALL SITE when capturing into a variable for
    # indexing/Count; pipe directly (no wrapping) when enumerating.
    return $leftovers
}

Export-ModuleMember -Function Get-VesAvailableMemoryBytes, Get-VesFreeRamDiskDriveLetter, `
    New-VesRamDiskJob, Test-VesRamDiskOwnedByCurrentJob, Remove-VesRamDiskJob, Get-VesRamDiskLeftovers
