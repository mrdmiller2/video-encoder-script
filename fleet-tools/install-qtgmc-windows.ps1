# install-qtgmc-windows.ps1 -- installs the QTGMC (VapourSynth) toolchain
# on a Windows fleet machine, for vintage-profile decombing. Idempotent:
# safe to re-run, skips steps whose output already exists.
#
# Proven working on PRINCE, 2026-08-07. Windows turned out to be the
# EASIEST platform for this, contrary to expectations going in -- unlike
# Linux/macOS, every plugin QTGMC needs (mvtools, znedi3, nnedi3 weights,
# miscfilters, removegrain) is a real vsrepo package with a prebuilt
# Windows binary, no from-source build required for anything but the
# VapourSynth core setup itself (which is also just download+unzip, no
# compiler needed at all).
#
# Mirrors the official VapourSynth "Install-Portable-VapourSynth-R79.ps1"
# bootstrap (a self-contained embeddable-Python + wheel install, no system
# Python needed), then layers vsrepo-managed plugins and the classic
# havsfunc.py on top (same classic-not-modern-akarin-based approach as the
# other platforms -- see project_qtgmc_merit_test_2026_08_07 memory for why).
#
# Usage: pwsh -NoProfile -File install-qtgmc-windows.ps1
# Verify afterwards: pwsh -NoProfile -File install-qtgmc-windows.ps1 -Verify

param(
    [switch]$Verify
)

$ErrorActionPreference = "Stop"
$QtgmcHome = "$env:USERPROFILE\qtgmc"
$PyVer = "3.14.0"
$VSVersion = "79"
$HavsfuncCommit = "771ef4b5cac89aa985f40786e9eaf82cbdabc888"

function Log($msg) { Write-Host "[install-qtgmc] $msg" }

if ($Verify) {
    Log "Verifying existing install at $QtgmcHome"
    $py = "$QtgmcHome\python.exe"
    if (-not (Test-Path $py)) { Write-Host "MISSING: python.exe"; exit 1 }
    if (-not (Test-Path "$QtgmcHome\havsfunc_classic.py")) { Write-Host "MISSING: havsfunc_classic.py"; exit 1 }
    $verifyScript = @"
import vapoursynth as vs
core = vs.core
assert hasattr(core, 'mv'), 'mvtools not loaded'
assert hasattr(core, 'znedi3'), 'znedi3 not loaded'
assert hasattr(core, 'rgvs'), 'removegrain not loaded'
assert hasattr(core, 'misc'), 'miscfilters not loaded'
assert hasattr(core, 'fmtc'), 'fmtconv not loaded'
assert hasattr(core, 'bs'), 'bestsource not loaded'
import sys
sys.path.insert(0, r'$QtgmcHome')
import havsfunc_classic as hf
assert hasattr(hf, 'QTGMC'), 'QTGMC function not found'
print('OK: all plugins load, QTGMC importable')
"@
    $verifyScript | & $py -
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Verify FAILED (python exited $LASTEXITCODE)"
        exit 1
    }
    Log "Verify passed."
    exit 0
}

New-Item -ItemType Directory -Force -Path $QtgmcHome | Out-Null
$DownloadDir = "$QtgmcHome\vs-temp-dl"
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
$ProgressPreference = 'SilentlyContinue'

# --- Portable Python + VapourSynth core (mirrors the official bootstrap) ---
if (-not (Test-Path "$QtgmcHome\python.exe")) {
    Log "Downloading embeddable Python $PyVer..."
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$PyVer/python-$PyVer-embed-amd64.zip" -OutFile "$DownloadDir\python-embed.zip"
    Log "Extracting Python..."
    Expand-Archive -LiteralPath "$DownloadDir\python-embed.zip" -DestinationPath $QtgmcHome -Force
    Add-Content -Path "$QtgmcHome\python314._pth" -Encoding UTF8 -Value "Lib\site-packages"

    Log "Downloading+installing pip..."
    Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile "$DownloadDir\get-pip.py"
    & "$QtgmcHome\python.exe" "$DownloadDir\get-pip.py" "--no-warn-script-location"

    Log "Downloading VapourSynth portable R$VSVersion..."
    Invoke-WebRequest -Uri "https://github.com/vapoursynth/vapoursynth/releases/download/R$VSVersion/VapourSynth64-Portable-R$VSVersion.zip" -OutFile "$DownloadDir\vs-portable.zip"
    Expand-Archive -LiteralPath "$DownloadDir\vs-portable.zip" -DestinationPath $QtgmcHome -Force

    Log "Installing VapourSynth wheel..."
    $wheel = Get-ChildItem "$QtgmcHome\wheel\*.whl" | Select-Object -First 1
    & "$QtgmcHome\python.exe" -m pip install --no-warn-script-location $wheel.FullName
} else {
    Log "Portable Python + VapourSynth already installed, skipping"
}

# --- vsrepo + plugins (every QTGMC dependency is a real vsrepo package on
#     Windows -- no from-source build needed, unlike Linux/macOS) ---
#
# vsrepo.py's own portable-install detection (`is_portable` -- note: missing
# parens in the upstream source, so it's always truthy, always takes the
# "portable" path-resolution branch regardless of environment) walks
# THREE directories up from its own location and expects to land at the
# VapourSynth portable root. That only works if vsrepo is `pip install`ed
# into site-packages (…\Lib\site-packages\vsrepo\vsrepo.py, three dirname()
# calls up = the portable root) -- a loose copy of the raw script one level
# deep computes the wrong path entirely and tries (and fails) to create
# vspackages3.json at the drive root. Install it as a real package instead
# of curling the raw file.
Log "Ensuring py7zr + tqdm (vsrepo's own dependencies) are installed..."
& "$QtgmcHome\python.exe" -m pip install --no-warn-script-location py7zr tqdm

# vsrepo.py's own `is_portable()` check walks exactly three directories up
# from its own location and looks for `_ctypes.pyd` there to confirm it's
# sitting inside a portable Python install; `is_portable` (no call, always
# truthy -- an upstream bug) then reuses that same three-level math to place
# vspackages3.json. Both only resolve correctly if vsrepo.py itself is
# nested three levels under $QtgmcHome (mirroring where `pip install vsrepo`
# would normally land it under Lib\site-packages\vsrepo\) -- a loose copy
# one level deep computes the wrong root and tries to write
# vspackages3.json at the drive root. Nest it artificially instead of
# fighting pip (a real vsrepo pip install hit a separate `flit_core` build
# backend failure in this embeddable-Python environment).
$VsrepoDir = "$QtgmcHome\Lib\site-packages\vsrepo"
New-Item -ItemType Directory -Force -Path $VsrepoDir | Out-Null
if (-not (Test-Path "$VsrepoDir\vsrepo.py")) {
    Log "Fetching vsrepo.py..."
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/vapoursynth/vsrepo/master/src/vsrepo/vsrepo.py" -OutFile "$VsrepoDir\vsrepo.py"
}

$vsPluginCheck = @"
import vapoursynth as vs
c = vs.core
print(hasattr(c, 'mv') and hasattr(c, 'znedi3') and hasattr(c, 'rgvs') and hasattr(c, 'misc') and hasattr(c, 'fmtc') and hasattr(c, 'bs'))
"@
$pluginsPresent = ($vsPluginCheck | & "$QtgmcHome\python.exe" -) -eq "True"

if (-not $pluginsPresent) {
    Log "Installing plugins..."
    # mvtools and znedi3 have been migrated off vsrepo to real pip wheels
    # (vsrepo itself prints the redirect the first time you try) -- these
    # are plain plugin-binary wheels, unlike the modern havsfunc/vsjetpack
    # ecosystem's `pip install havsfunc` (which pulls in akarin and
    # everything that comes with it -- deliberately avoided, see
    # project_qtgmc_merit_test_2026_08_07 memory).
    # mvtools, znedi3, and fmtconv have migrated off vsrepo to real pip
    # wheels -- vsrepo itself prints the redirect the first time you try to
    # install them. removegrain and miscfilters have NOT migrated (there is
    # no `vapoursynth-removegrain` PyPI package -- confirmed, don't add it
    # back) and still need vsrepo, same as the nnedi3 weights (a plain data
    # file with no pip package at all either way). Install these as two
    # separate steps -- a single combined pip command aborts entirely if
    # any one package name doesn't resolve.
    & "$QtgmcHome\python.exe" -m pip install --no-warn-script-location vapoursynth-mvtools vapoursynth-znedi3 vapoursynth-fmtconv vapoursynth-bestsource
    # vsrepo's own post-install `update_genstubs()` step throws
    # (`ModuleNotFoundError: vsstubs`) every time in this environment --
    # cosmetic stub-file generation, not runtime-required, happens after
    # the real download/install work is already done -- don't treat it as
    # a failure.
    & "$QtgmcHome\python.exe" "$VsrepoDir\vsrepo.py" update
    & "$QtgmcHome\python.exe" "$VsrepoDir\vsrepo.py" install com.deinterlace.nnedi3.weights com.vapoursynth.removegrainvs com.vapoursynth.misc
} else {
    Log "Plugins already installed, skipping"
}

# --- classic havsfunc.py (pinned commit -- master/main both 404) + patches
#     (same 3 fixes as Linux/macOS: guard mvsfunc/adjust imports, strip
#     mvtools _lambda/_global kwargs, guard the eager eedi3 fallback) ---
if (-not (Test-Path "$QtgmcHome\havsfunc_classic.py")) {
    Log "Fetching classic havsfunc.py (commit $HavsfuncCommit)..."
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/HomeOfVapourSynthEvolution/havsfunc/$HavsfuncCommit/havsfunc.py" -OutFile "$QtgmcHome\havsfunc_classic.py"
    $patchScript = @'
import re
path = r"REPLACED_PATH"
with open(path) as f:
    content = f.read()
content = content.replace(
    "import mvsfunc as mvf\nimport adjust\n",
    "try:\n    import mvsfunc as mvf\nexcept ImportError:\n    mvf = None\ntry:\n    import adjust\nexcept ImportError:\n    adjust = None\n",
)
content = re.sub(r"_lambda=\w+,\s*", "", content)
content = re.sub(r"_global=\w+,\s*", "", content)
old = "myEEDI3 = core.eedi3m.EEDI3 if hasattr(core, 'eedi3m') else core.eedi3.eedi3"
new = "myEEDI3 = core.eedi3m.EEDI3 if hasattr(core, 'eedi3m') else (core.eedi3.eedi3 if hasattr(core, 'eedi3') else None)"
content = content.replace(old, new)
with open(path, "w") as f:
    f.write(content)
print("Patched havsfunc_classic.py")
'@
    $patchScript = $patchScript.Replace("REPLACED_PATH", "$QtgmcHome\havsfunc_classic.py")
    $patchScript | & "$QtgmcHome\python.exe" -
} else {
    Log "havsfunc_classic.py already present, skipping"
}

Remove-Item -Recurse -Force $DownloadDir -ErrorAction SilentlyContinue
Log "Install complete. Verify with: pwsh -NoProfile -File $PSCommandPath -Verify"
