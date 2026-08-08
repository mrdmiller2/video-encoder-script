#!/usr/bin/env bash
# install-qtgmc-ubuntu.sh -- installs the QTGMC (VapourSynth) toolchain on a
# Ubuntu fleet machine, for vintage-profile decombing. Idempotent: safe to
# re-run, skips steps whose output already exists.
#
# Ubuntu has no VapourSynth core package at all (unlike Fedora's dnf
# packages) -- this script builds the VapourSynth core itself from source,
# not just the plugins. Proven working on LAYTOYAJ (Ubuntu 26.04) and should
# transfer to Plex (24.04), 2026-08-07. Real gotchas this recipe accounts
# for, none of which showed up on Fedora:
#   - meson installs VapourSynth's Python module to the version-agnostic
#     /usr/local/lib/python3/dist-packages, which Python's own import
#     machinery does NOT search (only .../python3.X/dist-packages is on
#     sys.path) -- fixed with a symlink into the versioned path.
#   - The installed vapoursynth.pc lands outside pkg-config's default
#     search path -- fixed with a symlink into /usr/local/lib/pkgconfig.
#   - Ubuntu's system Python is "externally managed" (PEP 668) -- plain
#     `pip install --user` refuses to run; `--break-system-packages` is
#     the correct override here (still a --user install, doesn't touch any
#     system-managed package).
#   - Package name is `libfftw3-dev`, not `fftw3-dev`/`fftw-devel`.
#   - The installed vapoursynth.pc uses a `${pcfiledir}`-relative prefix --
#     classic `pkg-config` (not `pkgconf`) resolves that against the path it
#     opened, so a symlink into /usr/local/lib/pkgconfig computes the wrong
#     include dir (silently -- meson step still "succeeds", the actual
#     compile fails with "VapourSynth4.h: No such file or directory"). Fixed
#     by writing a fresh .pc file with an absolute `prefix=` instead of
#     symlinking the original. Reproduced on Plex (classic pkg-config 1.8.1);
#     LAYTOYAJ's pkgconf tolerated the symlink fine -- don't assume one
#     Ubuntu box validates the other.
#   - Ubuntu 24.04's apt-packaged Cython (3.0.8) generates code against
#     CPython `PyLong` internals that Python 3.12 removed -- VapourSynth's
#     build fails with "PyLong_SHIFT was not declared". Fixed by installing
#     a newer Cython via pip (`--user --break-system-packages`) and
#     prepending `~/.local/bin` to PATH for the VapourSynth core build only.
#     Not needed on 26.04 (ships a compatible Cython already).
#
# Same classic-havsfunc.py approach as the Fedora installer (see
# project_qtgmc_merit_test_2026_08_07 memory for why: the modern
# `pip install havsfunc` ecosystem's QTempGaussMC segfaults inside akarin).
#
# Usage: bash install-qtgmc-ubuntu.sh
# Verify afterwards: bash install-qtgmc-ubuntu.sh --verify

set -euo pipefail

QTGMC_HOME="${QTGMC_HOME:-$HOME/qtgmc}"
BUILD_DIR="$QTGMC_HOME/build"
LIB_DIR="$QTGMC_HOME/lib"
HAVSFUNC_COMMIT="771ef4b5cac89aa985f40786e9eaf82cbdabc888"
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

log() { echo "[install-qtgmc] $*"; }

verify_only=false
[ "${1:-}" = "--verify" ] && verify_only=true

if [ "$verify_only" = true ]; then
  log "Verifying existing install at $QTGMC_HOME"
  for f in mvtools.so vsznedi3.so nnedi3_weights.bin libremovegrain.so libmiscfilters.so libfmtconv.so; do
    test -f "$LIB_DIR/$f" || { echo "MISSING: $f"; exit 1; }
  done
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
assert hasattr(core, 'bs'), 'bestsource not loaded'
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

log "Installing system packages via apt..."
sudo apt-get install -y \
  libzimg-dev cython3 python3-dev meson ninja-build nasm libfftw3-dev \
  automake autoconf libtool git pkg-config build-essential

# --- VapourSynth core itself (not packaged for Ubuntu at all) ---
AGNOSTIC_DIR="/usr/local/lib/python3/dist-packages/vapoursynth"
if ! python3 -c "import vapoursynth" 2>/dev/null; then
  log "Building VapourSynth core from source..."
  # Older Ubuntu LTS releases (24.04) ship a Cython too old for this
  # VapourSynth version's generated code against Python 3.12+ -- a pip-
  # installed newer Cython on PATH (ahead of the system one) fixes it
  # without touching the system Python packages.
  pip3 install --user --break-system-packages --quiet "cython>=3.1" || true
  export PATH="$HOME/.local/bin:$PATH"

  rm -rf "$BUILD_DIR/vapoursynth"
  git clone --depth 1 https://github.com/vapoursynth/vapoursynth.git "$BUILD_DIR/vapoursynth"
  cd "$BUILD_DIR/vapoursynth"
  rm -rf build
  meson setup build
  ninja -C build
  sudo ninja -C build install
  sudo ldconfig
  cd "$BUILD_DIR" >/dev/null
  python3 -c "import vapoursynth as vs; print(vs.core)"
else
  log "VapourSynth core already importable, skipping build"
fi

# meson installs to the version-agnostic dist-packages dir; Python only
# searches the versioned one.
VERSIONED_DIR="/usr/local/lib/python$PY_VER/dist-packages/vapoursynth"
if [ -d "$AGNOSTIC_DIR" ] && [ ! -e "$VERSIONED_DIR" ]; then
  sudo ln -sf "$AGNOSTIC_DIR" "$VERSIONED_DIR"
fi
# Same for pkg-config's search path -- write an absolute-prefix .pc file
# rather than symlinking the original (classic pkg-config resolves
# ${pcfiledir} against the symlink's own directory, not its target, and
# silently computes the wrong include path -- see header notes).
sudo mkdir -p /usr/local/lib/pkgconfig
if [ -d "$AGNOSTIC_DIR" ] && [ ! -f /usr/local/lib/pkgconfig/vapoursynth.pc ]; then
  printf 'prefix=%s\nincludedir=${prefix}/include\n\nName: vapoursynth\nDescription: A frameserver for the 21st century\nVersion: 79\nCflags: -I${includedir}\n' "$AGNOSTIC_DIR" | sudo tee /usr/local/lib/pkgconfig/vapoursynth.pc >/dev/null
fi

VS_INCLUDE="/usr/local/lib/python3/dist-packages/vapoursynth/include"

log "Installing vapoursynth-bestsource (pip, --user, --break-system-packages)..."
pip3 install --user --break-system-packages --quiet vapoursynth-bestsource

# --- mvtools ---
if [ ! -f "$LIB_DIR/mvtools.so" ]; then
  log "Building vapoursynth-mvtools..."
  rm -rf "$BUILD_DIR/vapoursynth-mvtools"
  git clone --depth 1 https://github.com/dubhater/vapoursynth-mvtools.git "$BUILD_DIR/vapoursynth-mvtools"
  cd "$BUILD_DIR/vapoursynth-mvtools"
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

# --- vs-miscfilters-obsolete (core.misc) ---
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
