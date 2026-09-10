# Windows port of modules/ves-scene-detect.sh -- Phase 5 shot-cut detection
# on the source (ffmpeg select=gt(scene,THRESHOLD)+showinfo). Prerequisite
# for Phase 6 per-shot QP search. See the bash module header for why this
# is deliberately distinct from SVT-AV1's own scd=1 (encode-time keyframe
# placement) -- not repeated here.
#
# Cost: a full sequential decode of the source. Same contract as bash:
# run once per title (result belongs on the shot/chunk manifest), never
# per-encoder.
#
# 2026-09-02 Phase 1 port: optional per-shot complexity fan-out on the SAME
# single decode (signalstats + entropy branch) -> Get-VesShotComplexityTable
# / Get-VesShotLongWindows, consumed by New-VesShotManifest for cx_* fields,
# the zero-signal fast-path, and content-driven multi-window placement.

function Get-VesSceneBoundaries {
    <#
    .SYNOPSIS
    Port of scene_detect_boundaries(). Returns real shot-cut timestamps
    (seconds, strictly increasing) for $Source. Does NOT include 0 or the
    file's end -- callers that need those add them. Threshold defaults to
    $env:SCENE_DETECT_THRESHOLD or 0.3.

    When -StatsOut is a writable path AND SHOT_COMPLEXITY_ENABLE is not
    "false", the SAME decode also fans the stream to a
    signalstats+entropy branch (sampled at SHOT_COMPLEXITY_FPS) whose
    per-frame lavfi.* metadata is written to that path -- the raw material
    for Get-VesShotComplexityTable. Additive: no path / flag false = the
    exact original behaviour and cost.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [double]$Threshold,
        [string]$StatsOut
    )
    if (-not $PSBoundParameters.ContainsKey('Threshold')) {
        $Threshold = if ($env:SCENE_DETECT_THRESHOLD) { [double]$env:SCENE_DETECT_THRESHOLD } else { 0.3 }
    }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $threshStr = $Threshold.ToString($inv)

    # [sc] filter body -- MUST match _scene_detect_filter() in
    # modules/ves-scene-detect.sh. The fleet default is the newer `scdet` filter
    # (more robust than select='gt(scene,X)' on low-contrast / anime masters);
    # the legacy 0-1 threshold maps onto scdet's 0-100 scale (0.3 -> ~10, a
    # low-contrast 0.12 -> ~4). SCENE_DETECT_METHOD=scene forces the old path.
    # (Before this the port always used select=scene -> ~7% different shot
    # boundaries vs the bash manifest; 2026-09-08.)
    $sceneMethod = if ($env:SCENE_DETECT_METHOD) { $env:SCENE_DETECT_METHOD } else { 'scdet' }
    if ($sceneMethod -eq 'scene') {
        $scFilter = "select='gt(scene,$threshStr)',showinfo"
    } else {
        $st = $Threshold * 33.3
        if ($st -lt 1)   { $st = 1 }
        if ($st -gt 100) { $st = 100 }
        $scFilter = "scdet=threshold=$(($st).ToString('0.0', $inv)):sc_pass=1,showinfo"
    }

    $wantStats = $StatsOut -and ($env:SHOT_COMPLEXITY_ENABLE -ne 'false')
    if ($wantStats) {
        try { Set-Content -LiteralPath $StatsOut -Value '' -NoNewline -ErrorAction Stop } catch { $wantStats = $false }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegPath
    $argv = @()
    if ($wantStats) {
        $fps = if ($env:SHOT_COMPLEXITY_FPS) { [int]$env:SHOT_COMPLEXITY_FPS } else { 4 }
        # metadata=print:file= must be a BARE filename with the process CWD set
        # to its directory -- a Windows drive-letter path (C:\... or C:/...)
        # breaks ffmpeg's ':'-delimited filter-option parser (same fix as
        # VesVmafCrfSearch.psm1's libvmaf log_path, 2026-08-05).
        $statsName = Split-Path -Leaf $StatsOut
        $psi.WorkingDirectory = Split-Path -Parent $StatsOut
        $fc = "[0:v]split=2[sc][st];" +
              "[sc]$scFilter[cuts];" +
              "[st]fps=$fps,signalstats,entropy=mode=normal,metadata=print:file=$statsName,nullsink"
        $argv = @('-nostdin', '-v', 'info', '-nostats', '-i', $Source,
                  '-filter_complex', $fc, '-map', '[cuts]', '-an', '-sn', '-f', 'null', '-')
    } else {
        $argv = @('-nostdin', '-v', 'info', '-nostats', '-i', $Source,
                  '-vf', $scFilter, '-an', '-sn', '-f', 'null', '-')
    }
    foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
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

function Get-VesShotComplexityTable {
    <#
    .SYNOPSIS
    Port of _shot_complexity_table(). Aggregates a Get-VesSceneBoundaries
    stats file into per-shot complexity. $Boundaries = the cut timestamps
    (NOT 0 or EOF). Returns a hashtable idx -> @{ Luma; Motion; Detail; Sat }.
    A shot with fewer than 2 sampled frames gets NO entry (absent cx_* =>
    the shot is searched normally -- never a false zero-signal).
    #>
    param(
        [Parameter(Mandatory)][string]$StatsFile,
        [Parameter(Mandatory)][string[]]$Boundaries
    )
    $out = @{}
    if (-not (Test-Path -LiteralPath $StatsFile)) { return $out }
    $B = @($Boundaries | Where-Object { $_ -match '^[0-9]' } | ForEach-Object { [double]$_ } | Sort-Object)
    $nb = $B.Count

    $SL = @{}; $SM = @{}; $SD = @{}; $SS = @{}; $SC = @{}
    $t = -1.0; $yavg = $null; $ydif = $null; $ent = $null; $sat = $null; $have = $false

    $attribute = {
        $s = 0
        while ($s -lt $nb -and $t -ge $B[$s]) { $s++ }
        if ($null -ne $yavg) { $SL[$s] = ($SL[$s] + $yavg) }
        if ($null -ne $ydif) { $SM[$s] = ($SM[$s] + $ydif) }
        if ($null -ne $ent)  { $SD[$s] = ($SD[$s] + $ent) }
        if ($null -ne $sat)  { $SS[$s] = ($SS[$s] + $sat) }
        $SC[$s] = ($SC[$s] + 1)
    }

    foreach ($line in [System.IO.File]::ReadLines($StatsFile)) {
        if ($line.StartsWith('frame:')) {
            if ($have) { & $attribute }
            $have = $true; $t = -1.0; $yavg = $null; $ydif = $null; $ent = $null; $sat = $null
            $mm = [regex]::Match($line, 'pts_time:([0-9.]+)')
            if ($mm.Success) { $t = [double]$mm.Groups[1].Value }
            continue
        }
        if ($line.StartsWith('lavfi.signalstats.YAVG='))   { $yavg = [double]($line.Split('=')[1]); continue }
        if ($line.StartsWith('lavfi.signalstats.YDIF='))   { $ydif = [double]($line.Split('=')[1]); continue }
        if ($line.StartsWith('lavfi.signalstats.SATAVG=')) { $sat  = [double]($line.Split('=')[1]); continue }
        if ($line.StartsWith('lavfi.entropy.entropy.normal.Y=')) { $ent = [double]($line.Split('=')[1]); continue }
    }
    if ($have) { & $attribute }

    for ($s = 0; $s -le $nb; $s++) {
        $c = if ($SC.ContainsKey($s)) { [int]$SC[$s] } else { 0 }
        if ($c -lt 2) { continue }
        $out[$s] = [PSCustomObject]@{
            Luma   = [math]::Round((($SL[$s]) / $c), 2)
            Motion = [math]::Round((($SM[$s]) / $c), 4)
            Detail = [math]::Round((($SD[$s]) / $c), 4)
            Sat    = [math]::Round((($SS[$s]) / $c), 2)
        }
    }
    return $out
}

function Get-VesShotLongWindows {
    <#
    .SYNOPSIS
    Port of _shot_long_windows(). Content-driven placement for a long shot:
    split [Start,End) into N equal segments and put each WinLen-second window
    on that segment's peak inter-frame motion (YDIF); flat segment -> centred.
    Returns "o1,..,oN" (window START offsets, seconds from Start) or $null.
    v6.0.4: N scales with duration -- clamp(round(D/Gap), NMin, NMax) -- was a
    flat 3.
    #>
    param(
        [Parameter(Mandatory)][string]$StatsFile,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][double]$End,
        [double]$WinLen = 12.0,
        [double]$Gap = 0.0,
        [int]$NMin = 0,
        [int]$NMax = 0
    )
    if ($Gap  -le 0) { $Gap  = if ($env:PER_SHOT_MW_GAP_SECS)   { [double]$env:PER_SHOT_MW_GAP_SECS }   else { 18.0 } }
    if ($NMin -le 0) { $NMin = if ($env:PER_SHOT_MW_WINDOWS_MIN) { [int]$env:PER_SHOT_MW_WINDOWS_MIN }  else { 4 } }
    if ($NMax -le 0) { $NMax = if ($env:PER_SHOT_MW_WINDOWS_MAX) { [int]$env:PER_SHOT_MW_WINDOWS_MAX }  else { 12 } }
    if (-not (Test-Path -LiteralPath $StatsFile)) { return $null }
    $T = [System.Collections.Generic.List[double]]::new()
    $Y = [System.Collections.Generic.List[double]]::new()
    $ct = -1.0
    foreach ($line in [System.IO.File]::ReadLines($StatsFile)) {
        if ($line.StartsWith('frame:')) {
            $ct = -1.0
            $mm = [regex]::Match($line, 'pts_time:([0-9.]+)')
            if ($mm.Success) { $ct = [double]$mm.Groups[1].Value }
            continue
        }
        if ($line.StartsWith('lavfi.signalstats.YDIF=')) {
            if ($ct -lt $Start -or $ct -ge $End) { continue }
            $T.Add($ct); $Y.Add([double]($line.Split('=')[1]))
        }
    }
    $n = $T.Count
    $D = $End - $Start
    if ($n -lt 6 -or $D -le ($WinLen * 1.5)) { return $null }
    $NW = [int][math]::Round($D / $Gap)
    if ($NW -lt $NMin) { $NW = $NMin }
    if ($NW -gt $NMax) { $NW = $NMax }
    $maxfit = [int][math]::Floor($D / $WinLen)
    if ($maxfit -ge 1 -and $NW -gt $maxfit) { $NW = $maxfit }
    if ($NW -lt 2) { $NW = 2 }
    $step = ($T[$n - 1] - $T[0]) / [math]::Max(1, ($n - 1))
    if ($step -le 0) { $step = 0.25 }
    $wspan = [int][math]::Round($WinLen / $step)
    if ($wspan -lt 1) { $wspan = 1 }

    $WS = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $s = 0.0; $c = 0
        for ($j = $i; $j -lt $n -and $j -lt ($i + $wspan); $j++) { $s += $Y[$j]; $c++ }
        $WS[$i] = if ($c) { $s / $c } else { 0.0 }
    }

    $offs = @()
    for ($k = 0; $k -lt $NW; $k++) {
        $lo = $Start + $k * $D / $NW
        $hi = $Start + ($k + 1) * $D / $NW
        $centre = ($lo - $Start) + ($D / $NW - $WinLen) / 2.0
        if ($centre -lt 0) { $centre = 0 }
        $best = -1.0; $boff = $centre; $msum = 0.0; $mc = 0
        for ($i = 0; $i -lt $n; $i++) {
            if ($T[$i] -lt $lo -or $T[$i] -ge $hi) { continue }
            if (($T[$i] + $WinLen) -gt $End) { continue }
            $msum += $WS[$i]; $mc++
            if ($WS[$i] -gt $best) { $best = $WS[$i]; $boff = $T[$i] - $Start }
        }
        if ($mc -gt 0 -and $best -le (($msum / $mc) * 1.08)) { $boff = $centre }
        if ($boff -lt 0) { $boff = 0 }
        if (($Start + $boff + $WinLen) -gt $End) { $boff = ($End - $Start) - $WinLen }
        if ($boff -lt 0) { $boff = 0 }
        $offs += ('{0:F2}' -f $boff)
    }
    return ($offs -join ',')
}

Export-ModuleMember -Function Get-VesSceneBoundaries, Get-VesShotComplexityTable, Get-VesShotLongWindows
