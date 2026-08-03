# Windows port of convert-v5.0.33S.sh's ffmpeg_encode() two-stage
# mechanism (lines ~10760-10950) -- the actual fix for the recurring
# encode-truncation bug (see [[project_truncation_bug_resolved_2026_08_02]]
# in memory). Stage 1 encodes video+audio only, no subtitles/attachments
# in the live encode at all. Stage 2 is a cheap stream-copy remux that
# adds source subtitles/attachments back in, with a retry-without-subs
# fallback if the subtitle remux itself fails (odd subtitle codecs can
# still break a remux header even though the expensive encode already
# succeeded).
#
# Deliberately NOT ported in this pass (separate, larger pieces):
#   - Video-arg construction (build_ffmpeg_video_args and everything
#     under it: HDR/DoVi classification, per-profile SVT-AV1/x265 params,
#     upscale targeting) -- this function takes already-built video args,
#     matching how the bash version's ffmpeg_encode() itself consumes
#     build_ffmpeg_video_args()'s output rather than inlining it.
#   - CRF resolution (VMAF search) -- ported separately, CRF is a required
#     parameter here.

if (-not (Get-Module -Name VesTrackedProcess)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTrackedProcess.psm1') -Force
}
if (-not (Get-Module -Name VesSubtitleFilter)) {
    Import-Module (Join-Path $PSScriptRoot 'VesSubtitleFilter.psm1') -Force
}
if (-not (Get-Module -Name VesStaging)) {
    Import-Module (Join-Path $PSScriptRoot 'VesStaging.psm1') -Force
}

function Get-VesAudioFilterChain {
    <#
    .SYNOPSIS
    Port of ffmpeg_audio_filter_chain(). Dialogue-clarity audio filter
    matching v4's HandBrake -D/--gain behavior: dynaudnorm (dynamic range
    compression) + a static volume gain. Always applied, matching the
    bash version's "every audio track regardless of codec" policy.
    #>
    param(
        [Parameter(Mandatory)][string]$AudioCodec,
        [Parameter(Mandatory)][double]$AudioDrc,
        [Parameter(Mandatory)][double]$AudioGainDb
    )
    $maxGain = [math]::Round($AudioDrc * 5, 1)
    $chain = "dynaudnorm=f=250:g=15:m=$maxGain,volume=${AudioGainDb}dB"
    if ($AudioCodec -eq 'libopus') {
        $chain = "aformat=channel_layouts=7.1|5.1|stereo|mono,$chain"
    }
    return $chain
}

function Invoke-VesTwoStageEncode {
    <#
    .SYNOPSIS
    Two-stage encode+remux: stage 1 produces video+audio only (no
    subtitles/attachments in the live encode, the actual truncation-bug
    fix), stage 2 is a cheap stream-copy remux that adds real (non-empty)
    source subtitles/attachments back in, with a retry-without-subs
    fallback on remux failure.

    .PARAMETER VideoArgs
    Pre-built video-encode args (e.g. -c:v libsvtav1 -preset ... -crf ...
    -pix_fmt ... -svtav1-params ...), matching FF_VIDEO_ARGS from
    build_ffmpeg_video_args() (not yet ported -- see task #31).

    .PARAMETER VideoFilters
    Pre-built -vf filter chain elements (scale/pad/unsharp/libplacebo),
    matching FF_VF. Joined with commas, same as the bash version.

    .PARAMETER ColorArgs
    HDR color-tag args for the stage-2 remux only (-color_primaries etc),
    matching remux_color_args.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string[]]$VideoArgs,
        [string[]]$VideoFilters = @(),
        [string[]]$ColorArgs = @(),
        [Parameter(Mandatory)][ValidateSet('libopus', 'aac')][string]$AudioCodec,
        [Parameter(Mandatory)][string]$AudioBitrate,
        [double]$AudioDrc = 1.0,
        [double]$AudioGainDb = 0.0,
        [Parameter(Mandatory)][string]$ErrorLogDir,
        [string]$StrippedSubtitlesLogPath,
        [string]$RamdiskDir,
        [string]$LocalFallbackDir
    )

    $titleTag = [System.IO.Path]::GetFileNameWithoutExtension($Source)
    $pidTag = $PID
    New-Item -ItemType Directory -Path $ErrorLogDir -Force -ErrorAction SilentlyContinue | Out-Null
    $errBase = Join-Path $ErrorLogDir "$titleTag.$pidTag"
    $encodeErrFile = "$errBase.stderr.log"
    $remuxErrFile = "$errBase.remux.stderr.log"
    $retryErrFile = "$errBase.remux-nosubs.stderr.log"

    # Stage to a private, unpredictable path (ramdisk if available and it
    # fits, else local disk) rather than writing straight to the final,
    # predictable $Destination -- closes the same symlink/reparse-point
    # race the bash version's own external review flagged. $writeDst is
    # what the encoder actually opens; the real $Destination is only
    # touched at the very end via Complete-VesStagedEncodeOutput.
    $realDst = $Destination
    $writeDst = Resolve-VesEncodeStagePath -Source $Source -Destination $realDst -RamdiskDir $RamdiskDir -LocalFallbackDir $LocalFallbackDir
    if (-not $writeDst) {
        return [PSCustomObject]@{ Success = $false; ExitCode = 1; Stage = 'stage-path' }
    }

    $stage1 = "$writeDst.video-audio-only.$pidTag"

    try {
        # --- Stage 1: video + audio only ---
        $stage1Args = @('-y', '-nostdin', '-v', 'warning', '-stats', '-thread_queue_size', '4096', '-i', $Source,
            '-map', '0:v:0', '-map', '0:a?', '-map_chapters', '0')
        $stage1Args += $VideoArgs
        if ($VideoFilters.Count -gt 0) {
            $stage1Args += @('-vf', ($VideoFilters -join ','))
        }
        $audioFilterChain = Get-VesAudioFilterChain -AudioCodec $AudioCodec -AudioDrc $AudioDrc -AudioGainDb $AudioGainDb
        $stage1Args += @('-c:a', $AudioCodec, '-b:a', $AudioBitrate, '-af', $audioFilterChain)
        if ($AudioCodec -eq 'libopus') { $stage1Args += @('-mapping_family', '1') }
        $stage1Args += @('-max_muxing_queue_size', '8192', '-fps_mode', 'passthrough', '-f', 'matroska', $stage1)

        Write-Host "ffmpeg encode stage 1/2 (video+audio only): $([System.IO.Path]::GetFileName($Source))"
        $encodeResult = Invoke-VesTrackedProcess -FilePath $FfmpegPath -ArgumentList $stage1Args -ErrorLogPath $encodeErrFile
        if ($encodeResult.ExitCode -ne 0) {
            Write-Warning "ffmpeg stage-1 encode failed (rc=$($encodeResult.ExitCode)) -- stderr: $encodeErrFile"
            if ($writeDst -ne $realDst) { Remove-VesStagedFileDir -StagedPath $writeDst -RamdiskJobStageDir $RamdiskDir }
            return [PSCustomObject]@{ Success = $false; ExitCode = $encodeResult.ExitCode; Stage = 'encode' }
        }
        if (-not (Test-Path $stage1) -or (Get-Item $stage1).Length -eq 0) {
            Write-Warning "ffmpeg stage-1 encode reported success but output is missing/empty: $stage1"
            if ($writeDst -ne $realDst) { Remove-VesStagedFileDir -StagedPath $writeDst -RamdiskJobStageDir $RamdiskDir }
            return [PSCustomObject]@{ Success = $false; ExitCode = 1; Stage = 'encode' }
        }

        # --- Real-subtitle-map filter (only non-empty source subtitle tracks) ---
        $mapArgs = New-VesRealSubtitleMapArgs -InputIndex 1 -Source $Source -FfprobePath $FfprobePath -FfmpegPath $FfmpegPath -StrippedSubtitlesLogPath $StrippedSubtitlesLogPath

        # --- Stage 2: cheap stream-copy remux, adds subtitles/attachments back ---
        $subArgs = @('-c:s', 'copy')
        $ext = [System.IO.Path]::GetExtension($Source).TrimStart('.').ToLowerInvariant()
        if ($ext -in @('mp4', 'm4v', 'mov')) { $subArgs = @('-c:s', 'srt') }

        $remuxArgs = @('-y', '-nostdin', '-v', 'warning', '-stats',
            '-thread_queue_size', '4096', '-i', $stage1,
            '-thread_queue_size', '4096', '-i', $Source,
            '-map', '0:v:0', '-map', '0:a?')
        $remuxArgs += $mapArgs
        $remuxArgs += @('-map', '1:t?', '-map_chapters', '1', '-c:v', 'copy')
        $remuxArgs += $ColorArgs
        $remuxArgs += @('-c:a', 'copy')
        $remuxArgs += $subArgs
        $remuxArgs += @('-max_muxing_queue_size', '8192', '-fps_mode', 'passthrough',
            '-max_interleave_delta', '1000000', '-flush_packets', '1', '-f', 'matroska', $writeDst)

        Write-Host "ffmpeg remux stage 2/2 (copying encoded video/audio plus source subtitles/attachments): $([System.IO.Path]::GetFileName($Source))"
        $remuxResult = Invoke-VesTrackedProcess -FilePath $FfmpegPath -ArgumentList $remuxArgs -ErrorLogPath $remuxErrFile

        if ($remuxResult.ExitCode -ne 0) {
            Write-Warning "ffmpeg remux with subtitle/attachment streams failed (rc=$($remuxResult.ExitCode)) -- retrying final remux without subtitle/attachment streams -- stderr: $remuxErrFile"
            $retryArgs = @('-y', '-nostdin', '-v', 'warning', '-stats',
                '-thread_queue_size', '4096', '-i', $stage1,
                '-map', '0:v:0', '-map', '0:a?', '-map_chapters', '0', '-c:v', 'copy')
            $retryArgs += $ColorArgs
            $retryArgs += @('-c:a', 'copy', '-max_muxing_queue_size', '8192', '-fps_mode', 'passthrough',
                '-max_interleave_delta', '1000000', '-flush_packets', '1', '-f', 'matroska', $writeDst)
            $remuxResult = Invoke-VesTrackedProcess -FilePath $FfmpegPath -ArgumentList $retryArgs -ErrorLogPath $retryErrFile
            if ($remuxResult.ExitCode -ne 0) {
                Write-Warning "ffmpeg subtitle-stripped remux retry also failed (rc=$($remuxResult.ExitCode)) -- stderr: $retryErrFile"
                if ($writeDst -ne $realDst) {
                    Remove-VesFileRobust -Path $writeDst
                    Remove-VesStagedFileDir -StagedPath $writeDst -RamdiskJobStageDir $RamdiskDir
                }
                return [PSCustomObject]@{ Success = $false; ExitCode = $remuxResult.ExitCode; Stage = 'remux' }
            }
        }

        if (-not (Test-Path $writeDst) -or (Get-Item $writeDst).Length -eq 0) {
            Write-Warning "ffmpeg reported success but output is missing/empty: $writeDst"
            if ($writeDst -ne $realDst) {
                Remove-VesFileRobust -Path $writeDst
                Remove-VesStagedFileDir -StagedPath $writeDst -RamdiskJobStageDir $RamdiskDir
            }
            return [PSCustomObject]@{ Success = $false; ExitCode = 1; Stage = 'remux' }
        }

        # Clean up empty error logs -- a real warning trail survives, empty
        # per-title clutter doesn't (same policy as the bash version).
        foreach ($f in @($encodeErrFile, $remuxErrFile, $retryErrFile)) {
            if ((Test-Path $f) -and (Get-Item $f).Length -eq 0) {
                Remove-VesFileRobust -Path $f
            }
        }

        if ($writeDst -ne $realDst) {
            if (Complete-VesStagedEncodeOutput -StagedPath $writeDst -FinalDestination $realDst) {
                Write-Host "Staging: moved finished output to $realDst"
                Remove-VesStagedFileDir -StagedPath $writeDst -RamdiskJobStageDir $RamdiskDir
            } else {
                Write-Warning "Staging: failed to move staged output to $realDst"
                return [PSCustomObject]@{ Success = $false; ExitCode = 1; Stage = 'finalize' }
            }
        }

        return [PSCustomObject]@{ Success = $true; ExitCode = 0; Stage = 'done' }
    } finally {
        # Stage-1 temp file cleanup must always run, matching
        # ACTIVE_FFMPEG_STAGE1_FILE's trap-composition role in the bash
        # version (see ROADMAP.md item 4 -- PowerShell's try/finally is
        # the direct equivalent here, not a raw trap).
        Remove-VesFileRobust -Path $stage1
    }
}

Export-ModuleMember -Function Invoke-VesTwoStageEncode, Get-VesAudioFilterChain
