#!/usr/bin/env pwsh
# DvalUpscaleLib.psm1 -- Windows port of dval_upscale_lib.sh. See
# docs/D-VAL-UPSCALE-PIPELINE.md for the full design. Kept in lockstep with
# the bash original -- same sidecar JSON schema, same stage semantics, same
# "resolve fresh every call, never cache" contract for Resolve-DvalSrc.
# PowerShell's native ConvertTo-Json/ConvertFrom-Json replace the bash
# side's python3 subprocess calls for the sidecar -- same schema, simpler
# implementation given native JSON support here.

Set-StrictMode -Version Latest

function Get-DvalUpscaleSidecarPath {
    param([Parameter(Mandatory)][string]$Src)
    $dir = Split-Path -Parent $Src
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Src)
    Join-Path $dir "$base.json"
}

function Get-DvalUpscaleWorkDir {
    param([Parameter(Mandatory)][string]$Src)
    Join-Path (Split-Path -Parent $Src) 'WORK'
}

# Creates WORK\ (if missing) and writes its .plexignore FIRST, before any
# other file lands in it -- same race-closing rationale as the bash
# version: the intermediate keeps the source's original extension, so
# Plex has no other way to tell it apart from real content.
function New-DvalUpscaleWorkDir {
    param([Parameter(Mandatory)][string]$Src)
    $wd = Get-DvalUpscaleWorkDir -Src $Src
    New-Item -ItemType Directory -Path $wd -Force | Out-Null
    $ignore = Join-Path $wd '.plexignore'
    if (-not (Test-Path -LiteralPath $ignore)) {
        Set-Content -LiteralPath $ignore -Value '*' -Encoding ascii -NoNewline:$false
    }
    return $wd
}

# Reads the sidecar, or returns $null (absent/unreadable/malformed) -- a
# crash mid-write should read as "no sidecar", never as parsed garbage,
# same fail-safe contract as the bash version.
function Get-DvalUpscaleSidecar {
    param([Parameter(Mandatory)][string]$Src)
    $sc = Get-DvalUpscaleSidecarPath -Src $Src
    if (-not (Test-Path -LiteralPath $sc)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $sc -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

# Atomic write (tmp file + Move-Item, same convention as the bash
# version's tmp+mv). created_utc is preserved across updates.
function Set-DvalUpscaleSidecar {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$Stage,
        [string]$Method = '',
        [string]$Intermediate = '',
        [string]$Final = ''
    )
    $sc = Get-DvalUpscaleSidecarPath -Src $Src
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $created = $now
    $existing = Get-DvalUpscaleSidecar -Src $Src
    if ($existing -and $existing.created_utc) { $created = $existing.created_utc }
    $obj = [ordered]@{
        stage        = $Stage
        method       = $Method
        intermediate = $Intermediate
        final        = $Final
        created_utc  = $created
        updated_utc  = $now
    }
    $tmp = "$sc.$([System.Guid]::NewGuid().ToString('N')).tmp"
    try {
        ($obj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $tmp -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $sc -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# The path callers should actually use for manifest/search/survey/
# production work. Resolved fresh every call -- never cached. Falls back
# to $Src unchanged whenever the sidecar is absent, or claims a stage
# whose target file isn't actually there yet (NFS/SMB lag, a half-finished
# write) OR is zero bytes (a placeholder, not real content) -- fail safe
# to the real original rather than pointing at nothing. Same contract as
# the bash version's _dval_resolve_src().
function Resolve-DvalSrc {
    param([Parameter(Mandatory)][string]$Src)
    $sc = Get-DvalUpscaleSidecar -Src $Src
    if (-not $sc) { return $Src }
    switch ($sc.stage) {
        'final' {
            if ($sc.final -and (Test-Path -LiteralPath $sc.final) -and (Get-Item -LiteralPath $sc.final).Length -gt 0) {
                return $sc.final
            }
        }
        { $_ -in @('upscaled', 'surveying') } {
            if ($sc.intermediate -and (Test-Path -LiteralPath $sc.intermediate) -and (Get-Item -LiteralPath $sc.intermediate).Length -gt 0) {
                return $sc.intermediate
            }
        }
    }
    return $Src
}

# $true if this src already has a sidecar at "upscaled" or later -- Queue
# B's pre-check, so a title already upscaled is never re-upscaled.
function Test-DvalUpscaleAlreadyDone {
    param([Parameter(Mandatory)][string]$Src)
    $sc = Get-DvalUpscaleSidecar -Src $Src
    if (-not $sc) { return $false }
    return $sc.stage -in @('upscaled', 'surveying', 'final')
}

# $Src path -> "A" (no upscale needed), "B" (needs upscale), or "C"
# (already AV1). Cheap: a codec probe + Resolve-VesUpscaleTarget's height
# rule -- no manifest/search required. Mirrors dval_upscale_triage()
# exactly, including the "already-done stays A" rationale (the redirected
# src is what search/survey will operate on, and it's >=720p by
# construction -- re-triaging off the ORIGINAL src's now-stale height
# would misclassify it back into B).
function Get-DvalUpscaleTriage {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    if (Test-DvalUpscaleAlreadyDone -Src $Src) { return 'A' }
    try {
        $codec = (& $FfprobePath -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $Src 2>$null).Trim()
    } catch { $codec = '' }
    if ($codec -eq 'av1') { return 'C' }
    $target = Resolve-VesUpscaleTarget -Source $Src -FfprobePath $FfprobePath
    if ($target -eq 0) { return 'A' } else { return 'B' }
}

# Profile bucket -> the realesrgan-ncnn-vulkan.exe model name (-n flag
# value). Mirrors dval_upscale_model_for_profile() exactly, including the
# western-animation resolution (live-action model, NOT the anime one --
# see docs/D-VAL-UPSCALE-PIPELINE.md's 2026-09-15 bakeoff finding).
function Get-DvalUpscaleModelForProfile {
    param([Parameter(Mandatory)][string]$Profile)
    if ($Profile -match '^anime') { return 'realesrgan-x4plus-anime' }
    return 'realesrgan-x4plus'
}

# $TargetHeight (720 or 1080) -> the ffmpeg scale+pad filter string,
# matching convert-v6.0.4.sh's own production filter exactly (see
# dval_upscale_scale_filter() in dval_upscale_lib.sh).
function Get-DvalUpscaleScaleFilter {
    param([Parameter(Mandatory)][int]$TargetHeight)
    switch ($TargetHeight) {
        720 { return 'scale=1280:720:flags=lanczos:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2' }
        1080 { return 'scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2' }
        default { throw "Get-DvalUpscaleScaleFilter: unknown target height $TargetHeight" }
    }
}

# VES_UPSCALED tag -- mkvpropedit-based, same Matroska Simple-tag
# mechanism as the bash side's _mkv_write_single_tag() (which the whole
# VES_PROCESSED/VES_UPSCALED pair is built on). Standalone here rather
# than depending on a Windows port of VES_PROCESSED tagging (which does
# not exist yet -- a separate, pre-existing, already-tracked parity gap,
# not something this function needs to wait on). Requires mkvpropedit.exe
# -- deployed 2026-09-15 to D:\VES-PRINCE\tools\bin and
# D:\VES-ELVIS\tools\bin (MKVToolNix wasn't present on either Windows GPU
# host at all before this).
function Write-DvalUpscaledTag {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$MkvpropeditPath,
        [string]$Version = 'unknown'
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $tagValue = "VES $Version Upscaled - $Method"
    $escaped = $tagValue -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
    $tagFile = [System.IO.Path]::GetTempFileName()
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Tags SYSTEM "matroskatags.dtd">
<Tags>
  <Tag>
    <Targets></Targets>
    <Simple>
      <Name>VES_UPSCALED</Name>
      <String>$escaped</String>
    </Simple>
  </Tag>
</Tags>
"@
    Set-Content -LiteralPath $tagFile -Value $xml -Encoding utf8
    try {
        & $MkvpropeditPath $Path --tags 'all:' --tags "global:$tagFile" | Out-Null
        return $LASTEXITCODE -eq 0
    } finally {
        Remove-Item -LiteralPath $tagFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-DvalUpscaledTagPresent {
    <#
    .SYNOPSIS
    Mirrors mkv_ves_tag_present()'s real mechanism: ffprobe's format_tags
    entry, not mkvmerge -J. Found live 2026-09-15: mkvmerge -J's
    global_tags only reports a tag COUNT ({"num_entries": N}), never the
    actual name/value content -- it's an identification tool, not a tag
    reader. A first pass of this function used mkvmerge and always
    returned false even right after a real, verified-successful tag
    write. ffprobe's format_tags=<name> read (same call the bash version
    makes) is the one that actually works.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FfprobePath,
        [string]$VesMajor = ''
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $val = (& $FfprobePath -v error -show_entries 'format_tags=VES_UPSCALED' -of 'default=noprint_wrappers=1:nokey=1' $Path 2>$null) -join "`n"
        $val = $val.Trim()
        if (-not $val) { return $false }
        if ($VesMajor) { return $val -like "VES $VesMajor.*" }
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function `
    Get-DvalUpscaleSidecarPath, Get-DvalUpscaleWorkDir, New-DvalUpscaleWorkDir, `
    Get-DvalUpscaleSidecar, Set-DvalUpscaleSidecar, Resolve-DvalSrc, `
    Test-DvalUpscaleAlreadyDone, Get-DvalUpscaleTriage, `
    Get-DvalUpscaleModelForProfile, Get-DvalUpscaleScaleFilter, `
    Write-DvalUpscaledTag, Test-DvalUpscaledTagPresent
