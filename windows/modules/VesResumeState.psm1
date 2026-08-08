# Windows port of convert-v5.0.33S.sh's resume-state persistence
# (resume_init_paths/resume_persist_state/resume_state_matches_current/
# resolve_job_sidecar_paths, lines ~1807-5391). Per-hostname sidecar
# files (state/queue/shards) so a fleet run under a shared job root
# resumes only THIS machine's own progress -- the done-log (already
# ported, VesDoneLog.psm1) is the one file genuinely shared fleet-wide.

if (-not (Get-Module -Name VesValidation)) {
    Import-Module (Join-Path $PSScriptRoot 'VesValidation.psm1') -Force
}

function Get-VesResumeSidecarPath {
    <#
    .SYNOPSIS
    Port of resolve_job_sidecar_paths()'s fallback chain: prefer
    $JobRoot itself if writable, else a local cache dir, else a temp
    dir -- same per-hostname naming as bash so a shared job root only
    resumes this machine's own progress.
    #>
    param(
        [Parameter(Mandatory)][string]$JobRoot,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][ValidateSet('state', 'queue', 'shards')][string]$Kind
    )
    $sidecarDir = $JobRoot
    $probeFile = Join-Path $sidecarDir ".ves-sidecar-write-probe.$PID"
    try {
        New-Item -ItemType Directory -Path $sidecarDir -Force -ErrorAction Stop | Out-Null
        [System.IO.File]::WriteAllText($probeFile, 'x')
        [System.IO.File]::Delete($probeFile)
    } catch {
        $sidecarDir = Join-Path $env:LOCALAPPDATA "VES\jobs\$(Split-Path -Leaf $JobRoot)"
        try {
            New-Item -ItemType Directory -Path $sidecarDir -Force -ErrorAction Stop | Out-Null
        } catch {
            $sidecarDir = Join-Path $env:TEMP "ves-job-$env:USERNAME-$(Split-Path -Leaf $JobRoot)"
            New-Item -ItemType Directory -Path $sidecarDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    return Join-Path $sidecarDir "convert-v5.$Hostname.$Kind"
}

function Save-VesResumeState {
    <#
    .SYNOPSIS
    Port of resume_persist_state(). Writes to a private temp file first,
    then atomically replaces the real sidecar path -- never a direct
    in-place write. Refuses if the destination is a reparse point
    (matches the orphan reaper's same refusal, closing the same
    planted-link class of risk for a truncating write).

    Uses [System.IO.File]::Open + a single write + close (the same
    create-and-write-to-the-open-handle pattern as VesSharedMutex.psm1,
    per team design review 2026-08-03) rather than Out-File followed by
    a separate reopen -- avoids the SMB oplock-break timing class of
    failure already found and fixed elsewhere in this port.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )
    if ((Test-Path -LiteralPath $Path) -and (Test-VesPathIsReparsePoint -Path $Path)) {
        Write-Warning "Refusing to write resume state to $Path -- it is a reparse point"
        return $false
    }
    $State['updated'] = [DateTimeOffset]::UtcNow.ToString('o')
    $json = $State | ConvertTo-Json -Compress -Depth 6
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $tmpPath = "$Path.tmp.$PID.$(Get-Random)"
    try {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($tmpPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
            $fs.Write($jsonBytes, 0, $jsonBytes.Length)
        } finally {
            # Pre-existing leak, same class as the flag writers' original
            # bug -- Write() throwing after Open() succeeds skipped
            # $fs.Close(). Found via second-round team review, 2026-08-06.
            if ($fs) { $fs.Close() }
        }
    } catch {
        Write-Warning "Could not write temp resume-state file: $($_.Exception.Message)"
        return $false
    }

    try {
        # File.Move's 3-arg (source, dest, overwrite) overload -- .NET
        # Core 3.0+/PS7+ only, fine since this fork targets PS7+ --
        # handles both create and atomic-overwrite without a backup-
        # filename parameter. Deliberately NOT File.Replace: passing
        # $null for its required backupFileName argument throws "The
        # path is empty" via PowerShell's method-overload binding
        # (confirmed via a real test on ELVIS, 2026-08-03) rather than
        # being treated as "no backup wanted" the way plain C# would.
        [System.IO.File]::Move($tmpPath, $Path, $true)
        return $true
    } catch {
        Write-Warning "Could not atomically replace resume-state file: $($_.Exception.Message)"
        try { [System.IO.File]::Delete($tmpPath) } catch { }
        return $false
    }
}

function Get-VesResumeState {
    <#
    .SYNOPSIS
    Reads a resume-state sidecar back as a hashtable. Returns $null on
    ANY read/parse ambiguity (missing file, corrupt JSON) -- caller must
    treat that as "no valid prior state," never as an error to surface
    destructively.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $json = [System.IO.File]::ReadAllText($Path)
        $obj = $json | ConvertFrom-Json
        $ht = @{}
        foreach ($prop in $obj.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
        return $ht
    } catch {
        return $null
    }
}

function Test-VesResumeStateMatchesCurrent {
    <#
    .SYNOPSIS
    Port of resume_state_matches_current(): field-by-field comparison
    of persisted state against the current run's parameters. A mismatch
    invalidates fast-resume (forces a full re-scan) -- same as bash.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$PersistedState,
        [Parameter(Mandatory)][hashtable]$CurrentArgs,
        [string[]]$FieldsToCompare = @('path', 'shard_depth', 'no_shard', 'name_glob', 'name_glob_ci', 'skip_av1', 'skip_x265')
    )
    foreach ($field in $FieldsToCompare) {
        $persistedVal = if ($PersistedState.ContainsKey($field)) { $PersistedState[$field] } else { $null }
        $currentVal = if ($CurrentArgs.ContainsKey($field)) { $CurrentArgs[$field] } else { $null }
        if ("$persistedVal" -ne "$currentVal") {
            return $false
        }
    }
    return $true
}

Export-ModuleMember -Function Get-VesResumeSidecarPath, Save-VesResumeState, Get-VesResumeState, `
    Test-VesResumeStateMatchesCurrent
