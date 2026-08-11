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
if (-not (Get-Module -Name VesDoneLog)) {
    Import-Module (Join-Path $PSScriptRoot 'VesDoneLog.psm1') -Force
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

function Invoke-VesFfmpegSrtEarlyExit {
    <#
    .SYNOPSIS
    Early-exit port of the bash text-decode probe's `| head -1` SIGPIPE
    short-circuit (2026-08-11) -- found via real fleet monitoring that
    PRINCE was hitting this probe's full retry budget (3x60s) repeatedly
    across many Sabrina episodes, since Invoke-VesFfmpegValidation's
    ReadToEndAsync always waits for the full decode to finish. Reads
    ffmpeg's stdout line-by-line via ReadLineAsync (same Task-based
    approach as Invoke-VesWithTimeoutRetry, for the same
    PowerShell-event-loop-independence reason) and kills the process the
    moment ONE real (non cue-number/timing/blank) line is found -- this
    only short-circuits the CONFIRMED-non-empty case; a track that's
    ambiguous or genuinely empty throughout still reads to EOF and
    reports ffmpeg's own real exit code, so the
    never-treat-ambiguous-as-empty invariant this whole probe exists for
    is unchanged.
    #>
    param(
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string[]]$FfmpegArgs,
        [int]$TimeoutSeconds = 60,
        [int]$MaxRetries = 2
    )
    $attempt = 0
    while ($true) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FfmpegPath
        foreach ($a in $FfmpegArgs) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $foundReal = $false
        $timedOut = $false
        try {
            $proc.Start() | Out-Null
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            while ($true) {
                $remainingMs = [Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                if ($remainingMs -le 0) { $timedOut = $true; break }
                $lineTask = $proc.StandardOutput.ReadLineAsync()
                $completedIdx = [System.Threading.Tasks.Task]::WaitAny(@($lineTask), [int]$remainingMs)
                if ($completedIdx -eq -1) { $timedOut = $true; break }
                $line = $lineTask.Result
                if ($null -eq $line) { break }  # EOF -- ffmpeg finished writing stdout
                $clean = $line -replace '\{\\[^}]*\}', '' -replace '<[^>]*>', ''
                if ($clean -notmatch '^\d+$' -and $clean -notmatch '^[0-9:,]+ --> [0-9:,]+$' -and $clean.Trim() -ne '') {
                    $foundReal = $true
                    break
                }
            }

            if ($timedOut) {
                try { $proc.Kill($true) } catch { }
                $proc.WaitForExit()
                try { [System.Threading.Tasks.Task]::WaitAll(@($stderrTask)) } catch { }
                $attempt++
                if ($attempt -gt $MaxRetries) {
                    return [PSCustomObject]@{ FoundReal = $false; ExitCode = 124; TimedOut = $true }
                }
                continue
            }

            if ($foundReal) {
                # Confirmed non-empty -- no need to wait for the rest of
                # the episode. Killing here (not letting it exit
                # naturally) is what delivers the early-exit time win.
                try { $proc.Kill($true) } catch { }
                $proc.WaitForExit()
                return [PSCustomObject]@{ FoundReal = $true; ExitCode = 0; TimedOut = $false }
            }

            # EOF reached with no real line found -- ffmpeg has already
            # exited by construction (ReadLineAsync only returns $null at
            # end of stream); reap it and trust its own real exit code,
            # exactly like the non-early-exit path did before this change.
            $proc.WaitForExit()
            try { [System.Threading.Tasks.Task]::WaitAll(@($stderrTask)) } catch { }
            return [PSCustomObject]@{ FoundReal = $false; ExitCode = $proc.ExitCode; TimedOut = $false }
        } finally {
            $proc.Dispose()
        }
    }
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

    # --- Text-decode probe (early-exit, 2026-08-11 -- see
    # Invoke-VesFfmpegSrtEarlyExit's own doc comment for why) ---
    $decodeArgs = @('-v', 'error', '-i', $Source, '-map', "0:s:$Index", '-f', 'srt', '-')
    $decodeResult = Invoke-VesFfmpegSrtEarlyExit -FfmpegPath $FfmpegPath -FfmpegArgs $decodeArgs

    # Team-review fix (2026-08-02, preserved across the early-exit port):
    # any nonzero/failed/timed-out outcome is always ambiguous, never
    # treated as proof of emptiness -- the exact invariant this whole
    # probe exists to prevent violating. $decodeResult.FoundReal is only
    # $true when a genuine non-cue-number/timing/blank line was actually
    # observed in ffmpeg's own output before it was killed.
    if ($decodeResult.ExitCode -ne 0) {
        Write-Warning "Subtitle stream s:${Index} in ${Source}: text-decode probe failed/timed out (exit $($decodeResult.ExitCode)) -- keeping rather than risk discarding real content"
        return $true
    }

    return $decodeResult.FoundReal
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
    <#
    .SYNOPSIS
    Records a stripped-subtitle-stream event. One-file-per-entry, not a
    shared-file append -- hardened ahead of need (2026-08-06 team
    review): nothing currently wires -StrippedSubtitlesLogPath to a NAS
    path (falls back to a name in the process's cwd today), but the
    exact same Add-Content-against-a-network-path failure mode already
    confirmed in production for Write-VesLowQualityFlag/
    Write-VesBadSourceFlag would hit this the moment it is. See
    VesValidation.psm1's Write-VesLowQualityFlag for the full story.

    .PARAMETER LogPath
    Despite the name (kept for caller-compatibility), this is a
    DIRECTORY entries are written into, not a single flat file --
    mirrors $JobSidecarDir elsewhere in this port. Defaults to the
    process's current directory if not supplied, matching the old
    default's location (just no longer a fixed filename within it).
    #>
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

    $logDir = if ($LogPath) { $LogPath } else { (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { return }
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $langOut = if ($lang) { $lang } else { 'und' }
    $titleOut = if ($title) { $title } else { 'none' }
    $line = "$timestamp`t$Source`ts:$Index`tlang=$langOut`ttitle=$titleOut`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $token = [System.IO.Path]::GetRandomFileName() -replace '[.]', ''
    $entryPath = Join-Path $logDir "stripped_subtitles-$env:COMPUTERNAME-$PID-$token.subtitle-flag"
    $wrote = $false
    try {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($entryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            $fs.Write($bytes, 0, $bytes.Length)
            $wrote = $true
        } finally {
            if ($fs) { $fs.Close() }
        }
    } catch { }
    if ($wrote) { Set-VesEveryoneReadWrite -Path $entryPath }
}

Export-ModuleMember -Function Test-VesSubtitleStreamHasRealContent, New-VesRealSubtitleMapArgs, Write-VesStrippedSubtitleRecord
