# Windows port of modules/ves-per-shot-qp.sh -- Phase 6 per-shot VMAF-
# target QP search + distributed shot-claim coordination (STABLE HALF
# ONLY, stage 1). See the bash module header for the full design
# reasoning (why SvtAv1EncApp --qpfile not ffmpeg -qp; why one continuous
# encode with a per-frame qpfile, not per-shot spliced files).
#
# Per-shot claim coordination intentionally matches the live bash fleet:
# the Phase-B <base>_WORKING/shots manifest layout at the category level
# (working_dir_for_source(), 2026-09-04) and atomic mkdir-style
# <title>.shot<N>.lock directories with owner.meta inside the lock dir
# (the legacy NFS lock -- the redis lease backend is bash-only for now).
# The earlier Windows file-lock deviation is obsolete now that the NAS
# media datasets use posix ACLs and PRINCE can create, write inside,
# mtime-check, rename, and remove SMB directories reliably.
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
    $v = if ($env:PER_SHOT_MULTIWINDOW_ENABLE) { $env:PER_SHOT_MULTIWINDOW_ENABLE } else { 'true' }
    return ($v -eq 'true')
}
function Get-VesShotMwDebias {
    $v = if ($env:SHOT_MW_DEBIAS) { $env:SHOT_MW_DEBIAS } else { '1' }
    return ($v -eq '1')
}
function Get-VesPerShotVmafStride {
    if ($env:PER_SHOT_VMAF_STRIDE) { return [int]$env:PER_SHOT_VMAF_STRIDE }
    return 2
}
function Get-VesShotComplexityEnable {
    $v = if ($env:SHOT_COMPLEXITY_ENABLE) { $env:SHOT_COMPLEXITY_ENABLE } else { 'true' }
    return ($v -ne 'false')
}
function Get-VesShotSrcLocalStage {
    $v = if ($env:SHOT_SRC_LOCAL_STAGE) { $env:SHOT_SRC_LOCAL_STAGE } else { 'true' }
    return ($v -eq 'true')
}
function Get-VesShotSrcLocalStageDir {
    if ($env:SHOT_SRC_LOCAL_STAGE_DIR) { return $env:SHOT_SRC_LOCAL_STAGE_DIR }
    # bash default is /var/tmp/ves-srcstage; on Windows that path is not
    # creatable, so fall back to a real temp dir. The PRINCE search-worker
    # driver MUST set SHOT_SRC_LOCAL_STAGE_DIR to a D: path explicitly --
    # C:\...\Temp is small and multi-GB sources will not fit there.
    return (Join-Path ([System.IO.Path]::GetTempPath()) 'ves-srcstage')
}
function Get-VesNosignalFastpath {
    $v = if ($env:PER_SHOT_NOSIGNAL_FASTPATH) { $env:PER_SHOT_NOSIGNAL_FASTPATH } else { 'true' }
    return ($v -eq 'true')
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
    $key = 'PER_SHOT_QP_BRACKET_' + ($Profile.ToUpperInvariant() -replace '-', '_')
    $band = [Environment]::GetEnvironmentVariable($key)
    if ($band -and ($band -match '^([0-9]+) +([0-9]+)$')) {
        return @([int]$Matches[1], [int]$Matches[2])
    }
    return $g
}
function Test-VesShotBracketEdge {
    param([int]$Qp = 30, [int]$Lo = 0, [int]$Hi = 63)
    if ($Qp -le $Lo -or $Qp -ge $Hi) { return 1 } else { return 0 }
}

function Get-VesAllocPosWeightHeadFrac { if ($env:ALLOC_POS_WEIGHT_HEAD_FRAC) { return [double]$env:ALLOC_POS_WEIGHT_HEAD_FRAC } return 0.05 }
function Get-VesAllocPosWeightTailFrac { if ($env:ALLOC_POS_WEIGHT_TAIL_FRAC) { return [double]$env:ALLOC_POS_WEIGHT_TAIL_FRAC } return 0.12 }
function Get-VesAllocPosWeightMin      { if ($env:ALLOC_POS_WEIGHT_MIN)       { return [double]$env:ALLOC_POS_WEIGHT_MIN }       return 0.85 }
function Get-VesAllocMinShotVmafDrop   { if ($env:ALLOC_MIN_SHOT_VMAF_DROP)   { return [double]$env:ALLOC_MIN_SHOT_VMAF_DROP }   return 6.0 }
function Get-VesAllocMinShotPinRounds  { if ($env:ALLOC_MIN_SHOT_PIN_ROUNDS)  { return [int]$env:ALLOC_MIN_SHOT_PIN_ROUNDS }     return 4 }
function Get-VesAllocBytesCalibrationK { if ($env:ALLOC_BYTES_CALIBRATION_K)  { return [double]$env:ALLOC_BYTES_CALIBRATION_K }  return 1.13 }

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

function Resolve-VesSvtAv1EncAppPath {
    param([string]$SvtAv1EncAppPath)
    if ($SvtAv1EncAppPath) {
        if (Test-Path -LiteralPath $SvtAv1EncAppPath) {
            return (Get-Item -LiteralPath $SvtAv1EncAppPath).FullName
        }
        $cmd = Get-Command $SvtAv1EncAppPath -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    $cmd = Get-Command SvtAv1EncApp.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command SvtAv1EncApp -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
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

function Get-VesWorkingDirForSource {
    <#
    .SYNOPSIS
    Port of working_dir_for_source() (ves-organize.sh, 2026-09-04). The
    per-source pipeline working folder: "<base>_WORKING" at the CATEGORY
    level -- beside the per-title / show folder, not inside it -- so
    pipeline scratch stays out of the real title folder (what Plex scans,
    what a bad delete could hit). "<base>" is the source filename minus the
    final extension only, verbatim (year kept), so bash and this fork
    compute the identical path. A LOOSE file sitting straight in a
    language/shelf dir has no title folder: keep _WORKING beside the file
    (going up would escape the library root).
    #>
    param([Parameter(Mandatory)][string]$Source)
    $cdir = Get-VesMediaContentDir -Source $Source
    $base = Get-VesMovieTitleFromFile -Path $Source   # strips the final ext only
    # A loose file straight in a language / shelf dir has no title folder --
    # keep _WORKING beside it (going up escapes the library root). Otherwise
    # cdir is the per-title / show folder: put _WORKING one level up (category).
    if ((Test-VesIsMovieLanguageDir -Path $cdir) -or (Test-VesIsShelfDir -Path $cdir)) {
        return (Join-Path $cdir "${base}_WORKING")
    }
    return (Join-Path (Get-VesPathParent -Path $cdir) "${base}_WORKING")
}

function Get-VesShotManifestDir {
    <#
    .SYNOPSIS
    Manifest directory for one title's shots, matching bash
    shot_manifest_dir() / shot_manifest_dir_nas() (Phase B, 2026-09-04):
    <category dir>/<base>_WORKING/shots. (This fork has no in-flight local
    override yet -- PRINCE Phase-B local-first is a separate owed item.)
    #>
    param([Parameter(Mandatory)][string]$Source)
    return Join-Path (Get-VesWorkingDirForSource -Source $Source) 'shots'
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
        [int][math]::Floor((($AboveQp + $BelowQp) / 2.0) + 0.5)
    } else {
        [int][math]::Floor(($AboveQp + ($Target - $AboveScore) * ($BelowQp - $AboveQp) / ($BelowScore - $AboveScore)) + 0.5)
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

function Get-VesManifestShotStatusPath {
    param(
        [Parameter(Mandatory)][string]$ManifestDir,
        [Parameter(Mandatory)][string]$Index
    )
    return (Join-Path $ManifestDir ("shot-{0:D3}.status" -f [int]$Index))
}

function Get-VesFpsAndTotalFrames {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $dur = Get-VesMediaDurationSeconds -Path $Source -FfprobePath $FfprobePath
    if ($null -eq $dur) { throw "Unable to determine media duration for $Source" }
    $fpsRate = & $FfprobePath -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- $Source 2>$null
    $fpsRate = @($fpsRate)[0]
    if (-not $fpsRate) { throw "Unable to determine frame rate for $Source" }
    $fpsParts = "$fpsRate".Trim().Split('/')
    $fpsNum = [double]$fpsParts[0]
    $fpsDen = if ($fpsParts.Count -gt 1) { [double]$fpsParts[1] } else { 1.0 }
    $fps = [double]::Parse(($fpsNum / $fpsDen).ToString('0.000000', [System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
    $totalFrames = [int64][math]::Truncate(([double]$dur * $fps) + 1.0)
    return [PSCustomObject]@{ Duration = [double]$dur; Fps = [double]$fps; TotalFrames = $totalFrames }
}

function Write-VesShotQpsToQpfile {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Shots,
        [Parameter(Mandatory)][int64]$TotalFrames,
        [Parameter(Mandatory)][double]$Fps,
        [Parameter(Mandatory)][string]$QpfileOut
    )
    $dir = Split-Path -Parent $QpfileOut
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.IO.StreamWriter]::new($QpfileOut, $false, $utf8NoBom)
    try {
        $si = 0
        $count = $Shots.Count
        if ($count -eq 0) { return }
        for ($frame = [int64]0; $frame -lt $TotalFrames; $frame++) {
            $t = [double]::Parse((([double]$frame / $Fps).ToString('0.000000', [System.Globalization.CultureInfo]::InvariantCulture)), [System.Globalization.CultureInfo]::InvariantCulture)
            while ($si -lt ($count - 1)) {
                $cur = "$($Shots[$si])"
                $parts = $cur.Split(':')
                $shotEnd = [double]$parts[1]
                if ($t -ge $shotEnd) { $si++ } else { break }
            }
            $writer.WriteLine(("$($Shots[$si])".Split(':'))[-1])
        }
    } finally {
        $writer.Dispose()
    }
}

function ConvertTo-VesShotQpArray {
    param([Parameter(Mandatory)][hashtable]$ShotQpMap)
    return @($ShotQpMap.Keys | Sort-Object { [int]$_ } | ForEach-Object { $ShotQpMap[$_] })
}

function Assemble-VesQpfileFromShotManifest {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$QpfileOut,
        [double]$Target,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $mdir = Get-VesShotManifestDir -Source $Source
    if (-not (Test-VesShotManifestAllResolved -Source $Source)) {
        throw "Shot manifest is not fully resolved: $mdir"
    }
    $shotQps = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $mdir -Filter 'shot-*.meta' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $meta = Get-Content -LiteralPath $f.FullName -Raw
        $idx = Get-VesShotMetaValue -Content $meta -Key 'index'
        $startTs = Get-VesShotMetaValue -Content $meta -Key 'start_ts'
        $endTs = Get-VesShotMetaValue -Content $meta -Key 'end_ts'
        $status = Get-Content -LiteralPath (Get-VesManifestShotStatusPath -ManifestDir $mdir -Index $idx) -Raw
        $qp = Get-VesShotMetaValue -Content $status -Key 'qp'
        $shotQps["$idx"] = "${startTs}:${endTs}:${qp}"
    }
    $ft = Get-VesFpsAndTotalFrames -Source $Source -FfprobePath $FfprobePath
    Write-VesShotQpsToQpfile -Shots (ConvertTo-VesShotQpArray -ShotQpMap $shotQps) -TotalFrames $ft.TotalFrames -Fps $ft.Fps -QpfileOut $QpfileOut
    Write-Host "Assembled qpfile from shot manifest: $($shotQps.Count) shots, $QpfileOut ($($ft.TotalFrames) frames)"
    return $true
}

function Get-VesCreditsRange {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $dur = Get-VesMediaDurationSeconds -Path $Source -FfprobePath $FfprobePath
    if ($null -eq $dur) { return $null }
    $chapStarts = & $FfprobePath -v error -show_chapters -show_entries chapter=start_time -of csv=p=0 -- $Source 2>$null
    $lines = @($chapStarts | Where-Object { $_ -ne '' })
    if ($lines.Count -gt 0) {
        $lastStartStr = ($lines[-1].Split(','))[0]
        $lastStart = 0.0
        if ([double]::TryParse($lastStartStr, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$lastStart)) {
            $lastDur = [double]$dur - $lastStart
            if ($lastDur -ge 30.0 -and $lastDur -le 300.0) {
                return @($lastStart, [double]$dur)
            }
        }
    }
    return $null
}

function ConvertTo-VesAwkNumber {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return 0.0 }
    $m = [regex]::Match($Value, '^\s*[+-]?((\d+(\.\d*)?)|(\.\d+))([eE][+-]?\d+)?')
    if (-not $m.Success) { return 0.0 }
    $parsed = 0.0
    if ([double]::TryParse($m.Value.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return 0.0
}

function ConvertFrom-VesShotSamplesLine {
    param([AllowNull()][string]$SamplesLine)
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not $SamplesLine) { return $rows }
    foreach ($p in $SamplesLine.Split(',')) {
        if ($p -eq '') { continue }
        $triple = $p.Split(':')
        if ($triple.Count -ne 3) { continue }
        if (($triple -join '') -notmatch '[0-9]') { continue }
        $rows.Add([PSCustomObject]@{
            Qp    = "$($triple[0])"
            Vmaf  = ConvertTo-VesAwkNumber $triple[1]
            Bytes = ConvertTo-VesAwkNumber $triple[2]
        })
    }
    return $rows
}

function Get-VesEqualSlopeBudgetBaseline {
    param(
        [Parameter(Mandatory)][string]$ManifestDir,
        [Parameter(Mandatory)][double]$Target
    )
    $pst = [double]::Parse($Target.ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
    $sum = 0.0
    foreach ($st in (Get-ChildItem -LiteralPath $ManifestDir -Filter 'shot-*.status' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $content = Get-Content -LiteralPath $st.FullName -Raw
        $samplesLine = Get-VesShotMetaValue -Content $content -Key 'samples'
        $samples = ConvertFrom-VesShotSamplesLine -SamplesLine $samplesLine
        $best = -1.0
        $bb = 0.0
        foreach ($s in $samples) {
            $sqp = ConvertTo-VesAwkNumber $s.Qp
            if ($s.Vmaf -ge $pst -and $sqp -gt $best) {
                $best = $sqp
                $bb = $s.Bytes
            }
        }
        if ($best -lt 0) {
            $bv = $null
            foreach ($s in $samples) {
                if ($null -eq $bv) { $bv = $s.Vmaf }
                if ($s.Vmaf -ge $bv) {
                    $bv = $s.Vmaf
                    $bb = $s.Bytes
                }
            }
        }
        $sum += $bb
    }
    return [double]::Parse($sum.ToString('0', [System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-VesEqualSlopeBudgetSolve {
    param(
        [Parameter(Mandatory)][object[]]$Samples,
        [Parameter(Mandatory)][hashtable]$ShotStart,
        [Parameter(Mandatory)][hashtable]$ShotEnd,
        [Parameter(Mandatory)][double]$Budget,
        [AllowNull()][string]$DeprioStart,
        [AllowNull()][string]$DeprioEnd,
        [Parameter(Mandatory)][double]$DeprioWeight,
        [Parameter(Mandatory)][double]$HeadFrac,
        [Parameter(Mandatory)][double]$TailFrac,
        [Parameter(Mandatory)][double]$WeightMin,
        [Parameter(Mandatory)][double]$Target,
        [Parameter(Mandatory)][double]$FloorDrop,
        [Parameter(Mandatory)][int]$PinRounds
    )
    if ($Samples.Count -eq 0) { throw 'No valid shot samples for equal-slope solve' }
    $dur = @{}
    $shotIds = @($ShotStart.Keys | Sort-Object { [int]$_ })
    $maxE = 0.0
    foreach ($idx in $shotIds) {
        $dur[$idx] = 1
        if ([double]$ShotEnd[$idx] -gt $maxE) { $maxE = [double]$ShotEnd[$idx] }
    }
    $totalDur = if ($maxE -gt 0) { $maxE } else { 1.0 }
    $haveDeprio = ($DeprioStart -ne '' -and $null -ne $DeprioStart -and $DeprioEnd -ne '' -and $null -ne $DeprioEnd)
    $ds = if ($haveDeprio) { [double]$DeprioStart } else { 0.0 }
    $de = if ($haveDeprio) { [double]$DeprioEnd } else { 0.0 }
    $weight = @{}
    foreach ($idx in $shotIds) {
        $mid = ([double]$ShotStart[$idx] + [double]$ShotEnd[$idx]) / 2.0
        if ($haveDeprio) {
            $weight[$idx] = if ($mid -ge $ds -and $mid -le $de) { $DeprioWeight } else { 1.0 }
        } else {
            $p = $mid / $totalDur
            if ($HeadFrac -gt 0 -and $p -lt $HeadFrac) {
                $weight[$idx] = $WeightMin + (1.0 - $WeightMin) * ($p / $HeadFrac)
            } elseif ($TailFrac -gt 0 -and $p -gt (1.0 - $TailFrac)) {
                $weight[$idx] = $WeightMin + (1.0 - $WeightMin) * ((1.0 - $p) / $TailFrac)
            } else {
                $weight[$idx] = 1.0
            }
        }
    }
    $maxvQp = @{}; $maxvV = @{}; $maxvB = @{}
    foreach ($s in $Samples) {
        $idx = $s.Idx
        if (-not $maxvV.ContainsKey($idx) -or [double]$s.Vmaf -gt [double]$maxvV[$idx]) {
            $maxvV[$idx] = [double]$s.Vmaf; $maxvQp[$idx] = "$($s.Qp)"; $maxvB[$idx] = [double]$s.Bytes
        }
    }
    $pinned = @{}
    $bestQp = @{}; $bestVmaf = @{}; $bestBytes = @{}; $bestObj = @{}
    $selectPicks = {
        param([double]$Lambda)
        $hasBest = @{}
        foreach ($idx in $shotIds) { $hasBest[$idx] = $false }
        foreach ($s in $Samples) {
            $idx = $s.Idx
            if ($pinned.ContainsKey($idx)) {
                if (-not $hasBest[$idx]) {
                    $hasBest[$idx] = $true
                    $bestQp[$idx] = $maxvQp[$idx]; $bestVmaf[$idx] = $maxvV[$idx]; $bestBytes[$idx] = $maxvB[$idx]
                }
                continue
            }
            $obj = [double]$weight[$idx] * [double]$s.Vmaf - $Lambda * [double]$s.Bytes
            if (-not $hasBest[$idx] -or $obj -gt [double]$bestObj[$idx]) {
                $hasBest[$idx] = $true; $bestObj[$idx] = $obj
                $bestQp[$idx] = "$($s.Qp)"; $bestVmaf[$idx] = [double]$s.Vmaf; $bestBytes[$idx] = [double]$s.Bytes
            }
        }
    }
    $floorV = if ($FloorDrop -gt 0) { $Target - $FloorDrop } else { -1.0 }
    $pinAddedTotal = 0
    $lambda = 0.0
    for ($round = 0; $round -le $PinRounds; $round++) {
        $lo = 1e-12; $hi = 1.0
        for ($iter = 0; $iter -lt 60; $iter++) {
            $lambda = [math]::Exp(([math]::Log($lo) + [math]::Log($hi)) / 2.0)
            & $selectPicks $lambda
            $totalBytes = 0.0
            foreach ($idx in $shotIds) { $totalBytes += [double]$bestBytes[$idx] }
            if ($totalBytes -gt $Budget) { $lo = $lambda } else { $hi = $lambda }
        }
        $lambda = [math]::Exp(([math]::Log($lo) + [math]::Log($hi)) / 2.0)
        & $selectPicks $lambda
        if ($floorV -lt 0) { break }
        $newPins = 0
        foreach ($idx in $shotIds) {
            if ($pinned.ContainsKey($idx)) { continue }
            if ([double]$weight[$idx] -lt 0.999) { continue }
            if ([double]$bestVmaf[$idx] -lt $floorV -and [double]$maxvV[$idx] -gt ([double]$bestVmaf[$idx] + 0.01)) {
                $pinned[$idx] = 1; $newPins++; $pinAddedTotal++
            }
        }
        if ($newPins -eq 0) { break }
    }
    $totalBytesFinal = 0.0; $minVmaf = 999.0; $minIdx = ''; $minBodyVmaf = 999.0; $minBodyIdx = ''; $weightedN = 0
    foreach ($idx in $bestVmaf.Keys) {
        $totalBytesFinal += [double]$bestBytes[$idx]
        if ([double]$bestVmaf[$idx] -lt $minVmaf) { $minVmaf = [double]$bestVmaf[$idx]; $minIdx = $idx }
        if ([double]$weight[$idx] -lt 0.999) {
            $weightedN++
        } elseif ([double]$bestVmaf[$idx] -lt $minBodyVmaf) {
            $minBodyVmaf = [double]$bestVmaf[$idx]; $minBodyIdx = $idx
        }
    }
    $overPct = if ($Budget -gt 0) { 100.0 * ($totalBytesFinal - $Budget) / $Budget } else { 0.0 }
    $report = "LAMBDA=$($lambda.ToString('0.##########e+0', [System.Globalization.CultureInfo]::InvariantCulture)) TOTAL_BYTES=$([int64][math]::Truncate($totalBytesFinal)) BUDGET=$([int64][math]::Truncate($Budget)) OVERSHOOT_PCT=$($overPct.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)) MIN_SHOT_VMAF=$($minVmaf.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)) (shot $minIdx) MIN_BODY_VMAF=$($minBodyVmaf.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)) (shot $minBodyIdx) POS_WEIGHTED_SHOTS=$weightedN FLOOR_PINNED=$pinAddedTotal (floor $($floorV.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)))"
    $picks = foreach ($idx in $bestQp.Keys) {
        [PSCustomObject]@{ Idx = $idx; Qp = "$($bestQp[$idx])"; Vmaf = [double]$bestVmaf[$idx] }
    }
    return [PSCustomObject]@{ Picks = @($picks); Report = $report; OvershootPct = $overPct }
}

function Assemble-VesQpfileViaEqualSlopeBudget {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$QpfileOut,
        [Parameter(Mandatory)][double]$ByteBudget,
        [double]$DeprioStart,
        [double]$DeprioEnd,
        [double]$DeprioWeight = 1.0,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $mdir = Get-VesShotManifestDir -Source $Source
    if (-not (Test-VesShotManifestAllResolved -Source $Source)) {
        throw "Shot manifest is not fully resolved: $mdir"
    }
    $pstTarget = 94.0
    try {
        $pstCandidate = Get-VesVmafTargetForSource -Source $Source -FfprobePath $FfprobePath
        if ($null -ne $pstCandidate) { $pstTarget = [double]$pstCandidate }
    } catch { $pstTarget = 94.0 }
    $floorDrop = Get-VesAllocMinShotVmafDrop
    $pinRounds = Get-VesAllocMinShotPinRounds
    $calK = Get-VesAllocBytesCalibrationK

    if ($ByteBudget -gt 0 -and $ByteBudget -le 4) {
        $baseline = Get-VesEqualSlopeBudgetBaseline -ManifestDir $mdir -Target $pstTarget
        $ByteBudget = [double]::Parse(($ByteBudget * $baseline).ToString('0', [System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
        Write-Warning "  equal-slope budget: fraction mode -> baseline=$([int64]$baseline) B, budget=$([int64]$ByteBudget) B"
    } else {
        $div = if ($calK -gt 0) { $calK } else { 1.0 }
        $ByteBudget = [double]::Parse(($ByteBudget / $div).ToString('0', [System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
        Write-Warning "  equal-slope budget: absolute mode, /K=$calK -> internal budget=$([int64]$ByteBudget) B"
    }

    $shotStart = @{}; $shotEnd = @{}; $sampleShotStart = @{}; $sampleShotEnd = @{}
    $samples = [System.Collections.Generic.List[object]]::new()
    $noSampleIdx = [System.Collections.Generic.List[string]]::new()
    foreach ($f in (Get-ChildItem -LiteralPath $mdir -Filter 'shot-*.meta' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $meta = Get-Content -LiteralPath $f.FullName -Raw
        $idx = Get-VesShotMetaValue -Content $meta -Key 'index'
        $startTs = Get-VesShotMetaValue -Content $meta -Key 'start_ts'
        $endTs = Get-VesShotMetaValue -Content $meta -Key 'end_ts'
        $shotStart[$idx] = $startTs; $shotEnd[$idx] = $endTs
        $statusFile = Get-VesManifestShotStatusPath -ManifestDir $mdir -Index $idx
        $status = Get-Content -LiteralPath $statusFile -Raw
        $samplesLine = Get-VesShotMetaValue -Content $status -Key 'samples'
        $valid = ConvertFrom-VesShotSamplesLine -SamplesLine $samplesLine
        if ($valid.Count -eq 0) {
            $noSampleIdx.Add($idx)
            continue
        }
        $sampleShotStart[$idx] = $startTs; $sampleShotEnd[$idx] = $endTs
        foreach ($s in $valid) {
            $samples.Add([PSCustomObject]@{ Idx = "$idx"; Qp = "$($s.Qp)"; Vmaf = [double]$s.Vmaf; Bytes = [double]$s.Bytes })
        }
    }
    $nTotal = @(Get-ChildItem -LiteralPath $mdir -Filter 'shot-*.meta' -File -ErrorAction SilentlyContinue).Count
    $nFb = $noSampleIdx.Count
    if ($nFb -gt 0 -and $nTotal -gt $nFb) {
        $ByteBudget = [double]::Parse(($ByteBudget * ($nTotal - $nFb) / $nTotal).ToString('0', [System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
        Write-Warning "  equal-slope budget: reserved for $nFb/$nTotal fallback shots -> solve budget=$([int64]$ByteBudget) B"
    }

    $bound = $PSBoundParameters.ContainsKey('DeprioStart') -and $PSBoundParameters.ContainsKey('DeprioEnd')
    $solve = Invoke-VesEqualSlopeBudgetSolve -Samples @($samples) -ShotStart $sampleShotStart -ShotEnd $sampleShotEnd `
        -Budget $ByteBudget -DeprioStart ($(if ($bound) { "$DeprioStart" } else { $null })) -DeprioEnd ($(if ($bound) { "$DeprioEnd" } else { $null })) `
        -DeprioWeight $DeprioWeight -HeadFrac (Get-VesAllocPosWeightHeadFrac) -TailFrac (Get-VesAllocPosWeightTailFrac) `
        -WeightMin (Get-VesAllocPosWeightMin) -Target $pstTarget -FloorDrop $floorDrop -PinRounds $pinRounds
    Write-Warning $solve.Report
    if ($solve.OvershootPct -gt 10.0) {
        Write-Warning "  equal-slope budget: BUDGET_UNREACHABLE -- solve overshoots by $($solve.OvershootPct.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture))% (floor pins + tight budget); qpfile is the constrained best, not the requested size"
    }

    $shotQps = @{}
    foreach ($p in $solve.Picks) {
        $shotQps["$($p.Idx)"] = "$($shotStart[$p.Idx]):$($shotEnd[$p.Idx]):$($p.Qp)"
    }
    foreach ($ni in $noSampleIdx) {
        $status = Get-Content -LiteralPath (Get-VesManifestShotStatusPath -ManifestDir $mdir -Index $ni) -Raw
        $fallbackQp = Get-VesShotMetaValue -Content $status -Key 'qp'
        $shotQps["$ni"] = "$($shotStart[$ni]):$($shotEnd[$ni]):$fallbackQp"
    }

    $ft = Get-VesFpsAndTotalFrames -Source $Source -FfprobePath $FfprobePath
    Write-VesShotQpsToQpfile -Shots (ConvertTo-VesShotQpArray -ShotQpMap $shotQps) -TotalFrames $ft.TotalFrames -Fps $ft.Fps -QpfileOut $QpfileOut
    Write-Host "Assembled qpfile via equal-slope budget allocation: $($shotQps.Count) shots, $QpfileOut ($($ft.TotalFrames) frames)"
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
            # -Path (not -LiteralPath, which New-Item lacks) globs [ ] * ? -- a
            # bracketed movie title would break the create. Escape it.
            New-Item -ItemType Directory -Path ([System.Management.Automation.WildcardPattern]::Escape($mdir)) -Force | Out-Null
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
            New-Item -ItemType Directory -Path ([System.Management.Automation.WildcardPattern]::Escape($lockPath)) -ErrorAction Stop | Out-Null
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
                    New-Item -ItemType Directory -Path ([System.Management.Automation.WildcardPattern]::Escape($lockPath)) -ErrorAction Stop | Out-Null
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
    # Serialize concurrent instances on this host (multi-worker per host,
    # 2026-09-03): an mkdir lock so only one instance copies the multi-GB
    # source; the rest wait, then find it done. Bounded -> fall back to a
    # network read if the copier is stuck.
    $lockDir = "$dst.copylock.d"
    $waited = 0
    while ($true) {
        try { New-Item -ItemType Directory -Path ([System.Management.Automation.WildcardPattern]::Escape($lockDir)) -ErrorAction Stop | Out-Null; break }
        catch {
            if ((Test-Path -LiteralPath $dst) -and ((Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue).Length -eq $want)) {
                try { (Get-Item -LiteralPath $dst).LastAccessTimeUtc = [DateTime]::UtcNow } catch { }
                return $dst
            }
            if (Test-Path -LiteralPath $lockDir) {
                $la = (Get-Item -LiteralPath $lockDir -ErrorAction SilentlyContinue).LastWriteTimeUtc
                if ($la -and ([DateTimeOffset]::UtcNow - $la).TotalSeconds -gt 2400) {
                    try { Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
            Start-Sleep -Seconds 5; $waited += 5
            if ($waited -gt 2700) { return $Source }
        }
    }
    try {
        if ((Test-Path -LiteralPath $dst) -and ((Get-Item -LiteralPath $dst).Length -eq $want)) {
            Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
            return $dst
        }
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
    } finally {
        Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
    $SvtAv1EncAppPath = Resolve-VesSvtAv1EncAppPath -SvtAv1EncAppPath $SvtAv1EncAppPath
    $useSvtBin = [bool]$SvtAv1EncAppPath
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
            Write-Warning "per-shot bytes: SvtAv1EncApp not found; falling back to ffmpeg libsvtav1. Results may not be fleet-comparable."
            $out = Join-Path $work 'shot.ivf'
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
    # Bash: sort -n; odd NR -> a[int(NR/2)+1] (1-indexed middle); even -> mean of
    # the two middle. The middle 0-indexed element for odd N is floor(N/2) -- NOT
    # [int](N/2), which for N=3 is [int]1.5 == 2 (PowerShell banker's rounding),
    # i.e. the MAX, biasing every long-shot score high (found live 2026-09-03,
    # PRINCE E2E: mw VMAFs ran +1..+7 vs the fleet).
    $mid = [int][math]::Floor($sorted.Count / 2)
    $med = if ($sorted.Count % 2) { $sorted[$mid] }
           else { ($sorted[$mid - 1] + $sorted[$mid]) / 2 }
    $avgRate = ($rates | Measure-Object -Average).Average
    # Bash does not round the combined median (window VMAFs are already 2dp from
    # _vmaf_score_shot; an even-count average may carry a 3rd digit -- keep it).
    return [PSCustomObject]@{ Vmaf = $med; Bytes = [long]($avgRate * $shotDur) }
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
    $SvtAv1EncAppPath = Resolve-VesSvtAv1EncAppPath -SvtAv1EncAppPath $SvtAv1EncAppPath
    $useSvtBin = [bool]$SvtAv1EncAppPath

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
            # ffmpeg libsvtav1 fallback, uniform QP == qp-file of one value.
            # Keep IVF as the measured byte artifact, matching the
            # SvtAv1EncApp path and bash's byte contract.
            Write-Warning "per-shot VMAF: SvtAv1EncApp not found; falling back to ffmpeg libsvtav1. Results may not be fleet-comparable."
            $out = Join-Path $work "shot-enc-$Qp.ivf"
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
            $outMkv = Join-Path $work "shot-enc-$Qp.mkv"
            $mux = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
                '-y', '-v', 'error', '-i', $out, '-c', 'copy', $outMkv
            ) -TimeoutSeconds $encTimeout -MaxRetries 1
            if ($mux.TimedOut -or $mux.ExitCode -ne 0) { return $null }
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
    Get-VesWorkingDirForSource, Get-VesShotManifestDir, Get-VesShotLockPath, Get-VesShotPathMtime, `
    Convert-VesFleetPath, `
    Test-VesShotManifestAllResolved, New-VesShotManifest, `
    Enter-VesShotClaim, Exit-VesShotClaim, `
    Clear-VesShotScratch, Invoke-VesShotSearchWorkerLoop, `
    Get-VesVmafScoreShot, Resolve-VesPerShotQp, Invoke-VesShotSearchClaimed, `
    Get-VesStageSourceLocal, Get-VesShotIsNosignal, Get-VesShotEncodeBytesOnly, `
    Get-VesVmafScoreShotMw, Test-VesShotManifestBracketHealth, `
    Write-VesShotQpsToQpfile, Assemble-VesQpfileFromShotManifest, `
    Get-VesCreditsRange, Assemble-VesQpfileViaEqualSlopeBudget, `
    Get-VesAllocPosWeightHeadFrac, Get-VesAllocPosWeightTailFrac, Get-VesAllocPosWeightMin, `
    Get-VesAllocMinShotVmafDrop, Get-VesAllocMinShotPinRounds, Get-VesAllocBytesCalibrationK, `
    Get-VesPerShotQpBracketFor, Test-VesShotBracketEdge, `
    Get-VesShotLongSecs, Get-VesPerShotMwLen, Get-VesPerShotVmafStride, `
    Get-VesShotComplexityEnable, Get-VesPerShotMultiwindowEnable, `
    Get-VesNosignalFastpath, Get-VesNosigQp, Get-VesPerShotQpBracketEnable
