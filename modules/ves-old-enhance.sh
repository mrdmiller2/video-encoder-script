#!/usr/bin/env bash
# ves-old-enhance.sh -- (#4/#5) per-title check: does THIS vintage/classic/vtv
# title actually benefit from synthetic film grain (#5) and/or heavier
# sub-shot adaptive quantisation (#4)?
#
# Rationale: "old" is not one thing. A genuinely grain-heavy print (a scanned
# 16mm/35mm transfer) spends a large fraction of its bitrate reproducing
# grain that AV1's grain synthesis can carry as a few bytes of metadata --
# big size win at neutral perceived quality. A clean telecined studio print
# (late-era sitcom shot on video, or a pristine restoration) has little real
# grain; forcing synthesis there gains nothing and can visibly soften it.
# aq/variance-boost is similar: worth more on high-contrast film, wasted (or
# a slight softener) on flat video.
#
# So this runs a short real A/B on a representative sample of the title and
# only adopts the enhanced params for that one title if the enhanced encode
# is SMALLER at a VMAF within PER_TITLE_OLD_ENHANCE_VMAF_TOL of the default.
# Sets SVT_PARAMS_OVERRIDE / SVT_PARAMS_OVERRIDE_PROFILE (consumed by
# profile_svt_params, shared by both the CRF/QP search and the final encode).
#
# GATED: no-op unless PER_TITLE_OLD_ENHANCE_CHECK=true and the profile is in
# PER_TITLE_OLD_ENHANCE_PROFILES. Call once per title, after the profile is
# known and before the search/encode. The caller must reset
# SVT_PARAMS_OVERRIDE="" at each title's entry (done in ves-config defaults,
# but a long-lived run should clear it explicitly per file).

# Build the "enhanced" variant of a profile's SVT param string.
#   #5 grain:  raise film-grain by +4 (add film-grain-denoise=1:film-grain=8
#              if absent). film-grain-denoise=1 is required for synthesis to
#              actually replace real grain rather than stack on top.
#   #4 subshot: ensure enable-variance-boost=1 + enable-tf=1, bump
#              variance-boost-strength by +1 (cap 4), widen variance-octile to 5.
_old_enhance_params() {
  local p="$1" out="$p"
  # --- #5 film grain ---
  if printf '%s' "$out" | grep -q 'film-grain='; then
    out="$(printf '%s' "$out" | awk -F: 'BEGIN{OFS=":"} {
      for (i=1;i<=NF;i++) {
        if ($i ~ /^film-grain=[0-9]+$/) { split($i,a,"="); v=a[2]+4; if(v>16)v=16; $i="film-grain=" v }
      }
      print
    }')"
    printf '%s' "$out" | grep -q 'film-grain-denoise=' || out="${out}:film-grain-denoise=1"
  else
    out="${out}:film-grain-denoise=1:film-grain=8"
  fi
  # --- #4 sub-shot AQ / temporal ---
  printf '%s' "$out" | grep -q 'enable-variance-boost=' || out="${out}:enable-variance-boost=1"
  printf '%s' "$out" | grep -q 'enable-tf=1' || out="$(printf '%s' "$out" | sed -E 's/:enable-tf=0//; s/$/:enable-tf=1/')"
  if printf '%s' "$out" | grep -q 'variance-boost-strength='; then
    out="$(printf '%s' "$out" | awk -F: 'BEGIN{OFS=":"} {
      for (i=1;i<=NF;i++) if ($i ~ /^variance-boost-strength=[0-9]+$/) { split($i,a,"="); v=a[2]+1; if(v>4)v=4; $i="variance-boost-strength=" v }
      print
    }')"
  else
    out="${out}:variance-boost-strength=2"
  fi
  printf '%s' "$out" | grep -q 'variance-octile=' \
    && out="$(printf '%s' "$out" | sed -E 's/variance-octile=[0-9]+/variance-octile=5/')" \
    || out="${out}:variance-octile=5"
  # collapse any accidental double colons
  printf '%s' "$out" | sed -E 's/::+/:/g; s/^://; s/:$//'
}

# Encode one sample clip (already a lossless .mkv) at $crf with $svtp, return
# "vmaf bytes" -- mirrors _vmaf_score_shot's encode+score, shorter.
_old_enhance_score() {
  local clip="$1" crf="$2" svtp="$3" model="$4" work
  work="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-oldenh-XXXXXX")" || return 1
  local y4m="$work/s.y4m" out="$work/s.ivf" omkv="$work/s.mkv" vlog="$work/s.json"
  run_ffmpeg_validation -y -v error -i "$clip" -map 0:v:0 -pix_fmt yuv420p10le -strict -1 "$y4m" 2>/dev/null \
    || { rm -rf "$work"; return 1; }
  run_ffmpeg_validation -y -v error -i "$y4m" -c:v libsvtav1 -preset "${SVT_PRESET_SEARCH:-8}" -crf "$crf" \
    -svtav1-params "${svtp}" "$out" 2>/dev/null || { rm -rf "$work"; return 1; }
  [ -s "$out" ] || { rm -rf "$work"; return 1; }
  run_ffmpeg_validation -y -v error -i "$out" -c copy "$omkv" 2>/dev/null || { rm -rf "$work"; return 1; }
  local gdf=()
  printf '%s' "$svtp" | grep -q 'film-grain=[1-9]' && gdf=(-export_side_data film_grain)
  run_ffmpeg_validation -y -v error "${gdf[@]}" -i "$omkv" -i "$clip" -lavfi \
    "[0:v]setpts=PTS-STARTPTS,format=yuv420p10le[d];[1:v]setpts=PTS-STARTPTS,format=yuv420p10le[r];[d][r]libvmaf=model=${model}:n_threads=$(nproc 2>/dev/null || echo 4):log_fmt=json:log_path=${vlog}" \
    -f null - 2>/dev/null || { rm -rf "$work"; return 1; }
  local v b
  v="$(python3 -c "import json;print(round(json.load(open('$vlog'))['pooled_metrics']['vmaf']['mean'],3))" 2>/dev/null)" || { rm -rf "$work"; return 1; }
  b="$(file_size_bytes "$out")"
  rm -rf "$work"
  printf '%s %s' "$v" "$b"
}

decide_old_title_enhancement() {
  local src="$1" profile="$2"
  SVT_PARAMS_OVERRIDE=""; SVT_PARAMS_OVERRIDE_PROFILE=""
  [ "${PER_TITLE_OLD_ENHANCE_CHECK:-false}" = "true" ] || return 0
  case " ${PER_TITLE_OLD_ENHANCE_PROFILES:-} " in *" $profile "*) : ;; *) return 0 ;; esac
  discover_svtav1encapp || return 0

  local base_p enh_p crf model dur secs ss clip work
  base_p="$(profile_svt_params "$profile")" || return 0
  enh_p="$(_old_enhance_params "$base_p")"
  [ "$enh_p" = "$base_p" ] && { log_err "[old-enhance] $profile: enhanced == default params, skip"; return 0; }
  crf="$(profile_fixed_crf av1 "$profile" 2>/dev/null || echo 25)"
  model="$(vmaf_model_for_source "$src")"
  dur="$(video_duration "$src")" || return 0
  secs="${PER_TITLE_OLD_ENHANCE_SAMPLE_SECS:-45}"
  # representative window: ~40% in, clear of intro/credits
  ss="$(awk -v d="$dur" -v s="$secs" 'BEGIN{p=d*0.40; if(p+s>d) p=d-s; if(p<0)p=0; printf "%.3f", p}')"
  work="$(mktemp -d "${RAMDISK_JOB_DIR:-${TMPDIR:-/tmp}}/ves-oldenh-src-XXXXXX")" || return 0
  clip="$work/sample.mkv"
  run_ffmpeg_validation -y -v error -ss "$ss" -i "$src" -t "$secs" -map 0:v:0 -c:v ffv1 -level 3 "$clip" 2>/dev/null \
    || { rm -rf "$work"; return 0; }

  local r_base r_enh vb bb ve be
  r_base="$(_old_enhance_score "$clip" "$crf" "$base_p" "$model")" || { rm -rf "$work"; return 0; }
  r_enh="$(_old_enhance_score  "$clip" "$crf" "$enh_p"  "$model")" || { rm -rf "$work"; return 0; }
  rm -rf "$work"
  vb="${r_base%% *}"; bb="${r_base##* }"
  ve="${r_enh%% *}";  be="${r_enh##* }"

  local verdict
  verdict="$(awk -v vb="$vb" -v bb="$bb" -v ve="$ve" -v be="$be" -v tol="${PER_TITLE_OLD_ENHANCE_VMAF_TOL:-0.5}" 'BEGIN{
    smaller = (be + 0 < bb + 0)
    ok_q    = (ve + 0 >= vb + 0 - tol)
    pct     = (bb+0>0) ? (100.0*(bb-be)/bb) : 0
    printf "%s size=%.1f%% vmaf=%.2f->%.2f", (smaller && ok_q) ? "ADOPT" : "KEEP", pct, vb, ve
  }')"
  log_err "[old-enhance] $profile sample(${secs}s@${ss}): default ${bb}B/${vb}  enhanced ${be}B/${ve}  -> ${verdict}"
  case "$verdict" in
    ADOPT*)
      SVT_PARAMS_OVERRIDE="$enh_p"
      SVT_PARAMS_OVERRIDE_PROFILE="$profile"
      log_err "[old-enhance] $profile: adopting enhanced params for this title: $enh_p"
      ;;
  esac
  return 0
}
