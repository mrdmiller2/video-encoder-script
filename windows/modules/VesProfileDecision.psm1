# Windows port of convert-v5.0.33S.sh's profile/HDR/CRF decision tree:
# detect_profile_for_path()/profile_for_source(), profile_svt_params()/
# profile_x265_params()/profile_x265_tune()/profile_fixed_crf(),
# determine_hdr_mode()/source_dovi_profile()/extract_hdr10_static_metadata(),
# and resolve_upscale_target() (lines ~4099-4165, 8997-9066, 9212-9431,
# 10219-10450).
#
# Deliberately NOT ported: upscale_sample_decision()'s dual-sample
# encode-and-compare-VMAF-at-720-vs-1080 path (a real, expensive decision
# requiring its own sample-encode machinery). resolve_upscale_target's
# fast paths (near-720p grace band, SD-native, low-bpppf) are ported in
# full; when none of those apply and a genuine sample test would be
# needed, this port uses the bash version's OWN documented conservative
# fallback (favor 1080 near the grace band, 720 for SD) rather than
# inventing different behavior or silently guessing.
#
# Team-review fix (2026-08-02): every ffprobe call in this module used
# to be a raw `& $FfprobePath ...` with no timeout -- the same missing-
# timeout bug already found and fixed in three OTHER modules this same
# session (a stalled child process blocks the caller indefinitely with
# climbing memory). All ffprobe calls here now go through
# Invoke-VesWithTimeoutRetry (VesTimeoutRetry.psm1), consistent with
# every other validation-probe call in this port.

if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}

function Invoke-VesProfileFfprobe {
    param(
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string[]]$ProbeArgs,
        [int]$TimeoutSeconds = 30
    )
    $r = Invoke-VesWithTimeoutRetry -FilePath $FfprobePath -ArgumentList $ProbeArgs -TimeoutSeconds $TimeoutSeconds
    if ($r.ExitCode -ne 0) { return $null }
    return $r.StdOut
}

$CLASSIC_ANIME_YEAR_CUTOFF = 1997

$FIXED_CRF_SVT_HDR = 24
$FIXED_CRF_X265_HDR = 18
$FIXED_CRF_SVT_CANIME = 24
$FIXED_CRF_X265_CANIME = 20
# v6.0.1N -- seed values, refined by the D-val budget-fraction survey
$FIXED_CRF_SVT_CONCERT = 25
$FIXED_CRF_SVT_STANDUP = 28
$FIXED_CRF_SVT_LEARNING = 30
$FIXED_CRF_X265_CONCERT = 20
$FIXED_CRF_X265_STANDUP = 22
$FIXED_CRF_X265_LEARNING = 23

$SVT_PARAMS = @{
    wanime  = 'enable-qm=1:qm-min=0:keyint=15s:scd=1:aq-mode=2:sharpness=2'
    anime   = 'enable-qm=1:film-grain-denoise=1:film-grain=6:qm-min=0:scd=1:enable-tf=0:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=3:variance-octile=4:enable-overlays=1:tune=0:sharpness=2'
    canime  = 'enable-qm=1:qm-min=0:scd=1:enable-tf=0:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=1:variance-octile=4:enable-overlays=1:sharpness=3'
    movies  = 'enable-qm=1:qm-min=0:keyint=15s:scd=1:aq-mode=2'
    classic = 'enable-qm=1:film-grain-denoise=1:film-grain=6:qm-min=0:scd=1:enable-tf=1:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=1:variance-octile=4:sharpness=1'
    vintage = 'enable-qm=1:film-grain-denoise=1:film-grain=12:qm-min=0:scd=1:enable-tf=1:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=2:variance-octile=4:sharpness=1'
    vtv     = 'enable-qm=1:film-grain-denoise=1:film-grain=5:qm-min=0:scd=1:enable-tf=1:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=2:variance-octile=4:sharpness=1'
    # Concerts / Stand-Up / Learning Series (v6.0.1N): digital capture, no
    # film-grain synthesis. See modules/ves-config.sh for the reasoning.
    concert  = 'enable-qm=1:qm-min=0:keyint=15s:scd=1:aq-mode=2:enable-variance-boost=1:variance-boost-strength=2:variance-octile=4'
    learning = 'enable-qm=1:qm-min=0:keyint=15s:scd=1:aq-mode=2:sharpness=1'
}
$SVT_PARAMS['mtv'] = $SVT_PARAMS['movies']
$SVT_PARAMS['standup'] = $SVT_PARAMS['movies']

$X265_PARAMS = @{
    wanime  = 'log-level=error:keyint=240:min-keyint=24:bframes=8:ref=4:rc-lookahead=30:aq-mode=2:psy-rd=1.0:psy-rdoq=0.8'
    anime   = 'log-level=error:keyint=240:min-keyint=24:bframes=8:ref=4:rc-lookahead=30:aq-mode=2:psy-rd=1.5:psy-rdoq=0.8'
    canime  = 'log-level=error:keyint=240:min-keyint=24:bframes=8:ref=4:rc-lookahead=30:aq-mode=2:psy-rd=2.0:psy-rdoq=1.0'
    movies  = 'log-level=error:keyint=240:min-keyint=24:bframes=8:ref=5:rc-lookahead=40:aq-mode=3:psy-rd=2.0:psy-rdoq=1.0:deblock=-1,-1'
    classic = 'log-level=error:keyint=240:min-keyint=24:bframes=8:ref=5:rc-lookahead=40:aq-mode=3:psy-rd=2.0:psy-rdoq=1.5:deblock=-1,-1'
    vintage = 'log-level=error:keyint=240:min-keyint=24:bframes=6:ref=4:rc-lookahead=30'
    vtv     = 'log-level=error:keyint=240:min-keyint=24:bframes=8:b-adapt=2:ref=5:rc-lookahead=50:aq-mode=3:no-sao=1:psy-rd=1.5:psy-rdoq=1.0'
    standup  = 'log-level=error:keyint=240:min-keyint=24:bframes=8:ref=4:rc-lookahead=30:aq-mode=3:psy-rd=1.5:psy-rdoq=1.0'
    learning = 'log-level=error:keyint=240:min-keyint=24:bframes=8:b-adapt=2:ref=4:rc-lookahead=40:aq-mode=3:no-sao=1:psy-rd=1.0:psy-rdoq=1.0'
}
$X265_PARAMS['mtv'] = $X265_PARAMS['movies']
$X265_PARAMS['concert'] = $X265_PARAMS['movies']

$GRAIN_SYNTHESIS_PROFILES = @('anime', 'classic', 'vintage', 'vtv')

$script:SvtAv1SupportsSharpness = $null

function Get-VesAnimeTitleYear {
    param([Parameter(Mandatory)][string]$Path)
    $matches = [regex]::Matches($Path, '\((\d{4})\)')
    if ($matches.Count -eq 0) { return $null }
    return [int]$matches[$matches.Count - 1].Groups[1].Value
}

function Get-VesAnimeProfileForPath {
    param([Parameter(Mandatory)][string]$Path)
    $year = Get-VesAnimeTitleYear -Path $Path
    if ($year -and $year -le $CLASSIC_ANIME_YEAR_CUTOFF) { return 'canime' }
    return 'anime'
}

function Get-VesDetectedProfileForPath {
    <#
    .SYNOPSIS
    Port of detect_profile_for_path(). Returns $null if ambiguous
    (Movies/Japanese/Animation needs an explicit --profile in the bash
    version) or undetectable.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $p = '/' + $Path.Trim('/') + '/'
    $pNorm = $p -replace '\\', '/'

    if ($pNorm -match '/Movies/Japanese/Animation/') { return $null }  # ambiguous -- caller must force
    if ($pNorm -match '/Movies/Anime/') { return Get-VesAnimeProfileForPath -Path $pNorm }
    if ($pNorm -match '/Anime/') { return Get-VesAnimeProfileForPath -Path $pNorm }
    if ($pNorm -match '/Concerts/') { return 'concert' }
    if ($pNorm -match '/Stand-Up Comedy/') { return 'standup' }
    if ($pNorm -match '/Learning Series/') { return 'learning' }
    if ($pNorm -match '/Animation/') { return 'wanime' }
    if ($pNorm -match '/Movies/[^/]+/Modern/') { return 'movies' }
    if ($pNorm -match '/Movies/[^/]+/Classic/') { return 'classic' }
    if ($pNorm -match '/Movies/[^/]+/Vintage/') { return 'vintage' }
    if ($pNorm -match '/Television/[^/]+/Modern/') { return 'mtv' }
    if ($pNorm -match '/Television/[^/]+/Vintage/') { return 'vtv' }
    return $null
}

function Test-VesSvtAv1SupportsSharpness {
    <#
    .SYNOPSIS
    Port of svtav1_supports_sharpness(). Cached per-process runtime probe
    (one real ffmpeg invocation), not assumed from a version string.
    #>
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [int]$TimeoutSeconds = 30
    )
    if ($null -ne $script:SvtAv1SupportsSharpness) { return $script:SvtAv1SupportsSharpness }

    # Timeout-bounded (2026-08-02) -- a sibling probe with no timeout
    # left its caller blocked indefinitely (climbing memory) when the
    # child process stalled; every probe call in this port needs the
    # same bound, not just the ones that hit it first in testing.
    $args = @('-hide_banner', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:d=1',
        '-c:v', 'libsvtav1', '-svtav1-params', 'sharpness=0', '-f', 'null', '-')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegPath
    foreach ($a in $args) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { }
        $proc.WaitForExit()
        $script:SvtAv1SupportsSharpness = $true
        return $script:SvtAv1SupportsSharpness
    }
    $stderrTask.Wait()
    $out = $stderrTask.Result

    if ($out -match '(?i)error parsing option sharpness') {
        $script:SvtAv1SupportsSharpness = $false
        Write-Warning "This machine's SVT-AV1 build doesn't support 'sharpness' -- omitting it from encode profiles (upgrade libsvtav1 to restore it)"
    } else {
        $script:SvtAv1SupportsSharpness = $true
    }
    return $script:SvtAv1SupportsSharpness
}

function Get-VesProfileSvtParams {
    param(
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$FfmpegPath
    )
    if (-not $SVT_PARAMS.ContainsKey($Profile)) { return $null }
    $params = $SVT_PARAMS[$Profile]
    if (-not (Test-VesSvtAv1SupportsSharpness -FfmpegPath $FfmpegPath)) {
        $params = $params -replace ':sharpness=\d+', ''
    }
    # Per-machine SVT-AV1 parallelism override (2026-08-21) -- see the
    # matching bash comment in profile_svt_params() (ves-vmaf-crf-search.sh)
    # for the full reasoning: a real observation on PRINCE (24c/32t, strong
    # modern cores) sitting at ~51-56% CPU utilization with no OS-level cap
    # found, most likely because SVT-AV1's tile-based parallelism doesn't
    # always scale to fully saturate very high core counts on its own.
    # Unset by default everywhere (zero behavior change); set per-machine
    # only after a real VMAF-at-matching-CRF benchmark on that specific
    # machine -- more tiles is a genuine, if usually small, compression
    # cost, and high core count alone doesn't justify it (a machine can
    # have many logical processors and weak per-core throughput, where
    # this wouldn't help). Applied here, shared by both the CRF search and
    # the final encode, so CRF search always stays calibrated against the
    # exact config the final encode uses.
    if ($env:CONVERT_SVTAV1_TILE_COLUMNS) { $params = "${params}:tile-columns=$($env:CONVERT_SVTAV1_TILE_COLUMNS)" }
    if ($env:CONVERT_SVTAV1_TILE_ROWS) { $params = "${params}:tile-rows=$($env:CONVERT_SVTAV1_TILE_ROWS)" }
    if ($env:CONVERT_SVTAV1_LP) { $params = "${params}:lp=$($env:CONVERT_SVTAV1_LP)" }
    return $params
}

function Get-VesProfileX265Params {
    param([Parameter(Mandatory)][string]$Profile)
    if (-not $X265_PARAMS.ContainsKey($Profile)) { return $null }
    return $X265_PARAMS[$Profile]
}

function Get-VesProfileX265Tune {
    <#
    .SYNOPSIS
    x265's own "tune" is a whole-preset shortcut, never a valid
    -x265-params key -- must be passed via ffmpeg's own -tune AVOption.
    Empty/$null means "no tune"; caller must skip the flag entirely.
    #>
    param([Parameter(Mandatory)][string]$Profile)
    switch ($Profile) {
        { $_ -in @('wanime', 'anime', 'canime') } { return 'animation' }
        'vintage' { return 'grain' }
        default { return $null }
    }
}

function Get-VesProfileFixedCrf {
    param(
        [Parameter(Mandatory)][ValidateSet('av1', 'hevc')][string]$Codec,
        [Parameter(Mandatory)][string]$Profile,
        [bool]$IsHdr = $false
    )
    if ($IsHdr) {
        if ($Codec -eq 'av1') { return $FIXED_CRF_SVT_HDR } else { return $FIXED_CRF_X265_HDR }
    }
    $table = @{
        'av1:wanime' = 26; 'av1:anime' = 26; 'av1:canime' = $FIXED_CRF_SVT_CANIME; 'av1:movies' = 26
        'av1:classic' = 25; 'av1:vintage' = 24; 'av1:mtv' = 26; 'av1:vtv' = 25
        'av1:concert' = $FIXED_CRF_SVT_CONCERT; 'av1:standup' = $FIXED_CRF_SVT_STANDUP; 'av1:learning' = $FIXED_CRF_SVT_LEARNING
        'hevc:wanime' = 20; 'hevc:anime' = 22; 'hevc:canime' = $FIXED_CRF_X265_CANIME; 'hevc:movies' = 20
        'hevc:classic' = 20; 'hevc:vintage' = 20; 'hevc:mtv' = 20; 'hevc:vtv' = 21
        'hevc:concert' = $FIXED_CRF_X265_CONCERT; 'hevc:standup' = $FIXED_CRF_X265_STANDUP; 'hevc:learning' = $FIXED_CRF_X265_LEARNING
    }
    $key = "${Codec}:${Profile}"
    if ($table.ContainsKey($key)) { return $table[$key] }
    return $null
}

function Test-VesProfileUsesGrainSynthesis {
    param([Parameter(Mandatory)][string]$Profile)
    return $Profile -in $GRAIN_SYNTHESIS_PROFILES
}

function Get-VesVideoColorTransfer {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $out = Invoke-VesProfileFfprobe -FfprobePath $FfprobePath -ProbeArgs @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=color_transfer', '-of', 'default=noprint_wrappers=1:nokey=1', $Source)
    if (-not $out) { return 'unknown' }
    return $out.Trim()
}

function Test-VesSourceHasDolbyVision {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $out = Invoke-VesProfileFfprobe -FfprobePath $FfprobePath -ProbeArgs @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream_side_data=side_data_type', '-of', 'csv=p=0', $Source)
    return $out -match '(?i)DOVI configuration record'
}

function Get-VesSourceDoviProfile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $out = Invoke-VesProfileFfprobe -FfprobePath $FfprobePath -ProbeArgs @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream_side_data=dv_profile', '-of', 'csv=p=0', $Source)
    if (-not $out) { return $null }
    $line = ($out -split "`n" | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
    return $line
}

function Resolve-VesHdrMode {
    <#
    .SYNOPSIS
    Port of determine_hdr_mode(). Returns one of: pq, pq_reconstruct,
    hlg, sdr, unknown. "unknown" means Dolby Vision side-data is present
    but couldn't be confidently classified -- caller MUST flag for human
    review, never guess (this is the exact failure shape that caused the
    original Profile 5 tint bug in the bash version).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $trc = Get-VesVideoColorTransfer -Source $Source -FfprobePath $FfprobePath

    if (Test-VesSourceHasDolbyVision -Source $Source -FfprobePath $FfprobePath) {
        $dovi = Get-VesSourceDoviProfile -Source $Source -FfprobePath $FfprobePath
        switch ($dovi) {
            '5' { return 'pq_reconstruct' }
            '7' { return 'pq' }
            '8' {
                switch ($trc) {
                    'smpte2084' { return 'pq' }
                    'arib-std-b67' { return 'hlg' }
                    default { return 'sdr' }
                }
            }
            default {
                switch ($trc) {
                    'smpte2084' { return 'pq' }
                    'arib-std-b67' { return 'hlg' }
                    default { return 'unknown' }
                }
            }
        }
    }

    switch ($trc) {
        'smpte2084' { return 'pq' }
        'arib-std-b67' { return 'hlg' }
        default { return 'sdr' }
    }
}

function Get-VesHdr10StaticMetadata {
    <#
    .SYNOPSIS
    Port of extract_hdr10_static_metadata(). Returns an object with
    MasterDisplay (SVT/x265 master-display string, or $null) and Cll
    (maxcll,maxfall, or $null).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $out = Invoke-VesProfileFfprobe -FfprobePath $FfprobePath -ProbeArgs @('-v', 'error', '-select_streams', 'v:0', '-show_frames', '-read_intervals', '%+#1', '-show_entries', 'frame_side_data_list', $Source)

    $hasMd = $false; $hasCll = $false
    $rx = $ry = $gx = $gy = $bx = $by = $wx = $wy = $minl = $maxl = $null
    $mc = $ma = 0

    $outLines = if ($out) { $out -split "`r?`n" } else { @() }
    foreach ($line in $outLines) {
        if ($line -match 'side_data_type=Mastering display metadata') { $hasMd = $true; continue }
        if ($line -match 'side_data_type=Content light level metadata') { $hasCll = $true; continue }
        if ($line -match '^red_x=(.+)$') { $rx = $Matches[1]; continue }
        if ($line -match '^red_y=(.+)$') { $ry = $Matches[1]; continue }
        if ($line -match '^green_x=(.+)$') { $gx = $Matches[1]; continue }
        if ($line -match '^green_y=(.+)$') { $gy = $Matches[1]; continue }
        if ($line -match '^blue_x=(.+)$') { $bx = $Matches[1]; continue }
        if ($line -match '^blue_y=(.+)$') { $by = $Matches[1]; continue }
        if ($line -match '^white_point_x=(.+)$') { $wx = $Matches[1]; continue }
        if ($line -match '^white_point_y=(.+)$') { $wy = $Matches[1]; continue }
        if ($line -match '^min_luminance=(.+)$') { $minl = $Matches[1]; continue }
        if ($line -match '^max_luminance=(.+)$') { $maxl = $Matches[1]; continue }
        if ($line -match '^max_content=(.+)$') { $mc = $Matches[1]; continue }
        if ($line -match '^max_average=(.+)$') { $ma = $Matches[1]; continue }
    }

    # Team-review fixes (2026-08-02): (1) a non-numeric, non-fraction
    # $s (any unexpected ffprobe field content) hit a bare [double]$s
    # cast that throws an unhandled FormatException, crashing the whole
    # metadata-extraction call -- now falls back to 0.0 instead. (2) the
    # "-f" string-format operator formats decimals using the CURRENT
    # THREAD CULTURE -- on a non-US locale (comma decimal separator)
    # this would silently corrupt the numbers ffmpeg/svtav1/x265 read
    # back as -svtav1-params/-x265-params values. Formatted via
    # [string]::Format with InvariantCulture explicitly instead.
    function ConvertTo-VesFraction($s) {
        if ($null -eq $s) { return 0.0 }
        if ($s -match '^(-?[\d.]+)/(-?[\d.]+)$') {
            $num = [double]$Matches[1]; $den = [double]$Matches[2]
            if ($den -gt 0) { return $num / $den }
        }
        $val = 0.0
        if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
            return $val
        }
        return 0.0
    }

    $masterDisplay = $null
    if ($hasMd -and $maxl) {
        $masterDisplay = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture,
            "G({0:F4},{1:F4})B({2:F4},{3:F4})R({4:F4},{5:F4})WP({6:F4},{7:F4})L({8:F1},{9:F4})",
            (ConvertTo-VesFraction $gx), (ConvertTo-VesFraction $gy),
            (ConvertTo-VesFraction $bx), (ConvertTo-VesFraction $by),
            (ConvertTo-VesFraction $rx), (ConvertTo-VesFraction $ry),
            (ConvertTo-VesFraction $wx), (ConvertTo-VesFraction $wy),
            (ConvertTo-VesFraction $maxl), (ConvertTo-VesFraction $minl))
    }
    $cll = $null
    if ($hasCll) { $cll = "$([int]$mc),$([int]$ma)" }

    return [PSCustomObject]@{ MasterDisplay = $masterDisplay; Cll = $cll }
}

function Test-VesIsDiskSource {
    param([Parameter(Mandatory)][string]$Source)
    if ([System.IO.Path]::GetExtension($Source).TrimStart('.').ToLowerInvariant() -eq 'iso') { return $true }
    return Test-Path (Join-Path $Source 'BDMV') -PathType Container
}

function Resolve-VesUpscaleTarget {
    <#
    .SYNOPSIS
    Port of resolve_upscale_target()'s fast paths (native/near-720p grace
    band, SD-native, low-bpppf). Returns 0 (no upscale), 720, or 1080.
    When none of the fast paths apply, a genuine sample-encode-based
    decision (upscale_sample_decision, not ported) would normally run --
    this falls back to the bash version's OWN documented conservative
    default for that case (1080 near the grace band, 720 for SD) rather
    than inventing new behavior.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath,
        [int]$HeightThreshold = 700,
        [double]$LowBpppf = 0.065
    )
    if (Test-VesIsDiskSource -Source $Source) { return 0 }

    $height = 0
    $bpppf = 0.0
    try {
        $h = Invoke-VesProfileFfprobe -FfprobePath $FfprobePath -ProbeArgs @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=height', '-of', 'default=noprint_wrappers=1:nokey=1', $Source)
        if ($h) { $height = [int]$h.Trim() }
    } catch { }

    if ($height -le 0) {
        Write-Warning "Upscale metrics retrieval failed/timed out -- conservative fallback: $Source"
        return 720
    }
    if ($height -ge $HeightThreshold) { return 0 }
    if ($height -gt 0 -and $height -le 360) { return 720 }

    # bpppf needs bitrate/fps too -- if those probes fail, fall through to
    # the same conservative default the bash version uses when the sample
    # test itself is unavailable/fails.
    try {
        $brOut = Invoke-VesProfileFfprobe -FfprobePath $FfprobePath -ProbeArgs @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=bit_rate', '-of', 'default=noprint_wrappers=1:nokey=1', $Source)
        $fpsOut = Invoke-VesProfileFfprobe -FfprobePath $FfprobePath -ProbeArgs @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=avg_frame_rate', '-of', 'default=noprint_wrappers=1:nokey=1', $Source)
        $br = 0.0
        if ($brOut -and $brOut.Trim() -match '^\d+$') { $br = [double]$brOut.Trim() }
        $fpsNum = 0.0
        if ($fpsOut -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -gt 0) { $fpsNum = [double]$Matches[1] / [double]$Matches[2] }
        $widthOut = Invoke-VesProfileFfprobe -FfprobePath $FfprobePath -ProbeArgs @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width', '-of', 'default=noprint_wrappers=1:nokey=1', $Source)
        $width = if ($widthOut) { [double]$widthOut.Trim() } else { 0 }

        if ($br -gt 0 -and $width -gt 0 -and $height -gt 0 -and $fpsNum -gt 0) {
            $bpppf = $br / ($width * $height * $fpsNum)
        }
    } catch { }

    if ($bpppf -gt 0 -and $bpppf -lt $LowBpppf) { return 720 }

    if ($height -ge 540) {
        Write-Warning "Upscale sample test unavailable (not ported) -- conservative 1080p fallback: $Source"
        return 1080
    }
    Write-Warning "Upscale sample test unavailable (not ported) -- conservative 720p fallback: $Source"
    return 720
}

function Build-VesFfmpegVideoArgs {
    <#
    .SYNOPSIS
    Port of build_ffmpeg_video_args(). Composes upscale filters, HDR/DoVi
    handling, and per-profile SVT-AV1/x265 params into the args consumed
    by Invoke-VesTwoStageEncode's -VideoArgs/-VideoFilters/-ColorArgs and
    by Resolve-VesCrfForEncode's -EncoderArgs/-VideoFilter (for the
    ab-av1 search to stay calibrated against the same params the real
    encode will use).

    .OUTPUTS
    PSCustomObject with VideoArgs, VideoFilters, ColorArgs (string[]).
    Returns $null (Dolby Vision profile 5 without libplacebo) when the
    caller must flag the source for human review instead of encoding --
    matching build_ffmpeg_video_args()'s rc=2 contract.

    Real bug found 2026-08-03: -SvtPreset/-X265Preset defaulted to '8'/
    'medium' -- bash's own SEARCH-only presets (SVT_PRESET_SEARCH=8,
    the fast-sample preset used only for VMAF CRF-search comparisons in
    VesVmafCrfSearch.psm1), not its FINAL-encode presets
    (SVT_PRESET_FINAL=5, X265_PRESET_FINAL=slow). Every real encode this
    port has produced to date used the fast/lower-quality search preset
    instead of the intended final-quality one. Found via a genuine SVT-AV1
    crash on GruntBox2's pre-AVX2 Xeon X5570 at preset 8 (reproduced
    identically on that host's Linux/WSL2 side with the same ffmpeg/
    SVT-AV1 build -- a real upstream SVT-AV1 crash at preset>6 on this
    CPU generation, not a Windows-specific bug), which is what surfaced
    that preset 8 was ever reaching a final encode in the first place.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('av1', 'hevc')][string]$Codec,
        [Parameter(Mandatory)][int]$Crf,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][bool]$IsHdr,
        [Parameter(Mandatory)][string]$HdrMode,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [int]$UpscaleTargetHeight = 0,
        [bool]$FfmpegHasLibPlacebo = $false,
        [string]$SvtPreset = '5',
        [string]$X265Preset = 'slow'
    )

    $videoFilters = [System.Collections.Generic.List[string]]::new()
    $videoArgs = [System.Collections.Generic.List[string]]::new()
    $colorArgs = [System.Collections.Generic.List[string]]::new()

    switch ($UpscaleTargetHeight) {
        720 { $videoFilters.Add('scale=1280:720:flags=lanczos:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2') }
        1080 { $videoFilters.Add('scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2') }
    }

    if ($Profile -eq 'canime') {
        $videoFilters.Add('unsharp=luma_msize_x=5:luma_msize_y=5:luma_amount=0.6:chroma_msize_x=5:chroma_msize_y=5:chroma_amount=0.0')
    }

    if ($IsHdr) {
        $dovi = Get-VesSourceDoviProfile -Source $Source -FfprobePath $FfprobePath
        if ($dovi -eq '5') {
            if (-not $FfmpegHasLibPlacebo) {
                return $null
            }
            Write-Host 'Dolby Vision profile 5 -- converting to HDR10 via libplacebo'
            $videoFilters.Add('libplacebo=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084:format=yuv420p10le')
        } elseif ($dovi) {
            $baseDesc = if ($HdrMode -eq 'hlg') { 'HLG' } else { 'HDR10' }
            Write-Host "Dolby Vision profile $dovi -- dropping RPU, keeping $baseDesc base layer"
        }
    }

    $hdrMeta = Get-VesHdr10StaticMetadata -Source $Source -FfprobePath $FfprobePath

    if ($Codec -eq 'av1') {
        $svtp = Get-VesProfileSvtParams -Profile $Profile -FfmpegPath $FfmpegPath
        if ($null -eq $svtp) { return $null }
        if ($IsHdr) {
            # No "enable-hdr" here -- see ves-twostage-encode.sh's matching
            # comment (2026-08-13): it was never a real SVT-AV1 option on
            # any version checked, silently logged-and-ignored on every HDR
            # encode this project has run. Real color signaling is set via
            # ffmpeg's own -color_primaries/-color_trc/-colorspace args.
            if ($HdrMode -ne 'hlg') {
                if ($hdrMeta.MasterDisplay) { $svtp = "${svtp}:mastering-display=$($hdrMeta.MasterDisplay)" }
                if ($hdrMeta.Cll) { $svtp = "${svtp}:content-light=$($hdrMeta.Cll)" }
            }
        }
        $videoArgs.AddRange([string[]]@('-c:v', 'libsvtav1', '-preset', $SvtPreset, '-crf', "$Crf", '-pix_fmt', 'yuv420p10le', '-svtav1-params', $svtp))
    } else {
        $x265p = Get-VesProfileX265Params -Profile $Profile
        if ($null -eq $x265p) { return $null }
        if ($IsHdr) {
            if ($HdrMode -eq 'hlg') {
                $x265p = "${x265p}:repeat-headers=1"
            } else {
                $x265p = "${x265p}:hdr10=1:repeat-headers=1"
                if ($hdrMeta.MasterDisplay) { $x265p = "${x265p}:master-display=$($hdrMeta.MasterDisplay)" }
                if ($hdrMeta.Cll) { $x265p = "${x265p}:max-cll=$($hdrMeta.Cll)" }
            }
        }
        $videoArgs.AddRange([string[]]@('-c:v', 'libx265', '-preset', $X265Preset, '-crf', "$Crf", '-pix_fmt', 'yuv420p10le', '-x265-params', $x265p))
        $x265Tune = Get-VesProfileX265Tune -Profile $Profile
        if ($x265Tune) { $videoArgs.AddRange([string[]]@('-tune', $x265Tune)) }
    }

    if ($IsHdr) {
        if ($HdrMode -eq 'hlg') {
            $colorArgs.AddRange([string[]]@('-color_primaries', 'bt2020', '-color_trc', 'arib-std-b67', '-colorspace', 'bt2020nc'))
        } else {
            $colorArgs.AddRange([string[]]@('-color_primaries', 'bt2020', '-color_trc', 'smpte2084', '-colorspace', 'bt2020nc'))
        }
        $videoArgs.AddRange($colorArgs)
    }

    return [PSCustomObject]@{
        VideoArgs    = $videoArgs.ToArray()
        VideoFilters = $videoFilters.ToArray()
        ColorArgs    = $colorArgs.ToArray()
    }
}

Export-ModuleMember -Function `
    Get-VesAnimeTitleYear, Get-VesAnimeProfileForPath, Get-VesDetectedProfileForPath, `
    Test-VesSvtAv1SupportsSharpness, Get-VesProfileSvtParams, Get-VesProfileX265Params, `
    Get-VesProfileX265Tune, Get-VesProfileFixedCrf, Test-VesProfileUsesGrainSynthesis, `
    Get-VesVideoColorTransfer, Test-VesSourceHasDolbyVision, Get-VesSourceDoviProfile, `
    Resolve-VesHdrMode, Get-VesHdr10StaticMetadata, Test-VesIsDiskSource, Resolve-VesUpscaleTarget, `
    Build-VesFfmpegVideoArgs
