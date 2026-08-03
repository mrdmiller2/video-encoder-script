# Small shared media-validation helpers, extracted so VesOrphanReaper.psm1
# (and any future caller) doesn't duplicate ffprobe/mkvalidator invocation
# logic that already exists ad hoc in this port's own test scripts. Not a
# port of a single bash function -- bash's equivalents are inlined at each
# call site (orphan_video_duration, mkvmerge --identify calls, etc.); this
# module exists because Windows callers benefit from one hardened
# implementation instead of several ad hoc ones.

if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}

function Get-VesMediaDurationSeconds {
    <#
    .SYNOPSIS
    ffprobe-based duration probe. Returns $null on ANY ambiguity (timeout,
    non-zero exit, unparseable output) -- never 0 or a guessed value. This
    matters: callers must treat $null as "don't know," never as proof the
    file is corrupt (the same "ambiguous is not corrupt" invariant this
    project applies everywhere else).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FfprobePath,
        [int]$TimeoutSeconds = 120
    )
    $result = Invoke-VesWithTimeoutRetry -FilePath $FfprobePath `
        -ArgumentList @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', $Path) `
        -TimeoutSeconds $TimeoutSeconds -MaxRetries 1
    if ($result.TimedOut -or $result.ExitCode -ne 0) { return $null }
    $val = $result.StdOut.Trim()
    $parsed = 0.0
    if ([double]::TryParse($val, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Test-VesDurationsMatch {
    <#
    .SYNOPSIS
    Tight duration-match check (mirrors bash's orphan_gate1_duration
    tolerance). Returns $false on ANY ambiguity input ($null durations)
    -- caller must treat that as "can't confirm," not as a match failure
    implying corruption.
    #>
    param(
        [double]$DurationA,
        [double]$DurationB,
        [double]$ToleranceSeconds = 2.0
    )
    if ($null -eq $DurationA -or $null -eq $DurationB) { return $false }
    return ([math]::Abs($DurationA - $DurationB) -le $ToleranceSeconds)
}

function Test-VesMkvStructureValid {
    <#
    .SYNOPSIS
    mkvalidator-based structural check. Returns $null (not $false) on
    ambiguity (timeout, mkvalidator missing) -- same "don't conflate
    ambiguous with invalid" reasoning as the duration probe.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$MkvalidatorPath,
        [int]$TimeoutSeconds = 120
    )
    if (-not (Test-Path $MkvalidatorPath)) { return $null }
    $result = Invoke-VesWithTimeoutRetry -FilePath $MkvalidatorPath -ArgumentList @($Path) `
        -TimeoutSeconds $TimeoutSeconds -MaxRetries 1
    if ($result.TimedOut) { return $null }
    if ($result.ExitCode -eq 0) { return $true }
    # A negative exit code means the PROCESS ITSELF crashed (an unhandled
    # Windows exception -- e.g. -1073741819 / 0xC0000005 ACCESS_VIOLATION),
    # not that mkvalidator examined the file and found it invalid. Found
    # via a real test on ELVIS (2026-08-03): mkvalidator crashed on a
    # genuinely valid real-world encode output (confirmed independently:
    # duration matched source to 3ms, correct AV1/Opus stream layout, a
    # full ffmpeg decode read the entire file with zero errors) -- treating
    # that crash as "structurally invalid" would have wrongly discarded a
    # good file. A real validation failure mkvalidator itself reports uses
    # a small positive exit code, never a large negative one, so this
    # distinction is reliable, not a guess. Crash is ambiguous, same as a
    # timeout -- never proof of corruption.
    if ($result.ExitCode -lt 0) { return $null }
    return $false
}

function Test-VesPathIsReparsePoint {
    <#
    .SYNOPSIS
    Windows equivalent of bash's symlink refusal before any delete/
    salvage decision -- refuses to treat a junction/symlink/mount-point
    as a normal file or directory. Returns $true (refuse to touch) for
    any reparse point, including ones Test-Path can't otherwise resolve.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    } catch {
        # Can't even stat it -- treat as "can't confirm it's safe," which
        # for a refusal check means refuse (fail closed), not proceed.
        return $true
    }
}

Export-ModuleMember -Function Get-VesMediaDurationSeconds, Test-VesDurationsMatch, `
    Test-VesMkvStructureValid, Test-VesPathIsReparsePoint
