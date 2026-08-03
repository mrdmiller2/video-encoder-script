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

function New-VesLocalStageDir {
    <#
    .SYNOPSIS
    Port of _local_stage_dir_for(). Creates a private, unpredictable
    staging directory as a sibling of $Destination's own directory.
    Returns $null if it couldn't be created (caller must fail closed,
    never fall back to writing the final path directly).
    #>
    param([Parameter(Mandatory)][string]$Destination)

    $parentDir = Split-Path -Parent $Destination
    $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
    $stageDir = Join-Path $parentDir ".convert-stage-$token"
    try {
        New-Item -ItemType Directory -Path $stageDir -ErrorAction Stop | Out-Null
        return $stageDir
    } catch {
        return $null
    }
}

function Resolve-VesEncodeStagePath {
    <#
    .SYNOPSIS
    Port of resolve_encode_stage_path(). Decides where the encoder
    should actually write for this one file: a RAM-disk path if
    -RamdiskDir is supplied and has enough free space for the source
    size (plus margin), else a private local staging directory next to
    the real destination. Returns $null (caller must skip the file,
    never encode straight to the predictable final path) if even the
    local staging directory couldn't be created.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$RamdiskDir,
        [int]$SizeEstimateMarginPct = 20
    )

    if ($RamdiskDir -and (Test-Path $RamdiskDir)) {
        $srcSize = (Get-Item $Source -ErrorAction SilentlyContinue).Length
        if ($srcSize -gt 0) {
            $needBytes = $srcSize + [long]($srcSize * $SizeEstimateMarginPct / 100)
            $drive = (Get-Item $RamdiskDir).PSDrive
            $freeBytes = $drive.Free
            if ($freeBytes -ge $needBytes) {
                $pidTag = $PID
                return Join-Path $RamdiskDir "$pidTag.$([System.IO.Path]::GetFileName($Destination))"
            }
            $needMb = [math]::Round($needBytes / 1MB)
            Write-Warning "Ramdisk staging: not enough free space in $RamdiskDir for this file (need ~${needMb}MB) -- falling back to local private staging"
        }
    }

    $localDir = New-VesLocalStageDir -Destination $Destination
    if (-not $localDir) {
        Write-Warning "Could not create a private staging directory next to $Destination -- refusing to encode directly to the final path (would reopen the race window)"
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
            Remove-Item -Path $stagedDir -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Complete-VesStagedEncodeOutput {
    <#
    .SYNOPSIS
    Port of finalize_staged_encode_output(). Moves a staged output into
    place on its real (possibly network) destination via a private,
    unpredictable temp directory + size-verified copy + rename -- never
    reopening the final path by name mid-copy (the same TOCTOU class the
    bash version's own review fixed: a plain "copy to $final_dst.tmp
    then rename" still lets another writer swap that predictable name
    for a reparse point between the two steps).
    #>
    param(
        [Parameter(Mandatory)][string]$StagedPath,
        [Parameter(Mandatory)][string]$FinalDestination
    )
    if ($StagedPath -eq $FinalDestination) { return $true }
    if (-not (Test-Path $StagedPath) -or (Get-Item $StagedPath).Length -eq 0) { return $false }

    $parentDir = Split-Path -Parent $FinalDestination
    $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
    $tmpDir = Join-Path $parentDir ".convert-finalize-$token"
    try {
        New-Item -ItemType Directory -Path $tmpDir -ErrorAction Stop | Out-Null
    } catch {
        return $false
    }

    $tmpOnDst = Join-Path $tmpDir ([System.IO.Path]::GetFileName($FinalDestination))
    $copyOk = $false
    try {
        Copy-Item -Path $StagedPath -Destination $tmpOnDst -ErrorAction Stop
        if ((Get-Item $tmpOnDst).Length -eq (Get-Item $StagedPath).Length) {
            $copyOk = $true
        }
    } catch { }

    if ($copyOk) {
        try {
            Move-Item -Path $tmpOnDst -Destination $FinalDestination -Force -ErrorAction Stop
            Remove-Item -Path $StagedPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $tmpDir -Force -Recurse -ErrorAction SilentlyContinue
            return $true
        } catch { }
    }
    Remove-Item -Path $tmpDir -Force -Recurse -ErrorAction SilentlyContinue
    return $false
}

Export-ModuleMember -Function New-VesLocalStageDir, Resolve-VesEncodeStagePath, Remove-VesStagedFileDir, Complete-VesStagedEncodeOutput
