# Windows port of convert-v5.0.33S.sh's pipeline-vs-batch dual mode
# (convert_library_use_pipeline/convert_scan_producer/
# convert_run_pipeline_jobs/convert_pipeline_should_start_batch, lines
# ~14174-14641). A large-library THROUGHPUT optimization, not a
# behavioral difference -- lower priority than correctness-affecting
# features, per explicit user framing.
#
# Windows deviation, deliberate: bash's background scanner is a separate
# OS process (mkfifo/file-based IPC is natural there). This port uses a
# PowerShell runspace (a background thread within the SAME process) for
# the scan producer instead of Start-Job -- VesSharedMutex.psm1's own
# header already documents Start-Job-spawned CHILD PROCESSES hitting a
# persistent Access-Denied writing to the real NAS even under the same
# Windows identity as the parent. A runspace has no such process
# boundary. This is treated as a real claim needing its own empirical
# proof, not an assumption carried over from the Start-Job finding --
# see this module's own test suite for the actual NAS-write verification.
#
# Constraint, stated explicitly per team design review: the scan
# producer requires a UNC path (\\host\share\...), never a mapped drive
# letter -- PowerShell drive-letter mappings are runspace-scoped and are
# NOT automatically inherited by a new runspace's initial session state.

if (-not (Get-Module -Name VesSharedMutex)) {
    Import-Module (Join-Path $PSScriptRoot 'VesSharedMutex.psm1') -Force
}

$script:VesPipelineFileThreshold = 500
$script:VesEncodeInspectBatchSize = 5

function Test-VesPathIsUnc {
    param([Parameter(Mandatory)][string]$Path)
    return $Path.StartsWith('\\')
}

function Test-VesShouldUsePipelineMode {
    <#
    .SYNOPSIS
    Port of convert_library_use_pipeline(): forced pipeline flag takes
    priority, then forced batch/largest-first, then "is this a network
    (UNC) path" (bash's CIFS-mount check -- a UNC path IS the Windows
    network-path convention, no separate mount-point lookup needed),
    then a fast pre-count against $PipelineFileThreshold.
    #>
    param(
        [Parameter(Mandatory)][string]$SearchPath,
        [switch]$ForcePipeline,
        [switch]$LargestFirst,
        [int]$PipelineFileThreshold = $script:VesPipelineFileThreshold,
        [string[]]$VideoExtensions = @('mkv', 'mp4', 'avi', 'm4v', 'mov', 'ts', 'wmv')
    )
    if ($ForcePipeline) { return $true }
    if ($LargestFirst) { return $false }
    if (Test-VesPathIsUnc -Path $SearchPath) { return $true }

    $count = 0
    foreach ($ext in $VideoExtensions) {
        $count += @([System.IO.Directory]::EnumerateFiles($SearchPath, "*.$ext", [System.IO.SearchOption]::AllDirectories) |
                Select-Object -First $PipelineFileThreshold).Count
        if ($count -ge $PipelineFileThreshold) { return $true }
    }
    return $false
}

function Get-VesPipelineShouldStartBatch {
    <#
    .SYNOPSIS
    Port of convert_pipeline_should_start_batch(): start an encode wave
    once $BatchSize items are queued, or flush whatever partial wave
    remains once the scan itself has finished.
    #>
    param(
        [Parameter(Mandatory)][int]$PendingCount,
        [Parameter(Mandatory)][bool]$ScanDone,
        [int]$BatchSize = $script:VesEncodeInspectBatchSize
    )
    if ($PendingCount -ge $BatchSize) { return $true }
    if ($ScanDone -and $PendingCount -gt 0) { return $true }
    return $false
}

function Start-VesScanProducer {
    <#
    .SYNOPSIS
    Port of convert_scan_producer(), run in a background runspace (NOT
    Start-Job -- see this module's header). Continuously enumerates
    video files under $SearchPath and appends each eligible path to
    $ReadyQueuePath as it's found, then creates $ScanDonePath when
    finished. Requires a UNC $SearchPath (enforced, not just
    documented) since a mapped drive letter would not resolve inside
    the runspace's own initial session state.

    Returns a handle object the caller must pass to
    Stop-VesScanProducer once done (or after receiving the scan-done
    signal) to reclaim the runspace/thread resources.
    #>
    param(
        [Parameter(Mandatory)][string]$SearchPath,
        [Parameter(Mandatory)][string]$ReadyQueuePath,
        [Parameter(Mandatory)][string]$ScanDonePath,
        [scriptblock]$ShouldQueue,
        [string[]]$VideoExtensions = @('mkv', 'mp4', 'avi', 'm4v', 'mov', 'ts', 'wmv')
    )
    if (-not (Test-VesPathIsUnc -Path $SearchPath)) {
        throw "Start-VesScanProducer requires a UNC path (\\host\share\...), got: $SearchPath -- a mapped drive letter would not resolve inside the background runspace's own session state."
    }

    $ps = [PowerShell]::Create()
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
            param($SearchPath, $ReadyQueuePath, $ScanDonePath, $VideoExtensions, $ShouldQueueDef)
            $shouldQueue = if ($ShouldQueueDef) { [scriptblock]::Create($ShouldQueueDef) } else { { $true } }
            foreach ($ext in $VideoExtensions) {
                foreach ($f in [System.IO.Directory]::EnumerateFiles($SearchPath, "*.$ext", [System.IO.SearchOption]::AllDirectories)) {
                    if (-not (& $shouldQueue $f)) { continue }
                    $attempt = 0
                    while ($attempt -lt 5) {
                        try {
                            $fs = [System.IO.File]::Open($ReadyQueuePath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                            $bytes = [System.Text.Encoding]::UTF8.GetBytes("$f`n")
                            $fs.Write($bytes, 0, $bytes.Length)
                            $fs.Close()
                            break
                        } catch {
                            $attempt++
                            Start-Sleep -Milliseconds 100
                        }
                    }
                }
            }
            [System.IO.File]::WriteAllText($ScanDonePath, 'done')
        }) | Out-Null
    [void]$ps.AddParameter('SearchPath', $SearchPath)
    [void]$ps.AddParameter('ReadyQueuePath', $ReadyQueuePath)
    [void]$ps.AddParameter('ScanDonePath', $ScanDonePath)
    [void]$ps.AddParameter('VideoExtensions', $VideoExtensions)
    [void]$ps.AddParameter('ShouldQueueDef', $(if ($ShouldQueue) { $ShouldQueue.ToString() }))

    if (Test-Path -LiteralPath $ReadyQueuePath) { [System.IO.File]::Delete($ReadyQueuePath) }
    if (Test-Path -LiteralPath $ScanDonePath) { [System.IO.File]::Delete($ScanDonePath) }
    [System.IO.File]::WriteAllText($ReadyQueuePath, '')

    $asyncResult = $ps.BeginInvoke()
    return [PSCustomObject]@{ PowerShell = $ps; Runspace = $rs; AsyncResult = $asyncResult; ScanDonePath = $ScanDonePath }
}

function Test-VesScanProducerDone {
    param([Parameter(Mandatory)][PSCustomObject]$Handle)
    return (Test-Path -LiteralPath $Handle.ScanDonePath)
}

function Stop-VesScanProducer {
    <#
    .SYNOPSIS
    Reclaims the runspace/thread. Safe to call whether or not the
    producer has finished on its own.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Handle)
    try {
        if (-not $Handle.AsyncResult.IsCompleted) {
            $Handle.PowerShell.Stop() | Out-Null
        }
        $Handle.PowerShell.EndInvoke($Handle.AsyncResult) | Out-Null
    } catch { }
    try { $Handle.PowerShell.Dispose() } catch { }
    try { $Handle.Runspace.Close(); $Handle.Runspace.Dispose() } catch { }
}

function Get-VesPipelineNewReadyItems {
    <#
    .SYNOPSIS
    Reads any lines appended to $ReadyQueuePath since the last call,
    tracked via a byte offset the caller keeps (avoids O(n^2) full-file
    rescans on a growing queue, matching bash's own stated reasoning for
    its persistent `read -u fd` approach). Pass $null/0 for
    -LastOffset on the first call.
    #>
    param(
        [Parameter(Mandatory)][string]$ReadyQueuePath,
        [long]$LastOffset = 0
    )
    if (-not (Test-Path -LiteralPath $ReadyQueuePath)) {
        return [PSCustomObject]@{ Items = @(); NewOffset = $LastOffset }
    }
    $fs = [System.IO.File]::Open($ReadyQueuePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -le $LastOffset) {
            return [PSCustomObject]@{ Items = @(); NewOffset = $LastOffset }
        }
        $fs.Seek($LastOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $newOffset = $fs.Length
        $reader = New-Object System.IO.StreamReader($fs)
        $text = $reader.ReadToEnd()
        $items = @($text -split "`n" | Where-Object { $_ })
        return [PSCustomObject]@{ Items = $items; NewOffset = $newOffset }
    } finally {
        $fs.Close()
    }
}

Export-ModuleMember -Function Test-VesPathIsUnc, Test-VesShouldUsePipelineMode, `
    Get-VesPipelineShouldStartBatch, Start-VesScanProducer, Test-VesScanProducerDone, `
    Stop-VesScanProducer, Get-VesPipelineNewReadyItems
