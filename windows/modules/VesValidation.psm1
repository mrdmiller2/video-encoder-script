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
if (-not (Get-Module -Name VesDoneLog)) {
    Import-Module (Join-Path $PSScriptRoot 'VesDoneLog.psm1') -Force
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
        # [Nullable[double]], not [double]: a plain [double] parameter
        # coerces a $null argument to 0.0 during binding, BEFORE the body
        # ever runs -- the null-check below was silently dead code (team
        # review, 2026-08-05, confirmed via direct testing). Two real
        # callers (convert.ps1, VesLegacyFallback.psm1) pass both
        # durations straight through without their own null-check first,
        # so a stalled-NAS probe failure on both sides was scoring as
        # "0.0 vs 0.0, matched" instead of "can't confirm" -- risking a
        # done-logged file that was never actually duration-verified.
        [Nullable[double]]$DurationA,
        [Nullable[double]]$DurationB,
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

function Write-VesLowQualityFlag {
    <#
    .SYNOPSIS
    Port of bash's flag_low_quality_output_for_human(): a kept, valid
    output whose final measured VMAF still lands below the quality floor
    gets logged for human review. Log-only, matching the bash design: the
    output stays exactly where the pipeline expects it (moving it would
    make "already done" detection blind to it and cause an endless
    re-encode-to-the-same-VMAF loop on every future scan). Same TSV shape
    (timestamp, VMAF, output path, source path) as bash's
    low_quality_review.txt so both platforms produce one comparable log.
    #>
    param(
        [Parameter(Mandatory)][string]$JobSidecarDir,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][double]$Vmaf,
        [Parameter(Mandatory)][double]$Threshold
    )
    Write-Warning "Kept output below VMAF $Threshold floor ($Vmaf) -- flagged for human review: $OutputPath"
    $logf = Join-Path $JobSidecarDir 'low_quality_review.txt'
    # Mirrors bash's _neutralize_symlink_sidecar_path: refuse to append
    # through a symlink at a predictable path, closing the class of risk
    # where a planted link could redirect this write into an arbitrary
    # file. Not a full match for bash's hardening -- bash opens its FD
    # once at job start and holds it for the run's lifetime (immune to
    # the path being swapped after that one check), whereas this
    # re-checks on every call since there's no long-lived handle plumbed
    # through here yet. Still closes the gap the team review flagged
    # (team review, 2026-08-06) -- a real improvement over no check at all.
    if ((Test-Path -LiteralPath $logf) -and (Test-VesPathIsReparsePoint -Path $logf)) {
        Write-Warning "Low-quality log path is a reparse point -- removing the link only (target untouched) before use: $logf"
        Remove-Item -LiteralPath $logf -Force -ErrorAction SilentlyContinue
    }
    $line = "{0}`t{1}`t{2}`t{3}" -f (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'), $Vmaf, $OutputPath, $SourcePath
    try {
        Add-Content -LiteralPath $logf -Value $line -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Warning "Could not write low-quality flag to $logf -- ${_}"
    }
}

function Write-VesBadSourceFlag {
    <#
    .SYNOPSIS
    Port of bash's flag_bad_source_for_human(): a source that can never
    succeed on retry (Dolby Vision Profile 5 without libplacebo, today's
    only caller) gets logged and durably marked 'skip' in the done-log,
    so future scans stop re-attempting a job that will always fail the
    same way. Never deletes or moves the source, matching bash. Same
    3-field TSV shape (timestamp, source, reason) as bash's
    bad_sources.txt, and the same log filename, so both platforms'
    human-review backlogs can be read as one combined list on a shared
    library.

    Unlike bash (which never deletes a source, only skips future
    conversion attempts on it), this reuses the existing done-log 'skip'
    status Add-VesDoneLogEntry already supports -- no new sidecar
    mechanism needed on the Windows side.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$JobSidecarDir,
        [Parameter(Mandatory)][string]$DoneLogDir,
        [Parameter(Mandatory)][string]$FfmpegPath
    )
    Write-Warning "Bad source -- durably skipping, needs human review: $Source ($Reason)"
    $logf = Join-Path $JobSidecarDir 'bad_sources.txt'
    if ((Test-Path -LiteralPath $logf) -and (Test-VesPathIsReparsePoint -Path $logf)) {
        Write-Warning "Bad-sources log path is a reparse point -- removing the link only (target untouched) before use: $logf"
        Remove-Item -LiteralPath $logf -Force -ErrorAction SilentlyContinue
    }
    $line = "{0}`t{1}`t{2}" -f (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'), $Source, $Reason
    try {
        Add-Content -LiteralPath $logf -Value $line -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Warning "Could not write bad-source flag to $logf -- ${_}"
    }
    Add-VesDoneLogEntry -Status skip -Source $Source -DoneLogDir $DoneLogDir -FfmpegPath $FfmpegPath
}

function Find-VesExistingValidOutput {
    <#
    .SYNOPSIS
    Cross-platform existing-output pre-check, port of the spirit of
    bash's inspect_existing_outputs_for_queue() (ves-profile-decision.sh)
    -- this port had NO equivalent at all before (team review, 2026-08-06):
    it relied purely on its own done-log, so a title a bash fleet machine
    already finished (bash's own ".AV1.mkv"/".x265.mkv" naming) would be
    silently re-encoded here every run, and vice versa if this port's
    done-log entry was ever lost. Checks bash's two output names plus
    this port's own -OutputSuffix (belt-and-suspenders: catches a
    completed title whose done-log entry didn't survive, same as bash's
    own layered done-log + filesystem checks).

    Deliberately safer than bash's version: this NEVER deletes a
    candidate that fails validation (bash's flag_bad_processed_output
    does, guarded by its own mtime/codec-claim checks) -- a failed
    candidate here is silently skipped and the caller proceeds to a
    normal encode, since this port has no equivalent ownership-proof
    mechanism (no VES-tag reading) to safely judge "is this genuinely
    something either platform produced, safe to delete" the way bash's
    layered guards do. Returns the valid candidate's path, or $null if
    none found/valid (caller must encode normally).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$MkvalidatorPath,
        [string]$OutputSuffix = '.AV1-WIN'
    )
    $dir = Split-Path -Parent $Source
    $title = [System.IO.Path]::GetFileNameWithoutExtension($Source)
    $candidates = @(
        (Join-Path $dir "$title.AV1.mkv"),
        (Join-Path $dir "$title.x265.mkv"),
        (Join-Path $dir "$title$OutputSuffix.mkv"),
        # convert.ps1's own x265 size-guard fallback naming (fixed, not
        # -OutputSuffix-configurable) -- team review, 2026-08-06: missing
        # this meant a title that finished via the x265 fallback path
        # was never recognized as already-done by this check.
        (Join-Path $dir "$title.X265-WIN.mkv")
    )
    # Full-path normalization, not a raw string match -- $Source can arrive
    # with forward slashes (a user-typed -SearchPath in single-file mode
    # isn't run through Join-Path the way $cand is), which a plain -eq
    # would miss. Found via review, 2026-08-06: without this, an -InPlace
    # or empty-$OutputSuffix run could have $cand resolve to $Source
    # itself, and this function would then ffprobe the source, see a
    # valid duration against itself, and return the SOURCE as if it were
    # an already-existing output -- silently skipping the encode entirely.
    $sourceFull = [System.IO.Path]::GetFullPath($Source)
    foreach ($cand in $candidates) {
        if ([System.IO.Path]::GetFullPath($cand) -eq $sourceFull) { continue }
        if (-not (Test-Path -LiteralPath $cand -PathType Leaf)) { continue }
        if ($MkvalidatorPath) {
            $structOk = Test-VesMkvStructureValid -Path $cand -MkvalidatorPath $MkvalidatorPath
            if ($structOk -eq $false) { continue }
        }
        $srcDur = Get-VesMediaDurationSeconds -Path $Source -FfprobePath $FfprobePath
        $dstDur = Get-VesMediaDurationSeconds -Path $cand -FfprobePath $FfprobePath
        if (Test-VesDurationsMatch -DurationA $srcDur -DurationB $dstDur -ToleranceSeconds 2.0) {
            return $cand
        }
    }
    return $null
}

Export-ModuleMember -Function Get-VesMediaDurationSeconds, Test-VesDurationsMatch, `
    Test-VesMkvStructureValid, Test-VesPathIsReparsePoint, Write-VesLowQualityFlag, Write-VesBadSourceFlag, `
    Find-VesExistingValidOutput
