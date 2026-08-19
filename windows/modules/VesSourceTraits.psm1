# Windows port of modules/ves-source-traits.sh -- per-file telecine/
# interlace and black-and-white ("source traits") detection, used to
# drive detelecine/deinterlace filter selection (QTGMC/bwdif) and
# B&W-aware CRF/VMAF tuning.
#
# Same standing priority order this whole project is built to respect:
# 1) no data loss, 2) no substantial quality/fidelity loss, 3) size
# reduction. Telecine and genuine interlace are classified SEPARATELY
# (never collapsed into one "combed" flag) -- see ves-source-traits.sh's
# own header comment for the full reasoning, unchanged here. When
# classification is ambiguous, this always returns "ambiguous" rather
# than guessing.

if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}
if (-not (Get-Module -Name VesValidation)) {
    Import-Module (Join-Path $PSScriptRoot 'VesValidation.psm1') -Force
}
if (-not (Get-Module -Name VesVmafCrfSearch)) {
    Import-Module (Join-Path $PSScriptRoot 'VesVmafCrfSearch.psm1') -Force
}

# Source-traits classification thresholds -- same values as
# modules/ves-config.sh's SOURCE_TRAITS_* constants, kept in lockstep by
# hand (no shared config file between the two platforms).
$script:SourceTraitsProbeWidthSecs = 10
$script:SourceTraitsProgressiveMin = 0.95
$script:SourceTraitsTelecineRepeatMin = 0.12
$script:SourceTraitsTelecineRepeatMax = 0.30
$script:SourceTraitsInterlaceMin = 0.10
$script:SourceTraitsWindowSpreadMax = 0.25
$script:SourceTraitsBwSatavgMax = 4.0
# SOURCE_TRAITS_VFR_CV_MAX / SOURCE_BASELINE_VMAF_MIN in ves-config.sh --
# added 2026-08-19 to close a real Windows/bash parity gap: this whole
# proactive per-source VFR/CFR detection + baseline self-VMAF check
# (bash's detect_frame_rate_mode()/measure_source_baseline_vmaf(),
# ves-source-traits.sh, shipped v5.1.0W) had no Windows port at all until
# now -- the VMAF-comparison frame-rate normalization itself was already
# ported (Get-VesFinalVmaf's measure-both-ways-take-max fps handling), so
# this closes the PROACTIVE detection/logging/ambiguous-flagging layer on
# top of that, not a quality-safety hole in the comparison math itself.
$script:SourceTraitsVfrCvMax = 0.05
$script:SourceBaselineVmafMin = 97.0

# $Source -> cached [PSCustomObject]@{ FieldMode; IsBw; FieldOrder }
$script:SourceTraitsCache = @{}
# $Source -> cached 'cfr'|'vfr'|'unknown'
$script:FrameRateModeCache = @{}
# $Source -> cached [double] baseline self-VMAF
$script:BaselineVmafCache = @{}

function Get-VesDtsDeltaCv {
    <#
    .SYNOPSIS
    Port of _dts_delta_cv() (ves-source-traits.sh). Coefficient of
    variation of packet dts_time deltas in one probe window -- low for
    genuinely regular frame pacing, high when frames are irregularly
    spaced or duplicated. Filters ffprobe's literal "N/A" dts_time near
    a seek boundary (same B-frame-reorder-buffer gotcha the bash version
    hit against a real Battlestar Galactica sample, 2026-08-13).

    .OUTPUTS
    [double] or $null on failure / fewer than 4 usable packets.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][string]$FfprobePath,
        [int]$TimeoutSeconds = 60
    )
    $startStr = $Start.ToString('F3', [System.Globalization.CultureInfo]::InvariantCulture)
    $result = Invoke-VesWithTimeoutRetry -FilePath $FfprobePath -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=dts_time',
        '-of', 'csv=p=0', '-read_intervals', "${startStr}%+${Width}", $Source
    ) -TimeoutSeconds $TimeoutSeconds -MaxRetries 1
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or -not $result.StdOut) { return $null }

    $times = [System.Collections.Generic.List[double]]::new()
    foreach ($line in ($result.StdOut -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $v = 0.0
        if ([double]::TryParse($line, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
            $times.Add($v)
        }
    }
    if ($times.Count -lt 4) { return $null }
    $sorted = $times | Sort-Object
    $deltas = [System.Collections.Generic.List[double]]::new()
    for ($i = 1; $i -lt $sorted.Count; $i++) { $deltas.Add($sorted[$i] - $sorted[$i - 1]) }
    $mean = ($deltas | Measure-Object -Average).Average
    if ($mean -le 0) { return $null }
    $sumSq = 0.0
    foreach ($d in $deltas) { $sumSq += [math]::Pow($d - $mean, 2) }
    $stdev = [math]::Sqrt($sumSq / $deltas.Count)
    return ($stdev / $mean)
}

function Get-VesSourceFrameRateMode {
    <#
    .SYNOPSIS
    Windows port of detect_frame_rate_mode() (ves-source-traits.sh) --
    2026-08-19 parity fix, the proactive per-source CFR/VFR classification
    had no Windows port at all before this. Reuses Get-VesComplexitySamplePoints
    for sample windows (same 3-point low/median/high spread already used
    for the CRF-search bake-off, not a second independent sampling pass)
    and Get-VesDtsDeltaCv for the actual measurement. Cached -- safe to
    call repeatedly.

    .OUTPUTS
    'cfr' | 'vfr' | 'unknown' (no usable probe windows)
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    if ($script:FrameRateModeCache.ContainsKey($Source)) {
        return $script:FrameRateModeCache[$Source]
    }

    $dur = Get-VesMediaDurationSeconds -Path $Source -FfprobePath $FfprobePath
    $starts = $null
    if ($dur -and $dur -gt 0) {
        $starts = Get-VesComplexitySamplePoints -Source $Source -Duration $dur -FfprobePath $FfprobePath
    }
    if (-not $starts) {
        $durOrZero = if ($dur) { $dur } else { 0 }
        $starts = @([math]::Max(0, $durOrZero / 2))
    }

    $width = $script:SourceTraitsProbeWidthSecs
    $cvs = [System.Collections.Generic.List[double]]::new()
    foreach ($start in $starts) {
        $cv = Get-VesDtsDeltaCv -Source $Source -Start $start -Width $width -FfprobePath $FfprobePath
        if ($null -ne $cv) { $cvs.Add($cv) }
    }

    $mode = 'unknown'
    if ($cvs.Count -gt 0) {
        $avgCv = ($cvs | Measure-Object -Average).Average
        $mode = if ($avgCv -le $script:SourceTraitsVfrCvMax) { 'cfr' } else { 'vfr' }
        Write-Host "Source frame-rate mode: $Source -> $mode (avg_cv=$('{0:F4}' -f $avgCv) windows=$($cvs.Count))"
    } else {
        Write-Warning "Source frame-rate mode: no usable probe windows for $Source -- unknown"
    }
    $script:FrameRateModeCache[$Source] = $mode
    return $mode
}

function Get-VesSourceBaselineVmaf {
    <#
    .SYNOPSIS
    Windows port of measure_source_baseline_vmaf() (ves-source-traits.sh)
    -- 2026-08-19 parity fix, no Windows port existed before this. Measures
    $Source's VMAF against itself: a pure measurement-methodology sanity
    check (identical content, a healthy source should score ~100), not a
    real quality assessment. Confirms the comparison technique actually
    works for THIS source's specific frame-timing characteristics before
    any later encode-vs-source comparison is trusted for it. Reuses
    Get-VesFinalVmaf unchanged (same measure-both-ways-take-max fps
    handling already hardened for the VMAF-VFR bug) rather than
    duplicating VMAF-comparison logic. Cached -- safe to call repeatedly.
    A source that fails this baseline gets flagged for human review via
    Write-VesSourceTraitsAmbiguousFlag immediately, instead of silently
    producing a misleading low "quality" number after a real encode.

    .OUTPUTS
    [double] VMAF score, or $null if it couldn't be measured at all.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$JobSidecarDir
    )
    if ($script:BaselineVmafCache.ContainsKey($Source)) {
        return $script:BaselineVmafCache[$Source]
    }
    if (-not (Test-Path -LiteralPath $Source)) { return $null }

    $vmaf = Get-VesFinalVmaf -Source $Source -Output $Source -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -TargetHeight 0
    if ($null -eq $vmaf) { return $null }

    $script:BaselineVmafCache[$Source] = $vmaf
    if ($vmaf -lt $script:SourceBaselineVmafMin) {
        $frMode = Get-VesSourceFrameRateMode -Source $Source -FfprobePath $FfprobePath
        Write-Warning "Source baseline VMAF LOW: $Source -> $vmaf (below $($script:SourceBaselineVmafMin) -- measurement methodology unreliable for this source)"
        if ($JobSidecarDir) {
            Write-VesSourceTraitsAmbiguousFlag -JobSidecarDir $JobSidecarDir -SourcePath $Source `
                -Detail "baseline self-VMAF $vmaf below $($script:SourceBaselineVmafMin) -- frame_rate_mode=$frMode"
        }
    } else {
        Write-Host "Source baseline VMAF: $Source -> $vmaf"
    }
    return $vmaf
}

function Get-VesOutputFrameDuplication {
    <#
    .SYNOPSIS
    Windows port of detect_output_frame_duplication() (ves-source-traits.sh,
    2026-08-16). Diagnostic-only, called from the below-VMAF-floor tagging
    path (same as bash) -- reuses Get-VesDtsDeltaCv on the FINISHED OUTPUT
    (not the source) to distinguish "genuinely low quality" from "real
    duplicate frames baked into the output," found auditing a 38-file
    fleet-wide below-floor backlog all traced to one 2026-08-13 batch run
    (root cause not pinned down -- see the bash function's own comment for
    the full investigation). $CvMax mirrors bash's
    OUTPUT_DUPLICATE_FRAME_CV_MAX (0.15), same wide-margin reasoning: clean
    encodes measure ~0.01-0.05, the confirmed-defective files measured
    0.5-0.8+.

    .OUTPUTS
    'ok' | 'duplicated' | 'unknown'
    #>
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$FfprobePath,
        [double]$CvMax = 0.15,
        [int]$ProbeWidth = 10
    )
    $durArgs = @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', $Output)
    $durResult = Invoke-VesWithTimeoutRetry -FilePath $FfprobePath -ArgumentList $durArgs -TimeoutSeconds 30 -MaxRetries 1
    $dur = 0.0
    if ($durResult.TimedOut -or $durResult.ExitCode -ne 0 -or
        -not [double]::TryParse(($durResult.StdOut).Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dur) -or $dur -le 0) {
        return 'unknown'
    }

    $starts = Get-VesComplexitySamplePoints -Source $Output -Duration $dur -FfprobePath $FfprobePath -ProbeWidth $ProbeWidth
    if (-not $starts -or $starts.Count -eq 0) { $starts = @([math]::Max(0, $dur / 2)) }

    $cvs = [System.Collections.Generic.List[double]]::new()
    foreach ($start in $starts) {
        $cv = Get-VesDtsDeltaCv -Source $Output -Start $start -Width $ProbeWidth -FfprobePath $FfprobePath
        if ($null -ne $cv) { $cvs.Add($cv) }
    }
    if ($cvs.Count -eq 0) { return 'unknown' }
    $avgCv = ($cvs | Measure-Object -Average).Average
    Write-Verbose "Output frame-pacing check: $Output -> avg_cv=$avgCv windows=$($cvs.Count)"
    if ($avgCv -le $CvMax) { return 'ok' } else { return 'duplicated' }
}

function Get-VesComplexitySamplePoints {
    <#
    .SYNOPSIS
    Port of find_complexity_sample_points() (ves-vmaf-crf-search.sh).
    Probes packet sizes at 15 evenly-spaced points across the file
    (excluding the first/last $ExclusionSeconds, intro/credits), then
    picks the low/median/high complexity-representative points -- same
    3-point sampling already used for the AV1-vs-x265 bake-off decision,
    reused here so source-traits detection doesn't add a second
    independent sampling pass.

    .OUTPUTS
    double[3] (low, median, high start times in seconds), or $null if
    the file is too short for any usable probe window.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][double]$Duration,
        [Parameter(Mandatory)][string]$FfprobePath,
        [double]$ExclusionSeconds = 180,
        [int]$ProbeWidth = 10,
        [int]$NumProbes = 15,
        [int]$TimeoutSeconds = 60
    )
    $usableEnd = [math]::Max(0, $Duration - $ExclusionSeconds)
    $usableDur = [math]::Max(0, $usableEnd - $ExclusionSeconds)
    if ($usableDur -le 0) { return $null }

    $maxProbes = [math]::Max(1, [int][math]::Floor($usableDur / $ProbeWidth))
    if ($NumProbes -gt $maxProbes) { $NumProbes = $maxProbes }
    $spacing = [math]::Max(1.0, $usableDur / $NumProbes)

    $probeStarts = [System.Collections.Generic.List[double]]::new()
    $specParts = [System.Collections.Generic.List[string]]::new()
    $pos = $ExclusionSeconds
    for ($i = 0; $i -lt $NumProbes; $i++) {
        $probeStarts.Add($pos)
        # InvariantCulture, not the `-f` operator's default (current-
        # thread) culture -- team review, 2026-08-07, confirmed by direct
        # test: under a comma-decimal locale (e.g. de-DE), `-f` formats
        # 180.123 as "180,123", producing an invalid ffprobe
        # -read_intervals spec and silently breaking complexity sampling
        # (and therefore source-traits detection) on any such machine.
        $posStr = $pos.ToString('F3', [System.Globalization.CultureInfo]::InvariantCulture)
        $specParts.Add("${posStr}%+${ProbeWidth}")
        $pos += $spacing
    }
    $spec = $specParts -join ','
    if (-not $spec) { return $null }

    $result = Invoke-VesWithTimeoutRetry -FilePath $FfprobePath -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-read_intervals', $spec,
        '-show_entries', 'packet=pts_time,size', '-of', 'csv=p=0', $Source
    ) -TimeoutSeconds $TimeoutSeconds -MaxRetries 1
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or -not $result.StdOut) { return $null }

    # Sum packet sizes into whichever probe window each packet's pts falls
    # into (first match wins, windows never overlap by construction).
    $sums = [double[]]::new($probeStarts.Count)
    $seen = [bool[]]::new($probeStarts.Count)
    foreach ($line in ($result.StdOut -split "`n")) {
        $parts = $line.Trim() -split ','
        if ($parts.Count -lt 2) { continue }
        $t = 0.0; $sz = 0.0
        # InvariantCulture (team review, 2026-08-07): TryParse's default
        # single-arg overload uses the current-thread culture, confirmed
        # by direct test to silently mis-parse "180.123" as 180123 under
        # a comma-decimal locale (period read as a thousands separator,
        # not a failure -- worse than an error, a wrong value) --
        # ffprobe's own output is always period-decimal regardless of
        # locale.
        if (-not [double]::TryParse($parts[0], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$t)) { continue }
        if (-not [double]::TryParse($parts[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$sz)) { continue }
        for ($k = 0; $k -lt $probeStarts.Count; $k++) {
            if ($t -ge $probeStarts[$k] -and $t -lt ($probeStarts[$k] + $ProbeWidth)) {
                $sums[$k] += $sz
                $seen[$k] = $true
                break
            }
        }
    }

    $order = for ($k = 0; $k -lt $probeStarts.Count; $k++) { if ($seen[$k]) { $k } }
    $order = @($order)
    if ($order.Count -eq 0) { return $null }

    $sortedVals = @($order | ForEach-Object { $sums[$_] } | Sort-Object)
    $medVal = $sortedVals[[int]($sortedVals.Count / 2)]

    $lowK = $order[0]; $lowV = $sums[$lowK]
    $highK = $order[0]; $highV = $sums[$highK]
    $bestMedK = $order[0]; $bestMedDiff = [math]::Abs($sums[$order[0]] - $medVal)
    foreach ($k in $order) {
        $v = $sums[$k]
        if ($v -lt $lowV) { $lowV = $v; $lowK = $k }
        if ($v -gt $highV) { $highV = $v; $highK = $k }
        $d = [math]::Abs($v - $medVal)
        if ($d -lt $bestMedDiff) { $bestMedDiff = $d; $bestMedK = $k }
    }
    return @($probeStarts[$lowK], $probeStarts[$bestMedK], $probeStarts[$highK])
}

function Invoke-VesIdetProbeWindow {
    <#
    .SYNOPSIS
    Port of _idet_probe_window(). Runs the idet filter over one sample
    window and returns progressive/interlaced/repeat-field/TFF/BFF
    counts, or $null on failure (unreadable window, no idet output).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [int]$TimeoutSeconds = 60
    )
    $result = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
        '-y', '-loglevel', 'info', '-nostdin', '-ss', "$Start", '-t', "$Width",
        '-i', $Source, '-vf', 'idet', '-f', 'null', '-'
    ) -TimeoutSeconds $TimeoutSeconds -MaxRetries 1
    # idet's summary lines print at -loglevel info, to stderr (matches
    # bash's ffmpeg CLI behavior -- this is not a Windows-specific quirk).
    $out = $result.StdErr
    if (-not $out) { return $null }

    $multiLine = ($out -split "`n" | Where-Object { $_ -match 'Multi frame detection:' } | Select-Object -Last 1)
    if (-not $multiLine) { return $null }
    $prog = $null; $tff = 0; $bff = 0
    if ($multiLine -match 'Progressive:\s*(\d+)') { $prog = [int]$Matches[1] } else { return $null }
    if ($multiLine -match 'TFF:\s*(\d+)') { $tff = [int]$Matches[1] }
    if ($multiLine -match 'BFF:\s*(\d+)') { $bff = [int]$Matches[1] }

    $repeatLine = ($out -split "`n" | Where-Object { $_ -match 'Repeated Fields:' } | Select-Object -Last 1)
    $rn = 0; $rt = 0; $rb = 0
    if ($repeatLine -match 'Neither:\s*(\d+)') { $rn = [int]$Matches[1] }
    if ($repeatLine -match 'Top:\s*(\d+)') { $rt = [int]$Matches[1] }
    if ($repeatLine -match 'Bottom:\s*(\d+)') { $rb = [int]$Matches[1] }

    return [PSCustomObject]@{
        Progressive = $prog
        Interlaced  = $tff + $bff
        RepeatNeither = $rn
        RepeatTop     = $rt
        RepeatBottom  = $rb
        Tff = $tff
        Bff = $bff
    }
}

function Invoke-VesSignalstatsProbeWindow {
    <#
    .SYNOPSIS
    Port of _signalstats_probe_window(). Returns the window's mean
    SATAVG (average saturation), or $null on failure. Uses
    metadata=print (raw per-frame tags to stdout) rather than the
    ffprobe movie-filter route, same reasoning as bash: avoids fragile
    manual escaping of colons/parens in real media paths.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [int]$TimeoutSeconds = 60
    )
    $result = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList @(
        '-y', '-v', 'error', '-nostdin', '-ss', "$Start", '-t', "$Width",
        '-i', $Source, '-vf', 'signalstats,metadata=print:file=-', '-f', 'null', '-'
    ) -TimeoutSeconds $TimeoutSeconds -MaxRetries 1
    if (-not $result.StdOut) { return $null }

    $vals = [System.Collections.Generic.List[double]]::new()
    foreach ($m in [regex]::Matches($result.StdOut, 'lavfi\.signalstats\.SATAVG=([0-9.]+)')) {
        $v = 0.0
        if ([double]::TryParse($m.Groups[1].Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $vals.Add($v) }
    }
    if ($vals.Count -eq 0) { return $null }
    return ($vals | Measure-Object -Average).Average
}

function Get-VesSourceTraits {
    <#
    .SYNOPSIS
    Port of detect_source_traits(). Detects field mode (progressive/
    telecine/interlaced/ambiguous), black-and-white status, and
    dominant field order for $Source, caches the result, and returns
    it. Safe to call repeatedly (cache hit after the first call).
    Read-only (ffmpeg -f null probing only) -- safe to call under
    -DryRun.

    .OUTPUTS
    [PSCustomObject]@{ FieldMode; IsBw; FieldOrder }
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    if ($script:SourceTraitsCache.ContainsKey($Source)) {
        return $script:SourceTraitsCache[$Source]
    }

    $dur = Get-VesMediaDurationSeconds -Path $Source -FfprobePath $FfprobePath
    $starts = $null
    if ($dur -and $dur -gt 0) {
        $starts = Get-VesComplexitySamplePoints -Source $Source -Duration $dur -FfprobePath $FfprobePath
    }
    if (-not $starts) {
        # sample_start_middle() equivalent: one probe at the file's
        # midpoint rather than nothing at all.
        $durOrZero = if ($dur) { $dur } else { 0 }
        $starts = @( [math]::Max(0, $durOrZero / 2) )
    }

    $width = $script:SourceTraitsProbeWidthSecs
    $progRatios = [System.Collections.Generic.List[double]]::new()
    $interlaceRatios = [System.Collections.Generic.List[double]]::new()
    $repeatRatios = [System.Collections.Generic.List[double]]::new()
    $satavgs = [System.Collections.Generic.List[double]]::new()
    $tffTotal = 0; $bffTotal = 0; $nWindows = 0

    foreach ($start in $starts) {
        $idet = Invoke-VesIdetProbeWindow -Source $Source -Start $start -Width $width -FfmpegPath $FfmpegPath
        if (-not $idet) { continue }
        $total = $idet.Progressive + $idet.Interlaced
        if ($total -le 0) { continue }
        $repeat = $idet.RepeatTop + $idet.RepeatBottom
        $repeatTotal = $idet.RepeatNeither + $idet.RepeatTop + $idet.RepeatBottom
        if ($repeatTotal -le 0) { $repeatTotal = $total }
        $progRatios.Add($idet.Progressive / $total)
        $interlaceRatios.Add($idet.Interlaced / $total)
        $repeatRatios.Add($repeat / $repeatTotal)
        $tffTotal += $idet.Tff
        $bffTotal += $idet.Bff

        $sat = Invoke-VesSignalstatsProbeWindow -Source $Source -Start $start -Width $width -FfmpegPath $FfmpegPath
        if ($null -ne $sat) { $satavgs.Add($sat) }

        $nWindows++
    }

    if ($nWindows -eq 0) {
        Write-Warning "Source traits: no usable probe windows for $Source -- treating as ambiguous"
        $result = [PSCustomObject]@{ FieldMode = 'ambiguous'; IsBw = $false; FieldOrder = 'tff' }
        $script:SourceTraitsCache[$Source] = $result
        return $result
    }

    $avgProg = ($progRatios | Measure-Object -Average).Average
    $avgInterlace = ($interlaceRatios | Measure-Object -Average).Average
    $avgRepeat = ($repeatRatios | Measure-Object -Average).Average
    $minProg = ($progRatios | Measure-Object -Minimum).Minimum
    $maxProg = ($progRatios | Measure-Object -Maximum).Maximum
    $spread = [math]::Abs($maxProg - $minProg)

    $fieldMode = 'ambiguous'
    if ($avgProg -ge $script:SourceTraitsProgressiveMin) {
        $fieldMode = 'progressive'
    } elseif ($avgRepeat -ge $script:SourceTraitsTelecineRepeatMin -and $avgRepeat -le $script:SourceTraitsTelecineRepeatMax -and $spread -le $script:SourceTraitsWindowSpreadMax) {
        $fieldMode = 'telecine'
    } elseif ($avgInterlace -ge $script:SourceTraitsInterlaceMin -and $spread -le $script:SourceTraitsWindowSpreadMax) {
        $fieldMode = 'interlaced'
    }

    $isBw = $false
    if ($satavgs.Count -gt 0) {
        $avgSat = ($satavgs | Measure-Object -Average).Average
        if ($avgSat -le $script:SourceTraitsBwSatavgMax) { $isBw = $true }
    }

    $fieldOrder = if ($bffTotal -gt $tffTotal) { 'bff' } else { 'tff' }

    $result = [PSCustomObject]@{ FieldMode = $fieldMode; IsBw = $isBw; FieldOrder = $fieldOrder }
    $script:SourceTraitsCache[$Source] = $result
    Write-Host "Source traits: $Source -> field_mode=$fieldMode (avg_prog=$('{0:F4}' -f $avgProg) avg_interlace=$('{0:F4}' -f $avgInterlace) avg_repeat=$('{0:F4}' -f $avgRepeat) window_spread=$('{0:F4}' -f $spread) windows=$nWindows field_order=$fieldOrder tff=$tffTotal bff=$bffTotal) is_bw=$([int]$isBw)"

    return $result
}

Export-ModuleMember -Function Get-VesComplexitySamplePoints, Invoke-VesIdetProbeWindow, Invoke-VesSignalstatsProbeWindow, Get-VesSourceTraits, Get-VesDtsDeltaCv, Get-VesOutputFrameDuplication, Get-VesSourceFrameRateMode, Get-VesSourceBaselineVmaf
