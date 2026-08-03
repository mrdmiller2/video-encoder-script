# Windows port of convert-v5.0.33S.sh's organize phase
# (organize_library/needs_flat_organize/organize_movie_entry/
# canonical_organize_title/is_movie_organize_parent, lines ~3928-7248).
# TV content is entirely excluded -- organize only ever touches movies.
#
# Windows deviation, per team design review (2026-08-03): a real
# empirical spike found new-folder-then-immediate-write succeeding
# against the real Movies path on this NAS, CONTRADICTING an earlier
# documented finding that freshly-created directories get a broken ACL
# unwritable even by the creator. That discrepancy is flagged, not
# silently resolved -- see DESIGN-remaining6features.md's "Spike 1"
# section. This module wraps folder creation + first write in a
# retry-with-backoff as cheap insurance regardless of which behavior
# holds on any given machine/session, and the interactive-session-only
# spike result should be re-verified under a real VesDetachedExecution
# (Scheduled Task) launch before fully trusting this in unattended
# production -- tracked as a required follow-up, not assumed.

if (-not (Get-Module -Name VesStaging)) {
    Import-Module (Join-Path $PSScriptRoot 'VesStaging.psm1') -Force
}
if (-not (Get-Module -Name VesShardedScan)) {
    Import-Module (Join-Path $PSScriptRoot 'VesShardedScan.psm1') -Force
}

$script:VesSubtitleExtensions = @('srt', 'sub', 'idx', 'ass', 'ssa', 'vtt', 'sup')
$script:VesMovieLanguageDirNames = @(
    'Japanese', 'Chinese', 'English', 'Korean', 'French', 'German', 'Spanish',
    'Italian', 'Cantonese', 'Mandarin', 'Hindi', 'Thai', 'Vietnamese', 'Russian',
    'Portuguese', 'Polish', 'Dutch', 'Swedish', 'Norwegian', 'Danish', 'Finnish',
    'Greek', 'Turkish', 'Arabic', 'Hebrew', 'Indonesian', 'Malay', 'Filipino',
    'Tagalog', 'Other', 'Misc'
)

function Get-VesMovieTitleFromFile {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

function Get-VesCanonicalOrganizeTitle {
    <#
    .SYNOPSIS
    Port of canonical_organize_title(): parenthesizes a trailing bare
    release year ("Sakura 1992" -> "Sakura (1992)"); an already-
    parenthesized year is left untouched.
    #>
    param([Parameter(Mandatory)][string]$Title)
    $t = $Title.Trim()
    if ($t -match '^(.+)\s+\((\d{4})\)$') { return $t }
    if ($t -match '^(.+)\s+(\d{4})$') { return "$($Matches[1]) ($($Matches[2]))" }
    return $t
}

function Test-VesIsTvEpisode {
    <#
    .SYNOPSIS
    Port of is_tv_episode(): S01E01, S01 E01, EP1, Episode 1, 1x01,
    trailing "- 01"/" 01", leading "065-" (2-3 digit sequential
    numbering, deliberately excludes 4-digit year-prefixed titles like
    "1999-Title"/"2001-A Space Odyssey").
    #>
    param([Parameter(Mandatory)][string]$Path)
    $stem = Get-VesMovieTitleFromFile -Path $Path
    if ($stem -match '[Ss]\d{1,2}[Ee]\d{1,3}') { return $true }
    if ($stem -match '[Ss]\d{1,2}[\s_.\-]+[Ee]\d{1,3}') { return $true }
    if ($stem -match '[Ee][Pp]\s*\d{1,3}') { return $true }
    if ($stem -match '[Ee]pisode\s*\d{1,3}') { return $true }
    if ($stem -match '\d{1,2}[xX]\d{1,2}') { return $true }
    if ($stem -match '-\s*\d{1,2}$') { return $true }
    if ($stem -match '\s\d{1,2}$') { return $true }
    if ($stem -match '^\d{2,3}-') { return $true }
    return $false
}

function Test-VesIsPlexSeasonDirName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -match '^[Ss]eason\s+\d+$') { return $true }
    if ($Name -match '^[Ss]pecials$') { return $true }
    return $false
}

function Test-VesIsTvLibraryPath {
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -match '[\\/]Television([\\/]|$)')
}

function Test-VesIsTvShowDirectory {
    <#
    .SYNOPSIS
    Port of is_tv_show_directory(): a Plex-style Season/Specials dir
    name, OR at least one direct child video file that itself looks
    like a TV episode, OR (under a Television/ library path) 2+ direct
    child video files at all -- since a TV library's show-root folder
    holds no episodes directly, only season subfolders.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$VideoExtensions = @('mkv', 'mp4', 'avi', 'm4v', 'mov', 'ts', 'wmv')
    )
    if (Test-VesIsPlexSeasonDirName -Name (Split-Path -Leaf $Path)) { return $true }
    $videos = @(Get-ChildItem -LiteralPath $Path -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $VideoExtensions -contains $_.Extension.TrimStart('.').ToLowerInvariant() })
    $episodeCount = @($videos | Where-Object { Test-VesIsTvEpisode -Path $_.FullName }).Count
    if ($episodeCount -ge 1) { return $true }
    if ((Test-VesIsTvLibraryPath -Path $Path) -and $videos.Count -ge 2) { return $true }
    return $false
}

function Test-VesIsSubtitleFile {
    param([Parameter(Mandatory)][string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
    return ($script:VesSubtitleExtensions -contains $ext)
}

function Test-VesIsDerivedOutput {
    <#
    .SYNOPSIS
    Port of is_derived_output(): a cheap, name-only guess (never
    ffprobes here) used to skip this port's own prior output during a
    broad organize scan.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $base = Split-Path -Leaf $Path
    if ($base -match '\.(AV1|av1|x265|X265)\.mkv$') { return $true }
    if ($base -match '-av1\.mkv$') { return $true }
    return $false
}

function Test-VesIsShelfDir {
    param([Parameter(Mandatory)][string]$Path)
    $name = Split-Path -Leaf $Path
    if ($name -eq '0') { return $true }
    return ($name -match '^[A-Za-z]$')
}

function Test-VesUsesLetterBucketLibrary {
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -match '[\\/][Ee]nglish([\\/]|$)')
}

function Test-VesIsMovieLanguageDir {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-VesIsShelfDir -Path $Path) { return $false }
    $name = Split-Path -Leaf $Path
    return ($script:VesMovieLanguageDirNames -contains $name)
}

function Test-VesIsMovieOrganizeParent {
    <#
    .SYNOPSIS
    Port of is_movie_organize_parent(): the parent directory where a
    loose movie file is allowed to be foldered -- a shelf dir (only if
    it's under the letter-bucket English library), a movie-language
    dir, or the search root itself.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SearchPath
    )
    if (Test-VesIsShelfDir -Path $Path) {
        return (Test-VesUsesLetterBucketLibrary -Path $Path)
    }
    if (Test-VesIsMovieLanguageDir -Path $Path) { return $true }
    if ($Path.TrimEnd('\', '/') -eq $SearchPath.TrimEnd('\', '/')) { return $true }
    return $false
}

function Test-VesNeedsFlatOrganize {
    <#
    .SYNOPSIS
    Port of needs_flat_organize(): true only for a loose movie file not
    yet in its own Title (YYYY)/Title (YYYY).ext folder, under a
    recognized movie-organize parent. TV episodes and TV show
    directories are always excluded first.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SearchPath
    )
    $parent = Split-Path -Parent $Path
    $rawTitle = Get-VesMovieTitleFromFile -Path $Path
    $canonTitle = Get-VesCanonicalOrganizeTitle -Title $rawTitle
    $dirBase = Split-Path -Leaf $parent

    if (Test-VesIsTvEpisode -Path $Path) { return $false }
    if (Test-VesIsTvShowDirectory -Path $parent) { return $false }

    if ($dirBase -eq $canonTitle -and $rawTitle -ne $canonTitle) { return $true }
    if ($dirBase -eq $canonTitle -and $rawTitle -eq $canonTitle) { return $false }

    if (-not (Test-VesIsMovieOrganizeParent -Path $parent -SearchPath $SearchPath)) { return $false }
    return $true
}

function Get-VesSubtitleLang {
    <#
    .SYNOPSIS
    Simplified port of detect_subtitle_lang(): checks the common
    embedded/trailing language-code patterns bash checks directly.
    Deliberately does NOT port the deeper guess_lang_from_path/
    lang_iso3_from_guess fallback chain (a cosmetic subtitle-naming
    heuristic, not a data-safety concern) -- falls back to 'und'
    (undetermined) instead, a real documented simplification, not a
    silent gap.
    #>
    param([Parameter(Mandatory)][string]$SubtitlePath)
    $base = Split-Path -Leaf $SubtitlePath
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($base)
    $map = [ordered]@{
        '\.(en|eng)\.'   = 'eng'; '\.(zh|zho|chi|chs|cht)\.' = 'chi'
        '\.(ja|jpn)\.'   = 'jpn'; '\.(ko|kor)\.'             = 'kor'
        '\.(fr|fre)\.'   = 'fre'; '\.(de|ger)\.'             = 'ger'
        '\.(es|spa)\.'   = 'spa'; '\.(it|ita)\.'             = 'ita'
        '\.(pt|por)\.'   = 'por'; '\.(ru|rus)\.'             = 'rus'
    }
    foreach ($pattern in $map.Keys) {
        if ($base -match $pattern) { return $map[$pattern] }
    }
    if ($stem -match '\.(en|eng)$') { return 'eng' }
    if ($stem -match '\.(zh|chi|zho)$') { return 'chi' }
    if ($stem -match '\.(ja|jpn)$') { return 'jpn' }
    if ($stem -match '\.(ko|kor)$') { return 'kor' }
    switch -Regex ($stem) {
        'english' { return 'eng' }
        'chinese|mandarin' { return 'chi' }
        'japanese' { return 'jpn' }
        'korean' { return 'kor' }
    }
    return 'und'
}

function Get-VesSubtitleTargetName {
    param(
        [Parameter(Mandatory)][string]$SubtitlePath,
        [Parameter(Mandatory)][string]$MovieFile
    )
    $lang = Get-VesSubtitleLang -SubtitlePath $SubtitlePath
    $ext = [System.IO.Path]::GetExtension($SubtitlePath).TrimStart('.').ToLowerInvariant()
    return "$lang.$ext"
}

function Test-VesSubtitleMatchesOrganizeTitle {
    param(
        [Parameter(Mandatory)][string]$SubtitlePath,
        [Parameter(Mandatory)][string]$RawTitle,
        [Parameter(Mandatory)][string]$CanonTitle
    )
    $stem = Get-VesMovieTitleFromFile -Path $SubtitlePath
    if ($stem.StartsWith($RawTitle) -or $RawTitle.Contains($stem)) { return $true }
    if ($stem.StartsWith($CanonTitle) -or $CanonTitle.Contains($stem)) { return $true }
    return $false
}

function New-VesOrganizeDestDirWithRetry {
    <#
    .SYNOPSIS
    Creates a destination folder with a short retry-with-backoff
    before the caller's first write into it -- see this module's
    header for why this is cheap insurance rather than a proven
    necessity on this NAS right now.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxAttempts = 5,
        [int]$InitialDelayMs = 200
    )
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    $probeFile = Join-Path $Path ".ves-organize-probe.$PID"
    $delay = $InitialDelayMs
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        try {
            [System.IO.File]::WriteAllText($probeFile, 'x')
            [System.IO.File]::Delete($probeFile)
            return $true
        } catch {
            Start-Sleep -Milliseconds $delay
            $delay *= 2
        }
    }
    return $false
}

function Invoke-VesOrganizeMovieEntry {
    <#
    .SYNOPSIS
    Port of organize_movie_entry(): moves a loose movie file (plus
    matching subtitle siblings) into its own canonical Title (YYYY)/
    folder. Refuses (warns, returns $false) on a destination collision
    rather than silently no-op'ing the way a bare `mv -n` would --
    matches bash's own explicit collision check and its stated reason
    (a silent no-op would leave the source un-organized with no warning
    at all).
    #>
    param([Parameter(Mandatory)][string]$Path)

    $parent = Split-Path -Parent $Path
    $rawTitle = Get-VesMovieTitleFromFile -Path $Path
    $canonTitle = Get-VesCanonicalOrganizeTitle -Title $rawTitle
    $ext = [System.IO.Path]::GetExtension($Path).TrimStart('.')
    $dirBase = Split-Path -Leaf $parent

    if ($dirBase -eq $canonTitle) {
        $destDir = $parent
    } else {
        $destDir = Join-Path $parent $canonTitle
    }
    $destVideo = Join-Path $destDir "$canonTitle.$ext"

    Write-Host "Organize: $Path -> $destVideo"

    if (-not (New-VesOrganizeDestDirWithRetry -Path $destDir)) {
        Write-Warning "Organize: could not create/write to destination folder, leaving source in place: $destDir"
        return $false
    }

    $video = $Path
    if ($Path -ne $destVideo) {
        if (Test-Path -LiteralPath $destVideo) {
            Write-Warning "Organize collision -- destination already exists, leaving source in place: $Path -> $destVideo"
            return $false
        }
        try {
            [System.IO.File]::Move($Path, $destVideo)
            $video = $destVideo
        } catch {
            Write-Warning "Organize: move failed, leaving source in place: $Path -> $destVideo -- $($_.Exception.Message)"
            return $false
        }
    }

    Get-ChildItem -LiteralPath $parent -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        $item = $_.FullName
        if (-not (Test-VesIsSubtitleFile -Path $item)) { return }
        if (-not (Test-VesSubtitleMatchesOrganizeTitle -SubtitlePath $item -RawTitle $rawTitle -CanonTitle $canonTitle)) { return }
        $targetName = Get-VesSubtitleTargetName -SubtitlePath $item -MovieFile $video
        $target = Join-Path $destDir $targetName
        if (Test-Path -LiteralPath $target) {
            Write-Warning "Organize collision -- subtitle destination already exists, leaving in place: $item -> $target"
            return
        }
        Write-Host "  subtitle: $item -> $target"
        try {
            [System.IO.File]::Move($item, $target)
        } catch {
            Write-Warning "Organize: subtitle move failed, leaving in place: $item -> $target -- $($_.Exception.Message)"
        }
    }
    return $true
}

function Invoke-VesOrganizeLibrary {
    <#
    .SYNOPSIS
    Port of organize_library(): scans for loose movie files (largest
    first), skips this port's own prior output and TV content, and
    organizes every matching file -- one entry's failure (a collision,
    a move error) is logged and does NOT abort the rest of the queue,
    matching bash's own explicit team-reviewed fix for exactly this
    failure-isolation requirement.
    #>
    param(
        [Parameter(Mandatory)][string]$SearchPath,
        [int]$ShardDepth = 1,
        [switch]$NoShard,
        [string]$NameGlob,
        [string[]]$VideoExtensions = @('mkv', 'mp4', 'avi', 'm4v', 'mov', 'ts', 'wmv')
    )
    $scanRoots = @(Get-VesScanRoots -SearchPath $SearchPath -ShardDepth $ShardDepth -NoShard:$NoShard -NameGlob $NameGlob)
    $allFiles = New-Object System.Collections.Generic.List[string]
    foreach ($root in $scanRoots) {
        Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $VideoExtensions -contains $_.Extension.TrimStart('.').ToLowerInvariant() } |
            ForEach-Object { $allFiles.Add($_.FullName) }
    }
    if (Test-VesRootsNeedCatchupScan -SearchPath $SearchPath -VideoExtensions $VideoExtensions) {
        Get-ChildItem -LiteralPath $SearchPath -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $VideoExtensions -contains $_.Extension.TrimStart('.').ToLowerInvariant() } |
            ForEach-Object { if (-not $allFiles.Contains($_.FullName)) { $allFiles.Add($_.FullName) } }
    }

    $queue = @($allFiles | Sort-Object -Property { (Get-Item $_ -Force).Length } -Descending)
    Write-Host "Organize queue: $($queue.Count) file(s) (largest first)"

    $organized = 0; $failed = 0; $skipped = 0
    foreach ($f in $queue) {
        if (Test-VesIsDerivedOutput -Path $f) { continue }
        if (-not (Test-VesNeedsFlatOrganize -Path $f -SearchPath $SearchPath)) { $skipped++; continue }
        try {
            if (Invoke-VesOrganizeMovieEntry -Path $f) { $organized++ } else { $failed++ }
        } catch {
            Write-Warning "Organize failed for this entry -- continuing with the rest of the queue: $f -- $($_.Exception.Message)"
            $failed++
        }
    }
    return [PSCustomObject]@{ Total = $queue.Count; Organized = $organized; Failed = $failed; Skipped = $skipped }
}

Export-ModuleMember -Function Get-VesMovieTitleFromFile, Get-VesCanonicalOrganizeTitle, `
    Test-VesIsTvEpisode, Test-VesIsPlexSeasonDirName, Test-VesIsTvLibraryPath, Test-VesIsTvShowDirectory, `
    Test-VesIsSubtitleFile, Test-VesIsDerivedOutput, Test-VesIsShelfDir, Test-VesUsesLetterBucketLibrary, `
    Test-VesIsMovieLanguageDir, Test-VesIsMovieOrganizeParent, Test-VesNeedsFlatOrganize, `
    Get-VesSubtitleLang, Get-VesSubtitleTargetName, Test-VesSubtitleMatchesOrganizeTitle, `
    Invoke-VesOrganizeMovieEntry, Invoke-VesOrganizeLibrary
