# Windows port of convert-v5.0.33S.sh's staging mechanism
# (resolve_encode_stage_path/_local_stage_dir_for/_cleanup_staged_file_dir/
# finalize_staged_encode_output, lines ~4661-4800).
#
# RAM-disk staging is NOT yet available on ELVIS -- ImDisk's installer
# requires an interactive session to complete (kernel driver consent),
# which a non-interactive SSH/automation session can't provide; tracked
# as a real follow-up needing the user's direct interaction, not a
# silent gap. This module implements the bash version's own documented
# fallback for exactly this situation: stage on real (local, ideally
# fast SSD) disk instead of RAM -- slower, but not a correctness
# blocker, and the module is structured so a RAM-disk path can be
# plugged into Resolve-VesEncodeStagePath's -RamdiskDir parameter later
# without changing any calling code.
#
# The private-staging-directory design (mktemp-equivalent unpredictable
# directory name, not writing straight to the final/predictable path)
# is preserved faithfully -- it's a real TOCTOU/symlink-race defense,
# not bash-specific: on Windows, another process with access to the
# destination directory could substitute a reparse point at a
# predictable path between a pre-flight check and the encoder actually
# opening it, same class of race the bash version's own external
# review flagged.
#
# Found via direct testing against the real NAS share (2026-08-02):
# PowerShell's Remove-Item cmdlet is UNRELIABLE for both files and
# directories over this SMB share -- fails with "Access is denied" on
# paths whose ACLs genuinely grant delete rights (confirmed via icacls),
# while `cmd /c del`/[System.IO.File]::Delete()/[System.IO.Directory]::Delete()
# succeed on the identical path immediately after. A known class of
# PowerShell-over-SMB provider-layer quirk on some NAS implementations,
# not a real permissions problem. All cleanup in this module therefore
# uses the raw .NET deletion APIs, never Remove-Item, for anything that
# might live on a network share (which is the common case here --
# without a ramdisk, the "local" staging directory is a sibling of the
# real destination, i.e. ON the network share itself).
#
# Also found the same session: Copy-Item can silently produce no
# destination file on this share without throwing, even with
# -ErrorAction Stop -- switched to [System.IO.File]::Copy(). And
# separately: this NAS's Samba config hides dot-prefixed names over SMB
# (a common "hide dot files = yes" default) -- Get-ChildItem needs
# -Force to see a dot-prefixed name at all (Test-Path/Get-Item already
# do by default; Test-Path has no -Force parameter for this purpose --
# confirmed directly, don't add it there). Fixed by dropping the
# leading dot from this port's temp-naming scheme entirely (it's a
# Unix/bash idiom this NAS's SMB layer actively works against, not a
# convention Windows needs) and using -Force on Get-Item/Get-ChildItem
# as defense-in-depth.

function Remove-VesFileRobust {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Delete($Path)
        }
    } catch { }
}

function Remove-VesDirectoryRobust {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            [System.IO.Directory]::Delete($Path, [bool]$Recurse)
        }
    } catch { }
}

function New-VesLocalStageDir {
    <#
    .SYNOPSIS
    Port of _local_stage_dir_for(). Creates a private, unpredictable
    staging directory. Prefers -PreferredParentDir (a known-writable
    local disk location) when supplied; otherwise falls back to a
    sibling of $Destination's own directory, matching the bash
    version's original behavior. Returns $null if it couldn't be
    created (caller must fail closed, never fall back to writing the
    final path directly).

    .PARAMETER PreferredParentDir
    Windows-specific deviation from the bash version, not an oversight:
    found via direct testing against the real NAS (2026-08-02) that
    freshly-created directories on this share get a broken ACL
    (Everyone: RX instead of inheriting the parent's Modify) that even
    the creating session can't write into afterward -- a Samba
    ACL-inheritance misconfiguration on the NAS side, not fixable from
    the Windows client. "Stage next to the destination" is therefore
    unsafe as a default on Windows whenever the destination is a
    network path. Callers should supply a known-good local disk
    directory (e.g. a fixed path on the machine's fastest local drive)
    here; this function still falls back to sibling-of-destination if
    omitted, for parity with the bash version and for genuinely local
    (non-network) destinations where the NAS quirk doesn't apply.
    #>
    param(
        [Parameter(Mandatory)][string]$Destination,
        [string]$PreferredParentDir
    )

    if ($PreferredParentDir) {
        try {
            New-Item -ItemType Directory -Path $PreferredParentDir -Force -ErrorAction Stop | Out-Null
        } catch {
            $PreferredParentDir = $null
        }
    }
    $parentDir = if ($PreferredParentDir) { $PreferredParentDir } else { Split-Path -Parent $Destination }
    $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
    $stageDir = Join-Path $parentDir "convert-stage-$token"
    try {
        New-Item -ItemType Directory -Path $stageDir -ErrorAction Stop | Out-Null
        # Ownership marker, matching VesRamDisk.psm1's .ves-owner.json
        # convention -- without this, a crashed job's stage dir has no
        # recorded owner and nothing can ever safely reclaim it (found
        # 2026-08-13: dozens of these accumulated per machine, some over a
        # week old, with zero automatic cleanup path -- Get-VesRamDiskLeftovers
        # only knows about mounted ImDisk RAM disks, not this local-disk
        # fallback). Best-effort; a marker write failure just means this
        # particular leftover won't be auto-reclaimed later, not a job
        # failure now.
        try {
            [PSCustomObject]@{
                JobPid     = $PID
                Host       = $env:COMPUTERNAME
                StartedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stageDir '.ves-owner.json') -ErrorAction Stop
        } catch { }
        return $stageDir
    } catch {
        return $null
    }
}

function Get-VesLocalStageLeftovers {
    <#
    .SYNOPSIS
    Crash-recovery counterpart to VesRamDisk.psm1's Get-VesRamDiskLeftovers,
    for the local-disk staging fallback (New-VesLocalStageDir). Enumerates
    convert-stage-* directories directly under $Root carrying this
    project's owner-marker convention, for the orphan reaper to evaluate
    -- never disposed of directly by this function, matching the RAM-disk
    leftover pattern's separation of enumeration from disposal.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $leftovers = @()
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $leftovers }
    Get-ChildItem -LiteralPath $Root -Directory -Force -Filter 'convert-stage-*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $markerPath = Join-Path $_.FullName '.ves-owner.json'
            if (Test-Path -LiteralPath $markerPath -ErrorAction SilentlyContinue) {
                try {
                    $owner = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
                    $leftovers += [PSCustomObject]@{
                        StageDir   = $_.FullName
                        JobPid     = $owner.JobPid
                        Host       = $owner.Host
                        StartedUtc = $owner.StartedUtc
                    }
                } catch { }
            }
        }
    # Plain return -- see Get-VesOrphanFlagCandidates's comment for why a
    # comma-wrap is deliberately not used; wrap with @(...) at the call
    # site when capturing into a variable for indexing/Count.
    return $leftovers
}

function Resolve-VesEncodeStagePath {
    <#
    .SYNOPSIS
    Port of resolve_encode_stage_path(). Decides where the encoder
    should actually write for this one file: a RAM-disk path if
    -RamdiskDir is supplied and has enough free space for the source
    size (plus margin), else a private local staging directory --
    preferring -LocalFallbackDir (a known-writable local disk location,
    see New-VesLocalStageDir's -PreferredParentDir doc for why this
    isn't just "next to the real destination" on Windows) over a
    sibling of the real destination. Returns $null (caller must skip
    the file, never encode straight to the predictable final path) if
    even the local staging directory couldn't be created.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$RamdiskDir,
        [string]$LocalFallbackDir,
        [int]$SizeEstimateMarginPct = 20
    )

    if ($RamdiskDir -and (Test-Path $RamdiskDir)) {
        $srcSize = (Get-Item $Source -Force -ErrorAction SilentlyContinue).Length
        if ($srcSize -gt 0) {
            $needBytes = $srcSize + [long]($srcSize * $SizeEstimateMarginPct / 100)
            $drive = (Get-Item $RamdiskDir -Force).PSDrive
            $freeBytes = $drive.Free
            if ($freeBytes -ge $needBytes) {
                $pidTag = $PID
                return Join-Path $RamdiskDir "$pidTag.$([System.IO.Path]::GetFileName($Destination))"
            }
            $needMb = [math]::Round($needBytes / 1MB)
            Write-Warning "Ramdisk staging: not enough free space in $RamdiskDir for this file (need ~${needMb}MB) -- falling back to local private staging"
        }
    }

    $localDir = New-VesLocalStageDir -Destination $Destination -PreferredParentDir $LocalFallbackDir
    if (-not $localDir) {
        Write-Warning "Could not create a private staging directory for $Destination -- refusing to encode directly to the final path (would reopen the race window)"
        return $null
    }
    $pidTag = $PID
    return Join-Path $localDir "$pidTag.$([System.IO.Path]::GetFileName($Destination))"
}

function Remove-VesStagedFileDir {
    <#
    .SYNOPSIS
    Port of _cleanup_staged_file_dir(). Removes the private per-file
    staging directory -- but NEVER the job-scoped ramdisk stage dir
    itself (that persists across every file in the run, torn down once
    elsewhere), matching the bash version's directory-identity check.
    #>
    param(
        [Parameter(Mandatory)][string]$StagedPath,
        [string]$RamdiskJobStageDir
    )
    $stagedDir = Split-Path -Parent $StagedPath
    if ($RamdiskJobStageDir -and ($stagedDir -eq $RamdiskJobStageDir)) {
        return
    }
    try {
        if ((Get-ChildItem -Path $stagedDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
            Remove-VesDirectoryRobust -Path $stagedDir
        }
    } catch { }
}

function Complete-VesStagedEncodeOutput {
    <#
    .SYNOPSIS
    Port of finalize_staged_encode_output(). Moves a staged output into
    place on its real (possibly network) destination via a private,
    unpredictable temp FILENAME (not a temp directory -- see below) in
    the final destination's own existing directory, size-verified copy,
    then a same-directory rename -- never reopening the final path by
    name mid-copy (the same TOCTOU class the bash version's own review
    fixed: a plain "copy to $final_dst.tmp then rename" still lets
    another writer swap that predictable name for a reparse point
    between the two steps).

    Deliberate Windows deviation from the bash version, not an
    oversight: the bash version (and this port's first draft) used a
    private temp DIRECTORY here, mirroring the staging-side design. But
    the real NAS this was tested against (2026-08-02) has a Samba
    ACL-inheritance bug where freshly-created directories get a broken
    ACL (Everyone: RX instead of inheriting the parent's Modify) that
    even the creating session can't write into -- confirmed via icacls
    comparison and reproduced consistently. Since the final
    destination's directory already exists (the working case, proven
    repeatedly), using a private temp FILENAME there instead of a new
    subdirectory keeps the same TOCTOU protection (the name is still
    unpredictable, so nothing can pre-position a reparse point at it)
    while never touching the broken directory-creation path.
    #>
    param(
        [Parameter(Mandatory)][string]$StagedPath,
        [Parameter(Mandatory)][string]$FinalDestination
    )
    if ($StagedPath -eq $FinalDestination) { return $true }
    if (-not (Test-Path $StagedPath) -or (Get-Item $StagedPath -Force).Length -eq 0) { return $false }

    $parentDir = Split-Path -Parent $FinalDestination
    $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
    $tmpOnDst = Join-Path $parentDir "convert-finalize-$token-$([System.IO.Path]::GetFileName($FinalDestination))"

    # [System.IO.File]::Copy(), not Copy-Item -- found via direct testing
    # against the real NAS (2026-08-02) that Copy-Item can silently
    # produce no file at all on this SMB share without throwing (even
    # with -ErrorAction Stop), the same class of PowerShell-provider-
    # layer unreliability already found for Remove-Item. The raw .NET
    # API is the reliable one in both cases.
    $copyOk = $false
    try {
        [System.IO.File]::Copy($StagedPath, $tmpOnDst, $true)
        if ((Test-Path $tmpOnDst) -and (Get-Item $tmpOnDst -Force).Length -eq (Get-Item $StagedPath -Force).Length) {
            $copyOk = $true
        }
    } catch { }

    if ($copyOk) {
        try {
            Move-Item -Path $tmpOnDst -Destination $FinalDestination -Force -ErrorAction Stop
            Remove-VesFileRobust -Path $StagedPath
            return $true
        } catch { }
    }
    Remove-VesFileRobust -Path $tmpOnDst
    return $false
}

Export-ModuleMember -Function New-VesLocalStageDir, Resolve-VesEncodeStagePath, Remove-VesStagedFileDir, `
    Complete-VesStagedEncodeOutput, Remove-VesFileRobust, Remove-VesDirectoryRobust, Get-VesLocalStageLeftovers
