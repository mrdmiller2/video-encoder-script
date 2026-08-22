# Windows port of modules/ves-chunk-coordinator.sh -- distributed
# chunk-parallel encoding coordination layer (Layer 1 of the
# chunk-parallel + per-shot dynamic optimization initiative, 2026-08-21).
# See the bash module's own header comment for the full design reasoning
# (why per-chunk claiming reuses the existing title-lock idiom instead of
# a new central dispatcher, why manifest storage is one-file-per-chunk
# not a single shared file, etc.) -- not repeated here.
#
# Deliberate Windows deviation from the bash version, not an oversight:
# bash's per-chunk claim reuses place_in_progress_flag()'s atomic mkdir
# lock. This port instead reuses VesTitleLock.psm1's own composition of
# VesSharedMutex's atomic-FILE-creation primitive, for the exact same
# documented reason VesTitleLock itself avoids mkdir on Windows: this
# NAS's SMB share gives freshly-created DIRECTORIES a broken ACL that
# even the creating session can't write into (VesSharedMutex.psm1's own
# header comment). The chunk MANIFEST directory itself (not a lock, a
# real content container multiple chunk files get written into) still
# has to be a directory -- created via New-Item, then immediately
# widened via Set-VesEveryoneReadWrite (VesDoneLog.psm1's own established
# fix for this exact NAS default-ACL problem) rather than assuming a
# fresh directory is safely writable.

if (-not (Get-Module -Name VesSharedMutex)) {
    Import-Module (Join-Path $PSScriptRoot 'VesSharedMutex.psm1') -Force
}
if (-not (Get-Module -Name VesDoneLog)) {
    Import-Module (Join-Path $PSScriptRoot 'VesDoneLog.psm1') -Force
}
if (-not (Get-Module -Name VesProfileDecision)) {
    Import-Module (Join-Path $PSScriptRoot 'VesProfileDecision.psm1') -Force
}
if (-not (Get-Module -Name VesVmafCrfSearch)) {
    Import-Module (Join-Path $PSScriptRoot 'VesVmafCrfSearch.psm1') -Force
}

$script:VesChunkLockStaleSeconds = 7200

function Get-VesChunkManifestDir {
    <#
    .SYNOPSIS
    Manifest directory for one title's chunks. Uses the full filename
    (not an extension-stripped "canonical title"), matching
    Get-VesTitleLockPath's own simplicity -- this port's locking and
    manifest paths are file-path-keyed throughout, not title-keyed.
    #>
    param([Parameter(Mandatory)][string]$Source)
    $dir = Split-Path -Parent $Source
    $name = Split-Path -Leaf $Source
    return Join-Path $dir "$name.chunks"
}

function Test-VesChunkShouldSplit {
    <#
    .SYNOPSIS
    Opt-in threshold check, same reasoning as bash's chunk_should_split():
    duration-based (not size-based), default OFF via
    $env:CONVERT_CHUNK_PARALLEL_ENABLED.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    if ($env:CONVERT_CHUNK_PARALLEL_ENABLED -ne 'true') { return $false }
    $minDuration = if ($env:CONVERT_CHUNK_MIN_DURATION_SECS) { [double]$env:CONVERT_CHUNK_MIN_DURATION_SECS } else { 3600 }
    $dur = Get-VesChunkSourceDuration -Source $Source -FfprobePath $FfprobePath
    if (-not $dur) { return $false }
    return ($dur -ge $minDuration)
}

function Get-VesChunkSourceDuration {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    try {
        $out = & $FfprobePath -v error -show_entries format=duration -of csv=print_section=0 -- $Source 2>$null
        if ($out) { return [double]($out.Trim()) }
    } catch { }
    return $null
}

function Get-VesChunkKeyframeTimestamps {
    <#
    .SYNOPSIS
    Real keyframe timestamps on the SOURCE (not the eventual encoded
    output), via ffprobe -skip_frame nokey. -of csv=print_section=0 still
    emits a trailing comma after the single field on every line (found
    via a real live test of the bash module against an actual 6674s
    movie, ported here proactively rather than waiting to hit the same
    bug independently) -- stripped below.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $lines = & $FfprobePath -v error -select_streams v:0 -skip_frame nokey `
        -show_entries frame=pts_time -of csv=print_section=0 -- $Source 2>$null
    return @($lines | ForEach-Object { $_.TrimEnd(',') } | Where-Object { $_ })
}

function Get-VesChunkSplitBoundaries {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    $target = if ($env:CONVERT_CHUNK_TARGET_SECS) { [double]$env:CONVERT_CHUNK_TARGET_SECS } else { 600 }
    $dur = Get-VesChunkSourceDuration -Source $Source -FfprobePath $FfprobePath
    if (-not $dur) { return @() }

    $boundaries = [System.Collections.Generic.List[double]]::new()
    $boundaries.Add(0)
    $nextTarget = $target
    foreach ($tsStr in (Get-VesChunkKeyframeTimestamps -Source $Source -FfprobePath $FfprobePath)) {
        $ts = [double]$tsStr
        if ($ts -ge $nextTarget) {
            $boundaries.Add($ts)
            $nextTarget = $ts + $target
        }
    }
    return $boundaries
}

function New-VesChunkManifest {
    <#
    .SYNOPSIS
    Creates the manifest directory + one boundary file per chunk.
    Idempotent -- if a complete manifest already exists (a ".complete"
    marker file, written last), returns $true immediately. The
    create-the-directory race itself is gated by a claim FILE (not a
    second directory), same Windows-safe primitive as every other lock
    in this port -- whichever machine wins that file claim does the real
    (expensive, full-file ffprobe keyframe scan) work; the loser walks
    away rather than duplicating it.
    #>
    <#
    .SYNOPSIS
    Also resolves and caches the profile/codec/HDR/CRF every chunk
    encoder must use -- resolved exactly ONCE here, not independently
    per chunk (see the bash module's matching comment on why: chunks
    are pieces of one continuous encode, and independent per-chunk CRF
    search could land different chunks on different quality/bitrate).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [string]$Codec = 'av1',
        [string]$AbAv1Path,
        [double]$VmafTarget,
        [bool]$FfmpegHasLibVmaf = $true
    )
    $mdir = Get-VesChunkManifestDir -Source $Source
    $completeMarker = Join-Path $mdir '.complete'
    if (Test-Path -LiteralPath $completeMarker) { return $true }

    $splitClaimPath = "$mdir.splitting.lock"
    $token = Enter-VesSharedMutexOnce -LockPath $splitClaimPath -StaleSeconds $script:VesChunkLockStaleSeconds
    if (-not $token) { return $false }
    try {
        if (Test-Path -LiteralPath $completeMarker) { return $true }

        $boundaries = Get-VesChunkSplitBoundaries -Source $Source -FfprobePath $FfprobePath
        if ($boundaries.Count -lt 2) {
            Write-Warning "Chunk split: fewer than 2 keyframe-snapped boundaries found -- refusing to split, falling back to whole-file encode: $Source"
            return $false
        }

        if (-not (Test-Path -LiteralPath $mdir)) {
            New-Item -ItemType Directory -Path $mdir -Force | Out-Null
            Set-VesEveryoneReadWrite -Path $mdir
        }

        $n = 0
        $prevTs = $boundaries[0]
        for ($i = 1; $i -lt $boundaries.Count; $i++) {
            $ts = $boundaries[$i]
            $chunkFile = Join-Path $mdir ("chunk-{0:D3}.meta" -f $n)
            @"
index=$n
start_ts=$prevTs
end_ts=$ts
"@ | Set-Content -LiteralPath $chunkFile -Encoding utf8
            Set-VesEveryoneReadWrite -Path $chunkFile
            $n++
            $prevTs = $ts
        }
        $finalChunkFile = Join-Path $mdir ("chunk-{0:D3}.meta" -f $n)
        @"
index=$n
start_ts=$prevTs
end_ts=EOF
"@ | Set-Content -LiteralPath $finalChunkFile -Encoding utf8
        Set-VesEveryoneReadWrite -Path $finalChunkFile
        $n++

        $profile = Get-VesDetectedProfileForPath -Path $Source
        $hdrMode = Resolve-VesHdrMode -Source $Source -FfprobePath $FfprobePath
        $isHdr = $hdrMode -in @('pq', 'pq_reconstruct', 'hlg')
        $upscaleTarget = Resolve-VesUpscaleTarget -Source $Source -FfprobePath $FfprobePath
        $fixedCrf = Get-VesProfileFixedCrf -Codec $Codec -Profile $profile -IsHdr $isHdr
        $crf = Resolve-VesCrfForEncode -Source $Source -Codec $Codec -Profile $profile -IsHdr $isHdr `
            -TargetHeight $upscaleTarget -FixedCrf $fixedCrf -VmafTarget $VmafTarget -FfmpegHasLibVmaf $FfmpegHasLibVmaf `
            -AbAv1Path $AbAv1Path -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath

        $manifestFile = Join-Path $mdir 'manifest.meta'
        @"
source=$Source
chunk_count=$n
codec=$Codec
profile=$profile
hdr=$isHdr
hdr_mode=$hdrMode
crf=$crf
created_utc=$([DateTimeOffset]::UtcNow.ToString('o'))
created_host=$env:COMPUTERNAME
"@ | Set-Content -LiteralPath $manifestFile -Encoding utf8
        Set-VesEveryoneReadWrite -Path $manifestFile

        # Written LAST -- any reader that sees .complete is guaranteed
        # every chunk file already exists, same ordering guarantee the
        # bash module documents.
        New-Item -ItemType File -Path $completeMarker -Force | Out-Null
        Set-VesEveryoneReadWrite -Path $completeMarker
        Write-Host "Chunk split: $n chunk(s) created for $(Split-Path -Leaf $Source)"
        return $true
    } finally {
        Exit-VesSharedMutex -LockPath $splitClaimPath -Token $token
    }
}

function Get-VesChunkLockPath {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][int]$Index)
    $dir = Split-Path -Parent $Source
    $name = Split-Path -Leaf $Source
    return Join-Path $dir "$name.chunk$Index.lock"
}

function Enter-VesChunkClaim {
    <#
    .SYNOPSIS
    Claims one not-yet-claimed, not-yet-verified chunk for $Source.
    Returns a token object (chunk Index + LockPath + Token, pass to
    Exit-VesChunkClaim) or $null if none are available right now.
    #>
    param([Parameter(Mandatory)][string]$Source)
    $mdir = Get-VesChunkManifestDir -Source $Source
    if (-not (Test-Path -LiteralPath (Join-Path $mdir '.complete'))) { return $null }

    $chunkFiles = Get-ChildItem -LiteralPath $mdir -Filter 'chunk-*.meta' -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($f in $chunkFiles) {
        $meta = Get-Content -LiteralPath $f.FullName -Raw
        if ($meta -notmatch '(?m)^index=(\d+)') { continue }
        $idx = [int]$Matches[1]
        $statusFile = Join-Path $mdir ("chunk-{0:D3}.status" -f $idx)
        if (Test-Path -LiteralPath $statusFile) {
            $statusContent = Get-Content -LiteralPath $statusFile -Raw
            if ($statusContent -match '(?m)^status=verified') { continue }
        }
        $lockPath = Get-VesChunkLockPath -Source $Source -Index $idx
        $token = Enter-VesSharedMutexOnce -LockPath $lockPath -StaleSeconds $script:VesChunkLockStaleSeconds
        if ($token) {
            return [PSCustomObject]@{ Index = $idx; LockPath = $lockPath; Token = $token }
        }
    }
    return $null
}

function Exit-VesChunkClaim {
    param([Parameter(Mandatory)][PSCustomObject]$Claim)
    Exit-VesSharedMutex -LockPath $Claim.LockPath -Token $Claim.Token
}

function Set-VesChunkStatus {
    <#
    .SYNOPSIS
    Records a chunk's outcome. $Status is one of: encoded | verify-failed
    | verified. $Extra (optional) is additional free-form key=value lines
    -- see the bash module's own comment on why this is deliberately not
    a fixed schema (Layer 2's per-shot QP selection needs fields this
    function's current callers don't know about yet).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Status,
        [string]$Extra = ''
    )
    $mdir = Get-VesChunkManifestDir -Source $Source
    $statusFile = Join-Path $mdir ("chunk-{0:D3}.status" -f $Index)
    $lines = @(
        "status=$Status"
        "updated_utc=$([DateTimeOffset]::UtcNow.ToString('o'))"
        "updated_host=$env:COMPUTERNAME"
    )
    if ($Extra) { $lines += $Extra }
    ($lines -join "`n") | Set-Content -LiteralPath $statusFile -Encoding utf8
    Set-VesEveryoneReadWrite -Path $statusFile
}

function Test-VesChunkAllVerified {
    param([Parameter(Mandatory)][string]$Source)
    $mdir = Get-VesChunkManifestDir -Source $Source
    if (-not (Test-Path -LiteralPath (Join-Path $mdir '.complete'))) { return $false }
    $chunkFiles = Get-ChildItem -LiteralPath $mdir -Filter 'chunk-*.meta' -ErrorAction SilentlyContinue
    foreach ($f in $chunkFiles) {
        if ($f.Name -notmatch '^chunk-(\d+)\.meta$') { continue }
        $idx = [int]$Matches[1]
        $statusFile = Join-Path $mdir ("chunk-{0:D3}.status" -f $idx)
        if (-not (Test-Path -LiteralPath $statusFile)) { return $false }
        $statusContent = Get-Content -LiteralPath $statusFile -Raw
        if ($statusContent -notmatch '(?m)^status=verified') { return $false }
    }
    return $true
}

Export-ModuleMember -Function Get-VesChunkManifestDir, Test-VesChunkShouldSplit, Get-VesChunkSourceDuration, `
    Get-VesChunkSplitBoundaries, New-VesChunkManifest, Get-VesChunkLockPath, Enter-VesChunkClaim, `
    Exit-VesChunkClaim, Set-VesChunkStatus, Test-VesChunkAllVerified
