# Windows port of convert-v5.0.33S.sh's season-retry shrink heuristic
# (season_retry_pass(), season_retry_key(), season_number_from_filename(),
# lines ~4212-4234, ~14766-14814).
#
# SCOPE, per explicit user decision (2026-08-03): tracking/retry logic
# only. Bash only ever triggers this for a file a cheap predictive
# sample-test decided wouldn't shrink (skip reason "re-encode sample
# predicts no size win") -- that predictive sample-test mechanism is NOT
# ported to Windows yet (convert.ps1 always goes straight to VMAF search
# + full encode, no cheap pre-check). This module is therefore reachable
# only via direct calls from tests right now, not from any real code
# path in convert.ps1 -- see the TODO below at the intended future call
# site. This is a deliberate, documented gap, not bit-rot by accident:
# flagged during team review as a real risk for a module with no live
# caller (silent divergence from bash as encode routing/skip reasons
# change later), mitigated by keeping this module's own tests narrow
# and direct (calling Add-VesSeasonSampleResult/
# Add-VesSeasonNoShrinkPrediction/Invoke-VesSeasonRetryPass directly with
# synthetic data) rather than pretending it's integration-tested through
# a real encode run it can't actually reach yet.

$script:SeasonSampleTestedCount = @{}
$script:SeasonShrinkCount = @{}
$script:SeasonNoShrinkFiles = @{}
$script:SeasonRetryInProgress = $false

function Get-VesSeasonNumberFromFilename {
    <#
    .SYNOPSIS
    Port of season_number_from_filename(). Returns a zero-padded 2-digit
    season number, or '_unknown' if the filename has no S##E## marker.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($stem -match '[Ss](\d{1,2})[\s_.\-]*[Ee]\d{1,3}') {
        return '{0:D2}' -f [int]$Matches[1]
    }
    return '_unknown'
}

function Get-VesSeasonRetryKey {
    <#
    .SYNOPSIS
    Port of season_retry_key(): "<parent-dir>|<season-number>" so one
    show's season shrink-rate can never bleed into a different show's
    same-numbered season. A literal "|" is a safe, unambiguous delimiter
    on Windows (invalid in a real path component), unlike bash's need
    for a unit-separator character since "|" IS a valid Unix filename
    character there.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Parent $Path
    $season = Get-VesSeasonNumberFromFilename -Path $Path
    return "$parent|$season"
}

function Add-VesSeasonSampleResult {
    <#
    .SYNOPSIS
    Port of the bookkeeping bash does inside record_conversion_result()
    for a genuine sample-test-driven encode attempt (KEPT or KEPT-larger
    branches). -Shrank $true increments both tested and shrink counts;
    -Shrank $false increments only tested.

    # TODO(season-retry-integration): call this from convert.ps1's
    # per-file loop once a cheap predictive sample-test mechanism is
    # ported and this port has a real "sample-test-driven encode result"
    # moment to hook into -- not reachable from any real code path yet.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Shrank
    )
    if ($script:SeasonRetryInProgress) { return }
    $key = Get-VesSeasonRetryKey -Path $Path
    $script:SeasonSampleTestedCount[$key] = ($script:SeasonSampleTestedCount[$key] ?? 0) + 1
    if ($Shrank) {
        $script:SeasonShrinkCount[$key] = ($script:SeasonShrinkCount[$key] ?? 0) + 1
    }
}

function Add-VesSeasonNoShrinkPrediction {
    <#
    .SYNOPSIS
    Port of the bookkeeping bash does inside record_skip() specifically
    for the "re-encode sample predicts no size win" skip reason.

    # TODO(season-retry-integration): call this from wherever this port
    # eventually implements that same predictive skip reason -- not
    # reachable from any real code path yet, see this module's header.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($script:SeasonRetryInProgress) { return }
    $key = Get-VesSeasonRetryKey -Path $Path
    $script:SeasonSampleTestedCount[$key] = ($script:SeasonSampleTestedCount[$key] ?? 0) + 1
    if (-not $script:SeasonNoShrinkFiles.ContainsKey($key)) {
        $script:SeasonNoShrinkFiles[$key] = New-Object System.Collections.Generic.List[string]
    }
    $script:SeasonNoShrinkFiles[$key].Add($Path)
}

function Reset-VesSeasonRetryState {
    <#
    .SYNOPSIS
    Clears all tracked state -- call once per run (matches bash's fresh
    associative arrays per script invocation), and useful for isolating
    tests from each other.
    #>
    $script:SeasonSampleTestedCount = @{}
    $script:SeasonShrinkCount = @{}
    $script:SeasonNoShrinkFiles = @{}
    $script:SeasonRetryInProgress = $false
}

function Invoke-VesSeasonRetryPass {
    <#
    .SYNOPSIS
    Port of season_retry_pass(): for each show-folder+season key with at
    least one sample-rejected episode, if shrink/tested*100 >=
    $ThresholdPct (default 60, matching bash's default), force-retries
    every such file through the real encode path -- codec-routed (AV1
    source -> AV1 retry, else x265 retry with force-transcode). Never
    re-tags on failure -- a non-zero result can be a transient failure,
    not a confirmed size loss, matching bash's own stated reasoning and
    this project's "ambiguous is not confirmed" invariant.

    .PARAMETER EncodeAv1
    Scriptblock taking a source path, returning $true/$false -- the
    caller's real AV1 retry encode function.

    .PARAMETER EncodeX265ForceTranscode
    Scriptblock taking a source path, returning $true/$false -- the
    caller's real x265 force-transcode retry encode function.

    .PARAMETER GetVideoCodec
    Scriptblock taking a source path, returning a codec string (e.g.
    'av1', 'hevc') -- used to route each retry.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$EncodeAv1,
        [Parameter(Mandatory)][scriptblock]$EncodeX265ForceTranscode,
        [Parameter(Mandatory)][scriptblock]$GetVideoCodec,
        [int]$ThresholdPct = 60
    )
    $results = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($key in @($script:SeasonSampleTestedCount.Keys)) {
        $tested = $script:SeasonSampleTestedCount[$key]
        $shrink = $script:SeasonShrinkCount[$key] ?? 0
        if ($tested -le 0) { continue }
        if (-not $script:SeasonNoShrinkFiles.ContainsKey($key)) { continue }
        $noShrinkFiles = $script:SeasonNoShrinkFiles[$key]
        if ($noShrinkFiles.Count -eq 0) { continue }

        $pct = ($shrink / $tested) * 100
        if ($pct -lt $ThresholdPct) { continue }

        $parts = $key -split '\|', 2
        Write-Host "Season $($parts[1]) ($($parts[0])): $shrink/$tested sample-tested episodes shrank (>=$ThresholdPct%) -- retrying $($noShrinkFiles.Count) episode(s) the sample predicted wouldn't shrink"

        $script:SeasonRetryInProgress = $true
        try {
            foreach ($file in $noShrinkFiles) {
                if (-not (Test-Path -LiteralPath $file)) { continue }
                $codec = & $GetVideoCodec $file
                $ok = if ($codec -eq 'av1') { & $EncodeAv1 $file } else { & $EncodeX265ForceTranscode $file }
                if (-not $ok) {
                    Write-Host "Season heuristic retry did not produce a smaller file (or hit an unrelated failure) -- leaving prior tag/state in place: $file"
                }
                $results.Add([PSCustomObject]@{ Path = $file; Retried = $true; Success = [bool]$ok })
            }
        } finally {
            $script:SeasonRetryInProgress = $false
        }
    }
    return , $results
}

function Get-VesSeasonRetryTestedCount {
    <#
    .SYNOPSIS
    Read-only accessor for this module's private tracking state --
    exists for test verification, not part of the real retry-pass flow.
    #>
    param([Parameter(Mandatory)][string]$Key)
    return $script:SeasonSampleTestedCount[$Key] ?? 0
}

Export-ModuleMember -Function Get-VesSeasonNumberFromFilename, Get-VesSeasonRetryKey, `
    Add-VesSeasonSampleResult, Add-VesSeasonNoShrinkPrediction, Reset-VesSeasonRetryState, `
    Invoke-VesSeasonRetryPass, Get-VesSeasonRetryTestedCount
