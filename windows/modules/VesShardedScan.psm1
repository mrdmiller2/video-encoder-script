# Windows port of convert-v5.0.33S.sh's directory-scan chunking
# (get_scan_roots/roots_need_catchup_scan/shard_for_path, lines
# ~4849-5250). Confirmed via research (2026-08-03): this is per-directory
# scan chunking to keep `find` calls small/resumable -- NOT a
# machine/hash partition scheme. Title-level collision avoidance across
# fleet machines is VesTitleLock.psm1's job, not this module's.
#
# Windows deviation, per team design review (2026-08-03): PowerShell's
# Get-ChildItem -Recurse -Depth N returns directories at EVERY level
# through N, not only exactly depth N -- doesn't match bash's
# find -mindepth N -maxdepth N. Fixed with an explicit level-by-level
# walk (Cursor's reviewed pattern) instead.

$script:VesShardExcludedDirNames = @('ffmpeg-logs', 'Deferred')

function Test-VesDirNameExcludedFromSharding {
    <#
    .SYNOPSIS
    Port of bash's hard directory exclusions in get_scan_roots() --
    missing these turns bookkeeping/log directories into false shards
    and can cause real video directories to be skipped. Dot-prefixed
    names are excluded too (matches bash's `-not -name '.*'`).
    #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name.StartsWith('.')) { return $true }
    return ($script:VesShardExcludedDirNames -contains $Name)
}

function Get-VesScanRoots {
    <#
    .SYNOPSIS
    Port of get_scan_roots(). Returns one root per shard at exactly
    -ShardDepth levels below -SearchPath (matching bash's
    find -mindepth N -maxdepth N -type d), applying the same hard
    exclusions and optional -NameGlob basename filter, sorted ordinal
    (bash's LC_ALL=C sort equivalent). Falls back to a single root
    (-SearchPath itself) if zero subdirectories exist at that depth,
    same as bash.
    #>
    param(
        [Parameter(Mandatory)][string]$SearchPath,
        [int]$ShardDepth = 1,
        [switch]$NoShard,
        [string]$NameGlob
    )

    if ($NoShard -and -not $NameGlob) {
        # Deliberately plain "return @($SearchPath)", NOT comma-wrapped.
        # PowerShell unrolls an array emitted to the output stream, so a
        # DIRECT-ASSIGNMENT caller ($x = Get-VesScanRoots ...) can get a
        # bare string instead of a 1-element array when there's only one
        # shard (confirmed via a real test on ELVIS, 2026-08-03: $x.Count
        # read 1, but $x[0] returned a single CHARACTER, since string
        # indexing silently substituted for array indexing). A leading
        # comma "fixes" that but BREAKS direct piping
        # (Get-VesScanRoots ... | ForEach-Object {...}) for the 2+-shard
        # case instead -- confirmed via a separate real, reproduced bug
        # in VesOrphanReaper.psm1's Get-VesOrphanFlagCandidates (see its
        # comment for the full mechanism). The correct fix belongs at the
        # CALL SITE: wrap with @(...) when capturing into a variable for
        # indexing/Count ($roots = @(Get-VesScanRoots ...)); pipe
        # directly (no wrapping) when enumerating.
        return @($SearchPath)
    }

    # Level-by-level walk -- after $ShardDepth iterations, $cur holds
    # directories at EXACTLY that depth, matching find -mindepth N
    # -maxdepth N (NOT PowerShell's own -Recurse -Depth N semantics,
    # which include every intermediate level too).
    $cur = @($SearchPath)
    for ($level = 1; $level -le $ShardDepth; $level++) {
        $next = New-Object System.Collections.Generic.List[string]
        foreach ($d in $cur) {
            Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-VesDirNameExcludedFromSharding -Name $_.Name) } |
                ForEach-Object { $next.Add($_.FullName) }
        }
        $cur = $next
    }

    if ($NameGlob) {
        $cur = @($cur | Where-Object { (Split-Path -Leaf $_) -like $NameGlob })
    }

    if ($cur.Count -eq 0) {
        return @($SearchPath)
    }

    # Plain return, same reasoning as above -- wrap with @(...) at the
    # call site, not here, if guaranteed array-ness is needed for a
    # direct-assignment caller.
    return @($cur | Sort-Object -Property { $_ } -CaseSensitive)
}

function Test-VesRootsNeedCatchupScan {
    <#
    .SYNOPSIS
    Port of roots_need_catchup_scan(): true if -SearchPath itself
    directly contains video-like files not captured by any subdirectory
    shard (bash's own fix for loose files sitting directly under the
    library root, not inside any per-title subdirectory).
    #>
    param(
        [Parameter(Mandatory)][string]$SearchPath,
        [string[]]$VideoExtensions = @('mkv', 'mp4', 'avi', 'm4v', 'mov', 'ts', 'wmv')
    )
    $loose = Get-ChildItem -LiteralPath $SearchPath -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $VideoExtensions -contains ($_.Extension.TrimStart('.').ToLowerInvariant()) }
    return (($loose | Measure-Object).Count -gt 0)
}

function Get-VesShardForPath {
    <#
    .SYNOPSIS
    Port of shard_for_path(): reverse-maps a source file to whichever
    scan root contains it, for resume-state logging. Path-boundary-aware
    and case-insensitive (Windows filesystem semantics) -- a naive
    string-prefix match would wrongly match "C:\A\B" as a prefix of
    "C:\A\B2" (a real gap a team design review caught before this was
    built).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string[]]$Roots
    )
    $srcFull = try { (Get-Item -LiteralPath $Source -Force -ErrorAction Stop).FullName } catch { $Source }
    $bestMatch = $null
    $bestLen = -1
    foreach ($root in $Roots) {
        $rootFull = $root.TrimEnd('\')
        $prefix = "$rootFull\"
        if ($srcFull.Length -gt $prefix.Length -and
            $srcFull.Substring(0, $prefix.Length).Equals($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($prefix.Length -gt $bestLen) {
                $bestLen = $prefix.Length
                $bestMatch = $root
            }
        }
    }
    return $bestMatch
}

Export-ModuleMember -Function Test-VesDirNameExcludedFromSharding, Get-VesScanRoots, `
    Test-VesRootsNeedCatchupScan, Get-VesShardForPath
