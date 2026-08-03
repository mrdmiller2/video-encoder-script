# Windows port of convert-v5.0.33S.sh's subtitle_stream_has_real_content()
# and build_real_subtitle_map_args() (lines ~8794-8902 in the primary script).
#
# This is a deliberate, reasoned-through-fresh port, not a line-by-line
# transliteration -- per ROADMAP.md item 4 ("pipefail-dependent idioms"),
# getting this tri-state logic wrong reintroduces exactly the
# ambiguous-failure-treated-as-confirmed-empty data-loss bug the
# 2026-08-02 team review fixed in the primary script. The invariant that
# must survive translation: a subprocess failure or timeout is NEVER
# treated as proof a subtitle stream is empty. Only a clean run (exit 0)
# with genuinely empty output confirms emptiness; everything else keeps
# the stream.
#
# One deliberate Windows deviation from the bash version: bash's
# `ffprobe ... | head -1` legitimately SIGPIPEs ffprobe (rc 141) once it
# has one line, short-circuiting a full-file scan. Start-Process's
# redirected-file output has no equivalent live-pipe short-circuit, so
# this port always lets ffprobe run to completion and takes the first
# line in PowerShell -- correct, but not the same NAS-scan-avoidance
# optimization. Worth revisiting if full-file subtitle probes prove slow
# on real network shares (tracked, not yet measured).

if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}

$script:StrippedSubtitleLogged = @{}

function Invoke-VesFfprobe {
    param(
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string[]]$ProbeArgs,
        [int]$TimeoutSeconds = 60
    )
    Invoke-VesWithTimeoutRetry -FilePath $FfprobePath -ArgumentList $ProbeArgs -TimeoutSeconds $TimeoutSeconds
}

function Invoke-VesFfmpegValidation {
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string[]]$FfmpegArgs,
        [int]$TimeoutSeconds = 60
    )
    Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath -ArgumentList $FfmpegArgs -TimeoutSeconds $TimeoutSeconds
}

function Test-VesSubtitleStreamHasRealContent {
    <#
    .SYNOPSIS
    Tri-state check: does subtitle stream s:$Index in $Source actually
    contain renderable content? Returns $true (keep) unless the stream
    is CONFIRMED empty via a clean, successful probe.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$FfmpegPath
    )

    # --- Packet-presence probe ---
    $pktArgs = @(
        '-v', 'error', '-select_streams', "s:$Index",
        '-show_entries', 'packet=pts_time', '-of', 'csv=p=0', $Source
    )
    $pktResult = Invoke-VesFfprobe -FfprobePath $FfprobePath -ProbeArgs $pktArgs
    $firstPkt = ($pktResult.StdOut -split "`n" | Where-Object { $_ -ne '' } | Select-Object -First 1)

    if ([string]::IsNullOrEmpty($firstPkt) -and $pktResult.ExitCode -ne 0) {
        Write-Warning "Subtitle stream s:${Index} in ${Source}: packet-presence probe failed/timed out -- keeping rather than risk discarding real content"
        return $true
    }
    if ([string]::IsNullOrEmpty($firstPkt)) {
        # Clean run (exit 0), genuinely no packets -- confirmed empty.
        return $false
    }

    # --- Codec check ---
    $codecArgs = @(
        '-v', 'error', '-select_streams', "s:$Index",
        '-show_entries', 'stream=codec_name', '-of', 'default=nw=1:nk=1', $Source
    )
    $codecResult = Invoke-VesFfprobe -FfprobePath $FfprobePath -ProbeArgs $codecArgs
    $codec = ($codecResult.StdOut | ForEach-Object { $_.Trim() })

    $textCodecs = @('subrip', 'srt', 'ass', 'ssa', 'mov_text', 'webvtt', 'text')
    if ($textCodecs -notcontains $codec) {
        # Bitmap/other subtitle codecs (dvd_subtitle, hdmv_pgs_subtitle, etc.)
        # can't be text-stripped -- packet presence (already confirmed
        # above) is the only reliable signal. Do not treat decode
        # warnings as proof of emptiness (PGS/DVD tracks from physical
        # media routinely produce benign non-fatal warnings).
        return $true
    }

    # --- Text-decode probe ---
    $decodeArgs = @('-v', 'error', '-i', $Source, '-map', "0:s:$Index", '-f', 'srt', '-')
    $decodeResult = Invoke-VesFfmpegValidation -FfmpegPath $FfmpegPath -FfmpegArgs $decodeArgs
    $rawSrt = $decodeResult.StdOut

    # Team-review fix (2026-08-02): checking ExitCode independently of
    # whether $rawSrt is empty, not "empty AND nonzero" -- if ffmpeg
    # crashes/times out AFTER already flushing some real (or garbage)
    # partial SRT text to stdout, the old "both" check let a nonzero
    # exit slip past unflagged, then fed that partial output into the
    # line-stripper below, which could legitimately net 0 dialogue
    # lines and return $false (discard) -- silently treating a genuine
    # subprocess failure as proof of emptiness, the exact invariant
    # this whole function exists to prevent. Any nonzero exit is now
    # always ambiguous, regardless of what partial output exists.
    if ($decodeResult.ExitCode -ne 0) {
        Write-Warning "Subtitle stream s:${Index} in ${Source}: text-decode probe failed/timed out (exit $($decodeResult.ExitCode)) -- keeping rather than risk discarding real content"
        return $true
    }

    if ([string]::IsNullOrEmpty($rawSrt)) {
        return $false
    }

    # Strip cue numbers/timing lines/blank lines, ASS override blocks
    # ({\an5}, {\pos(...)}, etc.), and <tag>/</tag> wrappers ffmpeg's srt
    # encoder adds for styled ASS cues. A track can have packets but
    # still be functionally empty (every cue authored as "" or as
    # position-only override codes with no dialogue).
    $lines = $rawSrt -split "`r?`n"
    $cueNumberRe = '^\d+$'
    $timingRe = '^[0-9:,]+ --> [0-9:,]+$'
    $decodeOut = foreach ($line in $lines) {
        $stripped = $line -replace '\{\\[^}]*\}', '' -replace '<[^>]*>', ''
        if ($stripped -match $cueNumberRe) { continue }
        if ($stripped -match $timingRe) { continue }
        if ($stripped.Trim() -eq '') { continue }
        $stripped
    }

    return (@($decodeOut).Count -gt 0)
}

function New-VesRealSubtitleMapArgs {
    <#
    .SYNOPSIS
    Builds an explicit "-map <InputIndex>:s:N" arg list containing only
    subtitle indices in $Source that pass Test-VesSubtitleStreamHasRealContent,
    so a blanket "?:s?" map never carries a flagged-but-empty track into
    the output. On ambiguous enumeration failure, falls back to an
    UNFILTERED blanket map rather than risk discarding all subtitles.
    #>
    param(
        [Parameter(Mandatory)][int]$InputIndex,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [string]$StrippedSubtitlesLogPath
    )

    $subsArgs = @('-v', 'error', '-select_streams', 's', '-show_entries', 'stream=index', '-of', 'csv=p=0', $Source)
    $subsResult = Invoke-VesFfprobe -FfprobePath $FfprobePath -ProbeArgs $subsArgs
    $subsList = @($subsResult.StdOut -split "`n" | Where-Object { $_ -ne '' })

    # Team-review fix (2026-08-02): same class of bug as the text-decode
    # check above -- ExitCode checked independently of whether $subsList
    # is empty. If ffprobe crashes/times out after already printing SOME
    # (but not all) stream indices, the old "both" check let that
    # nonzero exit slip past unflagged and iterate over a truncated
    # list, silently never even considering whatever subtitle streams
    # ffprobe hadn't gotten to yet.
    if ($subsResult.ExitCode -ne 0) {
        Write-Warning "Subtitle stream enumeration failed/timed out for ${Source} (exit $($subsResult.ExitCode)) -- falling back to unfiltered subtitle mapping rather than risk discarding all subtitles"
        return @('-map', "${InputIndex}:s?")
    }
    if ($subsList.Count -eq 0) {
        return @()
    }

    $mapArgs = @()
    for ($i = 0; $i -lt $subsList.Count; $i++) {
        $keep = Test-VesSubtitleStreamHasRealContent -Source $Source -Index $i -FfprobePath $FfprobePath -FfmpegPath $FfmpegPath
        if ($keep) {
            $mapArgs += '-map'
            $mapArgs += "${InputIndex}:s:${i}"
        } else {
            Write-Warning "Subtitle stream s:${i} in ${Source} has no renderable content -- stripping from output"
            Write-VesStrippedSubtitleRecord -Source $Source -Index $i -FfprobePath $FfprobePath -LogPath $StrippedSubtitlesLogPath
        }
    }
    return $mapArgs
}

function Write-VesStrippedSubtitleRecord {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$LogPath
    )
    $key = "${Source}#${Index}"
    if ($script:StrippedSubtitleLogged.ContainsKey($key)) { return }
    $script:StrippedSubtitleLogged[$key] = $true

    $langArgs = @('-v', 'error', '-select_streams', "s:$Index", '-show_entries', 'stream_tags=language', '-of', 'default=nw=1:nk=1', $Source)
    $titleArgs = @('-v', 'error', '-select_streams', "s:$Index", '-show_entries', 'stream_tags=title', '-of', 'default=nw=1:nk=1', $Source)
    $lang = "$((Invoke-VesFfprobe -FfprobePath $FfprobePath -ProbeArgs $langArgs).StdOut)".Trim()
    $title = "$((Invoke-VesFfprobe -FfprobePath $FfprobePath -ProbeArgs $titleArgs).StdOut)".Trim()

    if (-not $LogPath) { $LogPath = Join-Path (Get-Location) 'stripped_subtitles.txt' }
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $langOut = if ($lang) { $lang } else { 'und' }
    $titleOut = if ($title) { $title } else { 'none' }
    $line = "$timestamp`t$Source`ts:$Index`tlang=$langOut`ttitle=$titleOut"
    try {
        Add-Content -Path $LogPath -Value $line -ErrorAction Stop
    } catch { }
}

Export-ModuleMember -Function Test-VesSubtitleStreamHasRealContent, New-VesRealSubtitleMapArgs, Write-VesStrippedSubtitleRecord
