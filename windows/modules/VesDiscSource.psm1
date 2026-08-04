# Windows port of convert-v5.0.33S.sh's disc-source (ISO/BDMV) handling
# (is_disk_source/discover_disk_sources/select_dominant_disk_title/
# handbrake_extract_disc_title_lossless/process_disk, lines ~3820-13957).
#
# Confirmed via the bash research pass (2026-08-03): bash never mounts
# ISO files itself -- HandBrakeCLI reads ISO/BDMV structures directly.
# This port needs no ISO-mounting logic either (Mount-DiskImage is not
# used) -- a genuine like-for-like port, not a new mechanism.
#
# Windows deviation, per team design review (2026-08-03): bash symlinks
# the extracted lossless intermediate into the disc's own
# media_content_dir under a synthetic name specifically so downstream
# helpers (destination-path computation, done-log/title-lock keying,
# sidecar placement) resolve against the real library location while the
# actual encode reads from scratch -- NOT just cosmetic accounting. This
# port makes that role split explicit instead of relying on a symlink
# (which also often needs elevated privileges/Developer Mode on
# Windows): the extracted intermediate is the only thing ever passed as
# the encoder's real input; the disc's own logical path drives
# media-content-dir/collision/destination-naming decisions. The
# collision guard bash's symlink-name check provided is kept explicitly
# (Test-VesDiscExtractionTargetCollision) even without a symlink.

if (-not (Get-Module -Name VesProfileDecision)) {
    Import-Module (Join-Path $PSScriptRoot 'VesProfileDecision.psm1') -Force
}
if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}
if (-not (Get-Module -Name VesHandBrake)) {
    Import-Module (Join-Path $PSScriptRoot 'VesHandBrake.psm1') -Force
}
if (-not (Get-Module -Name VesStaging)) {
    Import-Module (Join-Path $PSScriptRoot 'VesStaging.psm1') -Force
}
if (-not (Get-Module -Name VesValidation)) {
    Import-Module (Join-Path $PSScriptRoot 'VesValidation.psm1') -Force
}

$script:VesDiskTitleDominancePct = 40
$script:VesDiscExtractSpaceMultiplier = 3

function Get-VesDiscMediaContentDir {
    <#
    .SYNOPSIS
    Port of media_content_dir()'s disc-source branch: the BDMV root
    itself for Blu-ray, the parent directory for an ISO file.
    #>
    param([Parameter(Mandatory)][string]$Source)
    if ([System.IO.Path]::GetExtension($Source).TrimStart('.').ToLowerInvariant() -eq 'iso') {
        return Split-Path -Parent $Source
    }
    return $Source
}

function Get-VesDiscExtractLinkBasename {
    <#
    .SYNOPSIS
    Port of disc_extract_link_basename(): the synthetic output name a
    disc source's real destination is based on -- ISO strips the .iso
    extension and adds .mkv; BDMV uses its own root directory's name.
    #>
    param([Parameter(Mandatory)][string]$Source)
    if ([System.IO.Path]::GetExtension($Source).TrimStart('.').ToLowerInvariant() -eq 'iso') {
        return "$([System.IO.Path]::GetFileNameWithoutExtension($Source)).mkv"
    }
    return "$(Split-Path -Leaf $Source).mkv"
}

function Find-VesDiskSources {
    <#
    .SYNOPSIS
    Port of discover_disk_sources(): finds *.iso files and BDMV-
    containing directories under the given root.
    #>
    param([Parameter(Mandatory)][string]$SearchPath)
    $found = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $SearchPath -Recurse -Force -File -Filter '*.iso' -ErrorAction SilentlyContinue |
        ForEach-Object { $found.Add($_.FullName) }
    Get-ChildItem -LiteralPath $SearchPath -Recurse -Force -Directory -Filter 'BDMV' -ErrorAction SilentlyContinue |
        ForEach-Object { $found.Add((Split-Path -Parent $_.FullName)) }
    return , (@($found) | Sort-Object -Unique)
}

function Invoke-VesHandBrakeScan {
    <#
    .SYNOPSIS
    Port of the `run_handbrake -t 0 --scan [--main-feature] -i $src`
    invocation. A real disc scan (parsing BD/DVD structure) can
    genuinely take a couple of minutes for a large Blu-ray -- bounded,
    not unbounded, but with a generous timeout matching that reality.

    Bumped from 300s to 1800s 2026-08-04: Select-VesDominantDiskTitle no
    longer has a fast --main-feature-restricted scan to fall back on for
    quick selection (merged into one full scan so duration-uniqueness can
    be computed from the same title list -- see that function's comment).
    A full scan of every title (not just the main feature) genuinely took
    longer than 300s on a real disc during fleet re-verification and hit
    this timeout, failing a source that the old two-scan version handled
    fine. bash's run_handbrake() has no timeout on this call at all, so
    only this PowerShell port needed the bump. Correctness (the
    duration-uniqueness safety gate) requires the full scan regardless;
    the extraction step's speed (12h -> 45s) is this feature's actual
    win, not the scan step's.
    #>
    param(
        [Parameter(Mandatory)][string]$HandBrakeCliPath,
        [Parameter(Mandatory)][string]$Source,
        [switch]$MainFeature,
        [int]$TimeoutSeconds = 1800
    )
    $hbArgs = @('-t', '0', '--scan', '-i', $Source)
    if ($MainFeature) { $hbArgs += '--main-feature' }
    $result = Invoke-VesWithTimeoutRetry -FilePath $HandBrakeCliPath -ArgumentList $hbArgs -TimeoutSeconds $TimeoutSeconds -MaxRetries 0
    if ($result.TimedOut) { return $null }
    return "$($result.StdOut)`n$($result.StdErr)"
}

function Get-VesHandbrakeMainFeatureTitle {
    <#
    .SYNOPSIS
    Port of handbrake_scan_main_feature_title(): parses HandBrake's
    scan output for a title flagged "+ Main Feature", returning its
    index and duration (seconds), or $null if none is flagged.
    #>
    param([Parameter(Mandatory)][string]$ScanText)
    $idx = 0; $isMain = $false
    foreach ($line in ($ScanText -split "`r?`n")) {
        if ($line -match '^\+ title (\d+):') {
            $idx = [int]$Matches[1]; $isMain = $false
            continue
        }
        if ($line -match '\+ Main Feature') { $isMain = $true; continue }
        if ($line -match '^\s+\+ duration:\s+(\d+):(\d+):(\d+)') {
            $dur = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]
            if ($isMain -and $idx -gt 0 -and $dur -gt 0) {
                return [PSCustomObject]@{ TitleIndex = $idx; DurationSeconds = $dur }
            }
        }
    }
    return $null
}

function Get-VesHandbrakeTitleDurations {
    <#
    .SYNOPSIS
    Port of handbrake_scan_title_durations(): every title's index and
    duration from a full (non-main-feature) scan.
    #>
    param([Parameter(Mandatory)][string]$ScanText)
    $results = New-Object System.Collections.Generic.List[PSCustomObject]
    $idx = 0; $dur = 0
    foreach ($line in ($ScanText -split "`r?`n")) {
        if ($line -match '^\+ title (\d+):') {
            if ($idx -gt 0 -and $dur -gt 0) {
                $results.Add([PSCustomObject]@{ TitleIndex = $idx; DurationSeconds = $dur })
            }
            $idx = [int]$Matches[1]; $dur = 0
            continue
        }
        if ($line -match '^\s+\+ duration:\s+(\d+):(\d+):(\d+)') {
            $dur = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]
        }
    }
    if ($idx -gt 0 -and $dur -gt 0) {
        $results.Add([PSCustomObject]@{ TitleIndex = $idx; DurationSeconds = $dur })
    }
    return , $results
}

function Select-VesDominantDiskTitle {
    <#
    .SYNOPSIS
    Port of select_dominant_disk_title(): tries HandBrake's own main-
    feature flag first (parsed from one full scan's own "+ Main Feature"
    marker, not a separate --main-feature-restricted scan -- team review,
    2026-08-04: the original two-scan version ran HandBrake against the
    same disc twice for every source even though a full scan's text
    already carries that flag when one exists); falls back to a
    duration-dominance heuristic (the single longest title must exceed
    every other title's duration by more than $DominancePct, else the
    disc is ambiguous and skipped for manual review). Returns a
    structured object (Action = 'select' or 'skip').

    Also computes DurationUnique on every 'select' result: $true unless
    another title on the disc has a duration within
    $script:VesDiscStreamCopyDurationToleranceSeconds of the selected
    one. Used to gate the fast stream-copy path
    (Invoke-VesFastStreamCopyDiscExtraction) -- a duration-only match
    can't safely prove libbluray's auto-selected playlist is the SAME
    title on playlist-obfuscated/multi-angle discs that have two full-
    length playlists of near-identical runtime (team review, 2026-08-04,
    all three reviewers independently flagged duration-only matching as
    unsafe on its own).
    #>
    param(
        [Parameter(Mandatory)][string]$HandBrakeCliPath,
        [Parameter(Mandatory)][string]$Source,
        [int]$DominancePct = $script:VesDiskTitleDominancePct
    )
    $fullScan = Invoke-VesHandBrakeScan -HandBrakeCliPath $HandBrakeCliPath -Source $Source
    if (-not $fullScan) {
        return [PSCustomObject]@{ Action = 'skip'; Reason = 'title scan failed' }
    }
    $titles = @(Get-VesHandbrakeTitleDurations -ScanText $fullScan)
    if ($titles.Count -eq 0) {
        return [PSCustomObject]@{ Action = 'skip'; Reason = 'no titles found on disc' }
    }

    $selected = $null
    $mainFeature = Get-VesHandbrakeMainFeatureTitle -ScanText $fullScan
    if ($mainFeature) {
        $selected = $mainFeature
    } elseif ($titles.Count -eq 1) {
        $selected = $titles[0]
    } else {
        $sorted = $titles | Sort-Object -Property DurationSeconds -Descending
        $longest = $sorted[0]
        $threshold = 1 + ($DominancePct / 100)
        foreach ($t in ($sorted | Select-Object -Skip 1)) {
            if ($longest.DurationSeconds -le ($t.DurationSeconds * $threshold)) {
                return [PSCustomObject]@{ Action = 'skip'; Reason = 'Unable to Determine which title you wish to convert, process this manually' }
            }
        }
        $selected = $longest
    }

    $durationUnique = $true
    foreach ($t in $titles) {
        if ($t.TitleIndex -eq $selected.TitleIndex) { continue }
        if ([math]::Abs($t.DurationSeconds - $selected.DurationSeconds) -le $script:VesDiscStreamCopyDurationToleranceSeconds) {
            $durationUnique = $false
            break
        }
    }

    return [PSCustomObject]@{ Action = 'select'; TitleIndex = $selected.TitleIndex; DurationSeconds = $selected.DurationSeconds; DurationUnique = $durationUnique }
}

function Test-VesDiscExtractionTargetCollision {
    <#
    .SYNOPSIS
    Port of process_disk()'s "extraction target already exists and
    isn't our own [symlink]" guard -- kept explicitly even without a
    symlink: refuses to proceed if anything (file OR directory -- bash's
    own `[ -e ... ]` check blocks both; -PathType Leaf here would have
    silently let a same-named directory through, team review 2026-08-04)
    already sits at the synthetic name this disc source would produce.
    #>
    param(
        [Parameter(Mandatory)][string]$Source
    )
    $contentDir = Get-VesDiscMediaContentDir -Source $Source
    $targetName = Get-VesDiscExtractLinkBasename -Source $Source
    $target = Join-Path $contentDir $targetName
    return (Test-Path -LiteralPath $target)
}

$script:VesDiscStreamCopyDurationToleranceSeconds = 5

function Get-VesBlurayProbeDurationSeconds {
    <#
    .SYNOPSIS
    Probes the duration (seconds) libbluray's default title-selection
    picks for a *disc source* (.iso file or BDMV root directory) when
    opened via ffmpeg's `bluray:` protocol with no explicit -playlist
    (auto-selects the main/longest playlist, the same thing HandBrake's
    own main-feature heuristic almost always lands on). No OS-level
    mount required, confirmed empirically 2026-08-04 (libbluray has its
    own internal image-reader). Returns $null on any probe failure (not
    a Blu-ray structure, corrupt disc, ffprobe missing libbluray
    support, etc.) so the caller can fall back safely.

    NOT for probing an ordinary media file's duration -- use
    Get-VesMediaDurationSeconds for that; prepending "bluray:" to a
    plain .mkv would make ffprobe try to parse it as a disc structure
    and fail.
    #>
    param(
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$Source,
        [int]$TimeoutSeconds = 60
    )
    $ffArgs = @('-v', 'error', '-i', "bluray:$Source", '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1')
    $result = Invoke-VesWithTimeoutRetry -FilePath $FfprobePath -ArgumentList $ffArgs -TimeoutSeconds $TimeoutSeconds -MaxRetries 0
    if ($result.TimedOut -or $result.ExitCode -ne 0) { return $null }
    $text = ($result.StdOut ?? '').Trim()
    $val = 0.0
    # InvariantCulture, matching Get-VesMediaDurationSeconds -- current-culture
    # parsing would mis-handle "5010.123"-style output on comma-decimal locales
    # (team review, 2026-08-04).
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val) -and $val -gt 0) {
        return $val
    }
    return $null
}

function Copy-VesDiscSourceLocal {
    <#
    .SYNOPSIS
    Stages a disc source (.iso file or BDMV root directory) to a local
    path via robocopy, before any libbluray read is attempted against
    it. Empirically required 2026-08-04: libbluray's `bluray:` protocol
    does many small seeky reads for BD navigation structures, which is
    catastrophically slow over a network share -- ~0.27MB/s observed
    reading a real NAS-hosted ISO directly (would take 16+ hours for a
    typical disc), versus ~380MB/s reading the exact same disc already
    staged locally (the original fast-path design validation). A plain
    sequential copy of that same network ISO ran at normal network
    throughput, confirming the bottleneck is libbluray's read pattern,
    not the network link -- so staging locally first, THEN doing the
    fast local stream-copy, is still dramatically faster overall than
    the original x264 -q 0 path even though it's no longer the ~45s
    this feature's early validation measured against an already-local
    source.

    Uses robocopy (native, has its own real retry/timeout behavior,
    and is a genuine external process this project's
    Invoke-VesWithTimeoutRetry wrapper can bound) rather than
    Copy-Item -- this project has documented, unrelated PowerShell
    async-mechanism gotchas (Start-Process ExitCode unreliability,
    Register-ObjectEvent output loss) that argue for external tools
    over ad-hoc background-job wrapping wherever one already exists.
    Handles both a single .iso file and a BDMV directory tree via
    robocopy's normal source-dir/dest-dir/file-pattern shape. Returns
    the local path (file or directory) on success, $null on any
    failure or timeout (caller falls back to the original x264 path).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$LocalStagingDir,
        # 3 hours: a 50GB disc needs ~14MB/s sustained to finish in 1 hour --
        # comfortable on healthy gigabit LAN/SMB but a real false-fail risk on a
        # congested/VPN/slow-Wi-Fi link (team review, 2026-08-04, all three
        # reviewers independently flagged the original 3600s as too tight).
        # Timing out here falls back to the ORIGINAL x264 -q 0 path (the thing
        # this whole feature exists to avoid), so a too-tight bound can quietly
        # defeat the fix without being unsafe.
        [int]$TimeoutSeconds = 10800
    )
    try {
        New-Item -ItemType Directory -Path $LocalStagingDir -Force -ErrorAction Stop | Out-Null
    } catch {
        return $null
    }
    $srcItem = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    if (-not $srcItem) { return $null }

    if ($srcItem.PSIsContainer) {
        $destDir = Join-Path $LocalStagingDir (Split-Path -Leaf $Source)
        $rcArgs = @($Source, $destDir, '/E', '/R:2', '/W:5', '/NFL', '/NDL', '/NJH', '/NJS')
        $localPath = $destDir
    } else {
        $srcDir = Split-Path -Parent $Source
        $fileName = Split-Path -Leaf $Source
        $rcArgs = @($srcDir, $LocalStagingDir, $fileName, '/R:2', '/W:5', '/NFL', '/NDL', '/NJH', '/NJS')
        $localPath = Join-Path $LocalStagingDir $fileName
    }

    $result = Invoke-VesWithTimeoutRetry -FilePath 'robocopy.exe' -ArgumentList $rcArgs -TimeoutSeconds $TimeoutSeconds -MaxRetries 0
    # robocopy's own exit-code convention: 0-7 are success variants (0 = nothing
    # copied/already current, 1 = files copied, etc.); 8+ is a real failure --
    # NOT the usual "0 = success, nonzero = failure" assumption. Also reject any
    # negative exit code explicitly (robocopy.exe crashing/killed outside the
    # normal path can surface a negative code, e.g. an access-violation code
    # coerced to Int32; "-lt 0" alone would slip past a bare "-ge 8" check --
    # team review, 2026-08-04).
    if ($result.TimedOut -or $result.ExitCode -lt 0 -or $result.ExitCode -ge 8) {
        Remove-VesDiscLocalCopyRobust -Path $localPath
        return $null
    }
    if (-not (Test-Path -LiteralPath $localPath)) { return $null }
    return $localPath
}

function Remove-VesDiscLocalCopyRobust {
    <#
    .SYNOPSIS
    Deletes a local disc-source staging copy (tens of GB) with a short
    retry loop -- a bare Remove-Item -ErrorAction SilentlyContinue can
    silently fail (and silently leak that much disk space) if robocopy's
    process handle on the file hasn't fully released yet immediately
    after a Kill()-based timeout, even though Invoke-VesWithTimeoutRetry
    already waits for full process exit (team review, 2026-08-04).
    #>
    param([Parameter(Mandatory)][string]$Path)
    for ($i = 0; $i -lt 5; $i++) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { return }
        Start-Sleep -Seconds 2
    }
    Write-Warning "Could not remove local disc-source staging copy after retries (possible disk-space leak): $Path"
}

function Invoke-VesFastStreamCopyDiscExtraction {
    <#
    .SYNOPSIS
    Genuine zero-recompression extraction: stages the disc source
    locally first (Copy-VesDiscSourceLocal -- required, see its own
    comment for why a direct network read is unusable), then ffmpeg
    reads the LOCAL copy via libbluray (`bluray:$localSource`, auto-
    selected main playlist) and stream-copies every track (-c copy)
    instead of HandBrake's x264 -q 0 re-encode. Verified empirically
    2026-08-04 against a real 83.5-minute Blu-ray title: the local
    stream-copy itself takes ~45 seconds versus 12+ hours for x264
    -q 0, smaller output (no redundant DTS-core-plus-MA duplication),
    byte-identical video, full DTS-HD MA audio preserved (not just the
    backward-compatible core). Total wall time including the local
    staging copy is a few minutes for a real disc, not 45 seconds --
    still a dramatic win over the original path.

    Safety: only trusted when (1) DurationUnique from
    Select-VesDominantDiskTitle is $true -- duration-match alone can't
    distinguish two full-length playlists of near-identical runtime on
    playlist-obfuscated/multi-angle discs, and (2) the auto-selected
    title's probed duration matches the title HandBrake's own scan
    already selected (within $script:VesDiscStreamCopyDurationToleranceSeconds).
    A disc that fails either check, or the local staging copy, safely
    returns $false so the caller falls back to the slower but
    unconditionally-correct HandBrake path -- never silently grabs the
    wrong title's content. Team review, 2026-08-04: all three reviewers
    independently flagged duration-only matching (without the
    uniqueness gate) as unsafe on its own, and flagged the original
    version of the post-copy duration re-check below as fail-OPEN
    (treating an unprobeable/unknown output duration as "trust it"
    instead of "reject it") -- fixed here to fail closed.
    #>
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][double]$ExpectedDurationSeconds,
        [Parameter(Mandatory)][string]$ScratchFile,
        [bool]$DurationUnique = $false,
        [int]$LocalCopyTimeoutSeconds = 10800,
        [int]$TimeoutSeconds = 600
    )
    if (-not $DurationUnique) {
        Write-Host "Fast stream-copy skipped: another title on the disc has a duration within $($script:VesDiscStreamCopyDurationToleranceSeconds)s of the selected one -- duration alone can't safely prove libbluray picked the same title -- falling back to lossless x264 extraction"
        return $false
    }

    $localStagingDir = Join-Path (Split-Path -Parent $ScratchFile) 'disc-source-local'
    $localSource = Copy-VesDiscSourceLocal -Source $Source -LocalStagingDir $localStagingDir -TimeoutSeconds $LocalCopyTimeoutSeconds
    if (-not $localSource) {
        Write-Host "Fast stream-copy skipped: could not stage the disc source locally -- falling back to lossless x264 extraction"
        return $false
    }
    # Defensive: a path ending in \ immediately before a closing " in a Windows
    # command line gets misparsed (the backslash escapes the quote) -- Join-Path
    # shouldn't produce a trailing separator here, but trimming is cheap
    # insurance against corrupting the ffprobe/ffmpeg argument list (team
    # review, 2026-08-04).
    $localSource = $localSource.TrimEnd('\')
    try {
        $probed = Get-VesBlurayProbeDurationSeconds -FfprobePath $FfprobePath -Source $localSource
        if ($null -eq $probed) { return $false }
        if ([math]::Abs($probed - $ExpectedDurationSeconds) -gt $script:VesDiscStreamCopyDurationToleranceSeconds) {
            Write-Host "Fast stream-copy skipped: libbluray auto-selected title ($([math]::Round($probed,1))s) doesn't match the selected title ($($ExpectedDurationSeconds)s) -- falling back to lossless x264 extraction"
            return $false
        }

        $ffArgs = @('-y', '-v', 'warning', '-i', "bluray:$localSource", '-map', '0', '-c', 'copy', $ScratchFile)
        $result = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList $ffArgs -TimeoutSeconds $TimeoutSeconds -MaxRetries 0
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            Remove-Item -LiteralPath $ScratchFile -Force -ErrorAction SilentlyContinue
            return $false
        }
        if (-not (Test-Path -LiteralPath $ScratchFile) -or (Get-Item -LiteralPath $ScratchFile -Force).Length -eq 0) {
            Remove-Item -LiteralPath $ScratchFile -Force -ErrorAction SilentlyContinue
            return $false
        }
        # Final correctness check: the actual written file's duration must also match --
        # a stream-copy that silently truncated (e.g. a corrupt disc region) would still
        # exit 0 from ffmpeg in some cases, so re-verify against the real output, not
        # just the pre-copy probe. This is a plain media file now, NOT a disc structure --
        # use the ordinary duration probe, not Get-VesBlurayProbeDurationSeconds. Fail
        # CLOSED (discard + fall back) when this probe can't produce a positive duration
        # -- "unknown" must never be treated as "trust it".
        $outDur = Get-VesMediaDurationSeconds -Path $ScratchFile -FfprobePath $FfprobePath
        if ($null -eq $outDur -or [math]::Abs($outDur - $ExpectedDurationSeconds) -gt $script:VesDiscStreamCopyDurationToleranceSeconds) {
            Write-Warning "Fast stream-copy output duration mismatch or unreadable ($outDur vs expected $ExpectedDurationSeconds s) -- discarding, falling back"
            Remove-Item -LiteralPath $ScratchFile -Force -ErrorAction SilentlyContinue
            return $false
        }
        return $true
    } finally {
        # Always clean up the local raw copy of the disc -- it served its purpose
        # once the stream-copy attempt (success or failure) is done, and it's as
        # large as the disc itself.
        Remove-VesDiscLocalCopyRobust -Path $localSource
    }
}

function Invoke-VesLosslessDiscExtraction {
    <#
    .SYNOPSIS
    Port of handbrake_extract_disc_title_lossless(), now trying a real
    zero-recompression stream-copy first (Invoke-VesFastStreamCopyDiscExtraction)
    and falling back to the original x264 -q 0 HandBrake re-encode (not
    a true lossless codec -- HandBrake has no video passthrough,
    matching bash's own documented reasoning and its ffv1-segfault
    finding) only when the fast path can't confidently identify the
    same title. Space-checked against $SpaceMultiplier x the disc's own
    size first (kept for the fallback path; the fast path's real output
    is normally much smaller than the disc itself). Returns the scratch
    file path on success, $null on any failure.
    #>
    param(
        [Parameter(Mandatory)][string]$HandBrakeCliPath,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$TitleIndex,
        [Parameter(Mandatory)][string]$ScratchRootDir,
        [int]$SpaceMultiplier = $script:VesDiscExtractSpaceMultiplier,
        [double]$ExpectedDurationSeconds = 0,
        [bool]$DurationUnique = $false,
        [string]$FfmpegPath,
        [string]$FfprobePath
    )
    try {
        New-Item -ItemType Directory -Path $ScratchRootDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Cannot create disc-extraction scratch dir -- skipping: $ScratchRootDir"
        return $null
    }

    $discSize = (Get-Item -LiteralPath $Source -Force).Length
    if ((Get-Item -LiteralPath $Source -Force).PSIsContainer) {
        # BDMV root -- sum the whole tree.
        $discSize = (Get-ChildItem -LiteralPath $Source -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    }
    $need = $discSize * $SpaceMultiplier
    # .PSDrive is $null for UNC/network scratch paths (no drive letter) --
    # $null.Free would itself be $null, and PowerShell's numeric comparison
    # coerces $null to 0, so "$null -lt $need" is always $true: every disc
    # would be skipped for "not enough space" whenever the scratch dir lives
    # on a network share. Skip the check entirely rather than fail closed on
    # a check that can't actually run (team review, 2026-08-04).
    $drive = (Get-Item -LiteralPath $ScratchRootDir -Force).PSDrive
    if ($drive -and $null -ne $drive.Free -and $drive.Free -lt $need) {
        Write-Warning "Not enough free space in disc-extraction scratch dir ($ScratchRootDir): $([math]::Round($drive.Free/1GB,1))GB free, need ~$([math]::Round($need/1GB,1))GB at ${SpaceMultiplier}x disc size -- skipping: $Source"
        return $null
    }

    $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
    $scratchDir = Join-Path $ScratchRootDir "disc-extract-$token"
    try {
        New-Item -ItemType Directory -Path $scratchDir -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Could not create a private extraction scratch dir under $ScratchRootDir -- skipping: $Source"
        return $null
    }
    $scratchFile = Join-Path $scratchDir "$([System.IO.Path]::GetFileNameWithoutExtension((Get-VesDiscExtractLinkBasename -Source $Source))).mkv"

    if ($FfmpegPath -and $FfprobePath -and $ExpectedDurationSeconds -gt 0) {
        Write-Host "Attempting fast stream-copy extraction (title $TitleIndex, expected ${ExpectedDurationSeconds}s): $Source"
        if (Invoke-VesFastStreamCopyDiscExtraction -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -Source $Source `
                -ExpectedDurationSeconds $ExpectedDurationSeconds -ScratchFile $scratchFile -DurationUnique $DurationUnique) {
            Write-Host "Fast stream-copy extraction OK: $scratchFile"
            return $scratchFile
        }
    }

    $hbArgs = @('-i', $Source, '-t', "$TitleIndex", '-o', $scratchFile, '-e', 'x264', '-q', '0',
        '--aencoder', 'copy', '--all-audio', '--all-subtitles')
    $errLog = Join-Path $scratchDir 'extract-error.log'
    $result = Invoke-VesHandBrakeWithProgress -HandBrakeCliPath $HandBrakeCliPath -ArgumentList $hbArgs -ErrorLogPath $errLog

    if ($result.Success -and (Test-Path -LiteralPath $scratchFile) -and (Get-Item -LiteralPath $scratchFile -Force).Length -gt 0) {
        return $scratchFile
    }
    Write-Warning "Lossless disc-title extraction failed (exitcode=$($result.ExitCode) hberror=$($result.HandBrakeError)): $Source"
    Remove-VesDirectoryRobust -Path $scratchDir -Recurse
    return $null
}

function Invoke-VesProcessDiskSource {
    <#
    .SYNOPSIS
    Port of process_disk(): scan -> select title -> collision-check ->
    lossless extraction -> hand the extracted intermediate (as the
    real encoder -Source) and the disc's own logical path (drives
    destination/content-dir decisions) to the caller's real encode
    function -> clean up the scratch extraction regardless of outcome.

    .PARAMETER EncodeFunction
    Scriptblock taking ($ExtractedPath, $LogicalSource, $Destination),
    returning $true/$false -- the caller's real encode pipeline
    (VesTwoStageEncode.psm1's Invoke-VesTwoStageEncode wrapped
    accordingly, or an AV1/x265 retry function). This module never
    encodes anything itself -- disc extraction produces an ordinary
    local MKV that the normal encode pipeline then processes exactly
    like any other source file, matching bash's own architecture.
    #>
    param(
        [Parameter(Mandatory)][string]$HandBrakeCliPath,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ScratchRootDir,
        [Parameter(Mandatory)][scriptblock]$EncodeFunction,
        [string]$FfmpegPath,
        [string]$FfprobePath
    )
    if (-not (Test-VesIsDiskSource -Source $Source)) {
        return [PSCustomObject]@{ Action = 'error'; Reason = 'not a disk source' }
    }

    Write-Host "Scanning titles: $Source"
    $sel = Select-VesDominantDiskTitle -HandBrakeCliPath $HandBrakeCliPath -Source $Source
    if ($sel.Action -eq 'skip') {
        Write-Warning "Skipping disc source: $($sel.Reason)"
        return [PSCustomObject]@{ Action = 'skip'; Reason = $sel.Reason }
    }

    if (Test-VesDiscExtractionTargetCollision -Source $Source) {
        Write-Warning "Skipping disc source: extraction target already exists -- needs manual review"
        return [PSCustomObject]@{ Action = 'skip'; Reason = 'extraction target collides with an existing real file' }
    }

    Write-Host "Processing (title $($sel.TitleIndex), $($sel.DurationSeconds)s): $Source"
    $extracted = Invoke-VesLosslessDiscExtraction -HandBrakeCliPath $HandBrakeCliPath -Source $Source `
        -TitleIndex $sel.TitleIndex -ScratchRootDir $ScratchRootDir -ExpectedDurationSeconds $sel.DurationSeconds `
        -DurationUnique ([bool]$sel.DurationUnique) -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath
    if (-not $extracted) {
        return [PSCustomObject]@{ Action = 'skip'; Reason = 'lossless title extraction failed' }
    }

    $ok = $false
    try {
        $ok = & $EncodeFunction $extracted $Source $Destination
    } finally {
        Remove-VesDirectoryRobust -Path (Split-Path -Parent $extracted) -Recurse
    }
    return [PSCustomObject]@{ Action = 'processed'; Success = [bool]$ok }
}

Export-ModuleMember -Function Get-VesDiscMediaContentDir, Get-VesDiscExtractLinkBasename, `
    Find-VesDiskSources, Invoke-VesHandBrakeScan, Get-VesHandbrakeMainFeatureTitle, `
    Get-VesHandbrakeTitleDurations, Select-VesDominantDiskTitle, Test-VesDiscExtractionTargetCollision, `
    Get-VesBlurayProbeDurationSeconds, Invoke-VesFastStreamCopyDiscExtraction, `
    Invoke-VesLosslessDiscExtraction, Invoke-VesProcessDiskSource
