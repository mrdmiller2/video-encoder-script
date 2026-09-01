# Windows port of modules/ves-chunk-verify.sh -- Phase 3 verifier +
# concatenator for the chunk-parallel pipeline. Per-chunk verification is
# structural/decode-only; the quality gate is a single whole-file sequential
# VMAF pass on the assembled output against the true source.

if (-not (Get-Module -Name VesTimeoutRetry)) {
    Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
}
if (-not (Get-Module -Name VesDoneLog)) {
    Import-Module (Join-Path $PSScriptRoot 'VesDoneLog.psm1') -Force
}
if (-not (Get-Module -Name VesValidation)) {
    Import-Module (Join-Path $PSScriptRoot 'VesValidation.psm1') -Force
}
if (-not (Get-Module -Name VesChunkCoordinator)) {
    Import-Module (Join-Path $PSScriptRoot 'VesChunkCoordinator.psm1') -Force
}
if (-not (Get-Module -Name VesVmafCrfSearch)) {
    Import-Module (Join-Path $PSScriptRoot 'VesVmafCrfSearch.psm1') -Force
}

function Get-VesChunkMetaValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $pattern = '(?m)^{0}=(.*)$' -f [regex]::Escape($Key)
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -match $pattern) { return $Matches[1].Trim() }
    return $null
}

function Get-VesChunkOutputPath {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$Index
    )
    $mdir = Get-VesChunkManifestDir -Source $Source
    return Join-Path $mdir ("chunk-{0:D3}.output.mkv" -f $Index)
}

function Get-VesChunkCanonicalOutputPath {
    param(
        [Parameter(Mandatory)][string]$Source,
        [string]$OutputSuffix = '.AV1-WIN'
    )
    $dir = Split-Path -Parent $Source
    $title = [System.IO.Path]::GetFileNameWithoutExtension($Source)
    return Join-Path $dir "$title$OutputSuffix.mkv"
}

function Test-VesChunkOutputDecodesClean {
    <#
    .SYNOPSIS
    Cheap structural check: decodes a chunk or concatenated output from
    start to finish with ffmpeg -v error. Retries once after a failure,
    matching the bash verifier's transient-load false-positive fix.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [int]$TimeoutSeconds = 900,
        [int]$RetryDelaySeconds = 20
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path -Force).Length -le 0) { return $false }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $result = Invoke-VesWithTimeoutRetry -FilePath $FfmpegPath `
            -ArgumentList @('-v', 'error', '-i', $Path, '-f', 'null', '-') `
            -TimeoutSeconds $TimeoutSeconds -MaxRetries 0
        if (-not $result.TimedOut -and $result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.StdErr)) {
            return $true
        }
        if ($attempt -eq 1 -and $RetryDelaySeconds -gt 0) {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    return $false
}

function Test-VesChunkPending {
    <#
    .SYNOPSIS
    Scans one manifest for status=encoded chunks and transitions each to
    verified or needs-requeue. Idempotent; already-verified and already-
    queued chunks are left untouched.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath
    )
    $mdir = Get-VesChunkManifestDir -Source $Source
    if (-not (Test-Path -LiteralPath (Join-Path $mdir '.complete') -PathType Leaf)) { return $false }

    $chunkFiles = Get-ChildItem -LiteralPath $mdir -Filter 'chunk-*.meta' -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($f in $chunkFiles) {
        $idxText = Get-VesChunkMetaValue -Path $f.FullName -Key 'index'
        $idx = 0
        if (-not [int]::TryParse($idxText, [ref]$idx)) { continue }
        $statusFile = Join-Path $mdir ("chunk-{0:D3}.status" -f $idx)
        if (-not (Test-Path -LiteralPath $statusFile -PathType Leaf)) { continue }
        $status = Get-VesChunkMetaValue -Path $statusFile -Key 'status'
        if ($status -ne 'encoded') { continue }

        $out = Get-VesChunkOutputPath -Source $Source -Index $idx
        if (Test-VesChunkOutputDecodesClean -Path $out -FfmpegPath $FfmpegPath) {
            Set-VesChunkStatus -Source $Source -Index $idx -Status 'verified' -Extra "output=$out"
            Write-Host "Chunk $idx verified (structural): $([System.IO.Path]::GetFileName($Source))"
        } else {
            Set-VesChunkStatus -Source $Source -Index $idx -Status 'needs-requeue' -Extra "output=$out`nreason=decode-error"
            Write-Warning "Chunk $idx failed structural verification (will be retried): $([System.IO.Path]::GetFileName($Source))"
        }
    }
    return $true
}

function Invoke-VesMkvMergeConcat {
    param(
        [Parameter(Mandatory)][string]$MkvmergePath,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string[]]$Parts,
        [int]$TimeoutSeconds = 86400
    )
    if ($Parts.Count -lt 1) { return [PSCustomObject]@{ Ok = $false; Output = 'no parts' } }
    $args = @('-o', $Output, $Parts[0])
    for ($i = 1; $i -lt $Parts.Count; $i++) {
        $args += "+$($Parts[$i])"
    }
    $result = Invoke-VesWithTimeoutRetry -FilePath $MkvmergePath -ArgumentList $args -TimeoutSeconds $TimeoutSeconds -MaxRetries 0
    return [PSCustomObject]@{ Ok = (-not $result.TimedOut -and $result.ExitCode -eq 0); Output = (($result.StdOut + $result.StdErr).Trim()) }
}

function Complete-VesChunkManifest {
    <#
    .SYNOPSIS
    Once all chunks are verified, concatenates them in manifest order,
    runs structural validation, strict decode, then sequential whole-file
    VMAF before promoting the file to the canonical Windows output path.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$MkvmergePath,
        [string]$MkvalidatorPath,
        [double]$VmafTarget = 90.0,
        [int]$TargetHeight = 0,
        [string]$OutputSuffix = '.AV1-WIN'
    )
    $mdir = Get-VesChunkManifestDir -Source $Source
    if (-not (Test-Path -LiteralPath (Join-Path $mdir '.complete') -PathType Leaf)) { return $false }
    $finalized = Join-Path $mdir '.finalized'
    if (Test-Path -LiteralPath $finalized -PathType Leaf) { return $true }
    if (-not (Test-VesChunkAllVerified -Source $Source)) { return $false }

    $outFinal = Get-VesChunkCanonicalOutputPath -Source $Source -OutputSuffix $OutputSuffix
    if (Test-Path -LiteralPath $outFinal -PathType Leaf) {
        Write-Host "Chunk-parallel: canonical output already exists, nothing to finalize: $outFinal"
        New-Item -ItemType File -Path $finalized -Force | Out-Null
        Set-VesEveryoneReadWrite -Path $finalized
        return $true
    }

    $parts = @()
    $chunkFiles = Get-ChildItem -LiteralPath $mdir -Filter 'chunk-*.meta' -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($f in $chunkFiles) {
        $idxText = Get-VesChunkMetaValue -Path $f.FullName -Key 'index'
        $idx = 0
        if (-not [int]::TryParse($idxText, [ref]$idx)) { continue }
        $parts += (Get-VesChunkOutputPath -Source $Source -Index $idx)
    }
    if ($parts.Count -lt 1) {
        Write-Warning "Chunk-parallel finalize: no chunk outputs found: $Source"
        return $false
    }
    foreach ($p in $parts) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            Write-Warning "Chunk-parallel finalize: missing chunk output: $p"
            return $false
        }
    }

    $concatTmp = Join-Path $mdir ".concat.$PID.mkv"
    $merge = Invoke-VesMkvMergeConcat -MkvmergePath $MkvmergePath -Output $concatTmp -Parts $parts
    if (-not $merge.Ok) {
        Write-Warning "Chunk-parallel finalize: mkvmerge concat failed: $Source -- $($merge.Output)"
        Remove-Item -LiteralPath $concatTmp -Force -ErrorAction SilentlyContinue
        return $false
    }

    if ($MkvalidatorPath) {
        $structOk = Test-VesMkvStructureValid -Path $concatTmp -MkvalidatorPath $MkvalidatorPath
        if ($structOk -eq $false) {
            Write-Warning "Chunk-parallel finalize: concatenated output failed structural validation, leaving chunks in place for review: $Source"
            Remove-Item -LiteralPath $concatTmp -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    $srcDur = Get-VesMediaDurationSeconds -Path $Source -FfprobePath $FfprobePath
    $dstDur = Get-VesMediaDurationSeconds -Path $concatTmp -FfprobePath $FfprobePath
    if (-not (Test-VesDurationsMatch -DurationA $srcDur -DurationB $dstDur -ToleranceSeconds 2.0)) {
        Write-Warning "Chunk-parallel finalize: concatenated output duration mismatch (src=$srcDur dst=$dstDur): $Source"
        Remove-Item -LiteralPath $concatTmp -Force -ErrorAction SilentlyContinue
        return $false
    }

    if (-not (Test-VesChunkOutputDecodesClean -Path $concatTmp -FfmpegPath $FfmpegPath)) {
        Write-Warning "Chunk-parallel finalize: concatenated output failed strict decode check -- leaving chunks in place for review: $([System.IO.Path]::GetFileName($Source))"
        Remove-Item -LiteralPath $concatTmp -Force -ErrorAction SilentlyContinue
        return $false
    }

    $vmafScore = Get-VesFinalVmaf -Source $Source -Output $concatTmp -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath -TargetHeight $TargetHeight -Sequential -TimeoutSeconds 86400
    if ($null -eq $vmafScore) {
        Write-Warning "Chunk-parallel finalize: VMAF measurement failed, leaving chunks in place for review: $Source"
        Remove-Item -LiteralPath $concatTmp -Force -ErrorAction SilentlyContinue
        return $false
    }
    if ($vmafScore -lt $VmafTarget) {
        Write-Warning "Chunk-parallel finalize: VMAF $vmafScore below target $VmafTarget -- leaving chunks in place, NOT promoting to canonical output: $Source"
        Remove-Item -LiteralPath $concatTmp -Force -ErrorAction SilentlyContinue
        return $false
    }

    Move-Item -LiteralPath $concatTmp -Destination $outFinal -Force
    Set-VesEveryoneReadWrite -Path $outFinal
    Write-Host "Chunk-parallel finalize: $([System.IO.Path]::GetFileName($Source)) assembled and validated (VMAF $vmafScore >= $VmafTarget) -> $outFinal"
    New-Item -ItemType File -Path $finalized -Force | Out-Null
    Set-VesEveryoneReadWrite -Path $finalized

    foreach ($p in $parts) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Invoke-VesChunkVerifierScanOnce {
    <#
    .SYNOPSIS
    One verifier-daemon pass over one or more roots: verifies encoded
    chunks and finalizes manifests that became fully verified.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$MkvmergePath,
        [string]$MkvalidatorPath,
        [double]$VmafTarget = 90.0,
        [int]$TargetHeight = 0,
        [string]$OutputSuffix = '.AV1-WIN'
    )
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $manifests = Get-ChildItem -LiteralPath $root -Directory -Recurse -Filter '*.chunks' -ErrorAction SilentlyContinue
        foreach ($mdir in $manifests) {
            if (Test-Path -LiteralPath (Join-Path $mdir.FullName '.finalized') -PathType Leaf) { continue }
            $manifestFile = Join-Path $mdir.FullName 'manifest.meta'
            if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) { continue }
            $src = Get-VesChunkMetaValue -Path $manifestFile -Key 'source'
            if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
            Test-VesChunkPending -Source $src -FfmpegPath $FfmpegPath | Out-Null
            if (Test-VesChunkAllVerified -Source $src) {
                Complete-VesChunkManifest -Source $src -FfmpegPath $FfmpegPath -FfprobePath $FfprobePath `
                    -MkvmergePath $MkvmergePath -MkvalidatorPath $MkvalidatorPath -VmafTarget $VmafTarget `
                    -TargetHeight $TargetHeight -OutputSuffix $OutputSuffix | Out-Null
            }
        }
    }
}

Export-ModuleMember -Function Get-VesChunkOutputPath, Get-VesChunkCanonicalOutputPath, `
    Test-VesChunkOutputDecodesClean, Test-VesChunkPending, Complete-VesChunkManifest, `
    Invoke-VesChunkVerifierScanOnce
