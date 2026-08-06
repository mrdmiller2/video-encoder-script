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
    [double]$Av1MaxOvershootPct = 20,
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
        'VesLegacyFallback', 'VesHwDetect'
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

# One-time capability probe (mirrors bash's FF_HAS_LIBPLACEBO) so Dolby
# Vision Profile 5 sources are only routed to human-review when this
# ffmpeg build genuinely can't handle them -- team review, 2026-08-06:
# this was never probed at all before, so -FfmpegHasLibPlacebo always
# silently defaulted to $false everywhere it was used.
$script:FfmpegHasLibPlacebo = Test-VesFfmpegHasLibPlacebo -FfmpegPath $FfmpegPath
Write-VesLog "ffmpeg capability: libplacebo=$script:FfmpegHasLibPlacebo"

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
function Invoke-VesCodecEncodeAttempt {
    <#
    .SYNOPSIS
    One encode+validate attempt for a single codec -- extracted from
    Invoke-VesEncodeAndValidate (team review, 2026-08-06) so the caller
    can try AV1, then fall back to a real x265 encode when AV1 is
    oversized or fails, mirroring bash's own try_av1_convert/
    try_x265_convert size-guard-driven fallback. Build-VesFfmpegVideoArgs
    was already fully codec-parameterized ('av1'/'hevc') before this --
    only the orchestration layer needed to grow a second codepath, not
    the encode pipeline itself.
    #>
    param(
        [Parameter(Mandatory)][string]$EncodeSource,
        [Parameter(Mandatory)][string]$ProfileSource,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidateSet('av1', 'hevc')][string]$Codec
    )
    $profile = if ($ForceProfile) { $ForceProfile } else { Get-VesDetectedProfileForPath -Path $ProfileSource }
    $hdrMode = Resolve-VesHdrMode -Source $EncodeSource -FfprobePath $FfprobePath
    $isHdr = $hdrMode -in @('pq', 'pq_reconstruct', 'hlg')
    $upscaleTarget = Resolve-VesUpscaleTarget -Source $EncodeSource -FfprobePath $FfprobePath
    $fixedCrf = Get-VesProfileFixedCrf -Codec $Codec -Profile $profile -IsHdr $isHdr
    Write-VesLog "Profile: $profile  Codec: $Codec  HDR: $hdrMode  Upscale target: $upscaleTarget"

    if ($Codec -eq 'av1') {
        $svtParams = Get-VesProfileSvtParams -Profile $profile -FfmpegPath $FfmpegPath
        $crf = Resolve-VesCrfForEncode -Source $EncodeSource -Codec av1 -Profile $profile -IsHdr $isHdr -TargetHeight $upscaleTarget `
            -FixedCrf $fixedCrf -VmafTarget $VmafTarget -AbAv1Path $AbAv1Path -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -EncoderArgs @('--svt', $svtParams)
    } else {
        # x265 is a size-guard fallback here, not the primary quality-search
        # path -- fixed CRF only, no VMAF-targeted ab-av1 search (ab-av1
        # itself is AV1-only). Matches this port's current scope: bash's
        # own multi-encoder GPU bake-off (NVENC/QSV/VideoToolbox/AMD VCE)
        # isn't ported here either -- this fallback is software x265 via
        # ffmpeg only, consistent with how this port's AV1 path is
        # currently software-only too.
        $crf = $fixedCrf
    }
    Write-VesLog "Resolved CRF: $crf"

    $videoArgsResult = Build-VesFfmpegVideoArgs -Codec $Codec -Crf $crf -Source $EncodeSource -Profile $profile -IsHdr $isHdr -HdrMode $hdrMode `
        -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -UpscaleTargetHeight $upscaleTarget -FfmpegHasLibPlacebo $script:FfmpegHasLibPlacebo

    if ($null -eq $videoArgsResult) {
        # Build-VesFfmpegVideoArgs returns $null for THREE distinct reasons
        # (Dolby Vision profile 5 without libplacebo; no SVT-AV1 params
        # entry for this profile; no x265 params entry for this profile) --
        # its own doc comment only mentions the DoVi case, and this caller
        # originally (and wrongly) attributed every $null to DoVi P5
        # unconditionally. Caught via direct testing, 2026-08-06: an
        # unrecognized -ForceProfile value hit the "no SVT params" path and
        # got durably flagged with a misleading "needs libplacebo" message.
        # Check the actual DoVi condition independently rather than assume.
        $isDoviP5WithoutLibplacebo = $isHdr -and
            (Test-VesSourceHasDolbyVision -Source $EncodeSource -FfprobePath $FfprobePath) -and
            ((Get-VesSourceDoviProfile -Source $EncodeSource -FfprobePath $FfprobePath) -eq '5') -and
            (-not $script:FfmpegHasLibPlacebo)
        if ($isDoviP5WithoutLibplacebo) {
            # Build-VesFfmpegVideoArgs's documented $null contract for
            # "caller must flag for human review instead of encoding."
            # Previously uncaught entirely (team review, 2026-08-05):
            # $videoArgsResult.VideoArgs on $null silently evaluates to
            # $null too (property access on $null doesn't throw in
            # PowerShell), so this fell through into Invoke-VesTwoStageEncode
            # with null video args instead of being caught -- risking
            # exactly the wrong-color-output class of bug this codebase's
            # own comments already warn about by name (the original bash
            # Profile 5 tint bug).
            return [PSCustomObject]@{
                Ok = $false; Destination = $Destination; SizeBytes = 0
                NeedsHumanReview = $true
                Reason = 'Dolby Vision profile 5 requires libplacebo (not in this ffmpeg build)'
            }
        }
        Write-VesLog "$Codec video args could not be built for profile '$profile' (no $Codec params entry for this profile) -- encode cannot proceed: $EncodeSource"
        return [PSCustomObject]@{ Ok = $false; Destination = $Destination; SizeBytes = 0 }
    }

    $errLogDir = Join-Path $JobRoot 'ffmpeg-logs'
    $result = Invoke-VesTwoStageEncode -Source $EncodeSource -Destination $Destination -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath `
        -VideoArgs $videoArgsResult.VideoArgs -VideoFilters $videoArgsResult.VideoFilters -ColorArgs $videoArgsResult.ColorArgs `
        -AudioCodec $AudioCodec -AudioBitrate $AudioBitrate -ErrorLogDir $errLogDir `
        -RamdiskDir $(if ($ramDiskJob) { $ramDiskJob.RootPath }) -LocalFallbackDir $stageDir

    if (-not $result.Success) {
        Write-VesLog "$Codec encode FAILED (stage=$($result.Stage) exitcode=$($result.ExitCode)): $EncodeSource"
        return [PSCustomObject]@{ Ok = $false; Destination = $Destination; SizeBytes = 0 }
    }

    $durMatch = $true
    if ($MkvalidatorPath) {
        $structOk = Test-VesMkvStructureValid -Path $Destination -MkvalidatorPath $MkvalidatorPath
        if ($structOk -eq $false) {
            Write-VesLog "$Codec output failed structure validation: $Destination"
            $durMatch = $false
        }
    }
    $srcDur = Get-VesMediaDurationSeconds -Path $EncodeSource -FfprobePath $FfprobePath
    $dstDur = Get-VesMediaDurationSeconds -Path $Destination -FfprobePath $FfprobePath
    if (-not (Test-VesDurationsMatch -DurationA $srcDur -DurationB $dstDur -ToleranceSeconds 2.0)) {
        Write-VesLog "$Codec duration mismatch (src=$srcDur dst=$dstDur): $Destination"
        $durMatch = $false
    }
    if (-not $durMatch) {
        Write-VesLog "$Codec output did not pass validation: $EncodeSource"
        return [PSCustomObject]@{ Ok = $false; Destination = $Destination; SizeBytes = 0 }
    }

    $sizeBytes = (Get-Item -LiteralPath $Destination -Force).Length
    return [PSCustomObject]@{ Ok = $true; Destination = $Destination; SizeBytes = $sizeBytes }
}

function Invoke-VesEncodeAndValidate {
    param(
        [Parameter(Mandatory)][string]$EncodeSource,
        [Parameter(Mandatory)][string]$ProfileSource,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$IsDiscSource
    )
    $errLogDir = Join-Path $JobRoot 'ffmpeg-logs'
    $srcSizeBytes = (Get-Item -LiteralPath $EncodeSource -Force).Length
    # -InPlace makes $Destination literally equal $EncodeSource for a
    # source already named *.mkv -- by the time a successful AV1 attempt
    # returns here, Invoke-VesTwoStageEncode's staging finalize has
    # ALREADY atomically replaced the source with the new encode (that's
    # the whole point of -InPlace). A real, serious bug found via team
    # review (2026-08-06, confirmed independently by two reviewers): the
    # size-guard fallback below unconditionally deletes $Destination
    # before trying x265, which in this specific case deletes the ONLY
    # remaining copy of the title -- if x265 then also fails, the source
    # is gone permanently. Matches bash's own "computed output path is
    # identical to the source, would destroy it" refusal class of guard.
    # Fix: skip the size-guard/x265-fallback dance entirely for this case
    # and just accept the AV1 result unconditionally, exactly matching
    # this port's pre-v5.1.0G behavior for -InPlace (no size guard existed
    # then either) -- no new risk introduced, just none of the new benefit
    # for this one mode.
    $inPlaceCollision = ($Destination -eq $EncodeSource)

    $av1Result = Invoke-VesCodecEncodeAttempt -EncodeSource $EncodeSource -ProfileSource $ProfileSource -Destination $Destination -Codec av1
    if ($av1Result.NeedsHumanReview) { return $av1Result }

    $finalDst = $Destination
    $ok = $false

    if ($inPlaceCollision) {
        # Skip the size-guard/x265-fallback dance entirely -- see the
        # comment above $inPlaceCollision. Matches this port's pre-
        # v5.1.0G behavior for -InPlace exactly: accept whatever AV1
        # produced (or didn't), never attempt a second encode that would
        # require deleting the only remaining copy first.
        $ok = $av1Result.Ok
        if (-not $ok) {
            Write-VesLog "AV1 encode/validation failed -- -InPlace target, not attempting x265 fallback (would require deleting the only remaining copy first): $EncodeSource"
        }
    } elseif ($av1Result.Ok) {
        $overshootPct = if ($srcSizeBytes -gt 0) { (($av1Result.SizeBytes - $srcSizeBytes) / $srcSizeBytes) * 100 } else { 0 }
        if ($av1Result.SizeBytes -le $srcSizeBytes -or $overshootPct -le $Av1MaxOvershootPct) {
            $finalDst = $av1Result.Destination
            $ok = $true
        } else {
            # Size-guard rejection -- port of bash's size_keep_policy_av1
            # (AV1_MAX_OVERSHOOT_PCT=20 there too). Team review, 2026-08-06:
            # this port had NO size guard at all before -- ANY duration/
            # structure-valid AV1 was kept regardless of size, a real,
            # silent policy divergence from bash on a shared library.
            # Deliberately simplified vs. bash's full behavior: no upscale-
            # tiered limit (bash's effective_upscale_overshoot_pct) and no
            # must-eliminate stash/tie-break bookkeeping -- scoped to the
            # common case (real x265 fallback exists now, vs. none before),
            # with the fuller bash-parity mechanics left as a follow-up.
            Write-VesLog "AV1 output >$Av1MaxOvershootPct% larger than original ($([math]::Round($overshootPct,1))%) -- trying x265 fallback: $EncodeSource"
        }
    } else {
        Write-VesLog "AV1 encode/validation failed -- trying x265 fallback: $EncodeSource"
    }

    if (-not $ok -and -not $inPlaceCollision) {
        # Parens around the pattern are load-bearing (found via direct
        # testing, 2026-08-06): without them, -replace's operator
        # precedence does not bind '+ "$"' to the pattern operand as a
        # plain read would suggest, and the suffix silently fails to
        # strip at all.
        $x265Dst = [System.IO.Path]::ChangeExtension($Destination, $null).TrimEnd('.') -replace ([regex]::Escape($OutputSuffix) + '$'), '.X265-WIN'
        $x265Dst = "$x265Dst.mkv"
        Remove-VesFileRobust -Path $Destination
        $x265Result = Invoke-VesCodecEncodeAttempt -EncodeSource $EncodeSource -ProfileSource $ProfileSource -Destination $x265Dst -Codec hevc
        if ($x265Result.NeedsHumanReview) { return $x265Result }

        if ($x265Result.Ok -and ($x265Result.SizeBytes -le $srcSizeBytes -or -not $av1Result.Ok)) {
            $finalDst = $x265Result.Destination
            $ok = $true
            Write-VesLog "Kept x265 fallback: $finalDst"
        } elseif ($av1Result.Ok -and (Test-VesIsMustEliminateFormat -Source $ProfileSource)) {
            # Must-eliminate format (avi/ogm/mpg/rmvb/etc.): don't discard a
            # working AV1 elimination just because x265 didn't beat it on
            # size -- matches bash's own reasoning (eliminating the
            # undesirable container matters more than the size guardrail
            # here). Re-run the AV1 attempt since its output was already
            # deleted above before trying x265.
            Remove-VesFileRobust -Path $x265Dst
            Write-VesLog "Source is a must-eliminate format -- re-encoding AV1 to keep despite exceeding the size guardrail: $EncodeSource"
            $av1Retry = Invoke-VesCodecEncodeAttempt -EncodeSource $EncodeSource -ProfileSource $ProfileSource -Destination $Destination -Codec av1
            if ($av1Retry.Ok) {
                $finalDst = $av1Retry.Destination
                $ok = $true
            } else {
                # Invoke-VesCodecEncodeAttempt's own validation-failure path
                # doesn't clean up $Destination (its caller usually still
                # wants the failed artifact for a future retry attempt) --
                # here, that would leave an invalid file sitting at the
                # canonical output path where a future scan's derived-output
                # detection would treat it as a finished title. Found via
                # review, 2026-08-06.
                Remove-VesFileRobust -Path $Destination
            }
        } else {
            Remove-VesFileRobust -Path $x265Dst
            if (Test-VesIsMustEliminateFormat -Source $ProfileSource) {
                $floor = Invoke-VesMustEliminateRemuxFloor -Source $EncodeSource -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -ErrorLogDir $errLogDir -IsDiscSource:$IsDiscSource
                if ($floor.Success) {
                    Write-VesLog "Must-eliminate remux floor succeeded: $($floor.Path)"
                    $finalDst = $floor.Path
                    $ok = $true
                }
            }
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
        $upscaleTarget = Resolve-VesUpscaleTarget -Source $EncodeSource -FfprobePath $FfprobePath
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

    # Cross-platform existing-output check (team review, 2026-08-06): this
    # port had no equivalent to bash's inspect_existing_outputs_for_queue
    # at all before -- a title a bash fleet machine (or an earlier run of
    # this port whose done-log entry didn't survive) already finished
    # would be silently re-encoded here every time. Scoped to non-disc
    # sources only, matching the title-lock cross-check's own scoping
    # (a disc source's canonical "title" derivation is a different,
    # more complex case -- out of scope for this pass).
    if (-not (Test-VesIsDiskSource -Source $src) -and -not $NoResume) {
        $existing = Find-VesExistingValidOutput -Source $src -FfprobePath $FfprobePath -MkvalidatorPath $MkvalidatorPath -OutputSuffix $OutputSuffix
        if ($existing) {
            Write-VesLog "Already has a valid output (this or another fleet machine) -- skipping: $src -> $existing"
            Add-VesDoneLogEntry -Status done -Source $src -DoneLogDir $doneLogDir -FfmpegPath $FfmpegPath
            $script:skippedDone++
            return
        }
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

                # Invoke-VesProcessDiskSource's EncodeFunction contract only
                # returns a bool -- $r.NeedsHumanReview/$r.Reason (e.g. a
                # DoVi P5 disc source without libplacebo) was silently
                # dropped before this, so that case just looked like an
                # ordinary encode failure and retried every scan forever
                # instead of being durably parked like the non-disc path.
                # Smuggled out via a script-scoped variable since changing
                # the EncodeFunction contract itself would touch every
                # other caller. Found via review, 2026-08-06.
                $script:discNeedsHumanReview = $null
                $discResult = Invoke-VesProcessDiskSource -HandBrakeCliPath $HandBrakeCliPath -Source $src -Destination $dst `
                    -ScratchRootDir $DiscScratchDir -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -EncodeFunction {
                        param($ExtractedPath, $LogicalSource, $Destination)
                        $r = Invoke-VesEncodeAndValidate -EncodeSource $ExtractedPath -ProfileSource $LogicalSource -Destination $Destination -IsDiscSource
                        if ($r.NeedsHumanReview) { $script:discNeedsHumanReview = $r.Reason }
                        return $r.Ok
                    }
                if ($discResult.Action -eq 'processed' -and $discResult.Success) {
                    Write-VesLog "Disc source processed: $dst"
                    Add-VesDoneLogEntry -Status done -Source $src -DoneLogDir $doneLogDir -FfmpegPath $FfmpegPath
                    $ok = $true
                } elseif ($script:discNeedsHumanReview) {
                    Write-VesBadSourceFlag -Source $src -Reason $script:discNeedsHumanReview -JobSidecarDir $JobRoot -DoneLogDir $doneLogDir -FfmpegPath $FfmpegPath
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
            } elseif ($r.NeedsHumanReview) {
                # A durable, deterministic failure -- retrying would fail
                # identically every time, so mark 'skip' (matches bash's
                # flag_bad_source_for_human) instead of leaving this to
                # retry forever on every future scan.
                Write-VesBadSourceFlag -Source $src -Reason $r.Reason -JobSidecarDir $JobRoot -DoneLogDir $doneLogDir -FfmpegPath $FfmpegPath
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
    # Self-contained (no module calls -- the background runspace doesn't
    # have VesOrganize.psm1 imported) equivalent of Test-VesIsDerivedOutput,
    # with $OutputSuffix baked in as a literal via string interpolation
    # since Start-VesScanProducer only forwards the scriptblock's .ToString()
    # across the runspace boundary, not captured variables. Same gap/fix as
    # the batch-mode loop above -- pipeline mode was equally queuing its own
    # prior outputs before this (team review, 2026-08-05).
    $escapedSuffix = [regex]::Escape($OutputSuffix)
    $shouldQueueScript = [scriptblock]::Create(@"
param(`$f)
`$base = Split-Path -Leaf `$f
if (`$base -match '\.(AV1|av1|x265|X265)\.mkv$') { return `$false }
if (`$base -match '-av1\.mkv$') { return `$false }
if (`$base -match '$escapedSuffix\.mkv$') { return `$false }
if (`$base -match '\.X265-WIN\.mkv$') { return `$false }
return `$true
"@)
    $handle = Start-VesScanProducer -SearchPath $SearchPath -ReadyQueuePath $readyQueue -ScanDonePath $scanDoneFlag -VideoExtensions $VideoExtensions -ShouldQueue $shouldQueueScript
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
        # Test-VesIsDerivedOutput skip is REQUIRED here, not optional --
        # without it this loop queues this port's own prior outputs
        # ("Title$OutputSuffix.mkv") as if they were fresh sources on
        # every rescan (team review, 2026-08-05; see that function's
        # comment for the full story).
        foreach ($root in $scanRoots) {
            Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $VideoExtensions -contains $_.Extension.TrimStart('.').ToLowerInvariant() } |
                Where-Object { -not (Test-VesIsDerivedOutput -Path $_.FullName -OutputSuffix $OutputSuffix) } |
                ForEach-Object { $allFiles.Add($_.FullName) }
        }
        if (Test-VesRootsNeedCatchupScan -SearchPath $SearchPath -VideoExtensions $VideoExtensions) {
            Get-ChildItem -LiteralPath $SearchPath -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $VideoExtensions -contains $_.Extension.TrimStart('.').ToLowerInvariant() } |
                Where-Object { -not (Test-VesIsDerivedOutput -Path $_.FullName -OutputSuffix $OutputSuffix) } |
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
