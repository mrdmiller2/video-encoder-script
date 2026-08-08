#!/usr/bin/env bash
# install-qtgmc-macos.sh -- installs the QTGMC (VapourSynth) toolchain on a
# macOS fleet machine, for vintage-profile decombing. Idempotent: safe to
# re-run, skips steps whose output already exists.
#
# Proven working on MARLONJ (macOS 26.6.1, Apple Silicon arm64), 2026-08-07.
# macOS turned out easier than Ubuntu for this: Homebrew has a bottled
# (prebuilt) `vapoursynth` formula, plus `vapoursynth-mvtools` and
# `vapoursynth-bestsource` formulas -- no core build needed, no pip needed
# at all for source-loading (bestsource comes from the brew formula
# directly). The remaining plugins (znedi3, removegrain, miscfilters,
# fmtconv) have no Homebrew formula and are built from source, same as
# Linux, with macOS-specific adjustments:
#   - `make X=none` for znedi3 (not `X=avx2` like Linux) -- the x86 SIMD
#     kernel source files compile to empty/guarded stubs on arm64 rather
#     than erroring, confirmed via `file` that the resulting .so is pure
#     arm64 (no x86 slice), consistent with this project's
#     native-architecture-only constant.
#   - fmtconv's autotools bootstrap needs `LIBTOOLIZE=glibtoolize`
#     (Homebrew's libtool, not macOS's incompatible BSD libtoolize).
#   - Plugin file extension is `.dylib` on macOS (`.so` on Linux) --
#     doesn't matter functionally, `core.std.LoadPlugin` takes any path.
#
# Same classic-havsfunc.py approach as the Linux installers (see
# project_qtgmc_merit_test_2026_08_07 memory for why).
#
# Usage: bash install-qtgmc-macos.sh
# Verify afterwards: bash install-qtgmc-macos.sh --verify

set -euo pipefail

BREW="${BREW:-/opt/homebrew/bin/brew}"
QTGMC_HOME="${QTGMC_HOME:-$HOME/qtgmc}"
BUILD_DIR="$QTGMC_HOME/build"
LIB_DIR="$QTGMC_HOME/lib"
HAVSFUNC_COMMIT="771ef4b5cac89aa985f40786e9eaf82cbdabc888"

log() { echo "[install-qtgmc] $*"; }

verify_only=false
[ "${1:-}" = "--verify" ] && verify_only=true

if [ "$verify_only" = true ]; then
  log "Verifying existing install at $QTGMC_HOME"
  for f in vsznedi3.so nnedi3_weights.bin libremovegrain.dylib libmiscfilters.dylib libfmtconv.dylib; do
    test -f "$LIB_DIR/$f" || { echo "MISSING: $f"; exit 1; }
  done
  test -f "$QTGMC_HOME/havsfunc_classic.py" || { echo "MISSING: havsfunc_classic.py"; exit 1; }
  /opt/homebrew/bin/python3.14 -c "
import vapoursynth as vs
core = vs.core
core.std.LoadPlugin('$LIB_DIR/vsznedi3.so')
core.std.LoadPlugin('$LIB_DIR/libremovegrain.dylib')
core.std.LoadPlugin('$LIB_DIR/libmiscfilters.dylib')
core.std.LoadPlugin('$LIB_DIR/libfmtconv.dylib')
assert hasattr(core, 'mv'), 'mvtools (brew formula) not loaded'
assert hasattr(core, 'znedi3'), 'znedi3 not loaded'
assert hasattr(core, 'rgvs'), 'removegrain not loaded'
assert hasattr(core, 'misc'), 'miscfilters not loaded'
assert hasattr(core, 'fmtc'), 'fmtconv not loaded'
assert hasattr(core, 'bs'), 'bestsource (brew formula) not loaded'
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
export PATH="/opt/homebrew/bin:$PATH"

log "Installing Homebrew formulas (VapourSynth core + mvtools + bestsource are bottled)..."
"$BREW" install --quiet \
  vapoursynth vapoursynth-mvtools vapoursynth-bestsource \
  meson ninja fftw automake autoconf libtool

VS_INCLUDE="$("$BREW" --prefix vapoursynth)/../../Cellar/vapoursynth/79/libexec/lib/python3.14/site-packages/vapoursynth/include"
# Fall back to a glob if the version-pinned path above doesn't match the
# installed VapourSynth version.
if [ ! -d "$VS_INCLUDE" ]; then
  VS_INCLUDE="$(find "$("$BREW" --cellar vapoursynth)" -maxdepth 5 -type d -name include -path '*vapoursynth/include' | head -1)"
fi
PKG_CONFIG_PATH_VS="$("$BREW" --prefix vapoursynth)/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_PATH_VS:${PKG_CONFIG_PATH:-}"

# --- znedi3 (+ nnedi3 weights) ---
if [ ! -f "$LIB_DIR/vsznedi3.so" ]; then
  log "Building znedi3..."
  rm -rf "$BUILD_DIR/znedi3"
  git clone --depth 1 https://github.com/sekrit-twc/znedi3.git "$BUILD_DIR/znedi3"
  cd "$BUILD_DIR/znedi3"
  git submodule update --init --recursive
  make X=none -j"$(sysctl -n hw.ncpu)" \
    GRAPHENGINE_INCLUDE="-Igraphengine/include" \
    VAPOURSYNTH_INCLUDE="-I$VS_INCLUDE"
  cp vsznedi3.so "$LIB_DIR/"
  cd "$BUILD_DIR" >/dev/null
  file "$LIB_DIR/vsznedi3.so" | grep -q "arm64" || { echo "WARNING: vsznedi3.so is not arm64 -- native-architecture-only constant violated, investigate before using"; }
else
  log "vsznedi3.so already present, skipping build"
fi
if [ ! -f "$LIB_DIR/nnedi3_weights.bin" ]; then
  log "Fetching nnedi3_weights.bin..."
  curl -sL https://raw.githubusercontent.com/dubhater/vapoursynth-nnedi3/master/src/nnedi3_weights.bin -o "$LIB_DIR/nnedi3_weights.bin"
fi

# --- vs-removegrain (core.rgvs) ---
if [ ! -f "$LIB_DIR/libremovegrain.dylib" ]; then
  log "Building vs-removegrain..."
  rm -rf "$BUILD_DIR/vs-removegrain"
  git clone --depth 1 https://github.com/vapoursynth/vs-removegrain.git "$BUILD_DIR/vs-removegrain"
  cd "$BUILD_DIR/vs-removegrain"
  rm -rf build
  meson setup build
  ninja -C build
  cp build/libremovegrain.dylib "$LIB_DIR/"
  cd "$BUILD_DIR" >/dev/null
else
  log "libremovegrain.dylib already present, skipping build"
fi

# --- vs-miscfilters-obsolete (core.misc) ---
if [ ! -f "$LIB_DIR/libmiscfilters.dylib" ]; then
  log "Building vs-miscfilters-obsolete..."
  rm -rf "$BUILD_DIR/vs-miscfilters-obsolete"
  git clone --depth 1 https://github.com/vapoursynth/vs-miscfilters-obsolete.git "$BUILD_DIR/vs-miscfilters-obsolete"
  cd "$BUILD_DIR/vs-miscfilters-obsolete"
  rm -rf build
  meson setup build
  ninja -C build
  cp build/libmiscfilters.dylib "$LIB_DIR/"
  cd "$BUILD_DIR" >/dev/null
else
  log "libmiscfilters.dylib already present, skipping build"
fi

# --- fmtconv (core.fmtc) -- autotools, needs Homebrew's glibtoolize ---
if [ ! -f "$LIB_DIR/libfmtconv.dylib" ]; then
  log "Building fmtconv..."
  rm -rf "$BUILD_DIR/fmtconv"
  git clone --depth 1 https://github.com/EleonoreMizo/fmtconv.git "$BUILD_DIR/fmtconv"
  cd "$BUILD_DIR/fmtconv/build/unix"
  LIBTOOLIZE=glibtoolize autoreconf -i
  ./configure
  make -j"$(sysctl -n hw.ncpu)"
  cp .libs/libfmtconv.dylib "$LIB_DIR/"
  cd "$BUILD_DIR" >/dev/null
else
  log "libfmtconv.dylib already present, skipping build"
fi

# --- classic havsfunc.py (pinned commit -- master/main both 404) + patches ---
if [ ! -f "$QTGMC_HOME/havsfunc_classic.py" ]; then
  log "Fetching classic havsfunc.py (commit $HAVSFUNC_COMMIT)..."
  curl -sL "https://raw.githubusercontent.com/HomeOfVapourSynthEvolution/havsfunc/$HAVSFUNC_COMMIT/havsfunc.py" -o "$QTGMC_HOME/havsfunc_classic.py"
  python3 - "$QTGMC_HOME/havsfunc_classic.py" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
content = content.replace(
    "import mvsfunc as mvf\nimport adjust\n",
    "try:\n    import mvsfunc as mvf\nexcept ImportError:\n    mvf = None\ntry:\n    import adjust\nexcept ImportError:\n    adjust = None\n",
)
content = re.sub(r'_lambda=\w+,\s*', '', content)
content = re.sub(r'_global=\w+,\s*', '', content)
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
