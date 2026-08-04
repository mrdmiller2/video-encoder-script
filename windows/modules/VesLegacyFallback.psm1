# Windows port of convert-v5.0.33S.sh's must-eliminate-format remux floor
# (is_must_eliminate_format 3841, must_eliminate_remux_path 4016,
# must_eliminate_fallback_or_fail 13309). Scoped to this port's current
# capability: convert.ps1 has no AV1-vs-x265 bake-off yet (only a single
# AV1 attempt), so the AV1-candidate-salvage half of the bash function
# doesn't apply here -- this ports the core safety guarantee only: a
# must-eliminate-format source (legacy container/transport-stream) whose
# real encode failed must never be left stuck in that format forever.
# Falls back to a plain lossless stream-copy remux into MKV as a last
# resort. When the AV1/x265 bake-off is eventually ported, revisit this
# module to add the candidate-salvage path bash has.
#
# Deliberately excludes disc sources (is_disk_source), matching bash's
# explicit team-review reasoning (2026-07-31): a disc job's -Source is
# already a temporary lossless extraction, not a container ffmpeg can
# trivially remux cheaply -- stream-copying it again would just produce
# another huge lossless file, defeating the point of this floor. A disc
# job with no salvageable candidate has no cheap floor; it stays failed
# for manual review, same as bash.

if (-not (Get-Module -Name VesProfileDecision)) {
    Import-Module (Join-Path $PSScriptRoot 'VesProfileDecision.psm1') -Force
}
if (-not (Get-Module -Name VesTrackedProcess)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTrackedProcess.psm1') -Force
}
if (-not (Get-Module -Name VesValidation)) {
    Import-Module (Join-Path $PSScriptRoot 'VesValidation.psm1') -Force
}

$script:VesMustEliminateExtensions = @('ts', 'm2ts', 'vob', 'avi', 'ogm', 'mpg', 'mpeg', 'm2v', 'rm', 'rmvb', 'divx', 'wmv', 'flv', 'asf')

function Test-VesIsMustEliminateFormat {
    <#
    .SYNOPSIS
    Port of is_must_eliminate_format(): container formats this project
    considers unacceptable to leave a library file in, plus disc sources.
    #>
    param([Parameter(Mandatory)][string]$Source)
    if (Test-VesIsDiskSource -Source $Source) { return $true }
    $ext = [System.IO.Path]::GetExtension($Source).TrimStart('.').ToLowerInvariant()
    return $script:VesMustEliminateExtensions -contains $ext
}

function Get-VesMustEliminateRemuxPath {
    <#
    .SYNOPSIS
    Port of must_eliminate_remux_path(): a bare Title.mkv path (no codec
    suffix, since no re-encode happened -- purely a container change).
    #>
    param([Parameter(Mandatory)][string]$Source)
    $dir = Split-Path -Parent $Source
    $title = [System.IO.Path]::GetFileNameWithoutExtension($Source)
    return Join-Path $dir "$title.mkv"
}

function Invoke-VesMustEliminateRemuxFloor {
    <#
    .SYNOPSIS
    Port of must_eliminate_fallback_or_fail()'s remux-floor half (the
    candidate-salvage half doesn't apply -- see module header). Only
    call this after the real encode attempt has already failed for a
    must-eliminate-format source. A plain per-stream stream-copy remux
    to a bare Title.mkv, with the same mp4/m4v/mov mov_text->srt
    exception the rest of this port's remux paths use.

    .PARAMETER IsDiscSource
    Set when $Source is a disc job's temporary lossless-extraction
    intermediate (not a real cheap-to-remux container) -- the floor is
    skipped, matching bash's explicit exclusion.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$ErrorLogDir,
        [switch]$IsDiscSource
    )
    if ($IsDiscSource) {
        Write-Warning "Must-eliminate remux floor skipped for disc source (no cheap floor exists): $Source"
        return [PSCustomObject]@{ Success = $false; Path = $null; Reason = 'disc-source-no-floor' }
    }
    if (-not (Test-VesIsMustEliminateFormat -Source $Source)) {
        return [PSCustomObject]@{ Success = $false; Path = $null; Reason = 'not-must-eliminate-format' }
    }

    $remuxOut = Get-VesMustEliminateRemuxPath -Source $Source
    $srcCanon = try { (Get-Item -LiteralPath $Source -Force).FullName } catch { $Source }
    $outCanon = if (Test-Path -LiteralPath $remuxOut) { (Get-Item -LiteralPath $remuxOut -Force).FullName } else { $remuxOut }
    if ($srcCanon -eq $outCanon) {
        Write-Warning "Must-eliminate remux fallback path collides with the source itself -- needs manual rename/review: $Source"
        return [PSCustomObject]@{ Success = $false; Path = $remuxOut; Reason = 'collides-with-source' }
    }
    if (Test-Path -LiteralPath $remuxOut) {
        $item = Get-Item -LiteralPath $remuxOut -Force
        if ($item.LinkType) {
            Write-Warning "Must-eliminate remux fallback path is an unexpected symlink/reparse point -- needs manual review: $remuxOut"
            return [PSCustomObject]@{ Success = $false; Path = $remuxOut; Reason = 'unexpected-symlink' }
        }
        Write-Warning "Must-eliminate remux fallback path already exists -- needs manual review before overwriting: $remuxOut"
        return [PSCustomObject]@{ Success = $false; Path = $remuxOut; Reason = 'target-exists' }
    }

    Write-Host "Both real encodes failed for must-eliminate format -- falling back to plain stream-copy remux: $remuxOut"

    $subArgs = @('-c:s', 'copy')
    $ext = [System.IO.Path]::GetExtension($Source).TrimStart('.').ToLowerInvariant()
    if ($ext -in @('mp4', 'm4v', 'mov')) { $subArgs = @('-c:s', 'srt') }

    $errFile = $null
    if ($ErrorLogDir) {
        New-Item -ItemType Directory -Path $ErrorLogDir -Force -ErrorAction SilentlyContinue | Out-Null
        $errFile = Join-Path $ErrorLogDir "$([System.IO.Path]::GetFileNameWithoutExtension($Source)).$PID.mustelim-remux.stderr.log"
    }

    $remuxArgs = @('-y', '-nostdin', '-v', 'warning', '-stats', '-thread_queue_size', '4096', '-i', $Source,
        '-map', '0:v:0?', '-map', '0:a?', '-map', '0:s?', '-map', '0:t?',
        '-map_chapters', '0', '-map_metadata', '0', '-c:v', 'copy', '-c:a', 'copy')
    $remuxArgs += $subArgs
    $remuxArgs += @('-max_muxing_queue_size', '8192', '-f', 'matroska', $remuxOut)

    $result = Invoke-VesTrackedProcess -FilePath $FfmpegPath -ArgumentList $remuxArgs -ErrorLogPath $errFile
    if ($result.ExitCode -ne 0) {
        Write-Warning "Stream-copy remux fallback failed for must-eliminate format (rc=$($result.ExitCode)): $Source"
        return [PSCustomObject]@{ Success = $false; Path = $remuxOut; Reason = 'remux-failed' }
    }
    if (-not (Test-Path -LiteralPath $remuxOut) -or (Get-Item -LiteralPath $remuxOut).Length -eq 0) {
        Write-Warning "Stream-copy remux fallback reported success but output is missing/empty: $remuxOut"
        return [PSCustomObject]@{ Success = $false; Path = $remuxOut; Reason = 'remux-empty-output' }
    }

    $srcDur = Get-VesMediaDurationSeconds -Path $Source -FfprobePath $FfprobePath
    $dstDur = Get-VesMediaDurationSeconds -Path $remuxOut -FfprobePath $FfprobePath
    if (-not (Test-VesDurationsMatch -DurationA $srcDur -DurationB $dstDur -ToleranceSeconds 2.0)) {
        Write-Warning "Stream-copy remux fallback failed duration validation (src=$srcDur dst=$dstDur): $remuxOut"
        Remove-Item -LiteralPath $remuxOut -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Success = $false; Path = $remuxOut; Reason = 'duration-mismatch' }
    }

    return [PSCustomObject]@{ Success = $true; Path = $remuxOut; Reason = 'ok' }
}

Export-ModuleMember -Function Test-VesIsMustEliminateFormat, Get-VesMustEliminateRemuxPath, Invoke-VesMustEliminateRemuxFloor
