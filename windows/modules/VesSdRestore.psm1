# Windows port of modules/ves-sd-restore.sh -- the SD "facelift"
# restoration pre-processor (v6.0.1O).
#
# PARITY STATUS: analysis telemetry + gate only. The full restore path
# (IVTC / QTGMC intermediate + optional deblock + video_src substitution)
# is deferred on Windows -- the Linux fleet runs the D-val survey and the
# degraded-SD titles, and the restore path shares the QTGMC toolchain which
# is already Linux-first here. When a Windows node needs it, port
# sd_restore_to_intermediate() against Invoke-VesQtgmcDeinterlace (already
# in VesQtgmc.psm1) + an ffmpeg fieldmatch,decimate path, following the
# bash module 1:1.
#
# Keep every default and threshold identical to modules/ves-config.sh's
# RESTORE_SD_* block (env-overridable).

function Get-VesSdRestoreConfig {
    [pscustomobject]@{
        Enable        = ($env:RESTORE_SD_ENABLE       -eq 'true')
        Experimental  = ($env:RESTORE_SD_EXPERIMENTAL -eq 'true')
        Deblock       = ($env:RESTORE_SD_DEBLOCK      ? $env:RESTORE_SD_DEBLOCK : 'off')
        MaxHeight     = [int]($env:RESTORE_SD_MAX_HEIGHT ? $env:RESTORE_SD_MAX_HEIGHT : 576)
        BpppfMax      = [double]($env:RESTORE_SD_BPPPF_MAX ? $env:RESTORE_SD_BPPPF_MAX : 0.065)
        CombMin       = [double]($env:RESTORE_SD_COMB_MIN  ? $env:RESTORE_SD_COMB_MIN  : 0.05)
        Windows       = [int]($env:RESTORE_SD_ANALYZE_WINDOWS ? $env:RESTORE_SD_ANALYZE_WINDOWS : 3)
        WindowSecs    = [int]($env:RESTORE_SD_ANALYZE_SECS    ? $env:RESTORE_SD_ANALYZE_SECS    : 12)
        Profiles      = (($env:RESTORE_SD_PROFILES ? $env:RESTORE_SD_PROFILES : 'vintage vtv standup concert canime wanime') -split '\s+')
    }
}

$script:VesSdRestoreMustElimExt = @('ts','m2ts','vob','avi','ogm','mpg','mpeg','m2v','rm','rmvb','divx','wmv','flv','asf')
$script:VesSdRestoreMustElimCodec = @('mpeg4','msmpeg4v1','msmpeg4v2','msmpeg4v3','rv10','rv20','rv30','rv40','wmv1','wmv2','wmv3','vc1')

function Get-VesSdRestoreMarkerPath {
    param([Parameter(Mandatory)][string]$Source)
    Join-Path (Split-Path -Parent $Source) '.ves-sd-restore'
}

function Get-VesSdRestoreCombRatio {
    # idet combed-frame ratio over N short windows. Mirrors _sdr_comb_ratio.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [int]$Windows = 3,
        [int]$WindowSecs = 12,
        [double]$DurationSec = 0
    )
    if ($DurationSec -le 0) { return 0.0 }
    $interlaced = 0; $total = 0
    for ($i = 1; $i -le $Windows; $i++) {
        $start = [int]($DurationSec * $i / ($Windows + 1))
        $out = & $FfmpegPath -hide_banner -nostats -ss $start -t $WindowSecs -i $Source -vf idet -an -f null - 2>&1 |
               Select-String 'Multi frame detection' | Select-Object -Last 1
        if (-not $out) { continue }
        $line = $out.ToString()
        $tff = if ($line -match 'TFF:\s*(\d+)') { [int]$Matches[1] } else { 0 }
        $bff = if ($line -match 'BFF:\s*(\d+)') { [int]$Matches[1] } else { 0 }
        $prog = if ($line -match 'Progressive:\s*(\d+)') { [int]$Matches[1] } else { 0 }
        $undet = if ($line -match 'Undetermined:\s*(\d+)') { [int]$Matches[1] } else { 0 }
        $interlaced += ($tff + $bff)
        $total += ($tff + $bff + $prog + $undet)
    }
    if ($total -le 0) { return 0.0 }
    [math]::Round($interlaced / $total, 3)
}

function Invoke-VesSdRestoreAnalyze {
    <#
      .SYNOPSIS
      Port of sd_restore_analyze(). Read-only telemetry. Returns a
      [pscustomobject] with Verdict (restore|skip|forced), Class, Width,
      Height, Bpppf, Comb, MustElim, Reason -- and logs one line.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [string]$Profile = '',
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$FieldClass = 'ambiguous',
        [double]$DurationSec = 0
    )
    $cfg = Get-VesSdRestoreConfig

    $streamJson = & $FfprobePath -v error -select_streams v:0 `
        -show_entries stream=width,height,codec_name,avg_frame_rate,bit_rate `
        -show_entries format=bit_rate -of json $Source 2>$null | ConvertFrom-Json
    $st = $streamJson.streams[0]
    $w = [int]$st.width; $h = [int]$st.height
    $codec = ("$($st.codec_name)").ToLower()
    $fps = 0.0
    if ("$($st.avg_frame_rate)" -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -gt 0) {
        $fps = [double]$Matches[1] / [double]$Matches[2]
    }
    $br = 0
    if ($st.bit_rate -as [int]) { $br = [int]$st.bit_rate }
    elseif ($streamJson.format.bit_rate -as [int]) { $br = [int]$streamJson.format.bit_rate }
    $bpppf = if ($w -gt 0 -and $h -gt 0 -and $fps -gt 0 -and $br -gt 0) {
        [math]::Round($br / ($w * $h * $fps), 8)
    } else { 0 }

    $ext = ($Source -replace '.*\.', '').ToLower()
    $mustElim = ($script:VesSdRestoreMustElimExt -contains $ext) -or `
                ($script:VesSdRestoreMustElimCodec -contains $codec)

    $comb = Get-VesSdRestoreCombRatio -Source $Source -FfmpegPath $FfmpegPath `
        -Windows $cfg.Windows -WindowSecs $cfg.WindowSecs -DurationSec $DurationSec

    $class = if ($FieldClass) { $FieldClass } else { 'ambiguous' }

    $sdCandidate = $mustElim -or ($h -gt 0 -and $h -le $cfg.MaxHeight -and $bpppf -gt 0 -and $bpppf -lt $cfg.BpppfMax)
    $metricTrigger = ($comb -ge $cfg.CombMin) -or ($class -in @('telecine','interlaced'))

    $marker = Get-VesSdRestoreMarkerPath -Source $Source
    $verdict = 'skip'; $reason = "not an SD/legacy candidate (h=$h bpppf=$bpppf)"
    if ((Test-Path $marker) -and ((Get-Content $marker -First 1 -ErrorAction SilentlyContinue) -match '^force')) {
        $verdict = 'forced'; $reason = 'per-title marker'
    } elseif ($sdCandidate -and $metricTrigger) {
        $verdict = 'restore'; $reason = "sd_candidate + metric_trigger (class=$class comb=$comb bpppf=$bpppf)"
    } elseif ($sdCandidate) {
        $verdict = 'skip'; $reason = 'SD/legacy but no metric trigger (looks clean)'
    }

    Write-Host "sd-restore: analyze $([IO.Path]::GetFileName($Source)) -> verdict=$verdict class=$class w=$w h=$h bpppf=$bpppf comb=$comb mustelim=$([int][bool]$mustElim) reason=`"$reason`""

    [pscustomobject]@{
        Verdict = $verdict; Class = $class; Width = $w; Height = $h
        Bpppf = $bpppf; Comb = $comb; MustElim = [bool]$mustElim; Reason = $reason
    }
}

function Test-VesSdRestoreShouldRestore {
    <# Port of sd_restore_should_restore(). #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [string]$Profile = '',
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$FieldClass = 'ambiguous',
        [double]$DurationSec = 0
    )
    $cfg = Get-VesSdRestoreConfig
    $marker = Get-VesSdRestoreMarkerPath -Source $Source
    $forced = (Test-Path $marker) -and ((Get-Content $marker -First 1 -ErrorAction SilentlyContinue) -match '^force')
    if (-not $cfg.Enable -and -not $forced) { return $false }
    if ($Profile -and ($cfg.Profiles -notcontains $Profile)) { return $false }

    $a = Invoke-VesSdRestoreAnalyze -Source $Source -Profile $Profile -FfmpegPath $FfmpegPath `
        -FfprobePath $FfprobePath -FieldClass $FieldClass -DurationSec $DurationSec
    return ($a.Verdict -in @('restore','forced'))
}

function Invoke-VesSdRestoreToIntermediate {
    <#
      .SYNOPSIS
      NOT YET PORTED. Returns $null so callers fall back to a normal encode.
      Port against Invoke-VesQtgmcDeinterlace + an ffmpeg fieldmatch,decimate
      path when a Windows node needs the restore path.
    #>
    param([Parameter(Mandatory)][string]$Source, [string]$Profile = '')
    Write-Warning "sd-restore: Invoke-VesSdRestoreToIntermediate not ported on Windows -- normal encode for: $Source"
    return $null
}

Export-ModuleMember -Function Get-VesSdRestoreConfig, Get-VesSdRestoreMarkerPath, `
    Get-VesSdRestoreCombRatio, Invoke-VesSdRestoreAnalyze, Test-VesSdRestoreShouldRestore, `
    Invoke-VesSdRestoreToIntermediate
