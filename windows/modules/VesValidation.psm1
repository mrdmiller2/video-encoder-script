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
    re-encode-to-the-same-VMAF loop on every future scan). Same TSV field
    shape (timestamp, VMAF, output path, source path) as bash's
    low_quality_review.txt.

    One-file-per-entry instead of a single shared-file append, mirroring
    Add-VesDoneLogEntry's fix for the same underlying problem (see that
    function's docs): appending to an existing shared file on this NAS
    (Samba/SMB from Windows clients, the same NAS the Linux fleet reaches
    over NFS) is unreliable -- confirmed in production 2026-08-06 when a
    second episode's flag write on PRINCE threw UnauthorizedAccessException
    while the first episode's write (a fresh-file create, not an append)
    succeeded moments earlier in the same run. A single new *file* append
    can throw Access Denied on this NAS the same way a single new
    *directory* create gets a broken ACL (see [[project_elvis_nas_smb_quirks_2026_08_02]])
    -- both are "modify an existing network object after the fact"
    operations, and both are avoided here the same way: only ever create
    brand-new, uniquely-named objects, never reopen one.

    Deliberately does NOT put entries in a subdirectory (unlike a
    from-scratch design might) -- creating a *new* directory on this NAS
    gets a broken ACL (Everyone -> read-only, unfixable from the Windows
    client, see the same NAS-quirks note) where writing into an
    *existing* directory has always been reliable. $JobSidecarDir is the
    show folder itself, which by construction already exists, so entry
    files land directly there -- exactly where Add-VesDoneLogEntry
    already puts its own per-source entries. Uses a distinct extension
    (.quality-flag, not .tsv) specifically so Import-VesDoneLog's
    *.tsv glob never picks these up as done-log entries.
    #>
    param(
        [Parameter(Mandatory)][string]$JobSidecarDir,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][double]$Vmaf,
        [Parameter(Mandatory)][double]$Threshold,
        # 2026-08-16: diagnostic-only 5th field, populated by the caller via
        # Get-VesOutputFrameDuplication ('ok'|'duplicated'|'unknown'/unset)
        # -- see that function's docs for the investigation that motivated
        # it. Turns "NEEDS REVIEW" into a self-diagnosing flag so a human
        # doesn't have to re-derive the same root-cause investigation every
        # time this (or something with the same below-floor symptom)
        # recurs. Appended past the original 4 fields, so any existing
        # reader that only consumes 4 stays correct.
        [string]$DuplicationCheck = ''
    )
    Write-Warning "Kept output below VMAF $Threshold floor ($Vmaf) -- flagged for human review: $OutputPath"
    if (-not (Test-Path -LiteralPath $JobSidecarDir -PathType Container)) {
        Write-Warning "Low-quality flag: sidecar directory does not exist, cannot record -- $JobSidecarDir"
        return
    }
    $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
    $entryPath = Join-Path $JobSidecarDir "low_quality_review-$env:COMPUTERNAME-$PID-$token.quality-flag"
    $line = "{0}`t{1}`t{2}`t{3}`t{4}`n" -f (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'), $Vmaf, $OutputPath, $SourcePath, $DuplicationCheck
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    try {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($entryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            $fs.Write($bytes, 0, $bytes.Length)
        } finally {
            if ($fs) { $fs.Close() }
        }
    } catch {
        Write-Warning "Could not write low-quality flag to $entryPath -- $_"
        return
    }
    Set-VesEveryoneReadWrite -Path $entryPath
}

function Write-VesSourceTraitsAmbiguousFlag {
    <#
    .SYNOPSIS
    Port of bash's flag_source_traits_ambiguous() (ves-source-traits.sh) --
    NOT the same as Write-VesBadSourceFlag: an ambiguous source-traits read
    means "don't auto-apply IVTC/deinterlace, and don't trust a VMAF
    comparison against this source without a human look" -- it still
    encodes normally, the source stays exactly where it is. Same
    one-file-per-entry pattern as Write-VesLowQualityFlag, same NAS-append
    unreliability this port is built around (see that function's docs) --
    reused here rather than re-derived, 2026-08-19 Windows/bash parity
    fix (this whole detection path had no Windows port at all until now).
    #>
    param(
        [Parameter(Mandatory)][string]$JobSidecarDir,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Detail
    )
    Write-Warning "Source traits ambiguous -- auto-detelecine/deinterlace skipped, needs human review: $SourcePath ($Detail)"
    if (-not (Test-Path -LiteralPath $JobSidecarDir -PathType Container)) {
        Write-Warning "Source-traits-ambiguous flag: sidecar directory does not exist, cannot record -- $JobSidecarDir"
        return
    }
    $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
    $entryPath = Join-Path $JobSidecarDir "source_traits_ambiguous-$env:COMPUTERNAME-$PID-$token.traits-flag"
    $line = "{0}`t{1}`t{2}`n" -f (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'), $SourcePath, $Detail
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    try {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($entryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            $fs.Write($bytes, 0, $bytes.Length)
        } finally {
            if ($fs) { $fs.Close() }
        }
    } catch {
        Write-Warning "Could not write source-traits-ambiguous flag to $entryPath -- $_"
        return
    }
    Set-VesEveryoneReadWrite -Path $entryPath
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
    bad_sources.txt.

    One-file-per-entry, not a shared-file append -- same NAS-reliability
    fix and same reasoning as Write-VesLowQualityFlag (see that
    function's docs for the full story): a second write into an
    already-existing file on this NAS is unreliable, a brand-new
    uniquely-named file is not. Entries land directly in $JobSidecarDir
    (never a fresh subdirectory -- new directories get a broken ACL on
    this NAS) with a distinct .bad-source-flag extension so
    Import-VesDoneLog's *.tsv glob never picks these up.

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
    if (-not (Test-Path -LiteralPath $JobSidecarDir -PathType Container)) {
        Write-Warning "Bad-source flag: sidecar directory does not exist, cannot record -- $JobSidecarDir"
    } else {
        $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
        $entryPath = Join-Path $JobSidecarDir "bad_sources-$env:COMPUTERNAME-$PID-$token.bad-source-flag"
        $line = "{0}`t{1}`t{2}`n" -f (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'), $Source, $Reason
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
        $wrote = $false
        try {
            $fs = $null
            try {
                $fs = [System.IO.File]::Open($entryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
                $fs.Write($bytes, 0, $bytes.Length)
                $wrote = $true
            } finally {
                if ($fs) { $fs.Close() }
            }
        } catch {
            Write-Warning "Could not write bad-source flag to $entryPath -- $_"
        }
        if ($wrote) { Set-VesEveryoneReadWrite -Path $entryPath }
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
    Write-VesSourceTraitsAmbiguousFlag, Find-VesExistingValidOutput
