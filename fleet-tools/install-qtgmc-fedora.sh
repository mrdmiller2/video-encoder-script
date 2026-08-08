#!/usr/bin/env bash
# install-qtgmc-fedora.sh -- installs the QTGMC (VapourSynth) toolchain on a
# Fedora fleet machine, for vintage-profile decombing. Idempotent: safe to
# re-run, skips steps whose output already exists.
#
# Recipe proven working on MJACKSON (Fedora 44), 2026-08-07 -- see
# project_qtgmc_merit_test_2026_08_07 memory for the full story, including
# the dead ends this script deliberately avoids:
#   - Does NOT `pip install havsfunc` (pulls in the modern vs-jetpack
#     rewrite ecosystem, whose QTempGaussMC reproducibly segfaults inside
#     the akarin JIT plugin -- confirmed via gdb, not fixed by downgrading
#     akarin). This script installs the classic single-file havsfunc.py
#     instead (pinned commit hash -- the canonical master/main branch URLs
#     404 as of this session), which needs no akarin at all.
#   - Only installs vapoursynth-bestsource from pip (source-loading plugin);
#     no other pip packages are needed for the classic script.
#
# Usage: bash install-qtgmc-fedora.sh
# Verify afterwards: bash install-qtgmc-fedora.sh --verify

set -euo pipefail

QTGMC_HOME="${QTGMC_HOME:-$HOME/qtgmc}"
BUILD_DIR="$QTGMC_HOME/build"
LIB_DIR="$QTGMC_HOME/lib"
HAVSFUNC_COMMIT="771ef4b5cac89aa985f40786e9eaf82cbdabc888"

log() { echo "[install-qtgmc] $*"; }

verify_only=false
[ "${1:-}" = "--verify" ] && verify_only=true

if [ "$verify_only" = true ]; then
  log "Verifying existing install at $QTGMC_HOME"
  test -f "$LIB_DIR/mvtools.so" || { echo "MISSING: mvtools.so"; exit 1; }
  test -f "$LIB_DIR/vsznedi3.so" || { echo "MISSING: vsznedi3.so"; exit 1; }
  test -f "$LIB_DIR/nnedi3_weights.bin" || { echo "MISSING: nnedi3_weights.bin"; exit 1; }
  test -f "$LIB_DIR/libremovegrain.so" || { echo "MISSING: libremovegrain.so"; exit 1; }
  test -f "$LIB_DIR/libmiscfilters.so" || { echo "MISSING: libmiscfilters.so"; exit 1; }
  test -f "$LIB_DIR/libfmtconv.so" || { echo "MISSING: libfmtconv.so"; exit 1; }
  test -f "$QTGMC_HOME/havsfunc_classic.py" || { echo "MISSING: havsfunc_classic.py"; exit 1; }
  python3 -c "
import vapoursynth as vs
core = vs.core
core.std.LoadPlugin('$LIB_DIR/mvtools.so')
core.std.LoadPlugin('$LIB_DIR/vsznedi3.so')
core.std.LoadPlugin('$LIB_DIR/libremovegrain.so')
core.std.LoadPlugin('$LIB_DIR/libmiscfilters.so')
core.std.LoadPlugin('$LIB_DIR/libfmtconv.so')
assert hasattr(core, 'mv'), 'mvtools not loaded'
assert hasattr(core, 'znedi3'), 'znedi3 not loaded'
assert hasattr(core, 'rgvs'), 'removegrain not loaded'
assert hasattr(core, 'misc'), 'miscfilters not loaded'
assert hasattr(core, 'fmtc'), 'fmtconv not loaded'
import sys
sys.path.insert(0, '$QTGMC_HOME')
import havsfunc_classic as hf
assert hasattr(hf, 'QTGMC'), 'QTGMC function not found'
print('OK: all plugins load, QTGMC importable')
"
  log "Verify passed."
  exit 0
fi

mkdir -p "$BUILD_DIR" "$LIB_DIR"

log "Installing system packages via dnf..."
sudo dnf install -y \
  python3-vapoursynth vapoursynth-tools vapoursynth-libs vapoursynth-devel \
  meson nasm fftw-devel automake autoconf libtool git gcc gcc-c++ pkgconf-pkg-config

log "Installing vapoursynth-bestsource (pip, --user)..."
pip3 install --user --quiet vapoursynth-bestsource

VS_INCLUDE=/usr/include/vapoursynth

# --- mvtools ---
if [ ! -f "$LIB_DIR/mvtools.so" ]; then
  log "Building vapoursynth-mvtools..."
  rm -rf "$BUILD_DIR/vapoursynth-mvtools"
  git clone --depth 1 https://github.com/dubhater/vapoursynth-mvtools.git "$BUILD_DIR/vapoursynth-mvtools"
  cd "$BUILD_DIR/vapoursynth-mvtools"
  # meson.build hardcodes `vs.get_include()`, which VapourSynth R72+'s
  # Python module no longer exposes -- point it at the real system header
  # path directly instead (found via pkg-config on MJACKSON).
  sed -i "s|run_command(py, '-c', 'import vapoursynth as vs; print(vs.get_include())', check: true).stdout().strip()|'$VS_INCLUDE'|" meson.build
  rm -rf build
  meson setup build
  ninja -C build
  cp build/mvtools.so "$LIB_DIR/"
  cd "$BUILD_DIR" >/dev/null
else
  log "mvtools.so already present, skipping build"
fi

# --- znedi3 (+ nnedi3 weights) ---
if [ ! -f "$LIB_DIR/vsznedi3.so" ]; then
  log "Building znedi3..."
  rm -rf "$BUILD_DIR/znedi3"
  git clone --depth 1 https://github.com/sekrit-twc/znedi3.git "$BUILD_DIR/znedi3"
  cd "$BUILD_DIR/znedi3"
  git submodule update --init --recursive
  make X=avx2 -j"$(nproc)"
  cp vsznedi3.so "$LIB_DIR/"
  cd "$BUILD_DIR" >/dev/null
else
  log "vsznedi3.so already present, skipping build"
fi
if [ ! -f "$LIB_DIR/nnedi3_weights.bin" ]; then
  log "Fetching nnedi3_weights.bin..."
  curl -sL https://raw.githubusercontent.com/dubhater/vapoursynth-nnedi3/master/src/nnedi3_weights.bin -o "$LIB_DIR/nnedi3_weights.bin"
fi

# --- vs-removegrain (core.rgvs) ---
if [ ! -f "$LIB_DIR/libremovegrain.so" ]; then
  log "Building vs-removegrain..."
  rm -rf "$BUILD_DIR/vs-removegrain"
  git clone --depth 1 https://github.com/vapoursynth/vs-removegrain.git "$BUILD_DIR/vs-removegrain"
  cd "$BUILD_DIR/vs-removegrain"
  rm -rf build
  meson setup build
  ninja -C build
  cp build/libremovegrain.so "$LIB_DIR/"
  cd "$BUILD_DIR" >/dev/null
else
  log "libremovegrain.so already present, skipping build"
fi

# --- vs-miscfilters-obsolete (core.misc, SCDetect/AverageFrames) ---
if [ ! -f "$LIB_DIR/libmiscfilters.so" ]; then
  log "Building vs-miscfilters-obsolete..."
  rm -rf "$BUILD_DIR/vs-miscfilters-obsolete"
  git clone --depth 1 https://github.com/vapoursynth/vs-miscfilters-obsolete.git "$BUILD_DIR/vs-miscfilters-obsolete"
  cd "$BUILD_DIR/vs-miscfilters-obsolete"
  rm -rf build
  meson setup build
  ninja -C build
  cp build/libmiscfilters.so "$LIB_DIR/"
  cd "$BUILD_DIR" >/dev/null
else
  log "libmiscfilters.so already present, skipping build"
fi

# --- fmtconv (core.fmtc) -- autotools, not meson ---
if [ ! -f "$LIB_DIR/libfmtconv.so" ]; then
  log "Building fmtconv..."
  rm -rf "$BUILD_DIR/fmtconv"
  git clone --depth 1 https://github.com/EleonoreMizo/fmtconv.git "$BUILD_DIR/fmtconv"
  cd "$BUILD_DIR/fmtconv/build/unix"
  autoreconf -i
  ./configure
  make -j"$(nproc)"
  cp .libs/libfmtconv.so "$LIB_DIR/"
  cd "$BUILD_DIR" >/dev/null
else
  log "libfmtconv.so already present, skipping build"
fi

# --- classic havsfunc.py (pinned commit -- master/main both 404 as of
#     this session) + the 3 patches needed for modern-mvtools API drift ---
if [ ! -f "$QTGMC_HOME/havsfunc_classic.py" ]; then
  log "Fetching classic havsfunc.py (commit $HAVSFUNC_COMMIT)..."
  curl -sL "https://raw.githubusercontent.com/HomeOfVapourSynthEvolution/havsfunc/$HAVSFUNC_COMMIT/havsfunc.py" -o "$QTGMC_HOME/havsfunc_classic.py"
  python3 - "$QTGMC_HOME/havsfunc_classic.py" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# QTGMC itself never calls mvsfunc/adjust (other havsfunc helpers do) --
# guard the imports so the module loads without those extra dependencies.
content = content.replace(
    "import mvsfunc as mvf\nimport adjust\n",
    "try:\n    import mvsfunc as mvf\nexcept ImportError:\n    mvf = None\ntry:\n    import adjust\nexcept ImportError:\n    adjust = None\n",
)

# mvtools v29 dropped the _lambda/_global Analyse/Recalculate params this
# script was written against.
content = re.sub(r'_lambda=\w+,\s*', '', content)
content = re.sub(r'_global=\w+,\s*', '', content)

# QTGMC_Interpolate eagerly resolves myEEDI3 even when EdiMode='NNEDI3'
# means eedi3 is never actually used -- guard it so a missing eedi3
# plugin (not installed by this script; NNEDI3-only usage doesn't need
# it) doesn't crash module-level graph construction.
old = "myEEDI3 = core.eedi3m.EEDI3 if hasattr(core, 'eedi3m') else core.eedi3.eedi3"
new = "myEEDI3 = core.eedi3m.EEDI3 if hasattr(core, 'eedi3m') else (core.eedi3.eedi3 if hasattr(core, 'eedi3') else None)"
content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)
print("Patched havsfunc_classic.py")
PYEOF
else
  log "havsfunc_classic.py already present, skipping fetch"
fi

log "Install complete. Verify with: bash $0 --verify"
