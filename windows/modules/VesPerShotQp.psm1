# Windows port of modules/ves-per-shot-qp.sh -- Phase 6 per-shot VMAF-
# target QP search + distributed shot-claim coordination (STABLE HALF
# ONLY, stage 1). See the bash module header for the full design
# reasoning (why SvtAv1EncApp --qpfile not ffmpeg -qp; why one continuous
# encode with a per-frame qpfile, not per-shot spliced files).
#
# Per-shot claim coordination intentionally matches the live bash fleet:
# canonical_title_from_source() keying, <title>.shots manifests, and
# atomic mkdir-style <title>.shot<N>.lock directories with owner.meta
# inside the lock dir. The earlier Windows file-lock deviation is obsolete
# now that the NAS media datasets use posix ACLs and PRINCE can create,
# write inside, mtime-check, rename, and remove SMB directories reliably.
#
# STAGE 2 DEFERRED (allocator still being calibrated by a live survey):
#   - assemble_qpfile_via_equal_slope_budget  -> Assemble-VesQpfileViaEqualSlopeBudget
#   - assemble_qpfile_from_shot_manifest      -> Assemble-VesQpfileFromShotManifest
#   - assemble_qpfile_via_equal_slope         (dead in bash; do not revive)
#
# v6.0.1H Phase 1 port (2026-09-02): per-shot complexity fan-out on the
# scene-detect decode (cx_luma/cx_motion/cx_detail/cx_sat in shot-NNN.meta),
# field_mode/is_bw in manifest.meta, local source staging (SHOT_SRC_LOCAL),
# long-shot multi-window search (Get-VesVmafScoreShotMw + content-driven
# Get-VesShotLongWindows), VMAF frame stride (progressive-only), zero-signal
# single-probe fast-path (Get-VesShotIsNosignal), per-profile QP-bracket
# scaffolding (inert). All flag-gated -- matches the bash defaults.

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
if (-not (Get-Module -Name VesOrganize)) {
    Import-Module (Join-Path $PSScriptRoot 'VesOrganize.psm1') -Force
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

# --- Phase 1 (2026-09-02) config getters -------------------------------------
function Get-VesShotLongSecs {
    if ($env:SHOT_LONG_SECS) { return [double]$env:SHOT_LONG_SECS }
    return 45.0
}
function Get-VesPerShotMwLen {
    if ($env:PER_SHOT_MW_LEN) { return [double]$env:PER_SHOT_MW_LEN }
    return 8.0
}
function Get-VesPerShotMultiwindowEnable {
    return ($env:PER_SHOT_MULTIWINDOW_ENABLE -ne 'false')
}
function Get-VesShotMwDebias {
    return ($env:SHOT_MW_DEBIAS -ne '0')
}
function Get-VesPerShotVmafStride {
    if ($env:PER_SHOT_VMAF_STRIDE) { return [int]$env:PER_SHOT_VMAF_STRIDE }
    return 2
}
function Get-VesShotComplexityEnable {
    return ($env:SHOT_COMPLEXITY_ENABLE -ne 'false')
}
function Get-VesShotSrcLocalStage {
    return ($env:SHOT_SRC_LOCAL_STAGE -ne 'false')
}
function Get-VesShotSrcLocalStageDir {
    if ($env:SHOT_SRC_LOCAL_STAGE_DIR) { return $env:SHOT_SRC_LOCAL_STAGE_DIR }
    return (Join-Path ([System.IO.Path]::GetTempPath()) 'ves-srcstage')
}
function Get-VesNosignalFastpath {
    return ($env:PER_SHOT_NOSIGNAL_FASTPATH -ne 'false')
}
function Get-VesNosigBlackLuma   { if ($env:NOSIG_BLACK_LUMA)    { return [double]$env:NOSIG_BLACK_LUMA }    return 16.0 }
function Get-VesNosigStaticMotion { if ($env:NOSIG_STATIC_MOTION) { return [double]$env:NOSIG_STATIC_MOTION } return 1.0 }
function Get-VesNosigFlatDetail  { if ($env:NOSIG_FLAT_DETAIL)   { return [double]$env:NOSIG_FLAT_DETAIL }   return 3.0 }
function Get-VesNosigQp          { if ($env:NOSIG_QP)            { return [int]$env:NOSIG_QP }              return 48 }
function Get-VesNosigMinSecs     { if ($env:NOSIG_MIN_SECS)      { return [double]$env:NOSIG_MIN_SECS }      return 0.5 }
function Get-VesPerShotQpBracketEnable {
    return ($env:PER_SHOT_QP_BRACKET_ENABLE -eq 'true')
}
function Get-VesPerShotQpBracketEdgeFailPct {
    if ($env:PER_SHOT_QP_BRACKET_EDGE_FAIL_PCT) { return [int]$env:PER_SHOT_QP_BRACKET_EDGE_FAIL_PCT }
    return 5
}
function Get-VesPerShotQpBracketFor {
    <#  Returns @(lo,hi). Global PER_SHOT_QP_MIN/MAX unless the bracket is
        enabled AND a band is defined for the profile (env
        PER_SHOT_QP_BRACKET_<PROFILE>="lo hi"). Never clamps the answer --
        the (B) extend logic + Test-VesShotBracketEdge handle a tight band. #>
    param([Parameter(Mandatory)][string]$Profile)
    $g = @((Get-VesPerShotQpMin), (Get-VesPerShotQpMax))
    if (-not (Get-VesPerShotQpBracketEnable)) { return $g }
    $key = 'PER_SHOT_QP_BRACKET_' + ($Profile.ToUpper() -replace '[^A-Z0-9]', '_')
    $band = [Environment]::GetEnvironmentVariable($key)
    if ($band -and ($band -match '^\s*([0-9]+)\s+([0-9]+)\s*$')) {
        return @([int]$Matches[1], [int]$Matches[2])
    }
    return $g
}
function Test-VesShotBracketEdge {
    param([int]$Qp, [int]$Lo, [int]$Hi)
    if ($Qp -le $Lo -or $Qp -ge $Hi) { return 1 } else { return 0 }
}

function Get-VesUtcStamp {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Write-VesKvFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines
    )
    $dir = Split-Path -Parent $Path
    if (-not $dir) { $dir = '.' }
    $leaf = Split-Path -Leaf $Path
    $tmp = Join-Path $dir (".$leaf.$PID.$(Get-Random).tmp")
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, (($Lines -join "`n") + "`n"), $utf8NoBom)
    try {
        [System.IO.File]::Move($tmp, $Path, $true)
    } catch {
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    }
}

function Convert-VesFleetPath {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Windows', 'Linux')][string]$To
    )
    $maps = @(
        [PSCustomObject]@{ Linux = '/mnt/BigMomma/Media'; Windows = '\\10.10.10.150\Media' },
        [PSCustomObject]@{ Linux = '/mnt/BabyBear/Media'; Windows = '\\10.10.10.150\BabyBearMedia' },
        [PSCustomObject]@{ Linux = '/mnt/BigPoppa/Media'; Windows = '\\10.10.10.150\BigPoppaMedia' }
    )
    foreach ($m in $maps) {
        if ($To -eq 'Windows') {
            if ($Path.Equals($m.Linux, [System.StringComparison]::Ordinal)) { return $m.Windows }
            $prefix = "$($m.Linux)/"
            if ($Path.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                $rest = $Path.Substring($prefix.Length) -replace '/', '\'
                return "$($m.Windows)\$rest"
            }
        } else {
            if ($Path.Equals($m.Windows, [System.StringComparison]::OrdinalIgnoreCase)) { return $m.Linux }
            $prefix = "$($m.Windows)\"
            if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rest = $Path.Substring($prefix.Length) -replace '\\', '/'
                return "$($m.Linux)/$rest"
            }
        }
    }
    return $Path
}

function Get-VesShotManifestDir {
    <#
    .SYNOPSIS
    Manifest directory for one title's shots, matching bash
    shot_manifest_dir(): media_content_dir/<canonical_title>.shots.
    #>
    param([Parameter(Mandatory)][string]$Source)
    return Join-Path (Get-VesMediaContentDir -Source $Source) "$(Get-VesCanonicalTitleFromSource -Source $Source).shots"
}

function Get-VesShotLockPath {
    <#
    .SYNOPSIS
    Lock directory path for one shot index, matching bash callers that
    append .lock to shot_lock_path().
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$Index
    )
    return Join-Path (Get-VesMediaContentDir -Source $Source) "$(Get-VesCanonicalTitleFromSource -Source $Source).shot$Index.lock"
}

function Get-VesShotPathMtime {
    <#
    .SYNOPSIS
    Port of _shot_path_mtime(). Unix-epoch mtime seconds of a path, or
    $null if unavailable. Used for stale-incomplete-mdir reclaim,
    directory-lock stale checks, and scratch sweep age checks.
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

        # Phase 1: fan the single scene-detect decode to a signalstats+entropy
        # branch. Raw per-frame file is LOCAL + transient (10s of MB); only
        # the small aggregated per-shot table lands in the manifest.
        $cxStats = $null
        if (Get-VesShotComplexityEnable) {
            $cxStats = Join-Path ([System.IO.Path]::GetTempPath()) ("ves-cxstats-$PID-$(Get-Random)")
        }
        try {
            $boundaries = @(Get-VesSceneBoundaries -Source $Source -FfmpegPath $FfmpegPath -StatsOut $cxStats)
        } catch {
            Write-Warning "Get-VesSceneBoundaries failed for $Source -- $_"
            if ($cxStats -and (Test-Path -LiteralPath $cxStats)) { Remove-Item -LiteralPath $cxStats -Force -ErrorAction SilentlyContinue }
            return $false
        }

        $cxTable = @{}
        if ($cxStats -and (Test-Path -LiteralPath $cxStats) -and ((Get-Item -LiteralPath $cxStats).Length -gt 0)) {
            try { $cxTable = Get-VesShotComplexityTable -StatsFile $cxStats -Boundaries $boundaries } catch { }
        }
        $longSecs = Get-VesShotLongSecs
        $mwLen = Get-VesPerShotMwLen
        $writeShotCx = {
            param([int]$Idx, [double]$SStart, [double]$SEnd)
            $lines = @()
            if ($cxTable.ContainsKey($Idx)) {
                $x = $cxTable[$Idx]
                $lines += "cx_luma=$($x.Luma)"; $lines += "cx_motion=$($x.Motion)"
                $lines += "cx_detail=$($x.Detail)"; $lines += "cx_sat=$($x.Sat)"
            }
            if ($cxStats -and (Test-Path -LiteralPath $cxStats) -and (($SEnd - $SStart) -gt $longSecs)) {
                try {
                    $w = Get-VesShotLongWindows -StatsFile $cxStats -Start $SStart -End $SEnd -WinLen $mwLen
                    if ($w) { $lines += "cx_windows=$w" }
                } catch { }
            }
            return $lines
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
                $body = @("index=$n", "start_ts=$prev", "end_ts=$ts") + (& $writeShotCx $n ([double]$prev) ([double]$ts))
                Write-VesKvFile -Path $shotFile -Lines $body
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
            $fbody = @("index=$n", "start_ts=$prev", "end_ts=$durStr") + (& $writeShotCx $n ([double]$prev) ([double]$dur))
            Write-VesKvFile -Path $finalShot -Lines $fbody
            $n++

            if ($cxStats -and (Test-Path -LiteralPath $cxStats)) { Remove-Item -LiteralPath $cxStats -Force -ErrorAction SilentlyContinue }

            # Field mode + B&W, resolved once so every search worker uses the
            # same VMAF-stride decision. Skipped when nothing that needs it is on.
            $fm = 'unknown'; $bw = '0'
            $needTraits = ((Get-VesPerShotVmafStride) -gt 1) -or (Get-VesShotComplexityEnable) -or (Get-VesPerShotMultiwindowEnable)
            if ($needTraits -and (Get-Command Get-VesSourceTraits -ErrorAction SilentlyContinue)) {
                try {
                    $st = Get-VesSourceTraits -Source $Source -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath
                    if ($st.FieldMode) { $fm = "$($st.FieldMode)" }
                    if ($null -ne $st.IsBw) { $bw = "$([int]$st.IsBw)" }
                } catch { }
            }

            $manifestFile = Join-Path $buildTmp 'manifest.meta'
            Write-VesKvFile -Path $manifestFile -Lines @(
                "source=$(Convert-VesFleetPath -Path $Source -To Linux)",
                "shot_count=$n",
                "codec=$Codec",
                "profile=$Profile",
                "target=$Target",
                "model=$Model",
                "field_mode=$fm",
                "is_bw=$bw",
                "created_utc=$(Get-VesUtcStamp)",
                "created_host=$env:COMPUTERNAME"
            )

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

        Write-VesKvFile -Path $completeMarker -Lines @()
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
    Port of shot_claim_next(). Claims one not-yet-resolved shot via an
    atomic lock directory containing owner.meta. Returns a claim object
    (Index/LockPath/Token/MetaPath) or $null. Staleness ceiling =
    SHOT_SEARCH_STALE_SECS (default 25200).
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
        $metaPath = Join-Path $lockPath 'owner.meta'
        try {
            New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
            try {
                Write-VesKvFile -Path $metaPath -Lines @(
                    "host=$env:COMPUTERNAME",
                    "pid=$PID",
                    "claimed_utc=$(Get-VesUtcStamp)"
                )
                Set-VesEveryoneReadWrite -Path $metaPath
            } catch { }
            return [PSCustomObject]@{
                Index    = $idx
                LockPath = $lockPath
                MetaPath = $metaPath
                Token    = $null
            }
        } catch {
            $mtime = Get-VesShotPathMtime -Path $metaPath
            if ($null -eq $mtime) { $mtime = Get-VesShotPathMtime -Path $lockPath }
            if ($null -eq $mtime) { continue }
            $age = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $mtime)
            if ($age -le $staleSecs) { continue }
            $reclaimName = "$lockPath.stale.$env:COMPUTERNAME.$PID.$(Get-Random)"
            try {
                [System.IO.Directory]::Move($lockPath, $reclaimName)
                try { [System.IO.Directory]::Delete($reclaimName, $true) } catch { }
                try {
                    New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
                    try {
                        Write-VesKvFile -Path $metaPath -Lines @(
                            "host=$env:COMPUTERNAME",
                            "pid=$PID",
                            "claimed_utc=$(Get-VesUtcStamp)"
                        )
                        Set-VesEveryoneReadWrite -Path $metaPath
                    } catch { }
                    return [PSCustomObject]@{
                        Index    = $idx
                        LockPath = $lockPath
                        MetaPath = $metaPath
                        Token    = $null
                    }
                } catch { }
            } catch { }
        }
    }
    return $null
}

function Exit-VesShotClaim {
    <#
    .SYNOPSIS
    Port of shot_release_claim() -- recursive removal of the lock dir.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Claim
    )
    Remove-Item -LiteralPath $Claim.LockPath -Recurse -Force -ErrorAction SilentlyContinue
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

function Get-VesStageSourceLocal {
    <#
    .SYNOPSIS
    Port of _stage_source_local(). Copy a fleet-shared (NFS/SMB) source to
    local disk ONCE so per-shot extraction stops re-reading a ~30s window
    over the network for every QP probe. Returns the local path on success,
    or the original path (unchanged behaviour) on any failure / when
    disabled. Idempotent per host (size match), disk-guarded, 48h sweep
    that never touches the file it is about to return.
    #>
    param([Parameter(Mandatory)][string]$Source)
    if (-not (Get-VesShotSrcLocalStage)) { return $Source }
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $Source }
    $dir = Get-VesShotSrcLocalStageDir
    try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { return $Source }

    $want = (Get-Item -LiteralPath $Source).Length
    $h = ([System.BitConverter]::ToString(
            [System.Security.Cryptography.MD5]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($Source))) -replace '-', '').Substring(0, 10).ToLower()
    $base = (Split-Path -Leaf $Source) -replace '[^A-Za-z0-9._-]', '_'
    $dst = Join-Path $dir ("${h}_${base}")
    $dstName = Split-Path -Leaf $dst

    # sweep stale stages (>48h by last-access), never the file we hand back
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -eq $dstName) { return }
        if (([DateTimeOffset]::UtcNow - $_.LastAccessTimeUtc).TotalHours -gt 48) {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { }
        }
    }

    if ((Test-Path -LiteralPath $dst) -and ((Get-Item -LiteralPath $dst).Length -eq $want)) {
        try { (Get-Item -LiteralPath $dst).LastAccessTimeUtc = [DateTime]::UtcNow } catch { }
        return $dst
    }
    try {
        $free = (Get-PSDrive -Name ((Get-Item -LiteralPath $dir).PSDrive.Name)).Free
        if ($null -ne $free -and $free -lt ($want + [math]::Floor($want / 10))) {
            Write-Warning "Get-VesStageSourceLocal: not enough local space in $dir -- reading source from network"
            return $Source
        }
    } catch { }
    $tmp = "$dst.$PID.part"
    try {
        Copy-Item -LiteralPath $Source -Destination $tmp -Force -ErrorAction Stop
        if ((Get-Item -LiteralPath $tmp).Length -eq $want) {
            Move-Item -LiteralPath $tmp -Destination $dst -Force -ErrorAction Stop
            return $dst
        }
    } catch { }
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    return $Source
}

function Get-VesShotIsNosignal {
    <#
    .SYNOPSIS
    Port of _shot_is_nosignal(). True when a shot's manifest complexity
    fields all indicate pure black / fade / flat static (no RD signal):
    cx_luma < NOSIG_BLACK_LUMA AND cx_motion < NOSIG_STATIC_MOTION AND
    cx_detail < NOSIG_FLAT_DETAIL. Absent fields => $false (search it).
    #>
    param([Parameter(Mandatory)][string]$ShotMetaContent)
    if (-not (Get-VesNosignalFastpath)) { return $false }
    $l = Get-VesShotMetaValue -Content $ShotMetaContent -Key 'cx_luma'
    $m = Get-VesShotMetaValue -Content $ShotMetaContent -Key 'cx_motion'
    $d = Get-VesShotMetaValue -Content $ShotMetaContent -Key 'cx_detail'
    if (-not $l -or -not $m -or -not $d) { return $false }
    return (([double]$l -lt (Get-VesNosigBlackLuma)) -and
            ([double]$m -lt (Get-VesNosigStaticMotion)) -and
            ([double]$d -lt (Get-VesNosigFlatDetail)))
}

function Get-VesShotEncodeBytesOnly {
    <#
    .SYNOPSIS
    Port of _shot_encode_bytes_only(). Encode the WHOLE shot once at a
    fixed QP and return byte size (no VMAF) -- used to de-bias multi-window
    byte estimates. Returns [long] or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][double]$End,
        [Parameter(Mandatory)][int]$Qp,
        [Parameter(Mandatory)][string]$Codec,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$SvtAv1EncAppPath
    )
    if ($Codec -ne 'av1') { return $null }
    $src = if ($env:SHOT_SRC_LOCAL) { $env:SHOT_SRC_LOCAL } else { $Source }
    $svtp = Get-VesProfileSvtParams -Profile $Profile -FfmpegPath $FfmpegPath
    if (-not $svtp) { return $null }
    $useSvtBin = $SvtAv1EncAppPath -and (Test-Path -LiteralPath $SvtAv1EncAppPath)
    $base = if ($env:RAMDISK_JOB_DIR) { $env:RAMDISK_JOB_DIR } else { [System.IO.Path]::GetTempPath() }
    $work = Join-Path $base ("ves-shotbytes-$PID-$(Get-Random)")
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $fastSs = [math]::Max(0.0, $Start - 30.0)
        $accSs = $Start - $fastSs
        $clipDur = [math]::Max(0.0, $End - $Start)
        $clip = Join-Path $work 'shot.mkv'
        $tmo = Get-VesShotFfmpegTimeout -DurationSeconds $clipDur
        $ext = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
            '-y', '-v', 'error', '-ss', $fastSs.ToString('0.######', $inv), '-i', $src,
            '-ss', $accSs.ToString('0.######', $inv), '-t', $clipDur.ToString('0.######', $inv),
            '-map', '0:v:0', '-c:v', 'ffv1', '-level', '3', $clip
        ) -TimeoutSeconds $tmo -MaxRetries 1
        if ($ext.TimedOut -or $ext.ExitCode -ne 0) { return $null }
        $y4m = Join-Path $work 'shot.y4m'
        $y4mRun = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
            '-y', '-v', 'error', '-i', $clip, '-map', '0:v:0', '-pix_fmt', 'yuv420p10le', '-strict', '-1', $y4m
        ) -TimeoutSeconds $tmo -MaxRetries 1
        if ($y4mRun.TimedOut -or $y4mRun.ExitCode -ne 0) { return $null }
        $nfRun = Invoke-VesWithTimeoutRetry -FilePath $FfprobePath -ArgumentList @(
            '-v', 'error', '-select_streams', 'v:0', '-count_packets',
            '-show_entries', 'stream=nb_read_packets', '-of', 'csv=p=0', $clip
        ) -TimeoutSeconds 60 -MaxRetries 1
        $nframes = 0
        if (-not [int]::TryParse(($nfRun.StdOut.Trim() -replace ',.*$', ''), [ref]$nframes) -or $nframes -le 0) { return $null }
        if ($useSvtBin) {
            $qpfile = Join-Path $work 'uniform.qp'
            $qpLines = for ($i = 0; $i -lt $nframes; $i++) { "$Qp" }
            $qpLines | Set-Content -LiteralPath $qpfile -Encoding ascii
            $out = Join-Path $work 'shot.ivf'
            $r = Invoke-VesWithTimeoutRetry -FilePath $SvtAv1EncAppPath -ArgumentList @(
                '-i', $y4m, '--use-q-file', '1', '--qpfile', $qpfile, '--svtav1-params', "${svtp}:rc=0", '-b', $out
            ) -TimeoutSeconds $tmo -MaxRetries 1
        } else {
            $out = Join-Path $work 'shot.mkv.out'
            $r = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
                '-y', '-v', 'error', '-i', $y4m, '-map', '0:v:0', '-c:v', 'libsvtav1', '-preset', '5',
                '-svtav1-params', "${svtp}:rc=0:qp=$Qp", '-pix_fmt', 'yuv420p10le', $out
            ) -TimeoutSeconds $tmo -MaxRetries 1
        }
        if ($r.TimedOut -or $r.ExitCode -ne 0) { return $null }
        if (-not (Test-Path -LiteralPath $out) -or (Get-Item -LiteralPath $out).Length -le 0) { return $null }
        return [long](Get-Item -LiteralPath $out).Length
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-VesVmafScoreShotMw {
    <#
    .SYNOPSIS
    Port of _vmaf_score_shot_mw(). Score a LONG shot as 3 short windows
    (placed by content via env SHOT_MW_OFFSETS, else evenly) and combine:
    MEDIAN window VMAF + rate-scaled bytes. Same @{Vmaf;Bytes} contract as
    Get-VesVmafScoreShot. >=2 usable windows required (else full-shot).
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
    $wl = if ($env:SHOT_MW_LEN) { [double]$env:SHOT_MW_LEN } else { 8.0 }
    $shotDur = [math]::Max(0.0, $End - $Start)
    $offs = @()
    if ($env:SHOT_MW_OFFSETS) {
        $offs = $env:SHOT_MW_OFFSETS.Split(',') | Where-Object { $_ -ne '' } | ForEach-Object { [double]$_ }
    }
    if ($offs.Count -lt 1) {
        for ($k = 0; $k -lt 3; $k++) {
            $o = $shotDur * (2 * $k + 1) / 6.0 - $wl / 2.0
            if ($o -lt 0) { $o = 0 }
            if (($o + $wl) -gt $shotDur) { $o = $shotDur - $wl }
            if ($o -lt 0) { $o = 0 }
            $offs += $o
        }
    }
    $vs = [System.Collections.Generic.List[double]]::new()
    $rates = [System.Collections.Generic.List[double]]::new()
    foreach ($o in $offs) {
        $ws = $Start + $o
        $we = [math]::Min($End, $ws + $wl)
        $r = Get-VesVmafScoreShot -Source $Source -Start $ws -End $we -Qp $Qp `
            -Codec $Codec -Model $Model -Profile $Profile `
            -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath
        if (-not $r) { continue }
        $vs.Add([double]$r.Vmaf)
        $wd = $we - $ws
        if ($wd -gt 0) { $rates.Add([double]$r.Bytes / $wd) }
    }
    if ($vs.Count -lt 2) {
        Write-Host "  per-shot mw: only $($vs.Count) usable window(s) shot=${Start}-${End} -- full-shot fallback"
        return (Get-VesVmafScoreShot -Source $Source -Start $Start -End $End -Qp $Qp `
            -Codec $Codec -Model $Model -Profile $Profile `
            -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath)
    }
    $sorted = @($vs | Sort-Object)
    $med = if ($sorted.Count % 2) { $sorted[[int]($sorted.Count / 2)] }
           else { ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2 }
    $avgRate = ($rates | Measure-Object -Average).Average
    return [PSCustomObject]@{ Vmaf = [math]::Round($med, 2); Bytes = [long]($avgRate * $shotDur) }
}

function Test-VesShotManifestBracketHealth {
    <#
    .SYNOPSIS
    Port of shot_manifest_bracket_health(). Returns @{ Edge; Real; Pct; Fit }.
    Fit is $false only when the bracket is ENABLED and > EdgeFailPct of a
    title's real shots resolved at/past a band edge.
    #>
    param([Parameter(Mandatory)][string]$Source)
    $mdir = Get-VesShotManifestDir -Source $Source
    $edge = 0; $real = 0
    Get-ChildItem -LiteralPath $mdir -Filter 'shot-*.status' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $c = Get-Content -LiteralPath $_.FullName -Raw
        if ($c -notmatch '(?m)^search_failed=0') { return }
        if ($c -notmatch '(?m)^vmaf=[0-9]') { return }
        $real++
        if ($c -match '(?m)^bracket_edge=1') { $edge++ }
    }
    $pct = if ($real -gt 0) { [int]([math]::Floor($edge * 100 / $real)) } else { 0 }
    $fit = $true
    if ((Get-VesPerShotQpBracketEnable) -and $pct -gt (Get-VesPerShotQpBracketEdgeFailPct)) { $fit = $false }
    return [PSCustomObject]@{ Edge = $edge; Real = $real; Pct = $pct; Fit = $fit }
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
    # Phase 1: read the extraction from the worker's local stage when set.
    if ($env:SHOT_SRC_LOCAL) { $Source = $env:SHOT_SRC_LOCAL }
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
        # Phase 1 VMAF frame stride: score every Sth frame in the SEARCH only.
        # ONLY when the source is confirmed progressive -- telecine/interlaced/
        # ambiguous/unknown alias badly under decimation. SHOT_FIELD_MODE is
        # set per-title by Invoke-VesShotSearchClaimed from manifest.meta.
        $sel = ''
        if ($env:SHOT_FIELD_MODE -eq 'progressive') {
            $stride = Get-VesPerShotVmafStride
            if ($stride -gt 1) { $sel = "select='not(mod(n\,$stride))'," }
        }
        $lavfi = "[0:v]${sel}setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]${sel}setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=${Model}:n_threads=${nThreads}:log_fmt=json:log_path=$vlogName"
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

    # Phase 1: long-shot multi-window path -- Invoke-VesShotSearchClaimed sets
    # SHOT_MW_ACTIVE=1 (+ SHOT_MW_OFFSETS) for a shot over SHOT_LONG_SECS.
    $mwActive = ($env:SHOT_MW_ACTIVE -eq '1') -and (Get-VesPerShotMultiwindowEnable)
    $probeQp = {
        param([int]$Q)
        if ($score.ContainsKey($Q)) { return $true }
        if ($mwActive) {
            $r = Get-VesVmafScoreShotMw -Source $Source -Start $Start -End $End -Qp $Q `
                -Codec $Codec -Model $Model -Profile $Profile `
                -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath
        } else {
            $r = Get-VesVmafScoreShot -Source $Source -Start $Start -End $End -Qp $Q `
                -Codec $Codec -Model $Model -Profile $Profile `
                -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath
        }
        if (-not $r) { return $false }
        $score[$Q] = [double]$r.Vmaf
        $bytes[$Q] = [long]$r.Bytes
        $samples.Add("${Q}:$($score[$Q]):$($bytes[$Q])")
        $tag = if ($mwActive) { ' mw' } else { '' }
        Write-Host "  per-shot qp-search [$Codec]$tag shot=${Start}-${End} qp=$Q vmaf=$($score[$Q])"
        return $true
    }

    $band = Get-VesPerShotQpBracketFor -Profile $Profile
    $qpLo = [int]$band[0]
    $qpHi = [int]$band[1]
    $qpMid = if ($qpLo -le 30 -and $qpHi -ge 30) { 30 } else { [int](($qpLo + $qpHi) / 2) }
    foreach ($qp in @($qpLo, $qpMid, $qpHi)) {
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

    # Phase 1 multi-window byte de-bias: anchor the whole RD-sample byte scale
    # to ONE real full-shot encode at the chosen QP, then rescale every
    # sample's bytes by the same ratio (curve SHAPE from the windows, byte
    # MAGNITUDE from the real encode).
    if ($mwActive -and (Get-VesShotMwDebias) -and $bytes.ContainsKey([int]$best) -and $bytes[[int]$best] -gt 0) {
        $realB = Get-VesShotEncodeBytesOnly -Source $Source -Start $Start -End $End -Qp ([int]$best) `
            -Codec $Codec -Profile $Profile -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath
        if ($realB -and $realB -gt 0) {
            $ratio = [double]$realB / [double]$bytes[[int]$best]
            Write-Host "  per-shot mw byte de-bias shot=${Start}-${End} qp=$best window=$($bytes[[int]$best]) real=$realB ratio=$('{0:F6}' -f $ratio)"
            for ($i = 0; $i -lt $samples.Count; $i++) {
                $parts = $samples[$i].Split(':')
                if ($parts.Count -eq 3 -and ($parts[2] -match '^[0-9]+$')) {
                    $samples[$i] = "$($parts[0]):$($parts[1]):$([long]([long]$parts[2] * $ratio))"
                }
            }
            $bytes[[int]$best] = [long]$realB
        }
    }

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
    $sdur = [math]::Max(0.0, $endTs - $startTs)

    # Phase 1 per-title / per-shot search modifiers, resolved from the manifest
    # here so Resolve-VesPerShotQp / Get-VesVmafScoreShot stay signature-stable.
    $fieldMode = Get-VesShotMetaValue -Content $manifestMeta -Key 'field_mode'
    $env:SHOT_FIELD_MODE = if ($fieldMode) { $fieldMode } else { 'unknown' }
    $env:SHOT_MW_ACTIVE = $null
    $env:SHOT_MW_OFFSETS = $null
    if ((Get-VesPerShotMultiwindowEnable) -and $sdur -gt (Get-VesShotLongSecs)) {
        $env:SHOT_MW_ACTIVE = '1'
        $cw = Get-VesShotMetaValue -Content $shotMeta -Key 'cx_windows'
        $env:SHOT_MW_OFFSETS = if ($cw) { $cw } else { '' }
        $env:SHOT_MW_LEN = "$(Get-VesPerShotMwLen)"
    }

    # Zero-signal single-probe path: one real encode at NOSIG_QP (the shot is
    # trivial -> a couple of seconds), record the real (qp,vmaf,bytes).
    $result = $null
    $nosignal = 0
    if ($sdur -ge (Get-VesNosigMinSecs) -and (Get-VesShotIsNosignal -ShotMetaContent $shotMeta)) {
        $nq = Get-VesNosigQp
        $prevMw = $env:SHOT_MW_ACTIVE; $env:SHOT_MW_ACTIVE = $null
        $nr = Get-VesVmafScoreShot -Source $Source -Start $startTs -End $endTs -Qp $nq `
            -Codec $codec -Model $model -Profile $profile `
            -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath
        $env:SHOT_MW_ACTIVE = $prevMw
        if ($nr) {
            $nosignal = 1
            $result = [PSCustomObject]@{ Qp = $nq; Vmaf = [double]$nr.Vmaf; Samples = "${nq}:$($nr.Vmaf):$($nr.Bytes)" }
            Write-Warning "per-shot NOSIGNAL (black/static) shot $idx ($startTs-$endTs) -> single probe qp=$nq vmaf=$($nr.Vmaf)"
        }
    }
    if (-not $result) {
        $result = Resolve-VesPerShotQp -Source $Source -Start $startTs -End $endTs `
            -Codec $codec -Target $target -Model $model -Profile $profile `
            -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -SvtAv1EncAppPath $SvtAv1EncAppPath
    }

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

    # bracket-edge flag (no-op payload while the bracket is disabled)
    $bracketEdge = 0
    if ($searchFailed -eq 0) {
        $b = Get-VesPerShotQpBracketFor -Profile $profile
        $bracketEdge = Test-VesShotBracketEdge -Qp ([int]$qp) -Lo ([int]$b[0]) -Hi ([int]$b[1])
    }

    Write-VesKvFile -Path $statusFile -Lines @(
        'status=resolved',
        "qp=$qp",
        "vmaf=$vmaf",
        "samples=$samples",
        "search_failed=$searchFailed",
        "nosignal=$nosignal",
        "bracket_edge=$bracketEdge",
        "searched_host=$env:COMPUTERNAME",
        "searched_utc=$(Get-VesUtcStamp)"
    )
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
    # Phase 1: stage the shared source to local disk once so every extraction
    # probe reads local instead of re-fetching a window over the network.
    try {
        $local = Get-VesStageSourceLocal -Source $Source
        if ($local -and $local -ne $Source -and (Test-Path -LiteralPath $local)) {
            $env:SHOT_SRC_LOCAL = $local
            Write-Host "  staged source local: $local ($([math]::Round((Get-Item -LiteralPath $local).Length / 1GB, 2)) GB)"
        } else {
            $env:SHOT_SRC_LOCAL = $null
            Write-Host "  local staging skipped -- reading source from network"
        }
    } catch { $env:SHOT_SRC_LOCAL = $null }

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
    Convert-VesFleetPath, `
    Test-VesShotManifestAllResolved, New-VesShotManifest, `
    Enter-VesShotClaim, Exit-VesShotClaim, `
    Clear-VesShotScratch, Invoke-VesShotSearchWorkerLoop, `
    Get-VesVmafScoreShot, Resolve-VesPerShotQp, Invoke-VesShotSearchClaimed, `
    Get-VesStageSourceLocal, Get-VesShotIsNosignal, Get-VesShotEncodeBytesOnly, `
    Get-VesVmafScoreShotMw, Test-VesShotManifestBracketHealth, `
    Get-VesPerShotQpBracketFor, Test-VesShotBracketEdge, `
    Get-VesShotLongSecs, Get-VesPerShotMwLen, Get-VesPerShotVmafStride, `
    Get-VesShotComplexityEnable, Get-VesPerShotMultiwindowEnable, `
    Get-VesNosignalFastpath, Get-VesNosigQp, Get-VesPerShotQpBracketEnable
