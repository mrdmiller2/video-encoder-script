#Requires -Version 7
<#
.SYNOPSIS
Native-Windows PowerShell orchestration entry point for the video-encoder
fleet, wiring together the windows/modules/Ves*.psm1 library into a real
runnable tool. Port scope: convert-v5.0.33S.sh's core
convert_library()/begin_convert_job()/end_convert_job() flow (profile
detection -> VMAF CRF search -> two-stage encode+remux -> validate ->
finalize -> done-log -> resume-state), organize phase, pipeline-vs-batch
dual mode, disc-source (ISO/BDMV) handling, orphan-reap-before-claiming-
new-work, RAM-disk job lifecycle, and Telegram notifications.

Deliberately NOT yet ported: dry-run library inspection report,
season-retry shrink heuristic (VesSeasonRetry.psm1 exists but is inert --
its dependency, the sample-test-predicts-no-win mechanism, isn't ported
yet), the AV1-vs-x265 encoder bake-off (this script only attempts AV1;
VesLegacyFallback.psm1's remux floor is the safety net for a must-
eliminate-format source whose AV1 attempt fails, standing in for bash's
fuller bake-off-plus-candidate-salvage fallback until that's ported).

.PARAMETER SearchPath
Library root to scan (a real folder or a single file's parent directory).

.PARAMETER JobRoot
Where resume-state sidecars and (by default) the done-log directory live.
Defaults to -SearchPath.

.PARAMETER ToolsRoot
Directory containing ffmpeg/ffprobe (in a bin\ subfolder), mkvalidator,
ab-av1, HandBrakeCLI, matching the D:\VES-ELVIS\tools convention already
established this project. Individual -FfmpegPath etc. override this.

.PARAMETER OrganizeOnly
Run only the organize phase (movie folder-naming/reorganization) and
exit -- matches bash's --organize-only. Skips orphan-reap/convert
entirely.

.PARAMETER Pipeline
Force pipeline (background-scan-while-encoding) mode instead of the
default batch (scan-everything-then-encode) mode. Auto-detected for UNC
-SearchPath values when not explicitly set either way; see
Test-VesShouldUsePipelineMode.
#>
param(
    [Parameter(Mandatory)][string]$SearchPath,
    [string]$JobRoot,
    [string]$ToolsRoot = 'D:\VES-ELVIS\tools',
    [string]$FfmpegPath,
    [string]$FfprobePath,
    [string]$AbAv1Path,
    [string]$MkvalidatorPath,
    [string]$HandBrakeCliPath,
    [string]$LocalStagingDir = 'D:\VES-ELVIS\staging',
    [string]$DiscScratchDir,
    [int]$ShardDepth = 1,
    [switch]$NoShard,
    [string]$NameGlob,
    [int]$VmafTarget = 90,
    [double]$LowQualityVmafThreshold = 85.00,
    [ValidateSet('libopus', 'aac')][string]$AudioCodec = 'libopus',
    [string]$AudioBitrate = '112k',
    [string]$ForceProfile,
    [switch]$NoAutoReap,
    [switch]$NoResume,
    [switch]$UseRamDisk,
    [switch]$InPlace,
    [string]$OutputSuffix = '.AV1-WIN',
    [switch]$DryRun,
    [switch]$OrganizeOnly,
    [switch]$Pipeline,
    [switch]$NoPipeline,
    [string[]]$VideoExtensions = @('mkv', 'mp4', 'avi', 'm4v', 'mov', 'ts', 'wmv')
)

$ErrorActionPreference = 'Stop'
$ModuleDir = $PSScriptRoot
foreach ($m in @(
        'VesTimeoutRetry', 'VesTrackedProcess', 'VesStaging', 'VesValidation',
        'VesSharedMutex', 'VesTitleLock', 'VesDoneLog', 'VesResumeState',
        'VesRamDisk', 'VesOrphanReaper', 'VesShardedScan',
        'VesSubtitleFilter', 'VesProfileDecision', 'VesVmafCrfSearch', 'VesTwoStageEncode',
        'VesTelegram', 'VesOrganize', 'VesPipelineScan', 'VesHandBrake', 'VesDiscSource',
        'VesLegacyFallback'
    )) {
    Import-Module (Join-Path $ModuleDir "modules\$m.psm1") -Force
}

if (-not (Test-Path -LiteralPath $SearchPath)) {
    Write-Error "Path not found: $SearchPath"
    exit 1
}

# Port of bash's SINGLE_FILE_MODE (convert-v5.1.0C.sh, "-p may target a
# single file directly"): -SearchPath may be a single file (movie or
# episode), not just a directory. Sidecars (log/state/resume/done-log)
# live in the file's parent directory; organize is skipped (nothing to
# reorganize for one file); sharding/name-glob/pipeline-mode scanning do
# not apply -- there is nothing to scan, the one file IS the job.
#
# Why this needs an explicit branch here (bash needed none): bash's
# get_scan_roots() sets _roots=("$SEARCH_PATH") for a no-shard root, and
# `find "$root" -maxdepth 1 -type f ...` naturally returns a file target
# itself (no -mindepth 1), so single-file mode "just worked" once
# NO_SHARD was forced -- no separate per-file code path was needed.
# PowerShell's Get-ChildItem -Recurse has no equivalent self-inclusive
# behavior for a Leaf path (it requires a container and returns nothing
# for a file, silently swallowed by -ErrorAction SilentlyContinue) --
# confirmed via direct testing, 2026-08-05 -- so the batch-mode scan
# loop below needs an explicit single-file branch instead.
$SingleFileMode = (Test-Path -LiteralPath $SearchPath -PathType Leaf)
if ($SingleFileMode) {
    if (-not $JobRoot) { $JobRoot = Split-Path -Parent $SearchPath }
    if ($NameGlob) {
        Write-Warning "-NameGlob ignored -- $SearchPath is a single file target"
        $NameGlob = $null
    }
    if ($Pipeline) {
        Write-Warning "-Pipeline ignored -- $SearchPath is a single file target (nothing to background-scan)"
        $Pipeline = $false
    }
    $NoShard = $true
}
if (-not $JobRoot) { $JobRoot = $SearchPath }
if (-not $FfmpegPath) { $FfmpegPath = Join-Path $ToolsRoot 'bin\ffmpeg.exe' }
if (-not $FfprobePath) { $FfprobePath = Join-Path $ToolsRoot 'bin\ffprobe.exe' }
if (-not $AbAv1Path) { $AbAv1Path = Join-Path $ToolsRoot 'ab-av1.exe' }
if (-not $MkvalidatorPath) { $MkvalidatorPath = Join-Path $ToolsRoot 'mkvalidator.exe' }
if (-not $DiscScratchDir) { $DiscScratchDir = Join-Path $LocalStagingDir 'disc-extract-scratch' }

foreach ($tool in @($FfmpegPath, $FfprobePath, $AbAv1Path)) {
    if (-not (Test-Path $tool)) {
        Write-Error "Required tool not found: $tool"
        exit 1
    }
}
if (-not (Test-Path $MkvalidatorPath)) {
    Write-Warning "mkvalidator not found at $MkvalidatorPath -- structure validation will be skipped (degrades gracefully, matching the primary script's own optional-tool convention)"
    $MkvalidatorPath = $null
}
$HandBrakeCliPath = Get-VesHandBrakeCli -PathOverride $HandBrakeCliPath
if (-not $HandBrakeCliPath -and (Test-Path (Join-Path $ToolsRoot 'HandBrakeCLI.exe'))) {
    $HandBrakeCliPath = Join-Path $ToolsRoot 'HandBrakeCLI.exe'
}
if (-not $HandBrakeCliPath) {
    Write-Warning 'HandBrakeCLI not found -- disc-source (ISO/BDMV) handling will be skipped/degraded (optional-tool convention: only needed when a disc source is actually encountered)'
}

function Write-VesLog {
    param([string]$Message)
    Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $Message"
}

# --- Organize-only mode: run the organize phase and exit, matching bash's --organize-only ---
if ($OrganizeOnly) {
    if ($SingleFileMode) {
        Write-VesLog "Organize phase: skipped -- $SearchPath is a single file target (nothing to reorganize)"
        exit 0
    }
    Write-VesLog 'Organize phase: scanning for loose movie files to reorganize'
    $orgResult = Invoke-VesOrganizeLibrary -SearchPath $SearchPath -ShardDepth $ShardDepth -NoShard:$NoShard -NameGlob $NameGlob -VideoExtensions $VideoExtensions
    Write-VesLog "Organize complete: $($orgResult.Total) found, $($orgResult.Organized) organized, $($orgResult.Skipped) already in place, $($orgResult.Failed) failed"
    exit 0
}

# --- Orphan reap phase (Phase B, before claiming new work) ---
if (-not $NoAutoReap) {
    Write-VesLog 'Orphan reaper: scanning for crashed-job leftovers before claiming new work'
    $flagCandidates = @(Get-VesOrphanFlagCandidates -Root $SearchPath)
    foreach ($cand in $flagCandidates) {
        $disp = Get-VesOrphanDisposition -Candidate $cand
        switch ($disp) {
            'stale_both_dead' {
                Write-VesLog "Orphan reaper: $($cand.Source) -- both script and encoder processes are dead, clearing stale flag"
                Clear-VesInProgressFlag -Source $cand.Source
            }
            'orphan_encoder_alive' {
                Write-VesLog "Orphan reaper: $($cand.Source) -- script died but encoder process $($cand.EncoderPid) is still running, killing it"
                Invoke-VesKillOrphanedProcess -Pid_ $cand.EncoderPid | Out-Null
                Clear-VesInProgressFlag -Source $cand.Source
            }
            'manual_review' { Write-VesLog "Orphan reaper: $($cand.Source) -- legacy flag with no encoder_pid, needs manual review, leaving in place" }
            'cross_host' { }
            'live' { }
        }
    }
    $ramDiskLeftovers = @(Get-VesRamDiskLeftovers)
    if ($ramDiskLeftovers.Count -gt 0) {
        Write-VesLog "Orphan reaper: found $($ramDiskLeftovers.Count) RAM disk leftover(s) from a prior crash, evaluating"
        Invoke-VesRamDiskOrphanRecovery -FfprobePath $FfprobePath -MkvalidatorPath $MkvalidatorPath -ResolveSourceAndDestination {
            param($p) $null # No safe general mapping from a bare staged filename back
            # to its real source without the job's own resume-state; a leftover this
            # script itself created always writes a resume-state entry with that
            # mapping (see the per-file loop below) -- left as $null here deliberately
            # so an unattributable leftover is skipped (never guessed at), matching
            # this project's ambiguous-is-not-actionable invariant.
        } | Out-Null
    }
} else {
    Write-VesLog 'Orphan reaper: skipped (-NoAutoReap)'
}

# --- RAM disk job lifecycle ---
$ramDiskJob = $null
$stageDir = $LocalStagingDir
if ($UseRamDisk -and -not $DryRun) {
    $ramDiskJob = New-VesRamDiskJob
    if ($ramDiskJob) {
        Write-VesLog "RAM disk staging: $($ramDiskJob.RootPath) ($($ramDiskJob.StagePath))"
        $stageDir = $ramDiskJob.StagePath
    } else {
        Write-VesLog 'RAM disk staging unavailable -- falling back to local disk staging'
    }
}

$statePath = Get-VesResumeSidecarPath -JobRoot $JobRoot -Hostname $env:COMPUTERNAME -Kind 'state'
$script:processed = 0; $script:skippedDone = 0; $script:skippedClaimed = 0; $script:failed = 0; $script:succeeded = 0

# --- Core per-file encode+validate, shared by normal files and a disc
#     source's extracted intermediate (EncodeSource differs from
#     ProfileSource only for the latter). ---
function Invoke-VesEncodeAndValidate {
    param(
        [Parameter(Mandatory)][string]$EncodeSource,
        [Parameter(Mandatory)][string]$ProfileSource,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$IsDiscSource
    )
    $profile = if ($ForceProfile) { $ForceProfile } else { Get-VesDetectedProfileForPath -Path $ProfileSource }
    $hdrMode = Resolve-VesHdrMode -Source $EncodeSource -FfprobePath $FfprobePath
    $isHdr = $hdrMode -in @('pq', 'pq_reconstruct', 'hlg')
    $upscaleTarget = Resolve-VesUpscaleTarget -Source $EncodeSource -FfprobePath $FfprobePath
    $fixedCrf = Get-VesProfileFixedCrf -Codec av1 -Profile $profile -IsHdr $isHdr
    $svtParams = Get-VesProfileSvtParams -Profile $profile -FfmpegPath $FfmpegPath
    Write-VesLog "Profile: $profile  HDR: $hdrMode  Upscale target: $upscaleTarget"

    $crf = Resolve-VesCrfForEncode -Source $EncodeSource -Codec av1 -Profile $profile -IsHdr $isHdr -TargetHeight $upscaleTarget `
        -FixedCrf $fixedCrf -VmafTarget $VmafTarget -AbAv1Path $AbAv1Path -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -EncoderArgs @('--svt', $svtParams)
    Write-VesLog "Resolved CRF: $crf"

    $videoArgsResult = Build-VesFfmpegVideoArgs -Codec av1 -Crf $crf -Source $EncodeSource -Profile $profile -IsHdr $isHdr -HdrMode $hdrMode `
        -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -UpscaleTargetHeight $upscaleTarget

    $errLogDir = Join-Path $JobRoot 'ffmpeg-logs'
    $result = Invoke-VesTwoStageEncode -Source $EncodeSource -Destination $Destination -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath `
        -VideoArgs $videoArgsResult.VideoArgs -VideoFilters $videoArgsResult.VideoFilters -ColorArgs $videoArgsResult.ColorArgs `
        -AudioCodec $AudioCodec -AudioBitrate $AudioBitrate -ErrorLogDir $errLogDir `
        -RamdiskDir $(if ($ramDiskJob) { $ramDiskJob.RootPath }) -LocalFallbackDir $stageDir

    $finalDst = $Destination
    $ok = $false
    if (-not $result.Success) {
        Write-VesLog "Encode FAILED (stage=$($result.Stage) exitcode=$($result.ExitCode)): $EncodeSource"
        if (Test-VesIsMustEliminateFormat -Source $ProfileSource) {
            $floor = Invoke-VesMustEliminateRemuxFloor -Source $EncodeSource -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -ErrorLogDir $errLogDir -IsDiscSource:$IsDiscSource
            if ($floor.Success) {
                Write-VesLog "Must-eliminate remux floor succeeded: $($floor.Path)"
                $finalDst = $floor.Path
                $ok = $true
            }
        }
    } else {
        $durMatch = $true
        if ($MkvalidatorPath) {
            $structOk = Test-VesMkvStructureValid -Path $Destination -MkvalidatorPath $MkvalidatorPath
            if ($structOk -eq $false) {
                Write-VesLog "Output failed structure validation: $Destination"
                $durMatch = $false
            }
        }
        $srcDur = Get-VesMediaDurationSeconds -Path $EncodeSource -FfprobePath $FfprobePath
        $dstDur = Get-VesMediaDurationSeconds -Path $Destination -FfprobePath $FfprobePath
        if (-not (Test-VesDurationsMatch -DurationA $srcDur -DurationB $dstDur -ToleranceSeconds 2.0)) {
            Write-VesLog "Duration mismatch (src=$srcDur dst=$dstDur): $Destination"
            $durMatch = $false
        }
        if ($durMatch) {
            $ok = $true
        } else {
            Write-VesLog "Output did not pass validation -- leaving source untouched, not recording as done: $EncodeSource"
        }
    }

    if ($ok) {
        # Measured for both a real encode AND the must-eliminate remux floor
        # alike (mirrors bash's write_ves_processed_tag, called uniformly for
        # both paths) -- see Get-VesFinalVmaf/Write-VesLowQualityFlag for why
        # a below-floor result is log-only rather than moving the output.
        # -TargetHeight $upscaleTarget matters: without it, an upscaled
        # output (source scaled to 720p/1080p during encode) gets compared
        # against the source at mismatched resolutions, so libvmaf fails
        # every sample -- team review, 2026-08-05, caught this was missing.
        $finalVmaf = Get-VesFinalVmaf -Source $EncodeSource -Output $finalDst -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -TargetHeight $upscaleTarget
        if ($null -ne $finalVmaf) {
            Write-VesLog "Final VMAF: $finalVmaf ($finalDst)"
            if ($finalVmaf -lt $LowQualityVmafThreshold) {
                Write-VesLowQualityFlag -JobSidecarDir $JobRoot -OutputPath $finalDst -SourcePath $EncodeSource -Vmaf $finalVmaf -Threshold $LowQualityVmafThreshold
            }
        }
    }

    return [PSCustomObject]@{ Ok = $ok; Destination = $finalDst }
}

# --- Full per-item lifecycle: done-log/title-lock/resume-state/telegram,
#     plus disc-source detection and dispatch. Shared by batch and
#     pipeline scan modes. $src is always the LOGICAL path (a disc's
#     .iso/BDMV-parent path for a disc source, an ordinary file path
#     otherwise) -- the same identity done-log/title-lock/resume-state
#     key off regardless of mode. ---
function Invoke-VesFileJob {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Total
    )
    $src = $Source
    $doneLogDir = if (Test-VesIsDiskSource -Source $src) { Get-VesDiscMediaContentDir -Source $src } else { Split-Path -Parent $src }

    Import-VesDoneLog -DoneLogDir $doneLogDir
    if (Test-VesDoneLogShouldSkip -Source $src -FfmpegPath $FfmpegPath -NoResume:$NoResume) {
        $script:skippedDone++
        return
    }

    $lock = Enter-VesTitleLock -Source $src
    if (-not $lock) {
        $script:skippedClaimed++
        return
    }

    Write-VesLog ('-' * 50)
    Write-VesLog "Job $Index of $Total`: $(Split-Path -Leaf $src)"

    if ($DryRun) {
        Write-VesLog "Dry-run: would encode $src"
        Exit-VesTitleLock -Lock $lock
        return
    }

    $flagPath = New-VesInProgressFlag -Source $src -EncoderPid $PID
    Save-VesResumeState -Path $statePath -State @{
        path = $SearchPath; shard_depth = "$ShardDepth"; no_shard = "$([bool]$NoShard)"
        last_source = $src; last_index = "$Index"; last_status = 'started'; queue_total = "$Total"
    } | Out-Null

    $ok = $false
    $jobSw = [System.Diagnostics.Stopwatch]::StartNew()
    $srcDurationForSpeed = $null
    try {
        if (Test-VesIsDiskSource -Source $src) {
            if (-not $HandBrakeCliPath) {
                Write-VesLog "Skipping disc source -- HandBrakeCLI not available: $src"
                $ok = $false
            } else {
                $srcDurationForSpeed = $null # unknown until after title selection; not worth a second scan just for the speed figure
                $linkBase = Get-VesDiscExtractLinkBasename -Source $src
                $contentDir = Get-VesDiscMediaContentDir -Source $src
                $dst = Join-Path $contentDir "$([System.IO.Path]::GetFileNameWithoutExtension($linkBase))$OutputSuffix.mkv"

                $discResult = Invoke-VesProcessDiskSource -HandBrakeCliPath $HandBrakeCliPath -Source $src -Destination $dst `
                    -ScratchRootDir $DiscScratchDir -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -EncodeFunction {
                        param($ExtractedPath, $LogicalSource, $Destination)
                        $r = Invoke-VesEncodeAndValidate -EncodeSource $ExtractedPath -ProfileSource $LogicalSource -Destination $Destination -IsDiscSource
                        return $r.Ok
                    }
                if ($discResult.Action -eq 'processed' -and $discResult.Success) {
                    Write-VesLog "Disc source processed: $dst"
                    Add-VesDoneLogEntry -Status done -Source $src -DoneLogDir $doneLogDir -FfmpegPath $FfmpegPath
                    $ok = $true
                } else {
                    Write-VesLog "Disc source not processed (action=$($discResult.Action) reason=$($discResult.Reason)): $src"
                    $ok = $false
                }
            }
        } else {
            $srcDurationForSpeed = Get-VesMediaDurationSeconds -Path $src -FfprobePath $FfprobePath
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($src)
            $dir = Split-Path -Parent $src
            $dst = if ($InPlace) { Join-Path $dir "$baseName.mkv" } else { Join-Path $dir "$baseName$OutputSuffix.mkv" }

            $r = Invoke-VesEncodeAndValidate -EncodeSource $src -ProfileSource $src -Destination $dst
            if ($r.Ok) {
                $srcSize = (Get-Item $src -Force).Length
                $dstSize = (Get-Item $r.Destination -Force).Length
                $shrinkPct = [math]::Round((1 - ($dstSize / $srcSize)) * 100, 1)
                Write-VesLog "Encode OK: $([math]::Round($srcSize/1MB,1))MB -> $([math]::Round($dstSize/1MB,1))MB ($shrinkPct% shrink): $($r.Destination)"
                Add-VesDoneLogEntry -Status done -Source $src -DoneLogDir $doneLogDir -FfmpegPath $FfmpegPath
                $ok = $true
            } else {
                $ok = $false
            }
        }
    } catch {
        Write-VesLog "Job threw an exception: $($_.Exception.Message)"
        $ok = $false
    } finally {
        Clear-VesInProgressFlag -Source $src
        Exit-VesTitleLock -Lock $lock
        Save-VesResumeState -Path $statePath -State @{
            path = $SearchPath; shard_depth = "$ShardDepth"; no_shard = "$([bool]$NoShard)"
            last_source = $src; last_index = "$Index"; last_status = $(if ($ok) { 'completed' } else { 'failed' }); queue_total = "$Total"
        } | Out-Null

        $jobSw.Stop()
        $elapsedSecs = $jobSw.Elapsed.TotalSeconds
        $elapsedHms = '{0:00}h {1:00}m {2:00}s' -f $jobSw.Elapsed.Hours, $jobSw.Elapsed.Minutes, $jobSw.Elapsed.Seconds
        if ($ok) {
            if ($srcDurationForSpeed -and $srcDurationForSpeed -gt 0 -and $elapsedSecs -gt 0) {
                $speed = [math]::Round($srcDurationForSpeed / $elapsedSecs, 2)
                Send-VesTelegramNotification -Message "OK Job $Index/$Total complete: $(Split-Path -Leaf $src) -- $elapsedHms (${speed}x realtime)"
            } else {
                Send-VesTelegramNotification -Message "OK Job $Index/$Total complete: $(Split-Path -Leaf $src) -- $elapsedHms"
            }
        } else {
            Send-VesTelegramNotification -Message "FAILED Job $Index/$Total`: $(Split-Path -Leaf $src)"
        }
    }

    $script:processed++
    if ($ok) { $script:succeeded++ } else { $script:failed++ }
}

# --- Resolve scan roots and pick batch vs. pipeline mode ---
$scanRoots = @(Get-VesScanRoots -SearchPath $SearchPath -ShardDepth $ShardDepth -NoShard:$NoShard -NameGlob $NameGlob)
$usePipeline = if ($SingleFileMode) { $false } elseif ($Pipeline) { $true } elseif ($NoPipeline) { $false } else { Test-VesShouldUsePipelineMode -SearchPath $SearchPath -ForcePipeline:$Pipeline -LargestFirst:$false }

if ($usePipeline -and -not (Test-VesPathIsUnc -Path $SearchPath)) {
    Write-VesLog "Pipeline mode requires a UNC -SearchPath (\\host\share\...) -- falling back to batch mode for: $SearchPath"
    $usePipeline = $false
}

if ($usePipeline) {
    Write-VesLog "Convert mode: pipeline (background scan while encoding) -- $SearchPath"
    $readyQueue = Join-Path $JobRoot 'pipeline-ready.txt'
    $scanDoneFlag = Join-Path $JobRoot 'pipeline-scandone.txt'
    $handle = Start-VesScanProducer -SearchPath $SearchPath -ReadyQueuePath $readyQueue -ScanDonePath $scanDoneFlag -VideoExtensions $VideoExtensions
    try {
        $offset = 0
        $idx = 0
        $seen = New-Object System.Collections.Generic.HashSet[string]

        # The background scan producer only looks for $VideoExtensions
        # files -- disc sources (.iso/BDMV) need their own discovery pass,
        # same as batch mode's Find-VesDiskSources call. Cheap (metadata-
        # only directory listing), so done synchronously up front rather
        # than adding disc-aware logic to the runspace scan producer.
        if ($HandBrakeCliPath) {
            foreach ($disc in @(Find-VesDiskSources -SearchPath $SearchPath)) {
                if ($seen.Add($disc)) {
                    $idx++
                    Invoke-VesFileJob -Source $disc -Index $idx -Total '?'
                }
            }
        }

        while ($true) {
            $poll = Get-VesPipelineNewReadyItems -ReadyQueuePath $readyQueue -LastOffset $offset
            $offset = $poll.NewOffset
            $scanDone = Test-VesScanProducerDone -Handle $handle
            foreach ($item in $poll.Items) {
                if (-not $seen.Add($item)) { continue }
                $idx++
                Invoke-VesFileJob -Source $item -Index $idx -Total $(if ($scanDone) { "$($seen.Count)" } else { '?' })
            }
            if ($scanDone -and $poll.Items.Count -eq 0) { break }
            if (-not $scanDone -and $poll.Items.Count -eq 0) { Start-Sleep -Milliseconds 500 }
        }
        $total = $seen.Count
    } finally {
        Stop-VesScanProducer -Handle $handle
    }
} else {
    $allFiles = New-Object System.Collections.Generic.List[string]
    if ($SingleFileMode) {
        # Get-ChildItem -Recurse cannot be pointed at a Leaf path (see the
        # SingleFileMode comment above) -- the one file IS the job, no scan
        # needed. Still honors the video-extension allowlist so an
        # unsupported single-file target fails the same clear way a
        # directory scan would (silently skipping it, not a cryptic
        # downstream encoder error).
        Write-VesLog "Convert mode: single file -- $SearchPath"
        $ext = [System.IO.Path]::GetExtension($SearchPath).TrimStart('.').ToLowerInvariant()
        if ($VideoExtensions -contains $ext) {
            $allFiles.Add($SearchPath)
        } else {
            Write-VesLog "Skip -- '$ext' is not in the video-extensions allowlist: $SearchPath"
        }
    } else {
        Write-VesLog "Convert mode: batch (scan everything, then encode) -- $SearchPath"
        foreach ($root in $scanRoots) {
            Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $VideoExtensions -contains $_.Extension.TrimStart('.').ToLowerInvariant() } |
                ForEach-Object { $allFiles.Add($_.FullName) }
        }
        if (Test-VesRootsNeedCatchupScan -SearchPath $SearchPath -VideoExtensions $VideoExtensions) {
            Get-ChildItem -LiteralPath $SearchPath -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $VideoExtensions -contains $_.Extension.TrimStart('.').ToLowerInvariant() } |
                ForEach-Object { if (-not $allFiles.Contains($_.FullName)) { $allFiles.Add($_.FullName) } }
        }
        if ($HandBrakeCliPath) {
            foreach ($disc in @(Find-VesDiskSources -SearchPath $SearchPath)) {
                if (-not $allFiles.Contains($disc)) { $allFiles.Add($disc) }
            }
        }
    }

    $total = $allFiles.Count
    Write-VesLog "Scan complete: $total video file(s)/disc source(s) found under $($scanRoots.Count) shard(s)"

    $idx = 0
    foreach ($src in $allFiles) {
        $idx++
        Invoke-VesFileJob -Source $src -Index $idx -Total "$total"
    }
}

if ($ramDiskJob) {
    Write-VesLog "Tearing down RAM disk staging ($($ramDiskJob.DriveLetter):)"
    Remove-VesRamDiskJob -DriveLetter $ramDiskJob.DriveLetter | Out-Null
}

Write-VesLog ('=' * 50)
Write-VesLog "Run complete: $total found, $script:processed processed ($script:succeeded ok, $script:failed failed), $script:skippedDone done-log-skipped, $script:skippedClaimed claimed-elsewhere"
