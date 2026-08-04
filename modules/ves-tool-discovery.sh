#!/usr/bin/env bash
# ves-tool-discovery.sh -- external tool presence/checklist/install-hint
# printing and resolution (ffmpeg, HandBrakeCLI, mkvmerge, etc -- not
# HandBrake-specific capability probing, which lives in ves-handbrake.sh).
# Pure move from the former monolithic script -- no logic changes.

# Print copy-pasteable install commands for this host (pre-compiled packages preferred).
print_platform_install_commands() {
  cat >&2 <<EOF

Package manager detected: ${PACKAGE_MANAGER:-none}
Platform: $PLATFORM

Prefer pre-built packages from your OS package manager (or Homebrew bottles).

EOF
  case "$PLATFORM" in
    macos)
      cat >&2 <<'EOF'
macOS (Homebrew — recommended):
  brew install bash ffmpeg mkvtoolnix handbrake python3 mkvalidator grep ripgrep

  Notes:
    - Script auto re-execs under Homebrew bash 4+ when /bin/bash is 3.2.
    - HandBrakeCLI comes from the handbrake formula.
EOF
      ;;
    linux|wsl)
      cat >&2 <<'EOF'
Linux / WSL — pick the block that matches your distro:

  Debian / Ubuntu / WSL (apt):
    sudo apt update
    sudo apt install -y ffmpeg mkvtoolnix handbrake-cli python3 grep ripgrep
    # mkvalidator is NOT in apt/dnf — optional. Drop a Linux x86_64 binary at:
    #   ~/.local/bin/mkvalidator
    # Or install Homebrew on Linux and: brew install mkvalidator
    # Without it, EBML segment-bounds checks still run.

  Fedora / RHEL (dnf):
    sudo dnf install -y ffmpeg mkvtoolnix HandBrake-cli python3 grep ripgrep
    # mkvalidator: brew install mkvalidator  (Homebrew on Linux) or build from Matroska source

  Arch:
    sudo pacman -S --needed ffmpeg mkvtoolnix handbrake python grep ripgrep
    # mkvalidator: yay -S mkvalidator   (AUR)  or: brew install mkvalidator

  openSUSE:
    sudo zypper install ffmpeg mkvtoolnix HandBrake-cli python3 grep ripgrep

  Alpine:
    sudo apk add ffmpeg mkvtoolnix handbrake python3 grep ripgrep

  HandBrake Flatpak (any Linux/WSL with Flatpak):
    flatpak install flathub fr.handbrake.ghb
    # Script auto-detects: flatpak run --command=HandBrakeCLI fr.handbrake.ghb

  WSL tip: Linux ffmpeg/mkvtoolnix + Windows HandBrakeCLI.exe (NVENC) is supported.
    Place HandBrakeCLI on PATH or set CONVERT_HANDBRAKE=/mnt/c/Program Files/HandBrake/HandBrakeCLI.exe
EOF
      if [ "$PACKAGE_MANAGER" = brew ]; then
        cat >&2 <<'EOF'

  This host has Homebrew — fastest path for missing tools (incl. mkvalidator bottle):
    brew install ffmpeg mkvtoolnix handbrake python3 mkvalidator grep ripgrep
EOF
      elif [ "$PACKAGE_MANAGER" = apt ]; then
        cat >&2 <<'EOF'

  Suggested for this host:
    sudo apt update && sudo apt install -y ffmpeg mkvtoolnix handbrake-cli python3 grep ripgrep
    # mkvalidator (optional): place binary at ~/.local/bin/mkvalidator — not available via apt
EOF
      elif [ "$PACKAGE_MANAGER" = dnf ] || [ "$PACKAGE_MANAGER" = yum ]; then
        cat >&2 <<'EOF'

  Suggested for this host:
    sudo dnf install -y ffmpeg mkvtoolnix HandBrake-cli python3 grep ripgrep
    # mkvalidator (optional): ~/.local/bin/mkvalidator or: brew install mkvalidator
EOF
      elif [ "$PACKAGE_MANAGER" = pacman ]; then
        cat >&2 <<'EOF'

  Suggested for this host:
    sudo pacman -S --needed ffmpeg mkvtoolnix handbrake python grep ripgrep
    # mkvalidator (optional): yay -S mkvalidator  or  ~/.local/bin/mkvalidator
EOF
      fi
      ;;
    windows)
      cat >&2 <<'EOF'
Windows / Cygwin / WSL:
  Prefer WSL2 + Linux tools (ffmpeg, mkvtoolnix) and Windows HandBrakeCLI.exe for NVENC.
  mkvalidator is optional and not in winget/choco apt — use WSL ~/.local/bin/mkvalidator
  (Linux x86_64 binary) or skip it (EBML bounds still validate structure).
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Unknown platform — install ffmpeg, ffprobe, HandBrakeCLI, mkvmerge, mkvpropedit, python3,
and optionally mkvalidator; then pass paths via CONVERT_* / --ffmpeg etc.
EOF
      ;;
  esac
  cat >&2 <<'EOF'

Optional overrides (when binaries are not on PATH):
  CONVERT_FFMPEG CONVERT_FFPROBE CONVERT_HANDBRAKE CONVERT_MKVPROPEDIT
  CONVERT_MKVMERGE CONVERT_MKVALIDATOR
  --ffmpeg --ffprobe --handbrake --mkvpropedit --mkvmerge --mkvalidator
EOF
}

print_tool_install_help() {
  err "One or more required tools were not found."
  print_platform_install_commands
}

# Log a one-line status for each tool; returns 1 if any required tool is missing.
report_tool_checklist() {
  local missing=0
  local status path

  log "Tool checklist (platform=$PLATFORM package_manager=${PACKAGE_MANAGER:-none}):"

  _tool_row() {
    local name="$1" required="$2" present="$3" detail="${4:-}"
    if [ "$present" = true ]; then
      log "  [OK]  $name${detail:+ — $detail}"
    elif [ "$required" = true ]; then
      log "  [MISSING] $name (required)${detail:+ — $detail}"
      missing=1
    else
      log "  [OPTIONAL MISSING] $name${detail:+ — $detail}"
    fi
  }

  if [ "${#FFMPEG_CMD[@]}" -gt 0 ]; then
    _tool_row "ffmpeg" true true "${FFMPEG_CMD[*]}"
  else
    _tool_row "ffmpeg" true false "install via package manager"
  fi
  if [ "${#FFPROBE_CMD[@]}" -gt 0 ]; then
    _tool_row "ffprobe" true true "${FFPROBE_CMD[*]}"
  else
    _tool_row "ffprobe" true false "usually bundled with ffmpeg"
  fi
  if [ -n "${HANDBRAKE_DISPLAY:-}" ]; then
    _tool_row "HandBrakeCLI" true true "$HANDBRAKE_DISPLAY"
  else
    _tool_row "HandBrakeCLI" true false "handbrake-cli / HandBrake-cli / brew handbrake / Flatpak"
  fi
  if [ "${#MKVMERGE_CMD[@]}" -gt 0 ]; then
    _tool_row "mkvmerge" true true "${MKVMERGE_CMD[*]}"
  else
    _tool_row "mkvmerge" true false "mkvtoolnix package"
  fi
  if [ "${#MKVPROPEDIT_CMD[@]}" -gt 0 ]; then
    _tool_row "mkvpropedit" true true "${MKVPROPEDIT_CMD[*]}"
  else
    _tool_row "mkvpropedit" true false "mkvtoolnix package"
  fi
  if [ "$HAS_MKVALIDATOR" = true ]; then
    _tool_row "mkvalidator" false true "${MKVALIDATOR_CMD[*]}"
  else
    _tool_row "mkvalidator" false false "optional — place at ~/.local/bin/mkvalidator (not in apt/winget)"
  fi
  if command -v python3 >/dev/null 2>&1; then
    HAS_PYTHON3=true
    _tool_row "python3" true true "$(command -v python3)"
  else
    HAS_PYTHON3=false
    _tool_row "python3" true false "needed for EBML structure + remux helpers"
  fi
  if [ "${TEXT_SEARCH_BACKEND:-}" = rg ] || [ "${TEXT_SEARCH_BACKEND:-}" = grep ] || command -v grep >/dev/null 2>&1 || command -v rg >/dev/null 2>&1; then
    HAS_GREP_OR_RG=true
    _tool_row "grep/rg" true true "${TEXT_SEARCH_DISPLAY:-grep}"
  else
    HAS_GREP_OR_RG=false
    _tool_row "grep/rg" true false
  fi

  if [ "$missing" -ne 0 ]; then
    print_platform_install_commands
    return 1
  fi
  return 0
}

resolve_configured_tool() {
  local configured="$1"
  local name="$2"
  local candidate

  if [ -z "$configured" ]; then
    return 1
  fi
  if [ -x "$configured" ]; then
    printf '%s' "$configured"
    return 0
  fi
  if [ "$PLATFORM" = wsl ] && [[ "$configured" == *.exe ]] && [ -f "$configured" ]; then
    printf '%s' "$configured"
    return 0
  fi
  err "Configured $name path is not executable: $configured"
  return 1
}

discover_binary() {
  local name="$1"
  local candidate

  # A user-built binary in ~/.local/bin takes priority over the system PATH
  # copy — e.g. a libvmaf-enabled ffmpeg build vs. the distro package. This
  # also covers non-interactive SSH/cron invocations where ~/.local/bin was
  # never added to PATH (shell rc files like .bashrc short-circuit for
  # non-interactive shells, and .profile only loads for login shells).
  candidate="$HOME/.local/bin/$name"
  [ -x "$candidate" ] && printf '%s' "$candidate" && return 0

  if candidate="$(command -v "$name" 2>/dev/null)"; then
    printf '%s' "$candidate"
    return 0
  fi

  while IFS= read -r candidate; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && printf '%s' "$candidate" && return 0
  done < <(platform_extra_paths "$name")

  return 1
}

discover_tools() {
  local tool
  local failed=0

  detect_package_manager

  FFMPEG_CMD=()
  FFPROBE_CMD=()
  MKVMERGE_CMD=()
  MKVPROPEDIT_CMD=()
  MKVALIDATOR_CMD=()
  HAS_MKVALIDATOR=false
  HANDBRAKE_DISPLAY=""

  if tool="$(resolve_configured_tool "$TOOL_FFMPEG" ffmpeg)" || tool="$(discover_binary ffmpeg)"; then
    FFMPEG_CMD=("$tool")
  else
    failed=1
  fi

  if tool="$(resolve_configured_tool "$TOOL_FFPROBE" ffprobe)" || tool="$(discover_binary ffprobe)"; then
    FFPROBE_CMD=("$tool")
  else
    failed=1
  fi

  if discover_handbrake_cli; then
    :
  else
    HANDBRAKE_DISPLAY=""
    failed=1
  fi

  if tool="$(resolve_configured_tool "$TOOL_MKVPROPEDIT" mkvpropedit)" || tool="$(discover_binary mkvpropedit)"; then
    MKVPROPEDIT_CMD=("$tool")
  else
    failed=1
  fi

  if tool="$(resolve_configured_tool "$TOOL_MKVMERGE" mkvmerge)" || tool="$(discover_binary mkvmerge)"; then
    MKVMERGE_CMD=("$tool")
  else
    failed=1
  fi

  if tool="$(resolve_configured_tool "$TOOL_MKVALIDATOR" mkvalidator)" || tool="$(discover_binary mkvalidator)"; then
    MKVALIDATOR_CMD=("$tool")
    HAS_MKVALIDATOR=true
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    failed=1
  fi

  if ! report_tool_checklist; then
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    err "Install the missing required tools above, then re-run (or use --check-tools)."
    return 1
  fi

  if [ "$HAS_MKVALIDATOR" = true ]; then
    log "mkvalidator: ${MKVALIDATOR_CMD[*]} (Matroska structure checks enabled)"
  else
    warn "mkvalidator not found — EBML bounds still run; optional: copy Linux x86_64 binary to ~/.local/bin/mkvalidator"
  fi

  log "Platform: $PLATFORM | shell: $(shell_name) | ffmpeg=${FFMPEG_CMD[*]} | HandBrake=${HANDBRAKE_DISPLAY} | search=${TEXT_SEARCH_DISPLAY:-?} | pkg=${PACKAGE_MANAGER:-none}"
  configure_sudo_wsl_handbrake
  detect_handbrake_cli_capabilities
}
