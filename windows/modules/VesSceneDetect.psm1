# Windows port of modules/ves-scene-detect.sh -- Phase 5 shot-cut detection
# on the source (ffmpeg select=gt(scene,THRESHOLD)+showinfo). Prerequisite
# for Phase 6 per-shot QP search. See the bash module header for why this
# is deliberately distinct from SVT-AV1's own scd=1 (encode-time keyframe
# placement) -- not repeated here.
#
# Cost: a full sequential decode of the source. Same contract as bash:
# run once per title (result belongs on the shot/chunk manifest), never
# per-encoder.

function Get-VesSceneBoundaries {
    <#
    .SYNOPSIS
    Port of scene_detect_boundaries(). Returns real shot-cut timestamps
    (seconds, strictly increasing) for $Source. Does NOT include 0 or the
    file's end -- callers that need those add them. Threshold defaults to
    $env:SCENE_DETECT_THRESHOLD or 0.3 (ffmpeg's commonly-documented
    default for this exact select=gt(scene,...) use).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [double]$Threshold
    )
    if (-not $PSBoundParameters.ContainsKey('Threshold')) {
        $Threshold = if ($env:SCENE_DETECT_THRESHOLD) {
            [double]$env:SCENE_DETECT_THRESHOLD
        } else {
            0.3
        }
    }

    # showinfo logs at AV_LOG_INFO -- -v error would silently suppress every
    # line this function needs; must stay at (or above) info level. Matches
    # bash exactly.
    $threshStr = $Threshold.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegPath
    foreach ($a in @(
            '-nostdin', '-v', 'info', '-nostats', '-i', $Source,
            '-vf', "select='gt(scene,$threshStr)',showinfo",
            '-an', '-sn', '-f', 'null', '-'
        )) {
        $psi.ArgumentList.Add($a)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $stderr = ''
    try {
        $proc.Start() | Out-Null
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        $stderr = $stderrTask.Result
        $null = $stdoutTask.Result
    } finally {
        $proc.Dispose()
    }

    $bounds = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($stderr, 'pts_time:([0-9]+(?:\.[0-9]+)?)')) {
        $bounds.Add($m.Groups[1].Value)
    }
    return @($bounds)
}

Export-ModuleMember -Function Get-VesSceneBoundaries
