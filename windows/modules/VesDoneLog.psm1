# Windows port of convert-v5.0.33S.sh's done-log (done_log_load()/
# done_log_append()/done_log_should_skip(), lines ~5028-5208) -- the
# "don't redo already-converted files" mechanism, shared across the
# whole fleet via state on the NAS.
#
# Deliberate Windows deviation from the bash version, not an oversight:
# bash's done-log is one flat file, appended to by every machine (with
# a shared mutex serializing the appends). Direct testing against the
# real NAS (2026-08-02) found that reopening a file for write/append
# shortly after it was created is UNRELIABLE here -- persistently, not
# transiently (10 retries over 3+ seconds all failed identically), and
# reproducible from a totally different process/session, not just the
# original writer. `icacls` showed why: freshly-created files get the
# same broken ACL already found for freshly-created directories in
# Phase 2 (`Everyone: R` only, not inheriting the parent's broader
# grant), and the one ACL entry that does have write access is tied to
# a specific session identity that isn't guaranteed to match across
# separate connections. A mutex correctly serializes WHO gets to write
# next, but can't fix an NAS-side ACL that denies the write outright.
#
# This port instead stores one small file PER ENTRY in a done-log
# directory, each with a unique, unpredictable filename created via
# atomic exclusive creation (the one operation proven reliable on this
# NAS across every test this session, in an already-existing
# directory). No reopen, no append, no shared-mutex requirement for
# the write itself -- each writer's entry is a unique file nothing
# else ever touches. Import-VesDoneLog enumerates and reads every file
# in the directory instead of parsing one flat file.

function Get-VesMkvStructureStatKey {
    <#
    .SYNOPSIS
    Port of mkv_structure_stat_key(). Prints "size|mtime" (mtime as
    Unix epoch seconds, matching the bash version's `stat -c%Y`).
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $epoch = [DateTimeOffset]::new($item.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
        return "$($item.Length)|$epoch"
    } catch {
        return $null
    }
}

$script:DoneSet = @{}
$script:DoneSetLoaded = $false
$script:SvtAv1MajorMinor = $null
$script:X265MajorMinor = $null

# Timeout-bounded, matching every other subprocess call in this port
# (VesTimeoutRetry.psm1's Invoke-VesWithTimeoutRetry) -- found via
# direct testing (2026-08-02) that these two probes had no timeout at
# all, unlike everywhere else, and a stalled ffmpeg child process left
# WaitForExit() (and the caller) blocked indefinitely while the parent
# pwsh process's memory climbed into the gigabytes over several
# minutes. A short bounded wait plus a hard Kill() on timeout is
# required here just like every validation-probe call elsewhere.
function Get-VesCurrentSvtAv1MajorMinor {
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [int]$TimeoutSeconds = 30
    )
    if ($null -ne $script:SvtAv1MajorMinor) { return $script:SvtAv1MajorMinor }
    $args = @('-hide_banner', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:d=1', '-c:v', 'libsvtav1', '-f', 'null', '-')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegPath
    foreach ($a in $args) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { }
        $proc.WaitForExit()
        $script:SvtAv1MajorMinor = 'unknown'
        return $script:SvtAv1MajorMinor
    }
    $stderrTask.Wait()
    $out = $stderrTask.Result
    $m = [regex]::Match($out, 'SVT \[version\][^\n]*v(\d+\.\d+)', 'IgnoreCase')
    $script:SvtAv1MajorMinor = if ($m.Success) { $m.Groups[1].Value } else { 'unknown' }
    return $script:SvtAv1MajorMinor
}

function Get-VesCurrentX265MajorMinor {
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [int]$TimeoutSeconds = 30
    )
    if ($null -ne $script:X265MajorMinor) { return $script:X265MajorMinor }
    $args = @('-hide_banner', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:d=1', '-c:v', 'libx265', '-f', 'null', '-')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegPath
    foreach ($a in $args) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { }
        $proc.WaitForExit()
        $script:X265MajorMinor = 'unknown'
        return $script:X265MajorMinor
    }
    $stderrTask.Wait()
    $out = $stderrTask.Result
    $m = [regex]::Match($out, 'HEVC encoder version (\d+\.\d+)')
    $script:X265MajorMinor = if ($m.Success) { $m.Groups[1].Value } else { 'unknown' }
    return $script:X265MajorMinor
}

function Get-VesCurrentToolsFingerprint {
    param([Parameter(Mandatory)][string]$FfmpegPath)
    $svt = Get-VesCurrentSvtAv1MajorMinor -FfmpegPath $FfmpegPath
    $x265 = Get-VesCurrentX265MajorMinor -FfmpegPath $FfmpegPath
    return "svtav1=$svt;x265=$x265"
}

function Get-VesFingerprintField {
    param(
        [Parameter(Mandatory)][string]$Fingerprint,
        [Parameter(Mandatory)][string]$Key
    )
    foreach ($pair in ($Fingerprint -split ';')) {
        if ($pair -like "$Key=*") { return $pair.Substring($Key.Length + 1) }
    }
    return $null
}

function Test-VesVersionMajorMinorNewer {
    <#
    .SYNOPSIS
    Port of _version_major_minor_newer(). True only if $Current is a
    strictly newer MAJOR.MINOR than $Recorded.
    #>
    param([string]$Current, [string]$Recorded)
    if (-not $Current -or -not $Recorded) { return $false }
    if ($Current -eq 'unknown' -or $Recorded -eq 'unknown') { return $false }
    if ($Current -notmatch '^(\d+)\.(\d+)$' ) { return $false }
    $curMaj = [int]$Matches[1]; $curMin = [int]$Matches[2]
    if ($Recorded -notmatch '^(\d+)\.(\d+)$') { return $false }
    $recMaj = [int]$Matches[1]; $recMin = [int]$Matches[2]
    if ($curMaj -gt $recMaj) { return $true }
    if ($curMaj -eq $recMaj -and $curMin -gt $recMin) { return $true }
    return $false
}

function Test-VesToolsFingerprintStale {
    <#
    .SYNOPSIS
    Port of tools_fingerprint_is_stale(). True only when a REAL
    recorded fingerprint exists AND this machine's svtav1 or x265 is a
    strictly newer major.minor than what's on record. An empty/missing
    fingerprint is never stale.
    #>
    param(
        [string]$Recorded,
        [Parameter(Mandatory)][string]$FfmpegPath
    )
    if (-not $Recorded) { return $false }
    $curFp = Get-VesCurrentToolsFingerprint -FfmpegPath $FfmpegPath
    $curSvt = Get-VesFingerprintField -Fingerprint $curFp -Key 'svtav1'
    $curX265 = Get-VesFingerprintField -Fingerprint $curFp -Key 'x265'
    $recSvt = Get-VesFingerprintField -Fingerprint $Recorded -Key 'svtav1'
    $recX265 = Get-VesFingerprintField -Fingerprint $Recorded -Key 'x265'
    if (Test-VesVersionMajorMinorNewer -Current $curSvt -Recorded $recSvt) { return $true }
    if (Test-VesVersionMajorMinorNewer -Current $curX265 -Recorded $recX265) { return $true }
    return $false
}

function Import-VesDoneLog {
    <#
    .SYNOPSIS
    Port of done_log_load(), adapted for the one-file-per-entry
    directory layout. Loads every entry file under $DoneLogDir into
    memory. Each file's content is one tab-separated line: status,
    size, mtime, path, fingerprint (5th field optional).
    #>
    param([Parameter(Mandatory)][string]$DoneLogDir)
    $script:DoneSet = @{}
    $script:DoneSetLoaded = $true
    if (-not (Test-Path $DoneLogDir)) { return }

    # [System.IO.Directory]::GetFiles() + [System.IO.File]::ReadAllText(),
    # not Get-ChildItem/Get-Content -- found via direct timing (2026-08-02)
    # that the cmdlet pair took 23+ seconds to enumerate and read just 2
    # small files on this NAS (not hung, genuinely that slow per-call),
    # consistent with the FileSystem-provider-cmdlet overhead already
    # found elsewhere this session. The raw .NET APIs are fast here.
    $n = 0
    $entryMTimes = @{}
    foreach ($filePath in [System.IO.Directory]::GetFiles($DoneLogDir)) {
        $line = $null
        try { $line = [System.IO.File]::ReadAllText($filePath) } catch { }
        $file = [PSCustomObject]@{ LastWriteTimeUtc = [System.IO.File]::GetLastWriteTimeUtc($filePath) }
        if (-not $line) { continue }
        $fields = $line.TrimEnd("`r", "`n") -split "`t"
        if ($fields.Count -lt 4) { continue }
        $status = $fields[0]; $size = $fields[1]; $mtime = $fields[2]; $path = $fields[3]
        $fp = if ($fields.Count -ge 5) { $fields[4] } else { '' }
        if (-not $path) { continue }
        if ($status -in @('done', 'skip')) {
            # Last-write-wins if the same source was recorded more than
            # once across separate entry files (e.g. re-converted after
            # a tool upgrade) -- compare by the entry FILE's own
            # timestamp, not the recorded source mtime.
            if (-not $entryMTimes.ContainsKey($path) -or $file.LastWriteTimeUtc -ge $entryMTimes[$path]) {
                $script:DoneSet[$path] = "$size|$mtime#$fp"
                $entryMTimes[$path] = $file.LastWriteTimeUtc
            }
            $n++
        }
    }
    if ($n -gt 0) {
        Write-Host "Done-log: $n finished source(s) on record -- unchanged files fast-skip"
    }
}

function Add-VesDoneLogEntry {
    <#
    .SYNOPSIS
    Port of done_log_append(), adapted for the one-file-per-entry
    layout: creates one new, uniquely-named file (atomic exclusive
    create, never a reopen/append) rather than appending to a shared
    file. No mutex needed -- each writer's filename can't collide.

    .PARAMETER DoneLogDir
    Must already exist -- this function deliberately does NOT create
    it (no New-Item/mkdir-equivalent call anywhere in this module).
    Matches the bash version's own resolve_job_sidecar_paths(): the
    done-log lives directly at the job root (the library scan path
    itself), which by construction always already exists before any
    conversion work starts. Auto-creating a fresh directory here would
    walk straight into the Phase 2/3 broken-new-folder-ACL bug --
    confirmed unfixable even via icacls immediately after creation
    (Access Denied despite the ACL listing showing Full Control), so
    this is a real constraint, not a missing convenience.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('done', 'skip')][string]$Status,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DoneLogDir,
        [Parameter(Mandatory)][string]$FfmpegPath
    )
    if (-not (Test-Path $DoneLogDir -PathType Container)) {
        Write-Warning "Done-log: directory does not exist and won't be auto-created (see New-VesLocalStageDir's new-folder-ACL note) -- $DoneLogDir"
        return
    }
    $key = Get-VesMkvStructureStatKey -Path $Source
    if (-not $key) { return }
    $fp = Get-VesCurrentToolsFingerprint -FfmpegPath $FfmpegPath
    $size, $mtime = $key -split '\|', 2

    $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
    $entryPath = Join-Path $DoneLogDir "$env:COMPUTERNAME-$PID-$token.tsv"
    $line = "$Status`t$size`t$mtime`t$Source`t$fp`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    try {
        $fs = [System.IO.File]::Open($entryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Close()
    } catch {
        Write-Warning "Done-log: failed to record entry for $Source -- $_"
        return
    }
    $script:DoneSet[$Source] = "$key#$fp"
}

function Test-VesDoneLogShouldSkip {
    <#
    .SYNOPSIS
    Port of done_log_should_skip(). True only when the source is
    durably recorded done/skip, its size|mtime is unchanged since then,
    and the recorded tool fingerprint hasn't gone stale.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [bool]$NoResume = $false
    )
    if ($NoResume) { return $false }
    if (-not $script:DoneSetLoaded) { return $false }
    $stored = $script:DoneSet[$Source]
    if (-not $stored) { return $false }

    $key = Get-VesMkvStructureStatKey -Path $Source
    if (-not $key) { return $false }

    $hashIdx = $stored.IndexOf('#')
    if ($hashIdx -lt 0) {
        $storedKey = $stored
        $storedFp = ''
    } else {
        $storedKey = $stored.Substring(0, $hashIdx)
        $storedFp = $stored.Substring($hashIdx + 1)
    }
    if ($key -ne $storedKey) { return $false }
    return -not (Test-VesToolsFingerprintStale -Recorded $storedFp -FfmpegPath $FfmpegPath)
}

Export-ModuleMember -Function `
    Get-VesMkvStructureStatKey, Get-VesCurrentSvtAv1MajorMinor, Get-VesCurrentX265MajorMinor, `
    Get-VesCurrentToolsFingerprint, Get-VesFingerprintField, Test-VesVersionMajorMinorNewer, `
    Test-VesToolsFingerprintStale, Import-VesDoneLog, Add-VesDoneLogEntry, Test-VesDoneLogShouldSkip
