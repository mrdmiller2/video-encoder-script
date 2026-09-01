# Windows port of modules/ves-per-shot-qp.sh -- Phase 6 per-shot VMAF-
# target QP search + distributed shot-claim coordination (STABLE HALF
# ONLY, stage 1). See the bash module header for the full design
# reasoning (why SvtAv1EncApp --qpfile not ffmpeg -qp; why one continuous
# encode with a per-frame qpfile, not per-shot spliced files).
#
# Deliberate Windows deviation from the bash version, not an oversight:
# bash's per-shot claim reuses atomic mkdir-lock (same idiom as
# place_in_progress_flag / chunk_claim_next). This port instead reuses
# VesSharedMutex's atomic-FILE-creation primitive, for the exact same
# documented reason VesTitleLock / VesChunkCoordinator avoid mkdir on
# Windows: this NAS's SMB share gives freshly-created DIRECTORIES a
# broken ACL that even the creating session can't write into
# (VesSharedMutex.psm1's own header comment). The shot MANIFEST
# directory itself (not a lock, a real content container) still has to
# be a directory -- created via New-Item, then immediately widened via
# Set-VesEveryoneReadWrite (VesDoneLog.psm1), matching
# VesChunkCoordinator's established fix.
#
# Path keying also follows VesChunkCoordinator: full filename (not
# bash's extension-stripped canonical_title_from_source). Manifest =
# "<leaf>.shots", lock = "<leaf>.shot<N>.lock". Cross-platform claim
# sharing with a concurrent bash fleet is therefore NOT automatic for
# this stage -- same tradeoff already accepted for .chunks.
#
# STAGE 2 DEFERRED (allocator still being calibrated by a live survey):
#   - assemble_qpfile_via_equal_slope_budget  -> Assemble-VesQpfileViaEqualSlopeBudget
#   - assemble_qpfile_from_shot_manifest      -> Assemble-VesQpfileFromShotManifest
#   - assemble_qpfile_via_equal_slope         (dead in bash; do not revive)

if (-not (Get-Module -Name VesSharedMutex)) {
    Import-Module (Join-Path $PSScriptRoot 'VesSharedMutex.psm1') -Force
}
if (-not (Get-Module -Name VesDoneLog)) {
    Import-Module (Join-Path $PSScriptRoot 'VesDoneLog.psm1') -Force
}
if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}
if (-not (Get-Module -Name VesValidation)) {
    Import-Module (Join-Path $PSScriptRoot 'VesValidation.psm1') -Force
}
if (-not (Get-Module -Name VesProfileDecision)) {
    Import-Module (Join-Path $PSScriptRoot 'VesProfileDecision.psm1') -Force
}
if (-not (Get-Module -Name VesVmafCrfSearch)) {
    Import-Module (Join-Path $PSScriptRoot 'VesVmafCrfSearch.psm1') -Force
}
if (-not (Get-Module -Name VesSceneDetect)) {
    Import-Module (Join-Path $PSScriptRoot 'VesSceneDetect.psm1') -Force
}

# Manifest-build incomplete reclaim ceiling (bash: 1800s) -- scene-detect
# only, much tighter than per-shot search staleness.
$script:VesShotManifestBuildStaleSeconds = 1800

function Get-VesShotSearchStaleSeconds {
    if ($env:SHOT_SEARCH_STALE_SECS) { return [int]$env:SHOT_SEARCH_STALE_SECS }
    return 25200
}

function Get-VesShotSearchRetryWait {
    if ($env:SHOT_SEARCH_RETRY_WAIT) { return [int]$env:SHOT_SEARCH_RETRY_WAIT }
    return 60
}

function Get-VesPerShotQpMin {
    if ($env:PER_SHOT_QP_MIN) { return [int]$env:PER_SHOT_QP_MIN }
    return 14
}

function Get-VesPerShotQpMax {
    if ($env:PER_SHOT_QP_MAX) { return [int]$env:PER_SHOT_QP_MAX }
    return 50
}

function Get-VesPerShotQpExtendMargin {
    if ($env:PER_SHOT_QP_EXTEND_MARGIN) { return [double]$env:PER_SHOT_QP_EXTEND_MARGIN }
    return 3.0
}

function Get-VesPerShotQpExtendStep {
    if ($env:PER_SHOT_QP_EXTEND_STEP) { return [int]$env:PER_SHOT_QP_EXTEND_STEP }
    return 4
}

function Get-VesPerShotQpExtendCeil {
    if ($env:PER_SHOT_QP_EXTEND_CEIL) { return [int]$env:PER_SHOT_QP_EXTEND_CEIL }
    return 55
}

function Get-VesPerShotQpExtendFloor {
    if ($env:PER_SHOT_QP_EXTEND_FLOOR) { return [int]$env:PER_SHOT_QP_EXTEND_FLOOR }
    return 10
}

function Get-VesPerShotQpExtendProbes {
    if ($env:PER_SHOT_QP_EXTEND_PROBES) { return [int]$env:PER_SHOT_QP_EXTEND_PROBES }
    return 2
}

function Get-VesPerShotQpCrossoverProbes {
    if ($env:PER_SHOT_QP_CROSSOVER_PROBES) { return [int]$env:PER_SHOT_QP_CROSSOVER_PROBES }
    return 1
}

function Get-VesShotManifestDir {
    <#
    .SYNOPSIS
    Manifest directory for one title's shots. Full-filename keyed (see
    module header), matching Get-VesChunkManifestDir.
    #>
    param([Parameter(Mandatory)][string]$Source)
    $dir = Split-Path -Parent $Source
    $name = Split-Path -Leaf $Source
    return Join-Path $dir "$name.shots"
}

function Get-VesShotLockPath {
    <#
    .SYNOPSIS
    Lock FILE path for one shot index (atomic CreateNew target -- NOT a
    directory). Bash's shot_lock_path prints the stem; callers append
    .lock. Here the returned path already includes .lock so it can be
    handed straight to Enter-VesSharedMutexOnce.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$Index
    )
    $dir = Split-Path -Parent $Source
    $name = Split-Path -Leaf $Source
    return Join-Path $dir "$name.shot$Index.lock"
}

function Get-VesShotPathMtime {
    <#
    .SYNOPSIS
    Port of _shot_path_mtime(). Unix-epoch mtime seconds of a path, or
    $null if unavailable. Used for stale-incomplete-mdir reclaim and
    scratch sweep age checks; shot CLAIM staleness goes through
    Get-VesSharedMutexAge / Enter-VesSharedMutexOnce (file lock mtime).
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [int][DateTimeOffset]::new($item.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
    } catch {
        return $null
    }
}

function Get-VesShotMetaValue {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Key
    )
    # Model values contain literal "=" (e.g. version=vmaf_v0.6.1neg) --
    # take everything after the first "=" on the matching line, matching
    # bash's substr(...,index(...)+1) fix (found live 2026-08-24).
    if ($Content -match "(?m)^$([regex]::Escape($Key))=(.*)$") {
        return $Matches[1].Trim()
    }
    return $null
}

function Get-VesShotFfmpegTimeout {
    <#
    .SYNOPSIS
    Port of _shot_ffmpeg_timeout() -- duration-scaled, not size-scaled.
    #>
    param([Parameter(Mandatory)][double]$DurationSeconds)
    $base = 300
    $perSec = 120
    $cap = 3600
    $dInt = [int][math]::Round([math]::Max(0, $DurationSeconds))
    $scaled = $base + ($dInt * $perSec)
    if ($scaled -gt $cap) { $scaled = $cap }
    return $scaled
}

function Get-VesInterpQp {
    <#
    .SYNOPSIS
    Port of _interp_qp() -- linear interpolation between bracketing
    (QP,VMAF) samples, clamped strictly inside (AboveQp, BelowQp).
    #>
    param(
        [Parameter(Mandatory)][int]$AboveQp,
        [Parameter(Mandatory)][double]$AboveScore,
        [Parameter(Mandatory)][int]$BelowQp,
        [Parameter(Mandatory)][double]$BelowScore,
        [Parameter(Mandatory)][double]$Target
    )
    if (($BelowQp - $AboveQp) -le 1) { return $AboveQp }
    $q = if ($BelowScore -eq $AboveScore) {
        [int][math]::Round(($AboveQp + $BelowQp) / 2.0)
    } else {
        [int][math]::Round($AboveQp + ($Target - $AboveScore) * ($BelowQp - $AboveQp) / ($BelowScore - $AboveScore))
    }
    if ($q -le $AboveQp) { $q = $AboveQp + 1 }
    if ($q -ge $BelowQp) { $q = $BelowQp - 1 }
    return $q
}

function Test-VesShotManifestAllResolved {
    <#
    .SYNOPSIS
    Port of shot_manifest_all_resolved().
    #>
    param([Parameter(Mandatory)][string]$Source)
    $mdir = Get-VesShotManifestDir -Source $Source
    if (-not (Test-Path -LiteralPath (Join-Path $mdir '.complete'))) { return $false }
    $shotFiles = Get-ChildItem -LiteralPath $mdir -Filter 'shot-*.meta' -ErrorAction SilentlyContinue
    if (-not $shotFiles) { return $false }
    foreach ($f in $shotFiles) {
        $meta = Get-Content -LiteralPath $f.FullName -Raw
        $idxStr = Get-VesShotMetaValue -Content $meta -Key 'index'
        if ($null -eq $idxStr) { return $false }
        $idx = [int]$idxStr
        $statusFile = Join-Path $mdir ("shot-{0:D3}.status" -f $idx)
        if (-not (Test-Path -LiteralPath $statusFile)) { return $false }
        $stContent = Get-Content -LiteralPath $statusFile -Raw
        $st = Get-VesShotMetaValue -Content $stContent -Key 'status'
        if ($st -ne 'resolved') { return $false }
    }
    return $true
}

function New-VesShotManifest {
    <#
    .SYNOPSIS
    Port of shot_split_create_manifest(). Runs Get-VesSceneBoundaries
    once and writes shot-NNN.meta + manifest.meta + .complete-last.
    Idempotent via .complete. Create race gated by a claim FILE (not
    mkdir on the manifest dir), matching New-VesChunkManifest. Stale
    incomplete mdir (no .complete, age > 1800s) is reclaimed.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Codec,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][double]$Target,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$Model
    )
    $mdir = Get-VesShotManifestDir -Source $Source
    $completeMarker = Join-Path $mdir '.complete'
    if (Test-Path -LiteralPath $completeMarker) { return $true }

    # Stale-incomplete reclaim BEFORE the split claim (bash reclaims when
    # mkdir fails on an existing incomplete dir). Same 1800s ceiling.
    if ((Test-Path -LiteralPath $mdir) -and -not (Test-Path -LiteralPath $completeMarker)) {
        $mtime = Get-VesShotPathMtime -Path $mdir
        if ($null -ne $mtime) {
            $age = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $mtime)
            if ($age -gt $script:VesShotManifestBuildStaleSeconds) {
                Write-Warning "Shot split: reclaiming stale incomplete manifest dir (age=${age}s > 1800): $mdir"
                try { Remove-Item -LiteralPath $mdir -Recurse -Force -ErrorAction Stop } catch {
                    Write-Warning "Shot split: could not remove stale mdir: $_"
                    return $false
                }
            }
        }
    }

    $splitClaimPath = "$mdir.splitting.lock"
    $token = Enter-VesSharedMutexOnce -LockPath $splitClaimPath -StaleSeconds $script:VesShotManifestBuildStaleSeconds
    if (-not $token) { return $false }
    try {
        if (Test-Path -LiteralPath $completeMarker) { return $true }

        if (-not (Test-Path -LiteralPath $mdir)) {
            New-Item -ItemType Directory -Path $mdir -Force | Out-Null
            Set-VesEveryoneReadWrite -Path $mdir
        }

        $dur = Get-VesMediaDurationSeconds -Path $Source -FfprobePath $FfprobePath
        if ($null -eq $dur) {
            Write-Warning "Shot split: could not probe duration for $Source"
            return $false
        }
        if (-not $Model) {
            $Model = Get-VesVmafModelForSource -Source $Source -FfprobePath $FfprobePath
        }

        try {
            $boundaries = @(Get-VesSceneBoundaries -Source $Source -FfmpegPath $FfmpegPath)
        } catch {
            Write-Warning "Get-VesSceneBoundaries failed for $Source -- $_"
            return $false
        }

        $n = 0
        $nb = 0
        $prev = '0.0'
        $buildTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ves-shotbuild-$PID-$(Get-Random)")
        New-Item -ItemType Directory -Path $buildTmp -Force | Out-Null
        try {
            foreach ($ts in $boundaries) {
                if (-not $ts) { continue }
                $shotFile = Join-Path $buildTmp ("shot-{0:D3}.meta" -f $n)
                @"
index=$n
start_ts=$prev
end_ts=$ts
"@ | Set-Content -LiteralPath $shotFile -Encoding utf8
                $n++
                $nb++
                $prev = $ts
            }
            # No cuts found for a non-trivial runtime -> refuse bogus 1-shot
            # manifest (bash guard, found live 2026-08-28).
            if ($nb -eq 0 -and $dur -gt 180) {
                Write-Warning "Get-VesSceneBoundaries found 0 cuts in a ${dur}s file -- refusing bogus 1-shot manifest for $Source"
                return $false
            }
            $finalShot = Join-Path $buildTmp ("shot-{0:D3}.meta" -f $n)
            $durStr = $dur.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            @"
index=$n
start_ts=$prev
end_ts=$durStr
"@ | Set-Content -LiteralPath $finalShot -Encoding utf8
            $n++

            $manifestFile = Join-Path $buildTmp 'manifest.meta'
            @"
source=$Source
shot_count=$n
codec=$Codec
profile=$Profile
target=$Target
model=$Model
created_utc=$([DateTimeOffset]::UtcNow.ToString('o'))
created_host=$env:COMPUTERNAME
"@ | Set-Content -LiteralPath $manifestFile -Encoding utf8

            Get-ChildItem -LiteralPath $buildTmp -File | ForEach-Object {
                $dest = Join-Path $mdir $_.Name
                Move-Item -LiteralPath $_.FullName -Destination $dest -Force
                Set-VesEveryoneReadWrite -Path $dest
            }
        } finally {
            if (Test-Path -LiteralPath $buildTmp) {
                Remove-Item -LiteralPath $buildTmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        New-Item -ItemType File -Path $completeMarker -Force | Out-Null
        Set-VesEveryoneReadWrite -Path $completeMarker
        Write-Host "Shot split: $n shot(s) created for $(Split-Path -Leaf $Source)"
        return $true
    } finally {
        Exit-VesSharedMutex -LockPath $splitClaimPath -Token $token
    }
}

function Enter-VesShotClaim {
    <#
    .SYNOPSIS
    Port of shot_claim_next(). Claims one not-yet-resolved shot via
    VesSharedMutex atomic FILE creation (NOT mkdir). Returns a claim
    object (Index/LockPath/Token/MetaPath) or $null. Staleness ceiling =
    SHOT_SEARCH_STALE_SECS (default 25200). Companion .meta holds host/pid
    for triage (never read by Enter/Exit-VesSharedMutex -- same VesTitleLock
    composition rule).
    #>
    param([Parameter(Mandatory)][string]$Source)
    $mdir = Get-VesShotManifestDir -Source $Source
    if (-not (Test-Path -LiteralPath (Join-Path $mdir '.complete'))) { return $null }

    $staleSecs = Get-VesShotSearchStaleSeconds
    $shotFiles = Get-ChildItem -LiteralPath $mdir -Filter 'shot-*.meta' -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($f in $shotFiles) {
        $meta = Get-Content -LiteralPath $f.FullName -Raw
        $idxStr = Get-VesShotMetaValue -Content $meta -Key 'index'
        if ($null -eq $idxStr) { continue }
        $idx = [int]$idxStr
        $statusFile = Join-Path $mdir ("shot-{0:D3}.status" -f $idx)
        if (Test-Path -LiteralPath $statusFile) {
            $stContent = Get-Content -LiteralPath $statusFile -Raw
            if ((Get-VesShotMetaValue -Content $stContent -Key 'status') -eq 'resolved') { continue }
        }

        $lockPath = Get-VesShotLockPath -Source $Source -Index $idx
        $metaPath = "$lockPath.meta"

        # Prefer SharedMutexOnce (CreateNew + one stale reclaim). Age for
        # reclaim uses lock-file mtime; if the lock file is gone but a
        # stranded companion .meta remains, fall back to that mtime the
        # same way bash falls back owner.meta -> lockdir (_shot_path_mtime
        # chain) -- then attempt CreateNew again after renaming the meta
        # aside. Primary path is still the lock file.
        $token = Enter-VesSharedMutexOnce -LockPath $lockPath -StaleSeconds $staleSecs
        if (-not $token -and (Test-Path -LiteralPath $lockPath)) {
            # Dual-mtime check matching bash: owner.meta age OR lock age.
            $mtime = Get-VesShotPathMtime -Path $metaPath
            if ($null -eq $mtime) { $mtime = Get-VesShotPathMtime -Path $lockPath }
            if ($null -ne $mtime) {
                $age = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $mtime)
                if ($age -gt $staleSecs) {
                    $reclaimName = "$lockPath.stale.$env:COMPUTERNAME.$PID.$(Get-Random)"
                    try {
                        [System.IO.File]::Move($lockPath, $reclaimName)
                        try { [System.IO.File]::Delete($reclaimName) } catch { }
                        if (Test-Path -LiteralPath $metaPath) {
                            try { Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue } catch { }
                        }
                        $token = Enter-VesSharedMutexOnce -LockPath $lockPath -StaleSeconds $staleSecs
                    } catch { }
                }
            }
        }
        if (-not $token) { continue }

        $owner = @"
host=$env:COMPUTERNAME
pid=$PID
claimed_utc=$([DateTimeOffset]::UtcNow.ToString('o'))
"@
        try {
            $owner | Set-Content -LiteralPath $metaPath -Encoding utf8
            Set-VesEveryoneReadWrite -Path $metaPath
        } catch { }

        return [PSCustomObject]@{
            Index    = $idx
            LockPath = $lockPath
            MetaPath = $metaPath
            Token    = $token
        }
    }
    return $null
}

function Exit-VesShotClaim {
    <#
    .SYNOPSIS
    Port of shot_release_claim() -- token-matched SharedMutex release +
    companion meta cleanup.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Claim
    )
    if ($Claim.MetaPath) {
        try { Remove-Item -LiteralPath $Claim.MetaPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    Exit-VesSharedMutex -LockPath $Claim.LockPath -Token $Claim.Token
}

function Clear-VesShotScratch {
    <#
    .SYNOPSIS
    Port of _shot_scratch_sweep(). Only removes dead-worker scratch
    (age > SHOT_SEARCH_STALE_SECS AND no child mtime within the last
    60 minutes). Live searches can sit write-quiet during a long VMAF
    read; a short window would delete a sibling's in-flight dir.
    #>
    param([string]$BaseDir)
    if (-not $BaseDir) {
        $BaseDir = if ($env:RAMDISK_JOB_DIR) { $env:RAMDISK_JOB_DIR } else { [System.IO.Path]::GetTempPath() }
    }
    $ceil = Get-VesShotSearchStaleSeconds
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $patterns = @('ves-shotqp-*', 'ves-crf-*', 'ves-vmaf-*', 'ves-oldenh-*')
    foreach ($pat in $patterns) {
        Get-ChildItem -LiteralPath $BaseDir -Directory -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
            $mtime = Get-VesShotPathMtime -Path $_.FullName
            if ($null -eq $mtime) { return }
            if (($now - $mtime) -le $ceil) { return }
            # Quiescence: any descendant touched in the last 60 minutes
            # means a live worker may still be using it.
            $recent = Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { (([DateTimeOffset]::UtcNow - $_.LastWriteTimeUtc).TotalMinutes) -lt 60 } |
                Select-Object -First 1
            if ($recent) { return }
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                Write-Host "shot-search: swept dead-worker scratch $($_.FullName)"
            } catch {
                # Likely still open -- leave for the system reaper.
            }
        }
    }
}

function Get-VesVmafScoreShot {
    <#
    .SYNOPSIS
    Port of _vmaf_score_shot() (v6.0.1A): SvtAv1EncApp --qpfile uniform
    encode, grain-ON VMAF (NO -export_side_data film_grain), frame-
    aligned via setpts=PTS-STARTPTS on matched extracted clips. Two-stage
    seek (fast pre-input -ss + accurate post-input -ss). Returns
    PSCustomObject @{ Vmaf; Bytes } or $null on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][double]$End,
        [Parameter(Mandatory)][int]$Qp,
        [Parameter(Mandatory)][string]$Codec,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$SvtAv1EncAppPath
    )
    if ($Codec -ne 'av1') { return $null }
    # SvtAv1EncApp is optional: several Windows fleet hosts (PRINCE) have no
    # standalone binary and encode via ffmpeg's libsvtav1. For the per-shot
    # SEARCH every qpfile is UNIFORM (one QP for the whole shot), which is
    # identical to `-svtav1-params qp=N` -- no per-frame qpfile needed here.
    # (The stage-2 allocator's per-frame qpfile will need the real thing.)
    $useSvtBin = $SvtAv1EncAppPath -and (Test-Path -LiteralPath $SvtAv1EncAppPath)

    $svtp = Get-VesProfileSvtParams -Profile $Profile -FfmpegPath $FfmpegPath
    if (-not $svtp) { return $null }

    $base = if ($env:RAMDISK_JOB_DIR) { $env:RAMDISK_JOB_DIR } else { [System.IO.Path]::GetTempPath() }
    $work = Join-Path $base ("ves-shotqp-$PID-$(Get-Random)")
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $clip = Join-Path $work 'shot.mkv'
        $seekMargin = 30.0
        $fastSs = [math]::Max(0.0, $Start - $seekMargin)
        $accSs = $Start - $fastSs
        $clipDur = [math]::Max(0.0, $End - $Start)
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $fastSsStr = $fastSs.ToString('0.######', $inv)
        $accSsStr = $accSs.ToString('0.######', $inv)
        $clipDurStr = $clipDur.ToString('0.######', $inv)

        $ext = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
            '-y', '-v', 'error', '-ss', $fastSsStr, '-i', $Source,
            '-ss', $accSsStr, '-t', $clipDurStr,
            '-map', '0:v:0', '-c:v', 'ffv1', '-level', '3', $clip
        ) -TimeoutSeconds (Get-VesShotFfmpegTimeout -DurationSeconds $clipDur) -MaxRetries 1
        if ($ext.TimedOut -or $ext.ExitCode -ne 0) { return $null }
        if (-not (Test-Path -LiteralPath $clip) -or (Get-Item -LiteralPath $clip).Length -le 0) { return $null }

        $encTimeout = Get-VesShotFfmpegTimeout -DurationSeconds $clipDur
        $y4m = Join-Path $work 'shot.y4m'
        $y4mRun = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
            '-y', '-v', 'error', '-i', $clip, '-map', '0:v:0',
            '-pix_fmt', 'yuv420p10le', '-strict', '-1', $y4m
        ) -TimeoutSeconds $encTimeout -MaxRetries 1
        if ($y4mRun.TimedOut -or $y4mRun.ExitCode -ne 0) { return $null }

        $nframesResult = Invoke-VesWithTimeoutRetry -FilePath $FfprobePath -ArgumentList @(
            '-v', 'error', '-select_streams', 'v:0', '-count_packets',
            '-show_entries', 'stream=nb_read_packets', '-of', 'csv=p=0', $clip
        ) -TimeoutSeconds 60 -MaxRetries 1
        $nframes = 0
        if (-not [int]::TryParse(($nframesResult.StdOut.Trim() -replace ',.*$', ''), [ref]$nframes) -or $nframes -le 0) {
            return $null
        }

        if ($useSvtBin) {
            $qpfile = Join-Path $work "uniform-$Qp.qp"
            $qpLines = for ($i = 0; $i -lt $nframes; $i++) { "$Qp" }
            $qpLines | Set-Content -LiteralPath $qpfile -Encoding ascii
            $out = Join-Path $work "shot-enc-$Qp.ivf"
            $svtRun = Invoke-VesWithTimeoutRetry -FilePath $SvtAv1EncAppPath -ArgumentList @(
                '-i', $y4m, '--use-q-file', '1', '--qpfile', $qpfile,
                '--svtav1-params', "${svtp}:rc=0", '-b', $out
            ) -TimeoutSeconds $encTimeout -MaxRetries 1
            if ($svtRun.TimedOut -or $svtRun.ExitCode -ne 0) { return $null }
        } else {
            # ffmpeg libsvtav1, uniform QP == qp-file of one value
            $out = Join-Path $work "shot-enc-$Qp.mkv"
            $ffEnc = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
                '-y', '-v', 'error', '-i', $y4m, '-map', '0:v:0',
                '-c:v', 'libsvtav1', '-preset', '5',
                '-svtav1-params', "${svtp}:rc=0:qp=$Qp",
                '-pix_fmt', 'yuv420p10le', $out
            ) -TimeoutSeconds $encTimeout -MaxRetries 1
            if ($ffEnc.TimedOut -or $ffEnc.ExitCode -ne 0) { return $null }
        }
        if (-not (Test-Path -LiteralPath $out) -or (Get-Item -LiteralPath $out).Length -le 0) { return $null }

        if ($useSvtBin) {
            $outMkv = Join-Path $work "shot-enc-$Qp.mkv"
            $mux = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
                '-y', '-v', 'error', '-i', $out, '-c', 'copy', $outMkv
            ) -TimeoutSeconds $encTimeout -MaxRetries 1
            if ($mux.TimedOut -or $mux.ExitCode -ne 0) { return $null }
        } else {
            $outMkv = $out
        }

        # Grain-ON: grain_decode_flag intentionally empty (v6.0.1A).
        # log_path must be a BARE filename with the process CWD set to $work --
        # a Windows drive-letter path (C:\...) breaks ffmpeg's `:`-delimited
        # filter-option parser, and `C\:/...` colon-escaping also fails on
        # current ffmpeg builds (VesVmafCrfSearch.psm1's 2026-08-05 fix,
        # verified on PRINCE).
        $vlogName = "shot-$Qp.vmaf.json"
        $vlog = Join-Path $work $vlogName
        $nThreads = [Environment]::ProcessorCount
        $lavfi = "[0:v]setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=${Model}:n_threads=${nThreads}:log_fmt=json:log_path=$vlogName"
        $vmafRun = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
            '-y', '-v', 'error', '-i', $outMkv, '-i', $clip,
            '-lavfi', $lavfi, '-f', 'null', '-'
        ) -TimeoutSeconds $encTimeout -MaxRetries 1 -WorkingDirectory $work
        if ($vmafRun.TimedOut -or $vmafRun.ExitCode -ne 0) { return $null }
        if (-not (Test-Path -LiteralPath $vlog)) { return $null }

        try {
            $json = Get-Content -LiteralPath $vlog -Raw | ConvertFrom-Json
            $v = [math]::Round([double]$json.pooled_metrics.vmaf.mean, 2)
        } catch {
            return $null
        }
        $b = (Get-Item -LiteralPath $out).Length
        return [PSCustomObject]@{ Vmaf = $v; Bytes = [long]$b }
    } finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-VesPerShotQp {
    <#
    .SYNOPSIS
    Port of resolve_per_shot_qp() (v6.0.1B/C): anchors qp_lo/30/qp_hi,
    interp loop with break when above/below empty, (B) window extension,
    (#3) crossover refinement with split range-check-vs-probe-failure.
    Returns @{ Qp; Vmaf; Samples } (Samples = comma-joined qp:vmaf:bytes)
    or $null on total failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][double]$End,
        [Parameter(Mandatory)][string]$Codec,
        [Parameter(Mandatory)][double]$Target,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$SvtAv1EncAppPath
    )

    $score = @{}
    $bytes = @{}
    $samples = [System.Collections.Generic.List[string]]::new()
    $workingTarget = $Target

    # (#2, GATED) content-adaptive per-shot target
    if ($env:PER_SHOT_ADAPTIVE_TARGET -eq 'true') {
        $baseT = $Target
        $span = if ($env:PER_SHOT_ADAPTIVE_TARGET_SPAN) { [double]$env:PER_SHOT_ADAPTIVE_TARGET_SPAN } else { 2.0 }
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $fss = [math]::Max(0.0, $Start - 30.0)
        $ass = $Start - $fss
        $dur = [math]::Max(0.0, $End - $Start)
        $fssStr = $fss.ToString('0.######', $inv)
        $assStr = $ass.ToString('0.######', $inv)
        $durStr = $dur.ToString('0.######', $inv)

        $yavg = 128.0
        $motion = 0.0
        try {
            $yRun = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
                '-v', 'error', '-nostats', '-ss', $fssStr, '-i', $Source,
                '-ss', $assStr, '-t', $durStr, '-map', '0:v:0',
                '-vf', 'signalstats,metadata=print:file=-', '-f', 'null', '-'
            ) -TimeoutSeconds 120 -MaxRetries 0
            $ys = @([regex]::Matches($yRun.StdErr + $yRun.StdOut, 'lavfi\.signalstats\.YAVG=([0-9.]+)')) |
                ForEach-Object { [double]$_.Groups[1].Value }
            if ($ys.Count -gt 0) { $yavg = [math]::Round(($ys | Measure-Object -Average).Average, 1) }

            $mRun = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
                '-v', 'error', '-nostats', '-ss', $fssStr, '-i', $Source,
                '-ss', $assStr, '-t', $durStr, '-map', '0:v:0',
                '-vf', 'tblend=all_mode=difference,signalstats,metadata=print:file=-', '-f', 'null', '-'
            ) -TimeoutSeconds 120 -MaxRetries 0
            $ms = @([regex]::Matches($mRun.StdErr + $mRun.StdOut, 'lavfi\.signalstats\.YAVG=([0-9.]+)')) |
                ForEach-Object { [double]$_.Groups[1].Value }
            if ($ms.Count -gt 0) { $motion = [math]::Round(($ms | Measure-Object -Average).Average, 2) }
        } catch { }

        $adj = 0.0
        if ($motion -ge 6.0) { $adj = -$span }
        elseif ($yavg -le 55 -and $motion -le 2.0) { $adj = $span }
        $nt = $baseT + $adj
        if ($nt -gt ($baseT + 3)) { $nt = $baseT + 3 }
        if ($nt -lt ($baseT - 3)) { $nt = $baseT - 3 }
        $workingTarget = [math]::Round($nt, 1)
        Write-Host "  per-shot adaptive-target shot=${Start}-${End} yavg=$yavg motion=$motion base=$baseT -> target=$workingTarget"
    }

    $probeQp = {
        param([int]$Q)
        if ($score.ContainsKey($Q)) { return $true }
        $r = Get-VesVmafScoreShot -Source $Source -Start $Start -End $End -Qp $Q `
            -Codec $Codec -Model $Model -Profile $Profile `
            -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath
        if (-not $r) { return $false }
        $score[$Q] = [double]$r.Vmaf
        $bytes[$Q] = [long]$r.Bytes
        $samples.Add("${Q}:$($score[$Q]):$($bytes[$Q])")
        Write-Host "  per-shot qp-search [$Codec] shot=${Start}-${End} qp=$Q vmaf=$($score[$Q])"
        return $true
    }

    $qpLo = Get-VesPerShotQpMin
    $qpHi = Get-VesPerShotQpMax
    foreach ($qp in @($qpLo, 30, $qpHi)) {
        if (-not (& $probeQp $qp)) { return $null }
    }

    for ($i = 0; $i -lt 3; $i++) {
        $above = $null
        $below = $null
        foreach ($qp in ($score.Keys | Sort-Object)) {
            if ($score[$qp] -ge $workingTarget) {
                $above = $qp
            } else {
                $below = $qp
                break
            }
        }
        # v6.0.1B: nothing meets / everything meets -- stop; (B) extension maps RD.
        if ($null -eq $above -or $null -eq $below) { break }
        $gap = $below - $above
        if ($gap -le 1) { break }
        $nextQp = Get-VesInterpQp -AboveQp $above -AboveScore $score[$above] `
            -BelowQp $below -BelowScore $score[$below] -Target $workingTarget
        if (-not (& $probeQp $nextQp)) { break }
    }

    # (B) content-adaptive window extension
    $hiQp = $null
    $hiV = $null
    foreach ($qp in ($score.Keys | Sort-Object)) {
        if ($score[$qp] -ge $workingTarget) {
            $hiQp = $qp
            $hiV = $score[$qp]
        }
    }
    $extMargin = Get-VesPerShotQpExtendMargin
    $extStep = Get-VesPerShotQpExtendStep
    $extCeil = Get-VesPerShotQpExtendCeil
    $extFloor = Get-VesPerShotQpExtendFloor
    $extProbes = Get-VesPerShotQpExtendProbes

    if ($null -ne $hiQp -and $hiQp -ge $qpHi -and $hiV -ge ($workingTarget + $extMargin)) {
        $q = $qpHi
        for ($p = 1; $p -le $extProbes; $p++) {
            $q = $q + $extStep
            if ($q -gt $extCeil) { break }
            if (-not (& $probeQp $q)) { break }
            if ($score[$q] -lt $workingTarget) { break }
        }
    } elseif ($null -eq $hiQp) {
        $q = $qpLo
        for ($p = 1; $p -le $extProbes; $p++) {
            $q = $q - $extStep
            if ($q -lt $extFloor) { break }
            if (-not (& $probeQp $q)) { break }
            if ($score[$q] -ge $workingTarget) { break }
        }
    }

    # (#3) crossover refinement -- v6.0.1C split range-check vs probe failure
    $xoProbes = Get-VesPerShotQpCrossoverProbes
    if ($xoProbes -gt 0) {
        $center = $null
        $ccv = $null
        foreach ($qp in ($score.Keys | Sort-Object)) {
            if ($score[$qp] -ge $workingTarget) { $center = $qp }
        }
        if ($null -eq $center) {
            foreach ($qp in ($score.Keys | Sort-Object)) {
                if ($null -eq $ccv -or $score[$qp] -gt $ccv) {
                    $center = $qp
                    $ccv = $score[$qp]
                }
            }
        }
        if ($null -ne $center) {
            for ($d = 1; $d -le $xoProbes; $d++) {
                $c = $center - $d
                if ($c -ge $extFloor) {
                    if (-not (& $probeQp $c)) {
                        Write-Warning "per-shot crossover probe qp=$c failed (non-fatal)"
                    }
                }
                $c = $center + $d
                if ($c -le $extCeil) {
                    if (-not (& $probeQp $c)) {
                        Write-Warning "per-shot crossover probe qp=$c failed (non-fatal)"
                    }
                }
            }
        }
    }

    $best = $null
    $bv = $null
    $closest = $null
    $cv = $null
    foreach ($qp in ($score.Keys | Sort-Object)) {
        if ($score[$qp] -ge $workingTarget) {
            $best = $qp
            $bv = $score[$qp]
        }
        if ($null -eq $cv -or $score[$qp] -gt $cv) {
            $closest = $qp
            $cv = $score[$qp]
        }
    }
    if ($null -eq $best) {
        $best = $closest
        $bv = $cv
    }
    if ($null -eq $best) { return $null }

    return [PSCustomObject]@{
        Qp      = [int]$best
        Vmaf    = [double]$bv
        Samples = ($samples -join ',')
    }
}

function Invoke-VesShotSearchClaimed {
    <#
    .SYNOPSIS
    Port of shot_search_claimed(). Runs Resolve-VesPerShotQp for one
    already-claimed shot and writes shot-NNN.status. Releases the claim
    on the way out (success or fallback).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][PSCustomObject]$Claim,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$SvtAv1EncAppPath
    )
    $mdir = Get-VesShotManifestDir -Source $Source
    $idx = [int]$Claim.Index
    $shotMetaPath = Join-Path $mdir ("shot-{0:D3}.meta" -f $idx)
    if (-not (Test-Path -LiteralPath $shotMetaPath)) {
        Exit-VesShotClaim -Claim $Claim
        return $false
    }

    $statusFile = Join-Path $mdir ("shot-{0:D3}.status" -f $idx)
    if (Test-Path -LiteralPath $statusFile) {
        $stContent = Get-Content -LiteralPath $statusFile -Raw
        if ((Get-VesShotMetaValue -Content $stContent -Key 'status') -eq 'resolved') {
            Exit-VesShotClaim -Claim $Claim
            return $true
        }
    }

    $shotMeta = Get-Content -LiteralPath $shotMetaPath -Raw
    $manifestMeta = Get-Content -LiteralPath (Join-Path $mdir 'manifest.meta') -Raw
    $startTs = [double](Get-VesShotMetaValue -Content $shotMeta -Key 'start_ts')
    $endTs = [double](Get-VesShotMetaValue -Content $shotMeta -Key 'end_ts')
    $codec = Get-VesShotMetaValue -Content $manifestMeta -Key 'codec'
    $profile = Get-VesShotMetaValue -Content $manifestMeta -Key 'profile'
    $target = [double](Get-VesShotMetaValue -Content $manifestMeta -Key 'target')
    $model = Get-VesShotMetaValue -Content $manifestMeta -Key 'model'

    $result = Resolve-VesPerShotQp -Source $Source -Start $startTs -End $endTs `
        -Codec $codec -Target $target -Model $model -Profile $profile `
        -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath

    $searchFailed = 0
    $qp = $null
    $vmaf = ''
    $samples = ''
    if ($result) {
        $qp = $result.Qp
        $vmaf = "$($result.Vmaf)"
        $samples = $result.Samples
    } else {
        $qp = Get-VesProfileFixedCrf -Codec $codec -Profile $profile -IsHdr $false
        if ($null -eq $qp) { $qp = 30 }
        $searchFailed = 1
        Write-Warning "Shot search failed for shot $idx ($startTs-$endTs) on $env:COMPUTERNAME -- falling back to fixed qp=$qp"
    }

    $tmp = "$statusFile.$PID.$(Get-Random).tmp"
    @"
status=resolved
qp=$qp
vmaf=$vmaf
samples=$samples
search_failed=$searchFailed
searched_host=$env:COMPUTERNAME
searched_utc=$([DateTimeOffset]::UtcNow.ToString('o'))
"@ | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $statusFile -Force
    Set-VesEveryoneReadWrite -Path $statusFile
    Exit-VesShotClaim -Claim $Claim
    return $true
}

function Invoke-VesShotSearchWorkerLoop {
    <#
    .SYNOPSIS
    Port of shot_search_worker_loop(). Idle ceiling MUST default to
    STALE + 3*retry (v6.0.1B) so a live worker outlasts a dead peer's
    lock and can perform the reclaim.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$SvtAv1EncAppPath,
        [int]$MaxShots = 99999,
        [int]$MaxIdleSeconds = -1
    )
    $retryWait = Get-VesShotSearchRetryWait
    if ($MaxIdleSeconds -lt 0) {
        $MaxIdleSeconds = (Get-VesShotSearchStaleSeconds) + ($retryWait * 3)
    }
    $count = 0
    $idle = 0
    Clear-VesShotScratch
    while ($count -lt $MaxShots) {
        $claim = Enter-VesShotClaim -Source $Source
        if ($claim) {
            $idle = 0
            Write-Host "claimed shot $($claim.Index)"
            $ok = Invoke-VesShotSearchClaimed -Source $Source -Claim $claim `
                -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath
            if ($ok) {
                Write-Host "resolved shot $($claim.Index)"
                $count++
            } else {
                Write-Warning "shot-search: shot $($claim.Index) did not resolve -- will retry"
            }
            Clear-VesShotScratch
            continue
        }
        if (Test-VesShotManifestAllResolved -Source $Source) {
            Write-Host 'shot-search: manifest fully resolved'
            break
        }
        $idle += $retryWait
        if ($idle -ge $MaxIdleSeconds) {
            Write-Warning "shot-search: ${MaxIdleSeconds}s idle with shots still unresolved -- giving up on $env:COMPUTERNAME"
            break
        }
        Write-Host "shot-search: nothing claimable, ${idle}s/${MaxIdleSeconds}s idle -- retry in ${retryWait}s"
        Start-Sleep -Seconds $retryWait
    }
    Write-Host "shot-search worker done: processed $count shots"
    return $count
}

Export-ModuleMember -Function `
    Get-VesShotManifestDir, Get-VesShotLockPath, Get-VesShotPathMtime, `
    Test-VesShotManifestAllResolved, New-VesShotManifest, `
    Enter-VesShotClaim, Exit-VesShotClaim, `
    Clear-VesShotScratch, Invoke-VesShotSearchWorkerLoop, `
    Get-VesVmafScoreShot, Resolve-VesPerShotQp, Invoke-VesShotSearchClaimed
