#Requires -Version 7
<#
.SYNOPSIS
Native-Windows PowerShell orchestration entry point for the video-encoder
fleet, wiring together the windows/modules/Ves*.psm1 library built in
Phases 1-3 into a real runnable tool. Port scope: convert-v5.0.33S.sh's
core convert_library()/begin_convert_job()/end_convert_job() flow (profile
detection -> VMAF CRF search -> two-stage encode+remux -> validate ->
finalize -> done-log -> resume-state), plus orphan-reap-before-claiming-
new-work and RAM-disk job lifecycle.

Deliberately NOT yet ported (see ROADMAP.md's Phase 4/5 notes and
DESIGN-remaining6features.md): organize phase, dry-run library inspection
report, pipeline-vs-batch dual mode (this script always processes files
one at a time, matching bash's "batch" mode -- the "pipeline" mode exists
in bash purely as a large-library performance optimization, not a
behavioral difference), season-retry shrink heuristic, disc-source
(ISO/BDMV) handling. All of these are real, scoped gaps, not oversights.

Telegram notifications ARE ported (VesTelegram.psm1, 2026-08-03) -- env
var config only (VES_TELEGRAM_BOT_TOKEN/VES_TELEGRAM_CHAT_ID), never a
CLI flag, matching bash's own stated security reasoning.

.PARAMETER SearchPath
Library root to scan (a real folder or a single file's parent directory).

.PARAMETER JobRoot
Where resume-state sidecars and (by default) the done-log directory live.
Defaults to -SearchPath.

.PARAMETER ToolsRoot
Directory containing ffmpeg/ffprobe (in a bin\ subfolder), mkvalidator,
ab-av1, matching the D:\VES-ELVIS\tools convention already established
this project. Individual -FfmpegPath etc. override this.
#>
param(
    [Parameter(Mandatory)][string]$SearchPath,
    [string]$JobRoot,
    [string]$ToolsRoot = 'D:\VES-ELVIS\tools',
    [string]$FfmpegPath,
    [string]$FfprobePath,
    [string]$AbAv1Path,
    [string]$MkvalidatorPath,
    [string]$LocalStagingDir = 'D:\VES-ELVIS\staging',
    [int]$ShardDepth = 1,
    [switch]$NoShard,
    [string]$NameGlob,
    [int]$VmafTarget = 90,
    [ValidateSet('libopus', 'aac')][string]$AudioCodec = 'libopus',
    [string]$AudioBitrate = '112k',
    [string]$ForceProfile,
    [switch]$NoAutoReap,
    [switch]$NoResume,
    [switch]$UseRamDisk,
    [switch]$InPlace,
    [string]$OutputSuffix = '.AV1-WIN',
    [switch]$DryRun,
    [string[]]$VideoExtensions = @('mkv', 'mp4', 'avi', 'm4v', 'mov', 'ts', 'wmv')
)

$ErrorActionPreference = 'Stop'
$ModuleDir = $PSScriptRoot
foreach ($m in @(
        'VesTimeoutRetry', 'VesTrackedProcess', 'VesStaging', 'VesValidation',
        'VesSharedMutex', 'VesTitleLock', 'VesDoneLog', 'VesResumeState',
        'VesRamDisk', 'VesOrphanReaper', 'VesShardedScan',
        'VesSubtitleFilter', 'VesProfileDecision', 'VesVmafCrfSearch', 'VesTwoStageEncode',
        'VesTelegram'
    )) {
    Import-Module (Join-Path $ModuleDir "modules\$m.psm1") -Force
}

if (-not $JobRoot) { $JobRoot = $SearchPath }
if (-not $FfmpegPath) { $FfmpegPath = Join-Path $ToolsRoot 'bin\ffmpeg.exe' }
if (-not $FfprobePath) { $FfprobePath = Join-Path $ToolsRoot 'bin\ffprobe.exe' }
if (-not $AbAv1Path) { $AbAv1Path = Join-Path $ToolsRoot 'ab-av1.exe' }
if (-not $MkvalidatorPath) { $MkvalidatorPath = Join-Path $ToolsRoot 'mkvalidator.exe' }

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

function Write-VesLog {
    param([string]$Message)
    Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $Message"
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

# --- Resolve scan roots and enumerate video files ---
$scanRoots = @(Get-VesScanRoots -SearchPath $SearchPath -ShardDepth $ShardDepth -NoShard:$NoShard -NameGlob $NameGlob)
$allFiles = New-Object System.Collections.Generic.List[string]
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

$total = $allFiles.Count
Write-VesLog "Scan complete: $total video file(s) found under $($scanRoots.Count) shard(s)"

$statePath = Get-VesResumeSidecarPath -JobRoot $JobRoot -Hostname $env:COMPUTERNAME -Kind 'state'
$processed = 0; $skippedDone = 0; $skippedClaimed = 0; $failed = 0; $succeeded = 0
$idx = 0

foreach ($src in $allFiles) {
    $idx++
    $doneLogDir = Split-Path -Parent $src

    Import-VesDoneLog -DoneLogDir $doneLogDir
    if (Test-VesDoneLogShouldSkip -Source $src -FfmpegPath $FfmpegPath -NoResume:$NoResume) {
        $skippedDone++
        continue
    }

    $lock = Enter-VesTitleLock -Source $src
    if (-not $lock) {
        $skippedClaimed++
        continue
    }

    Write-VesLog ('-' * 50)
    Write-VesLog "Job $idx of $total`: $(Split-Path -Leaf $src)"

    if ($DryRun) {
        Write-VesLog "Dry-run: would encode $src"
        Exit-VesTitleLock -Lock $lock
        continue
    }

    $flagPath = New-VesInProgressFlag -Source $src -EncoderPid $PID
    Save-VesResumeState -Path $statePath -State @{
        path = $SearchPath; shard_depth = "$ShardDepth"; no_shard = "$([bool]$NoShard)"
        last_source = $src; last_index = "$idx"; last_status = 'started'; queue_total = "$total"
    } | Out-Null

    $ok = $false
    $jobSw = [System.Diagnostics.Stopwatch]::StartNew()
    $srcDurationForSpeed = $null
    try {
        $profile = if ($ForceProfile) { $ForceProfile } else { Get-VesDetectedProfileForPath -Path $src }
        $hdrMode = Resolve-VesHdrMode -Source $src -FfprobePath $FfprobePath
        $isHdr = $hdrMode -in @('pq', 'pq_reconstruct', 'hlg')
        $srcDurationForSpeed = Get-VesMediaDurationSeconds -Path $src -FfprobePath $FfprobePath
        $upscaleTarget = Resolve-VesUpscaleTarget -Source $src -FfprobePath $FfprobePath
        $fixedCrf = Get-VesProfileFixedCrf -Codec av1 -Profile $profile -IsHdr $isHdr
        $svtParams = Get-VesProfileSvtParams -Profile $profile -FfmpegPath $FfmpegPath
        Write-VesLog "Profile: $profile  HDR: $hdrMode  Upscale target: $upscaleTarget"

        $crf = Resolve-VesCrfForEncode -Source $src -Codec av1 -Profile $profile -IsHdr $isHdr -TargetHeight $upscaleTarget `
            -FixedCrf $fixedCrf -VmafTarget $VmafTarget -AbAv1Path $AbAv1Path -FfprobePath $FfprobePath -EncoderArgs @('--svt', $svtParams)
        Write-VesLog "Resolved CRF: $crf"

        $videoArgsResult = Build-VesFfmpegVideoArgs -Codec av1 -Crf $crf -Source $src -Profile $profile -IsHdr $isHdr -HdrMode $hdrMode `
            -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -UpscaleTargetHeight $upscaleTarget

        $ext = [System.IO.Path]::GetExtension($src)
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($src)
        $dir = Split-Path -Parent $src
        $dst = if ($InPlace) { Join-Path $dir "$baseName.mkv" } else { Join-Path $dir "$baseName$OutputSuffix.mkv" }

        $errLogDir = Join-Path $JobRoot 'ffmpeg-logs'
        $result = Invoke-VesTwoStageEncode -Source $src -Destination $dst -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath `
            -VideoArgs $videoArgsResult.VideoArgs -VideoFilters $videoArgsResult.VideoFilters -ColorArgs $videoArgsResult.ColorArgs `
            -AudioCodec $AudioCodec -AudioBitrate $AudioBitrate -ErrorLogDir $errLogDir `
            -RamdiskDir $(if ($ramDiskJob) { $ramDiskJob.RootPath }) -LocalFallbackDir $stageDir

        if (-not $result.Success) {
            Write-VesLog "Encode FAILED (stage=$($result.Stage) exitcode=$($result.ExitCode)): $src"
            $ok = $false
        } else {
            $durMatch = $true
            if ($MkvalidatorPath) {
                $structOk = Test-VesMkvStructureValid -Path $dst -MkvalidatorPath $MkvalidatorPath
                if ($structOk -eq $false) {
                    Write-VesLog "Output failed structure validation: $dst"
                    $durMatch = $false
                }
            }
            $srcDur = Get-VesMediaDurationSeconds -Path $src -FfprobePath $FfprobePath
            $dstDur = Get-VesMediaDurationSeconds -Path $dst -FfprobePath $FfprobePath
            if (-not (Test-VesDurationsMatch -DurationA $srcDur -DurationB $dstDur -ToleranceSeconds 2.0)) {
                Write-VesLog "Duration mismatch (src=$srcDur dst=$dstDur): $dst"
                $durMatch = $false
            }
            if ($durMatch) {
                $srcSize = (Get-Item $src -Force).Length
                $dstSize = (Get-Item $dst -Force).Length
                $shrinkPct = [math]::Round((1 - ($dstSize / $srcSize)) * 100, 1)
                Write-VesLog "Encode OK: $([math]::Round($srcSize/1MB,1))MB -> $([math]::Round($dstSize/1MB,1))MB ($shrinkPct% shrink)"
                Add-VesDoneLogEntry -Status done -Source $src -DoneLogDir $doneLogDir -FfmpegPath $FfmpegPath
                $ok = $true
            } else {
                Write-VesLog "Output did not pass validation -- leaving source untouched, not recording as done: $src"
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
            last_source = $src; last_index = "$idx"; last_status = $(if ($ok) { 'completed' } else { 'failed' }); queue_total = "$total"
        } | Out-Null

        $jobSw.Stop()
        $elapsedSecs = $jobSw.Elapsed.TotalSeconds
        $elapsedHms = '{0:00}h {1:00}m {2:00}s' -f $jobSw.Elapsed.Hours, $jobSw.Elapsed.Minutes, $jobSw.Elapsed.Seconds
        if ($ok) {
            if ($srcDurationForSpeed -and $srcDurationForSpeed -gt 0 -and $elapsedSecs -gt 0) {
                $speed = [math]::Round($srcDurationForSpeed / $elapsedSecs, 2)
                Send-VesTelegramNotification -Message "OK Job $idx/$total complete: $(Split-Path -Leaf $src) -- $elapsedHms (${speed}x realtime)"
            } else {
                Send-VesTelegramNotification -Message "OK Job $idx/$total complete: $(Split-Path -Leaf $src) -- $elapsedHms"
            }
        } else {
            Send-VesTelegramNotification -Message "FAILED Job $idx/$total`: $(Split-Path -Leaf $src)"
        }
    }

    $processed++
    if ($ok) { $succeeded++ } else { $failed++ }
}

if ($ramDiskJob) {
    Write-VesLog "Tearing down RAM disk staging ($($ramDiskJob.DriveLetter):)"
    Remove-VesRamDiskJob -DriveLetter $ramDiskJob.DriveLetter | Out-Null
}

Write-VesLog ('=' * 50)
Write-VesLog "Run complete: $total found, $processed processed ($succeeded ok, $failed failed), $skippedDone done-log-skipped, $skippedClaimed claimed-elsewhere"
