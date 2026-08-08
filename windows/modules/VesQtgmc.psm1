# Windows port of modules/ves-qtgmc.sh -- QTGMC (VapourSynth) real
# field-based deinterlace as a pipeline pre-process stage, for
# confidently-detected genuine interlace within the vintage profile.
#
# Scope is identical to the bash/macOS module (see that file's header and
# project_qtgmc_merit_test_2026_08_07 memory for the full reasoning): only
# QTGMC's real field-based deinterlace (classic havsfunc.py QTGMC,
# InputType=0 -- genuine bob+weave motion-compensated deinterlace) for the
# `interlaced` field_mode tier. Never QTGMC's InputType=2/3 "progressive
# repair" mode (a separate, manual, human-invoked tool, not part of this
# auto-detect path). Never the `telecine` tier (ffmpeg-native
# fieldmatch/decimate territory, not QTGMC).
#
# Toolchain installed by fleet-tools/install-qtgmc-windows.ps1 under
# $env:USERPROFILE\qtgmc -- portable embeddable Python + a real pip-
# installed VapourSynth wheel, so (confirmed via direct inspection on
# ELVIS, 2026-08-07) every plugin (mvtools/znedi3/fmtconv/bestsource/
# removegrain/miscfilters) sits under VapourSynth's own plugin-autoload
# directory and loads automatically on `import vapoursynth` -- unlike the
# Linux/macOS from-source builds, no explicit core.std.LoadPlugin() calls
# are needed here at all.
#
# Every real bug found and fixed in the bash/macOS module during this
# project's multi-tool review (2026-08-07) is addressed here from the
# start, not retrofitted:
#   - ChromaEdi='none' is never used (confirmed real chroma-corruption bug
#     on the other platforms -- see project_qtgmc_phase_bc_wiring_2026_08_07
#     memory). Leaving ChromaEdi unset mirrors EdiMode (NNEDI3) for chroma.
#   - Source path is passed via a process environment variable
#     (QTGMC_SRC_PATH), read with os.environ[...] in the generated script,
#     never shell/string-interpolated into Python source text -- a path
#     containing a single quote can't break anything.
#   - Mod-4 height padding (AddBorders/Crop) around the QTGMC call, same
#     real-world trigger as the other platforms (a genuinely-interlaced
#     source cropped to a height not divisible by 4).
#   - SAR/DAR (anamorphic aspect ratio) is read from the real source via
#     ffprobe and stamped onto the intermediate via a `setsar` filter (NOT
#     `-aspect`, which sets DAR not SAR -- confirmed by direct testing),
#     so a real anamorphic source doesn't silently reset to square pixels.
#   - FPSDivisor=1 (explicit): full bob output, genuine field-rate
#     doubling, no temporal data blended/discarded -- confirmed intended
#     behavior with the user, not an oversight.

if (-not (Get-Module -Name VesSourceTraits)) {
    Import-Module (Join-Path $PSScriptRoot 'VesSourceTraits.psm1') -Force
}

$script:QtgmcHome = if ($env:QTGMC_HOME) { $env:QTGMC_HOME } else { Join-Path $env:USERPROFILE 'qtgmc' }
$script:QtgmcAvailableCached = $null

function Test-VesQtgmcAvailable {
    <#
    .SYNOPSIS
    Port of qtgmc_available(). Returns $true if the QTGMC toolchain is
    fully installed and importable on this machine, $false otherwise.
    Cached after the first call within a process.
    #>
    param(
        [int]$TimeoutSeconds = 30
    )
    if ($null -ne $script:QtgmcAvailableCached) {
        return $script:QtgmcAvailableCached
    }

    $py = Join-Path $script:QtgmcHome 'python.exe'
    $havsfunc = Join-Path $script:QtgmcHome 'havsfunc_classic.py'
    if (-not (Test-Path $py) -or -not (Test-Path $havsfunc)) {
        $script:QtgmcAvailableCached = $false
        return $false
    }

    $probeScript = @'
import vapoursynth as vs
core = vs.core
assert hasattr(core, 'mv') or hasattr(core, 'znedi3')
import havsfunc_classic
assert hasattr(havsfunc_classic, 'QTGMC')
'@
    $probeFile = Join-Path ([System.IO.Path]::GetTempPath()) "ves-qtgmc-probe-$PID.py"
    Set-Content -Path $probeFile -Value $probeScript -NoNewline
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $py
        $psi.ArgumentList.Add($probeFile)
        $psi.EnvironmentVariables['PYTHONPATH'] = $script:QtgmcHome
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) {
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit()
            $script:QtgmcAvailableCached = $false
            return $false
        }
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        $script:QtgmcAvailableCached = ($proc.ExitCode -eq 0)
        return $script:QtgmcAvailableCached
    } finally {
        Remove-Item -Path $probeFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-VesSampleAspectRatioArgs {
    <#
    .SYNOPSIS
    Reads $Source's real SAR via ffprobe and returns a `-vf setsar=...`
    arg pair to stamp onto the QTGMC intermediate, or an empty array for
    1:1/unset SAR. See this module's header for why: QTGMC's intermediate
    carries no SAR of its own, which would silently reset a real
    anamorphic source's display aspect to square pixels.

    NOT `-aspect $sar` (an earlier version of this function) -- confirmed
    by team review and a direct empirical test, ffmpeg's `-aspect` sets
    *display* aspect ratio (DAR), not sample aspect ratio (SAR): `-aspect
    8:9` on a 720x480 frame produced sample_aspect_ratio=16:27 (wrong) and
    display_aspect_ratio=8:9, while `-vf setsar=8/9` correctly produced
    sample_aspect_ratio=8:9 and the correctly-derived
    display_aspect_ratio=4:3. Same class of bug as this session's
    ChromaEdi finding -- a plausible-looking "fix" that would never show
    up in a duration/codec/frame-count check, only in the real stored
    SAR/DAR values.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FfprobePath,
        [int]$TimeoutSeconds = 30
    )
    if (-not (Get-Module -Name VesTimeoutRetry)) {
        Import-Module (Join-Path $PSScriptRoot 'VesTimeoutRetry.psm1') -Force
    }
    $result = Invoke-VesWithTimeoutRetry -FilePath $FfprobePath -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=sample_aspect_ratio', '-of', 'csv=p=0', $Source
    ) -TimeoutSeconds $TimeoutSeconds -MaxRetries 1
    if ($result.TimedOut -or $result.ExitCode -ne 0) { return @() }
    $sar = ($result.StdOut -split "`n" | Select-Object -First 1).Trim()
    if (-not $sar -or $sar -eq '0:1' -or $sar -eq '1:1' -or $sar -notmatch ':') { return @() }
    return @('-vf', "setsar=$($sar -replace ':', '/')")
}

function Invoke-VesQtgmcDeinterlace {
    <#
    .SYNOPSIS
    Port of qtgmc_deinterlace_to_intermediate(). Runs QTGMC's real
    field-based deinterlace on $Source, staged under $StageDir, and
    returns the resulting lossless intermediate's path on success, or
    $null on any failure (caller must fall back to bwdif -- never treat
    $null as "skip deinterlacing", matching the bash module's contract).

    Only ever call this for FieldMode=interlaced -- see this module's
    header for why telecine/progressive/ambiguous must never reach here.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FieldOrder,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath,
        [Parameter(Mandatory)][string]$StageDir,
        [int]$TimeoutSeconds = 3600
    )
    if (-not (Test-VesQtgmcAvailable)) {
        Write-Warning "QTGMC toolchain not available on this machine -- falling back to bwdif for: $Source"
        return $null
    }

    $py = Join-Path $script:QtgmcHome 'python.exe'
    $vspipe = Join-Path $script:QtgmcHome 'Lib\site-packages\vapoursynth\vspipe.exe'
    if (-not (Test-Path $vspipe)) {
        Write-Warning "vspipe.exe not found at $vspipe -- falling back to bwdif for: $Source"
        return $null
    }

    $jobStageDir = Join-Path $StageDir ".convert-stage-qtgmc-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        New-Item -ItemType Directory -Path $jobStageDir -Force | Out-Null
    } catch {
        Write-Warning "Could not create QTGMC staging dir -- falling back to bwdif for: $Source"
        return $null
    }

    $scriptPath = Join-Path $jobStageDir 'qtgmc.py'
    $intermediate = Join-Path $jobStageDir 'qtgmc-deinterlaced.mkv'
    $stderrLog = Join-Path $jobStageDir 'qtgmc.log'
    $tffBool = if ($FieldOrder -eq 'bff') { 'False' } else { 'True' }

    # KNOWN LIMITATION, deliberately not fixed yet (matches the bash/macOS
    # module): always downconverts to 8-bit even for a genuinely >8-bit
    # source. No real vintage source tested on this project so far was
    # ever >8-bit -- do not "fix" this blind without real 10-bit
    # interlaced test footage and the same raw-pixel + rendered-frame
    # verification that caught the ChromaEdi bug.
    $pyScript = @"
import sys, os
sys.path.insert(0, r'$script:QtgmcHome')
import vapoursynth as vs
core = vs.core
import havsfunc_classic as hf
src = core.bs.VideoSource(source=os.environ['QTGMC_SRC_PATH'])
src8 = core.resize.Bicubic(src, format=vs.YUV420P8) if src.format.bits_per_sample != 8 else src
_pad_h = (4 - (src8.height % 4)) % 4
if _pad_h:
    src8 = core.std.AddBorders(src8, bottom=_pad_h)
# InputType=0: real field-based deinterlace. FPSDivisor=1: full bob
# output (e.g. 25i -> 50p), every real field kept as its own distinct
# temporal sample -- no data discarded/blended, consistent with this
# project's #1 priority (no data loss) outranking #3 (size). No
# ChromaEdi override -- mirrors EdiMode (NNEDI3) for chroma too; see
# this module's header for why ChromaEdi='none' is a real, confirmed bug.
out = hf.QTGMC(src8, Preset='Slower', InputType=0, TFF=$tffBool, FPSDivisor=1, EdiMode='NNEDI3')
if _pad_h:
    out = core.std.Crop(out, bottom=_pad_h)
out.set_output()
"@
    Set-Content -Path $scriptPath -Value $pyScript -NoNewline

    Write-Host "QTGMC real deinterlace (field_order=$FieldOrder): $Source"
    $sarArgs = Get-VesSampleAspectRatioArgs -Source $Source -FfprobePath $FfprobePath

    $vspipePsi = New-Object System.Diagnostics.ProcessStartInfo
    $vspipePsi.FileName = $vspipe
    foreach ($a in @('-c', 'y4m', $scriptPath, '-')) { $vspipePsi.ArgumentList.Add($a) }
    $vspipePsi.EnvironmentVariables['QTGMC_SRC_PATH'] = $Source
    $vspipePsi.RedirectStandardOutput = $true
    $vspipePsi.RedirectStandardError = $true
    $vspipePsi.UseShellExecute = $false
    $vspipePsi.CreateNoWindow = $true

    $ffmpegPsi = New-Object System.Diagnostics.ProcessStartInfo
    $ffmpegPsi.FileName = $FfmpegPath
    $ffArgs = @('-y', '-v', 'error', '-i', '-') + $sarArgs + @('-c:v', 'libx264', '-crf', '0', '-preset', 'veryfast', '-an', $intermediate)
    foreach ($a in $ffArgs) { $ffmpegPsi.ArgumentList.Add($a) }
    $ffmpegPsi.RedirectStandardInput = $true
    $ffmpegPsi.RedirectStandardError = $true
    $ffmpegPsi.UseShellExecute = $false
    $ffmpegPsi.CreateNoWindow = $true

    $vspipeProc = $null; $ffmpegProc = $null
    $ok = $false
    try {
        $vspipeProc = [System.Diagnostics.Process]::Start($vspipePsi)
        $ffmpegProc = [System.Diagnostics.Process]::Start($ffmpegPsi)

        $vspipeStderrTask = $vspipeProc.StandardError.ReadToEndAsync()
        $ffmpegStderrTask = $ffmpegProc.StandardError.ReadToEndAsync()
        # Raw byte-stream copy, not PowerShell's object pipeline -- the
        # y4m stream is binary and must never pass through PS's
        # text/object marshaling.
        $copyTask = $vspipeProc.StandardOutput.BaseStream.CopyToAsync($ffmpegProc.StandardInput.BaseStream)

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not $copyTask.IsCompleted -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        if (-not $copyTask.IsCompleted) {
            try { $vspipeProc.Kill($true) } catch { }
            try { $ffmpegProc.Kill($true) } catch { }
        }
        try { $ffmpegProc.StandardInput.Close() } catch { }

        # Real bug found via direct testing on ELVIS, 2026-08-07: .NET's
        # Process.WaitForExit(int)/Task.WaitAll(..., int) both RETURN a
        # bool -- unsuppressed, that return value leaks onto this
        # function's own output pipeline right alongside the real
        # `return $intermediate` below, and PowerShell silently joins
        # everything not otherwise captured into the caller's result
        # (confirmed: caller received "True True True <path>" as a single
        # string instead of just the path). Capture (not `[void]`-discard)
        # both WaitForExit results -- team review, 2026-08-07 found the
        # `[void]` version silently ignored a genuine hang: if the copy
        # finished but ffmpeg then hung flushing/muxing, WaitForExit could
        # return false (still running) and the code fell straight into
        # reading .ExitCode on a still-live process without ever killing
        # it, leaking an orphan ffmpeg process holding the intermediate
        # file open.
        $vspipeExited = $vspipeProc.WaitForExit([int]([math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)))
        $ffmpegExited = $ffmpegProc.WaitForExit([int]([math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)))
        if (-not $vspipeExited) { try { $vspipeProc.Kill($true) } catch { }; $vspipeProc.WaitForExit() }
        if (-not $ffmpegExited) { try { $ffmpegProc.Kill($true) } catch { }; $ffmpegProc.WaitForExit() }
        [void][System.Threading.Tasks.Task]::WaitAll(@($vspipeStderrTask, $ffmpegStderrTask), 5000)

        $combinedLog = "--- vspipe stderr ---`n$($vspipeStderrTask.Result)`n--- ffmpeg stderr ---`n$($ffmpegStderrTask.Result)"
        Set-Content -Path $stderrLog -Value $combinedLog -ErrorAction SilentlyContinue

        # Real bug found by team review, 2026-08-07: only ffmpeg's exit
        # code was checked. If vspipe crashes partway through (e.g. a
        # VapourSynth exception mid-render), it can still emit a partial
        # y4m stream; ffmpeg sees that as a normal EOF, exits 0, and
        # writes a real non-empty (but truncated) MKV -- this branch would
        # have returned that truncated intermediate as if QTGMC had fully
        # succeeded instead of falling back to bwdif.
        $ok = $vspipeExited -and $ffmpegExited -and ($vspipeProc.ExitCode -eq 0) -and ($ffmpegProc.ExitCode -eq 0) `
            -and -not $copyTask.IsFaulted -and -not $copyTask.IsCanceled `
            -and (Test-Path $intermediate) -and ((Get-Item $intermediate).Length -gt 0)
    } catch {
        Write-Warning "QTGMC deinterlace threw an exception ($($_.Exception.Message)) -- falling back to bwdif for: $Source"
        $ok = $false
    } finally {
        if ($vspipeProc) { $vspipeProc.Dispose() }
        if ($ffmpegProc) { $ffmpegProc.Dispose() }
    }

    if (-not $ok) {
        Write-Warning "QTGMC deinterlace failed (see $stderrLog) -- falling back to bwdif for: $Source"
        Remove-Item -Path $jobStageDir -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    return $intermediate
}

Export-ModuleMember -Function Test-VesQtgmcAvailable, Invoke-VesQtgmcDeinterlace, Get-VesSampleAspectRatioArgs
