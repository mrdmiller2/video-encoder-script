#!/usr/bin/env bash
# ves-twostage-encode.sh -- HDR mode/metadata resolution, the ffmpeg
# video/audio arg builders, and the stage-1 encode + encode_dispatch/
# ffmpeg_encode_hw execution paths. Pure move from the former monolithic
# script -- no logic changes.

# Last-resort output for a must-eliminate-format source where both AV1 and
# x265 genuinely failed (see must_eliminate_fallback_or_fail): a plain,
# codec-agnostic stream-copy remux to MKV, deliberately named without a
# codec suffix (unlike av1_output_path/x265_output_path) since no re-encode
# happened -- this is purely a container change.
must_eliminate_remux_path() {
  local src="$1"
  local dir title
  dir="$(media_content_dir "$src")"
  title="$(canonical_title_from_source "$src")"
  printf '%s/%s.mkv' "$dir" "$title"
}

source_is_hdr_transfer() {
  local trc
  trc="$(video_color_transfer "$1")"
  case "$trc" in smpte2084|arib-std-b67) return 0 ;; esac
  return 1
}

source_dovi_profile() {
  run_ffprobe -v error -select_streams v:0 \
    -show_entries stream_side_data=dv_profile -of csv=p=0 "$1" 2>/dev/null \
    | grep -E '^[0-9]+$' | head -1
}

# Classifies a source's HDR transfer intent for encoding/tagging purposes.
# Prints one of:
#   pq            plain HDR10 (or DoVi profile 7 / profile 8 w/ PQ base) --
#                 output should be tagged/encoded as PQ (smpte2084).
#   pq_reconstruct  DoVi profile 5 -- no backward-compatible base layer at
#                 all; the RPU must be applied via libplacebo to reconstruct
#                 a viewable PQ picture. Software (ffmpeg_encode) only --
#                 hardware encode paths have no equivalent filter and must
#                 fall back to software for these sources.
#   hlg           plain HLG, or DoVi profile 8 with an HLG base layer --
#                 must be tagged arib-std-b67, NOT smpte2084/PQ (a player
#                 would otherwise decode the HLG curve as if it were PQ:
#                 crushed shadows, blown highlights).
#   sdr           no HDR handling needed (includes DoVi profile 8 with an
#                 SDR base layer, e.g. profile 8.2 -- forcing this into a
#                 PQ/HDR10 encode would wash out the picture).
#   unknown        Dolby Vision side-data is present but the profile number
#                 couldn't be parsed (muxing quirk / old ffprobe) and the
#                 base layer carries no PQ/HLG transfer tag either -- this
#                 is exactly the shape of source that caused the original
#                 Profile 5 tint bug. Never guess; caller must flag for
#                 human review instead of silently encoding it.
#
# dv_profile alone can't tell profile 8.1 (HDR10 base) apart from 8.2 (SDR
# base) or 8.4 (HLG base) -- ffprobe reports "8" for all three -- so the
# base layer's own color_transfer tag is what actually decides the mode for
# profile 8 (and any other/older profile that isn't 5 or 7).
determine_hdr_mode() {
  local src="$1"
  local trc dovi
  trc="$(video_color_transfer "$src")"

  if source_has_dolby_vision "$src"; then
    dovi="$(source_dovi_profile "$src")" || dovi=""
    case "$dovi" in
      5) printf 'pq_reconstruct' ;;
      7) printf 'pq' ;;  # UHD Blu-ray profile 7 always carries an HDR10/PQ base layer
      8)
        case "$trc" in
          smpte2084) printf 'pq' ;;
          arib-std-b67) printf 'hlg' ;;
          *) printf 'sdr' ;;
        esac
        ;;
      *)
        # Either the profile number failed to parse, or it's some other/
        # older profile (2, 4, 9...) we don't special-case. Either way,
        # trust a clear PQ/HLG transfer tag on the base layer if one is
        # present -- that's an independent, reliable signal regardless of
        # whether the profile number itself parsed. Only fall through to
        # "unknown" (never guess) when even that tag is missing, which is
        # exactly the shape of source that caused the original tint bug.
        case "$trc" in
          smpte2084) printf 'pq' ;;
          arib-std-b67) printf 'hlg' ;;
          *) printf 'unknown' ;;
        esac
        ;;
    esac
    return 0
  fi

  case "$trc" in
    smpte2084) printf 'pq' ;;
    arib-std-b67) printf 'hlg' ;;
    *) printf 'sdr' ;;
  esac
}

# Extract HDR10 static metadata from the first frame; prints two lines:
#   G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)   (SVT/x265 master-display string, or empty)
#   maxcll,maxfall                        (or empty)
extract_hdr10_static_metadata() {
  local src="$1"
  run_ffprobe -v error -select_streams v:0 -show_frames -read_intervals "%+#1" \
    -show_entries frame_side_data_list "$src" 2>/dev/null | awk -F= '
    /side_data_type=Mastering display metadata/ { md=1 }
    /side_data_type=Content light level metadata/ { cll=1 }
    /^red_x=/ {rx=$2} /^red_y=/ {ry=$2} /^green_x=/ {gx=$2} /^green_y=/ {gy=$2}
    /^blue_x=/ {bx=$2} /^blue_y=/ {by=$2}
    /^white_point_x=/ {wx=$2} /^white_point_y=/ {wy=$2}
    /^min_luminance=/ {minl=$2} /^max_luminance=/ {maxl=$2}
    /^max_content=/ {mc=$2} /^max_average=/ {ma=$2}
    function frac(s,  a) { n=split(s, a, "/"); if (n==2 && a[2]+0>0) return a[1]/a[2]; return s+0 }
    END {
      if (md && maxl != "")
        printf "G(%.4f,%.4f)B(%.4f,%.4f)R(%.4f,%.4f)WP(%.4f,%.4f)L(%.1f,%.4f)\n",
          frac(gx),frac(gy),frac(bx),frac(by),frac(rx),frac(ry),frac(wx),frac(wy),frac(maxl),frac(minl)
      else print ""
      if (cll) printf "%d,%d\n", mc+0, ma+0; else print ""
    }'
}

# Shared by build_ffmpeg_video_args (final encode) AND the VMAF CRF search
# (vmaf_crf_search_internal / vmaf_crf_search_abav1) so the CRF that gets
# chosen is always calibrated against the exact params the final encode will
# use. (v5.0.29 fix: the search previously used only the base svtav1-params,
# then the final encode added these extras at the same CRF -- since film-grain
# synthesis and variance-boost both cost real bits, this made anime/grain
# profiles balloon past what the search predicted, in one case past 100% of
# source size. See resolve_crf_for_encode / vmaf_crf_search_internal for the
# grain-aware VMAF-scoring fix that goes with this.)
# Prints the colon-joined extra svtav1-params tail for the given profile (may
# be empty for movie/tv).
svtav1_profile_extras() {
  profile_svt_params "$1"
}

# true if this profile's svtav1-params include real film-grain synthesis --
# these profiles CANNOT use ab-av1 (or plain VMAF scoring) for CRF search,
# since synthesized grain is applied pseudo-randomly at decode time and
# mismatches the source pixel-for-pixel, corrupting the VMAF score (confirmed
# against SVT-AV1's own Parameters.md and ab-av1 GitHub issue #139, which
# remains open/unfixed as of ab-av1 0.11.4).
svtav1_profile_uses_grain_synthesis() {
  profile_uses_grain_synthesis "$1"
}

# Sets FF_VIDEO_ARGS (array) for the chosen codec/quality/profile.
# Args: codec crf src profile hdr hdr_mode
build_ffmpeg_video_args() {
  local codec="$1" crf="$2" src="$3" profile="$4" hdr="$5" hdr_mode="${6:-}"
  local svtp x265p md cll dovi
  FF_VIDEO_ARGS=()
  FF_VF=()
  # hdr_mode may not have been supplied by an older/direct caller -- fall
  # back to the same classifier hdr itself should already agree with.
  [ -n "$hdr_mode" ] || hdr_mode="$(determine_hdr_mode "$src")"

  resolve_upscale_target "$src"
  case "$UPSCALE_TARGET_HEIGHT" in
    720) FF_VF+=("scale=1280:720:flags=lanczos:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2") ;;
    1080) FF_VF+=("scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2") ;;
  esac

  # Classic anime line-art retention: the ffmpeg engine had no sharpening
  # step for anime at all (HandBrake's --lapsharp only applies on that
  # engine's own path) -- light luma-only unsharp after any scaling, to
  # help preserve thin hand-inked lines against the softening tendency
  # SVT-AV1 has on this content. Chroma untouched (avoid color fringing).
  [ "$profile" = canime ] && FF_VF+=("unsharp=luma_msize_x=5:luma_msize_y=5:luma_amount=0.6:chroma_msize_x=5:chroma_msize_y=5:chroma_amount=0.0")

  if [ "$hdr" = true ]; then
    dovi="$(source_dovi_profile "$src")" || dovi=""
    if [ "$dovi" = "5" ]; then
      if [ "$FF_HAS_LIBPLACEBO" = true ]; then
        log "Dolby Vision profile 5 — converting to HDR10 via libplacebo"
        FF_VF+=("libplacebo=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084:format=yuv420p10le")
      else
        return 2   # caller flags for human review
      fi
    elif [ -n "$dovi" ]; then
      log "Dolby Vision profile $dovi — dropping RPU, keeping $([ "$hdr_mode" = hlg ] && printf HLG || printf HDR10) base layer"
    fi
  fi

  local _hdrmeta
  # Bare assignment from a pipeline (extract_hdr10_static_metadata's own
  # ffprobe|awk chain) under this script's `set -euo pipefail`: if the
  # underlying ffprobe call fails or times out (a transient NFS hiccup on a
  # large file is enough), pipefail makes the whole pipeline's exit status
  # non-zero, and without a guard here that aborts the ENTIRE script
  # immediately -- not a graceful "skip this file" -- since assignment alone
  # doesn't exempt a command from errexit the way `if`/`&&`/`||` do. This hit
  # in practice testing the new ffmpeg sample path (build_ffmpeg_video_args
  # is shared with the real encode, so this same latent bug exists there
  # too). Missing/failed HDR10 static metadata just means md/cll stay empty,
  # which build_ffmpeg_video_args already handles fine (both are optional
  # svtav1-params/x265-params tails). Found in team review, 2026-07-22.
  _hdrmeta="$(extract_hdr10_static_metadata "$src")" || _hdrmeta=""
  md="$(printf '%s\n' "$_hdrmeta" | sed -n 1p)"
  cll="$(printf '%s\n' "$_hdrmeta" | sed -n 2p)"

  case "$codec" in
    av1)
      svtp="$(profile_svt_params "$profile")"
      if [ "$hdr" = true ]; then
        svtp="$svtp:enable-hdr=1"
        # Static mastering-display/CLL metadata is a PQ/HDR10-specific
        # concept -- HLG doesn't carry it, and a genuine HLG source's own
        # frames naturally won't have this SEI anyway, but be explicit
        # rather than rely on that.
        if [ "$hdr_mode" != hlg ]; then
          [ -n "$md" ] && svtp="$svtp:mastering-display=$md"
          [ -n "$cll" ] && svtp="$svtp:content-light=$cll"
        fi
      fi
      FF_VIDEO_ARGS=(-c:v libsvtav1 -preset "$SVT_PRESET_FINAL" -crf "$crf"
                     -pix_fmt yuv420p10le -svtav1-params "$svtp")
      ;;
    hevc)
      x265p="$(profile_x265_params "$profile")"
      if [ "$hdr" = true ]; then
        if [ "$hdr_mode" = hlg ]; then
          # x265's hdr10=1 specifically forces PQ-style mastering-display/
          # CLL SEI generation -- wrong for HLG, which signals via the VUI
          # transfer characteristic alone (set on the ffmpeg side below).
          x265p="$x265p:repeat-headers=1"
        else
          x265p="$x265p:hdr10=1:repeat-headers=1"
          [ -n "$md" ] && x265p="$x265p:master-display=$md"
          [ -n "$cll" ] && x265p="$x265p:max-cll=$cll"
        fi
      fi
      FF_VIDEO_ARGS=(-c:v libx265 -preset "$X265_PRESET_FINAL" -crf "$crf"
                     -pix_fmt yuv420p10le -x265-params "$x265p")
      # tune is NOT an x265-params key (see profile_x265_tune) -- ffmpeg
      # exposes it as its own -tune AVOption for libx265, same as -preset.
      local x265_tune
      x265_tune="$(profile_x265_tune "$profile")" || x265_tune=""
      [ -n "$x265_tune" ] && FF_VIDEO_ARGS+=(-tune "$x265_tune")
      ;;
  esac

  if [ "$hdr" = true ]; then
    if [ "$hdr_mode" = hlg ]; then
      FF_VIDEO_ARGS+=(-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc)
    else
      FF_VIDEO_ARGS+=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)
    fi
  fi
  return 0
}

# ffmpeg_encode src dst codec(av1|hevc)
# Stage 1 maps video+audio only; video per build_ffmpeg_video_args; audio
# Opus (av1) / AAC (hevc) matching v4 policy. Stage 2 stream-copies the
# encoded video/audio and remuxes source subtitles/attachments, with mp4/
# m4v/mov mov_text converted for MKV.
# Dialogue-clarity audio filter: matches v4's HandBrake -D/--gain behavior
# (dynamic range compression + static gain) via ffmpeg's dynaudnorm + volume.
# AUDIO_DRC (HandBrake scale, 1.0=none) maps to dynaudnorm's max-gain factor;
# AUDIO_GAIN (dB) applies as a static gain afterward. Always applied — v4
# applies -D/--gain to every audio track regardless of codec.
ffmpeg_audio_filter_chain() {
  local acodec="$1" mgain chain
  mgain="$(awk -v d="$AUDIO_DRC" 'BEGIN{printf "%.1f", d*5}')"
  chain="dynaudnorm=f=250:g=15:m=${mgain},volume=${AUDIO_GAIN}dB"
  if [ "$acodec" = libopus ]; then
    chain="aformat=channel_layouts=7.1|5.1|stereo|mono,$chain"
  fi
  printf '%s' "$chain"
}

ffmpeg_encode() {
  local src="$1" dst="$2" codec="$3"
  local profile hdr=false hdr_mode crf resolved_crf rc acodec abr
  local -a args sub_args
  local real_dst="$dst"
  # Cleared unconditionally at entry, not just set on success: a prior
  # attempt for this SAME $src (e.g. an AV1 attempt whose QTGMC succeeded
  # and cached a value, later rejected by the size guard) must never
  # leak into a later, different attempt for the same source (e.g. an
  # x265 fallback whose own QTGMC failed transiently and took the bwdif
  # path instead) -- the $src-only match in write_ves_processed_tag can't
  # tell those two attempts' outputs apart on its own. Found by
  # independent multi-tool review, 2026-08-08.
  QTGMC_FINAL_VMAF_SRC=""
  QTGMC_FINAL_VMAF_DST=""
  QTGMC_FINAL_VMAF_VALUE=""
  dst="$(resolve_encode_stage_path "$src" "$real_dst")" || {
    warn "Cannot safely stage output for this title — skipping rather than risk the direct-write symlink race: $real_dst"
    return 1
  }

  profile="$(profile_for_source "$src")" || return $?

  # Vintage-profile real deinterlace (QTGMC), confidently-detected genuine
  # interlace only -- never telecine/progressive/ambiguous, and never
  # outside the two vintage profiles (see modules/ves-qtgmc.sh header +
  # approved plan, which explicitly scopes this to "old movies/TV" -- i.e.
  # BOTH `vintage` (Movies/*/Vintage/*) AND `vtv` (Television/*/Vintage/*),
  # not movies only). REAL BUG found and fixed 2026-08-08, caught only by
  # running an actual real-content encode through the unmocked production
  # profile-detection path: this check originally read `[ "$profile" =
  # vintage ]` alone, so every vintage TV title -- including Cosmos (1980)
  # S01E10, this whole feature's own positive-control interlaced test file
  # -- silently never triggered QTGMC OR the bwdif fallback in real
  # production, despite passing every test all session (every test up to
  # this point either force-set PROFILE_CONTEXT=vintage directly or used
  # SEARCH_PATH override, never exercising real detect_profile_for_path()
  # against a real vtv-classified library path). video_src is what
  # actually gets decoded for the encode (and for CRF search below, so the
  # search is calibrated against the same pixels the final encode uses --
  # an interlaced-vs-deinterlaced CRF/VMAF mismatch would make the search
  # meaningless). $src stays the original file for everything else (audio,
  # subtitles, chapters, attachments, HDR/DoVi metadata) -- QTGMC's
  # intermediate is a silent, metadata-stripped video-only file and must
  # never become the source for those.
  local video_src="$src"
  local needs_bwdif_fallback=false
  if { [ "$profile" = vintage ] || [ "$profile" = vtv ]; } && [ "$NO_AUTO_DETELECINE" != true ]; then
    detect_source_traits "$src" >/dev/null
    if [ "$(source_traits_field_mode "$src")" = interlaced ]; then
      if [ "$DRY_RUN" = true ]; then
        # Dry-run only reports what would happen — the real QTGMC pass is a
        # full transcode (minutes of real work), not cheap inspection like
        # the rest of this function's DRY_RUN-safe classification calls.
        log "[dry-run] would run QTGMC real deinterlace on: $(basename "$src")"
      elif qtgmc_available; then
        # NOT `local qtgmc_intermediate="$(...)"` -- under this script's
        # `set -euo pipefail`, a bare failing command substitution assignment
        # (unlike one combined with `local`) triggers errexit immediately,
        # aborting ffmpeg_encode() before `needs_bwdif_fallback=true` below
        # ever runs. Reproduced directly (team review, 2026-08-07): every
        # QTGMC failure -- missing vspipe, bad VS script, empty output, any
        # of qtgmc_deinterlace_to_intermediate's own documented failure
        # modes -- silently killed the whole encode instead of falling back
        # to bwdif. The `if` here is load-bearing, not stylistic.
        local qtgmc_intermediate=""
        if qtgmc_intermediate="$(qtgmc_deinterlace_to_intermediate "$src")" && \
           [ -n "$qtgmc_intermediate" ] && [ -s "$qtgmc_intermediate" ]; then
          video_src="$qtgmc_intermediate"
          # Nothing else in this codebase ever removed this staging
          # directory on the success path (only qtgmc_deinterlace_to_
          # intermediate's own failure branches did) -- every successful
          # QTGMC run permanently leaked its multi-GB lossless intermediate
          # on the RAM disk / staging location. `trap RETURN` fires on
          # every exit from this function (early returns included), so it
          # cleans up regardless of which path out of ffmpeg_encode() is
          # taken from here on. Found via the same real single-file
          # production test that found the QTGMC_FINAL_VMAF_* bug just
          # below, 2026-08-08.
          local qtgmc_stage_dir="$(dirname "$qtgmc_intermediate")"
          # trap - RETURN as the trap body's own first action is load-
          # bearing, not defensive: ffmpeg_encode() is called as the tail
          # statement of encode_dispatch() (no `return` after it), and a
          # RETURN trap fires once for the function that sets it AND AGAIN
          # for that function's caller's own return when the call was a
          # tail position -- reproduced directly in isolation, 2026-08-08.
          # Without self-clearing, the second firing ran inside
          # encode_dispatch()'s frame, where qtgmc_stage_dir was never
          # local, and crashed the whole job with "unbound variable" under
          # this script's `set -u` immediately after a fully successful
          # encode (caught by the same real single-file production test
          # that found the leak this trap fixes).
          trap 'rm -rf -- "$qtgmc_stage_dir" 2>/dev/null || true; trap - RETURN' RETURN
        else
          needs_bwdif_fallback=true
        fi
      else
        needs_bwdif_fallback=true
      fi
    fi
  fi

  resolve_upscale_target "$src"
  log "Encoder profile: $profile ($codec) — $(upscale_status_desc)"
  # determine_hdr_mode classifies plain HDR10/HLG AND every Dolby Vision case
  # (including profile 5, whose PQ tone curve lives entirely in the RPU with
  # no container-level color_transfer tag -- source_is_hdr_transfer alone
  # would miss it, which is exactly what caused the original tint bug).
  hdr_mode="$(determine_hdr_mode "$src")"
  case "$hdr_mode" in
    pq|pq_reconstruct|hlg) hdr=true ;;
    unknown)
      flag_bad_source_for_human "$src" "Dolby Vision detected but its profile/base-layer transfer couldn't be confidently classified — encoding it anyway risks the same wrong-color bug a Profile 5 source hit; needs manual review"
      return 1
      ;;
    *) hdr=false ;;
  esac

  # PROFILE_CONTEXT save/set/restore: when video_src is QTGMC's temp
  # intermediate (a path like .convert-stage-qtgmc-XXXXXX/qtgmc-deinterlaced.mkv,
  # nothing like the real library layout), resolve_crf_for_encode's own
  # internal vmaf_target_for_source() call re-derives the profile by parsing
  # that path -- which fails to classify as `vintage` (or anything), silently
  # degrading every QTGMC-processed title from real VMAF-targeted CRF search
  # down to a fixed CRF. PROFILE_CONTEXT is the existing, already-honored
  # override profile_for_source() checks first (see vmaf_crf_search_internal's
  # own save/restore of this same variable for its sample-encode helper) --
  # setting it here makes that internal lookup return the already-known-
  # correct `$profile` instead of trying to path-parse the temp file.
  local _saved_profile_context="$PROFILE_CONTEXT"
  PROFILE_CONTEXT="$profile"
  resolve_crf_for_encode "$video_src" "$codec" "$profile" "$hdr" resolved_crf
  crf="$resolved_crf"
  PROFILE_CONTEXT="$_saved_profile_context"

  rc=0
  # build_ffmpeg_video_args gets $src, not $video_src, even when QTGMC
  # succeeded: it only uses its `src` arg for metadata lookups (DoVi
  # profile, HDR10 static mastering/CLL SEI, upscale-target resolution) --
  # never for actual pixel data -- and QTGMC's intermediate is a silent,
  # metadata-stripped file that would make those lookups fail. Safe to
  # always pass $src here because QTGMC never changes frame width/height
  # (only frame rate, via FPSDivisor), so the resolution-based decisions
  # inside this function land on the same answer either way.
  build_ffmpeg_video_args "$codec" "$crf" "$src" "$profile" "$hdr" "$hdr_mode" || rc=$?
  if [ "$rc" -eq 2 ]; then
    flag_bad_source_for_human "$src" "Dolby Vision profile 5 requires libplacebo (not in this ffmpeg build)"
    return 1
  fi
  if [ "$needs_bwdif_fallback" = true ]; then
    local bwdif_parity="0"
    [ "$(source_traits_field_order "$src")" = bff ] && bwdif_parity="1"
    FF_VF=("bwdif=mode=send_field:parity=${bwdif_parity}" "${FF_VF[@]}")
    log "QTGMC unavailable/failed — using bwdif (parity=$bwdif_parity) as the deinterlace fallback: $(basename "$src")"
  fi

  case "$codec" in
    av1)  if [ "$FF_HAS_LIBOPUS" = true ]; then acodec="libopus"; abr="$OPUS_BITRATE_V5"; else acodec="aac"; abr="$AAC_BITRATE_V5"; fi ;;
    hevc) acodec="aac"; abr="$AAC_BITRATE_V5" ;;
  esac

  # Subtitle handling for the cheap stage-2 remux: bitmap+text subs copy
  # into MKV; mp4/m4v/mov mov_text must convert because Matroska cannot
  # mux it directly.
  sub_args=(-c:s copy)
  case "$(to_lower "${src##*.}")" in
    mp4|m4v|mov) sub_args=(-c:s srt) ;;
  esac

  # -v warning (was -v error) + a durable per-title stderr capture: both
  # part of the 2026-07-20 audio-truncation fix. -v error was silently
  # swallowing whatever ffmpeg had to say about the audio path faltering
  # on Angel Cop/5cm-per-Second; -v warning surfaces it, and capturing it
  # to a file that only this one attempt ever writes means a future
  # occurrence survives even if the shared per-run log gets overwritten by
  # a later, unrelated invocation (exactly what erased the evidence here).
  # max_muxing_queue_size raised from 2048 as cheap insurance against A/V
  # pipeline pressure on long/complex files (team review didn't confirm
  # this was the actual trigger, but there's no downside to more headroom);
  # thread_queue_size added on the input side for the same reason.
  # -fps_mode passthrough (2026-07-31, team review): low-risk
  # belt-and-suspenders addition after "KanColle The Movie (2016)" produced
  # a video stream that stalled well before real EOF on a long (93min)
  # subtitle+font-attachment-heavy source, on both AV1 and x265 attempts
  # independently.
  #
  # Two-stage muxing (2026-08-02): the empirical KanColle re-run proved
  # the minimal -max_interleave_delta/-flush_packets mitigation does not
  # fix the frame=324 truncation. Keep source subtitles/attachments out of
  # the live encode entirely; the main pass now produces video+audio only,
  # and a second cheap stream-copy remux adds source subtitles/attachments.
  # The old "retry without subtitles" still makes sense, but only as a
  # stage-2 fallback: odd subtitle codecs can still make the remux header
  # fail, and rerunning the expensive encode would be wasteful.
  local errbase encode_errfile remux_errfile retry_errfile stage1
  local -a remux_args remux_color_args
  errbase="${JOB_SIDECAR_DIR:-/tmp}/ffmpeg-logs"
  mkdir -p "$errbase" 2>/dev/null || true
  errbase="${errbase}/$(canonical_title_from_source "$src").$$"
  encode_errfile="${errbase}.stderr.log"
  remux_errfile="${errbase}.remux.stderr.log"
  retry_errfile="${errbase}.remux-nosubs.stderr.log"

  stage1="${dst}.video-audio-only.$$"
  ACTIVE_FFMPEG_STAGE1_FILE="$stage1"

  # video_src differs from src only when QTGMC produced a real (silent,
  # video-only) deinterlaced intermediate -- in that case audio must still
  # come from the original file, via a second input, or it would be lost
  # entirely (QTGMC's intermediate has no audio track at all).
  if [ "$video_src" != "$src" ]; then
    args=(-y -nostdin -v warning -stats
          -thread_queue_size 4096 -i "$video_src"
          -thread_queue_size 4096 -i "$src"
          -map 0:v:0 -map "1:a?"
          -map_chapters 1 -map_metadata 1
          "${FF_VIDEO_ARGS[@]}")
  else
    args=(-y -nostdin -v warning -stats -thread_queue_size 4096 -i "$src"
          -map 0:v:0 -map "0:a?"
          -map_chapters 0
          "${FF_VIDEO_ARGS[@]}")
  fi
  local vf_joined=""
  if [ "${#FF_VF[@]}" -gt 0 ]; then
    vf_joined="$(IFS=,; printf '%s' "${FF_VF[*]}")"
    args+=(-vf "$vf_joined")
  fi
  args+=(-c:a "$acodec" -b:a "$abr" -af "$(ffmpeg_audio_filter_chain "$acodec")")
  if [ "$acodec" = libopus ]; then args+=(-mapping_family 1); fi
  args+=(-max_muxing_queue_size 8192
         -fps_mode passthrough
         -f matroska "$stage1")

  if [ "$hdr" = true ]; then
    if [ "$hdr_mode" = hlg ]; then
      remux_color_args=(-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc)
    else
      remux_color_args=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)
    fi
  fi

  # Flagged-but-empty subtitle tracks (container index present, zero
  # renderable content) otherwise get mapped through by a blanket "1:s?"
  # and show up in a player as a meaningless selection -- filter to only
  # the source subtitle streams that actually have real content.
  build_real_subtitle_map_args 1 "$src"

  remux_args=(-y -nostdin -v warning -stats
              -thread_queue_size 4096 -i "$stage1"
              -thread_queue_size 4096 -i "$src"
              -map 0:v:0 -map "0:a?" "${REAL_SUBTITLE_MAP_ARGS[@]}" -map "1:t?"
              -map_chapters 1
              -c:v copy "${remux_color_args[@]}" -c:a copy
              "${sub_args[@]}"
              -max_muxing_queue_size 8192
              -fps_mode passthrough
              -max_interleave_delta 1000000
              -flush_packets 1
              -f matroska "$dst")

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] ffmpeg ${args[*]}"
    log "[dry-run] ffmpeg ${remux_args[*]}"
    ACTIVE_FFMPEG_STAGE1_FILE=""
    _cleanup_staged_file_dir "$dst"
    return 0
  fi

  log "ffmpeg encode stage 1/2 ($codec crf=$crf, profile=$profile$( [ "$hdr" = true ] && printf ', HDR10'), video+audio only): $(basename "$src")"
  rc=0
  run_tracked_encoder "ffmpeg encode" _run_capturing_stderr "$encode_errfile" "${FFMPEG_CMD[@]}" "${args[@]}" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$stage1" ]; then
    warn "ffmpeg stage-1 encode reported success but output is missing/empty: $stage1"
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    log "ffmpeg remux stage 2/2 (copying encoded video/audio plus source subtitles/attachments): $(basename "$src")"
    run_tracked_encoder "ffmpeg remux subtitles" _run_capturing_stderr "$remux_errfile" "${FFMPEG_CMD[@]}" "${remux_args[@]}" || rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "ffmpeg remux with subtitle/attachment streams failed (rc=$rc) — retrying final remux without subtitle/attachment streams — stderr: $remux_errfile"
      remux_args=(-y -nostdin -v warning -stats
                  -thread_queue_size 4096 -i "$stage1"
                  -map 0:v:0 -map "0:a?"
                  -map_chapters 0
                  -c:v copy "${remux_color_args[@]}" -c:a copy
                  -max_muxing_queue_size 8192
                  -fps_mode passthrough
                  -max_interleave_delta 1000000
                  -flush_packets 1
                  -f matroska "$dst")
      rc=0
      run_tracked_encoder "ffmpeg subtitle-stripped remux retry" _run_capturing_stderr "$retry_errfile" "${FFMPEG_CMD[@]}" "${remux_args[@]}" || rc=$?
    fi
  fi
  if [ "$rc" -eq 0 ] && [ ! -s "$dst" ]; then
    warn "ffmpeg reported success but output is missing/empty: $dst"
    rc=1
  fi
  # QTGMC_FINAL_VMAF_*: computed here, against $video_src (QTGMC's
  # deinterlaced intermediate), while that intermediate still exists --
  # the trap RETURN above deletes it as soon as this function returns.
  # write_ves_processed_tag's own measure_final_vmaf call only ever has
  # the ORIGINAL (raw interlaced/telecined) $src, and scoring a clean
  # deinterlaced output against a raw combed frame at the same timestamp
  # is not a meaningful comparison -- they are structurally different
  # images by design, not a quality regression. Real single-file
  # production test measured this as VMAF 4.9 for a genuinely correct
  # QTGMC encode, which would have wrongly flagged every future
  # QTGMC-processed title as a below-floor quality failure. 2026-08-08.
  if [ "$rc" -eq 0 ] && [ "$video_src" != "$src" ]; then
    local _qtgmc_final_vmaf=""
    # $UPSCALE_TARGET_HEIGHT (not a hardcoded 0): genuine interlaced
    # vintage content is SD (480i/576i), which resolve_upscale_target's
    # own threshold routinely upscales to 720p/1080p during the real
    # encode -- $dst is then that upscaled size while $video_src (QTGMC's
    # intermediate) stays SD. Without passing the target height through,
    # _vmaf_compare_window's libvmaf filter graph rejects the mismatched
    # dimensions outright (real ffmpeg test: "input width must match" /
    # "Failed to configure input pad", rc=234) on every sample, this
    # whole precomputed-VMAF path silently produces nothing, and
    # write_ves_processed_tag falls back to the exact wrong-reference
    # comparison this fix exists to avoid. Missed in the original fix
    # because the real test title (Cosmos S01E10, 1412x1074) happened to
    # be tall enough to skip upscaling -- the one case where 0 was right.
    # Already set correctly above (line ~368's resolve_upscale_target
    # "$src" call, nothing resets it before here). Found by independent
    # multi-tool review, 2026-08-08.
    _qtgmc_final_vmaf="$(measure_final_vmaf "$video_src" "$dst" "$UPSCALE_TARGET_HEIGHT" 2>/dev/null)" || _qtgmc_final_vmaf=""
    if [ -n "$_qtgmc_final_vmaf" ]; then
      # Keyed on $real_dst (the canonical output path, the same value
      # passed as $out/$mkv to finalize_mkv_output/write_ves_processed_tag
      # by every caller) as well as $src -- an earlier version matched on
      # $src alone, which could let a stale value from a DISCARDED attempt
      # (e.g. an AV1 output rejected by the size guard) get wrongly
      # consumed by a later, different attempt's output for the same
      # source (an x265 fallback, or the must-eliminate remux floor, whose
      # own QTGMC either wasn't run or failed differently). Found by
      # independent multi-tool review, 2026-08-08.
      QTGMC_FINAL_VMAF_SRC="$src"
      QTGMC_FINAL_VMAF_DST="$real_dst"
      QTGMC_FINAL_VMAF_VALUE="$_qtgmc_final_vmaf"
    fi
  fi
  # Script cleans up after itself: a clean encode with nothing logged at
  # -v warning gets its (empty) stderr file removed rather than left as
  # permanent per-title clutter. Anything actually written to it survives
  # -- that's a real warning trail worth keeping regardless of whether the
  # audio-truncation validation gate below happens to catch this instance.
  if [ "$rc" -eq 0 ]; then
    [ ! -s "$encode_errfile" ] && rm -f -- "$encode_errfile" 2>/dev/null
    [ ! -s "$remux_errfile" ] && rm -f -- "$remux_errfile" 2>/dev/null
    [ ! -s "$retry_errfile" ] && rm -f -- "$retry_errfile" 2>/dev/null
  fi
  rm -f -- "$stage1" 2>/dev/null
  ACTIVE_FFMPEG_STAGE1_FILE=""
  if [ "$rc" -eq 0 ] && [ "$dst" != "$real_dst" ]; then
    if finalize_staged_encode_output "$dst" "$real_dst"; then
      log "Ramdisk staging: moved finished output to $real_dst"
    else
      warn "Ramdisk staging: failed to move staged output to $real_dst"
      rc=1
    fi
  elif [ "$rc" -ne 0 ] && [ "$dst" != "$real_dst" ]; then
    rm -f "$dst" 2>/dev/null
    _cleanup_staged_file_dir "$dst"
  elif [ "$rc" -ne 0 ] && [ "$dst" = "$real_dst" ]; then
    # Phase C defense-in-depth (v5.0.33): currently unreachable.
    # resolve_encode_stage_path() fails closed — it returns 1 rather than
    # ever falling back to real_dst — and ffmpeg_encode() returns early on
    # that failure, before any encode/retry. This branch is kept as cheap
    # insurance so a future fail-open change to staging (or a new caller
    # that bypasses it) cannot silently leave a truncated direct-write
    # output behind. Not an active-bug fix; do not describe it as one.
    rm -f -- "$dst"
  fi
  return "$rc"
}

# Route an encode to ffmpeg (files) or HandBrake (discs / --engine handbrake).
# Args mirror handbrake_encode: src dst hb_encoder gpu hb_title
encode_dispatch() {
  local src="$1" dst="$2" hb_encoder="$3" gpu="${4:-}" hb_title="${5:-}"
  local codec

  if [ "$ENCODE_ENGINE" = handbrake ] || [ -n "$hb_title" ] || is_disk_source "$src"; then
    handbrake_encode "$src" "$dst" "$hb_encoder" "$gpu" "$hb_title"
    return $?
  fi

  case "$hb_encoder" in
    *av1*) codec=av1 ;;
    *) codec=hevc ;;
  esac
  # ffmpeg-engine display names are not HandBrake encoders — normalize if a
  # disc/handbrake dispatch ever receives one
  case "$hb_encoder" in
    ffmpeg/*) hb_encoder="$( [ "$codec" = av1 ] && printf svt_av1_10bit || printf x265 )" ;;
  esac

  # --prefer-hw: hardware encoder at fixed quality (speed mode; no VMAF search)
  if [ "$PREFER_HW_ENCODE" = true ]; then
    local hw=""
    case "$codec" in av1) hw="$FF_AV1_HW" ;; hevc) hw="$FF_HEVC_HW" ;; esac
    if [ -n "$hw" ]; then
      # Hardware encoders here have no libplacebo-equivalent filter, so a
      # Dolby Vision profile 5 source (needs RPU-based reconstruction) or an
      # unclassifiable DoVi source can't be handled safely on this path --
      # same graceful degrade already used just below for "no hw encoder at
      # all": use software for this one title rather than risk the exact
      # wrong-color bug a Profile 5 source hit on the plain hdr-flag miss.
      case "$(determine_hdr_mode "$src")" in
        pq_reconstruct|unknown)
          warn "--prefer-hw set but this source needs Dolby Vision handling no hardware encoder here can do — using software for this title"
          ;;
        *)
          ffmpeg_encode_hw "$src" "$dst" "$codec" "$hw"
          return $?
          ;;
      esac
    else
      warn "--prefer-hw set but no functional hardware $codec encoder — using software"
    fi
  fi

  ffmpeg_encode "$src" "$dst" "$codec"
}

# Hardware-encoder speed path (fixed quality, no VMAF search).
ffmpeg_encode_hw() {
  local src="$1" dst="$2" codec="$3" enc="$4"
  local -a vargs pre=()
  local q acodec abr hdr_mode
  local real_dst="$dst"

  # Defense in depth: encode_dispatch already routes pq_reconstruct/unknown
  # sources to software before calling here, but refuse directly too in case
  # this is ever reached another way -- there is no libplacebo-equivalent
  # filter on any hardware encode path in this script.
  hdr_mode="$(determine_hdr_mode "$src")"
  case "$hdr_mode" in
    pq_reconstruct|unknown)
      warn "Refusing hardware encode — this source needs Dolby Vision handling no hardware path here can do: $src"
      return 1
      ;;
  esac

  case "$enc" in
    av1_nvenc)  q=30; vargs=(-c:v av1_nvenc -preset p7 -tune "${NVENC_AV1_TUNE:-hq}" -rc vbr -cq "$q" -b:v 0 -multipass fullres -spatial-aq 1 -temporal-aq 1 -highbitdepth 1) ;;
    av1_qsv)    q=28; vargs=(-c:v av1_qsv -global_quality "$q" -preset veryslow) ;;
    av1_vaapi)  q=30; pre=(-vaapi_device "${FF_VAAPI_DEVICE:-/dev/dri/renderD128}"); vargs=(-vf "format=nv12,hwupload" -c:v av1_vaapi -rc_mode CQP -qp "$q") ;;
    hevc_nvenc) q=24; vargs=(-c:v hevc_nvenc -preset p7 -tune hq -rc vbr -cq "$q" -b:v 0 -multipass fullres -spatial-aq 1 -temporal-aq 1) ;;
    hevc_qsv)   q=22; vargs=(-c:v hevc_qsv -global_quality "$q" -preset veryslow) ;;
    hevc_videotoolbox) q=58; vargs=(-c:v hevc_videotoolbox -q:v "$q" -tag:v hvc1) ;;
    hevc_vaapi) q=22; pre=(-vaapi_device "${FF_VAAPI_DEVICE:-/dev/dri/renderD128}"); vargs=(-vf "format=nv12,hwupload" -c:v hevc_vaapi -rc_mode CQP -qp "$q") ;;
    hevc_amf)   q=22; vargs=(-c:v hevc_amf -quality quality -rc cqp -qp_i "$q" -qp_p "$q") ;;
    *) return 1 ;;
  esac
  case "$codec" in
    av1)  if [ "$FF_HAS_LIBOPUS" = true ]; then acodec=libopus; abr="$OPUS_BITRATE_V5"; else acodec=aac; abr="$AAC_BITRATE_V5"; fi ;;
    hevc) acodec=aac; abr="$AAC_BITRATE_V5" ;;
  esac
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] ffmpeg hw encode $enc q=$q: $src -> $dst"
    return 0
  fi
  dst="$(resolve_encode_stage_path "$src" "$real_dst")" || {
    warn "Cannot safely stage output for this title — skipping rather than risk the direct-write symlink race: $real_dst"
    return 1
  }
  log "ffmpeg hw encode ($enc q=$q): $(basename "$src")"
  local -a aextra=(-af "$(ffmpeg_audio_filter_chain "$acodec")")
  if [ "$acodec" = libopus ]; then aextra+=(-mapping_family 1); fi
  local -a hdr_tags=()
  case "$hdr_mode" in
    pq)  hdr_tags=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc) ;;
    hlg) hdr_tags=(-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc) ;;
  esac
  # `rc=0; cmd || rc=$?` (not a bare command then `local rc=$?` on the next
  # line): a failing run_tracked_encoder here is common (bad input, driver
  # crash, OOM) and a bare failure aborts the whole script under `set -e`
  # right there, before `rc=$?` ever runs -- verified via direct bash
  # testing, 2026-07-22 (team review flagged this exact pattern here and in
  # handbrake_encode/vaapi_hevc_encode/remux_copy_to_mkv).
  local rc=0
  build_real_subtitle_map_args 0 "$src"
  # mp4/m4v/mov -> srt exception, same as try_av1_convert's sub_args and
  # remux_copy_to_mkv's sub_codec -- Matroska cannot hold mov_text at all.
  # This hw-encode path hardcoded "-c:s copy" and was missed when that fix
  # went in elsewhere, so it would fail outright on any MP4 source with
  # subtitles (found in team review, 2026-08-02).
  local sub_codec="copy"
  case "$(to_lower "${src##*.}")" in
    mp4|m4v|mov) sub_codec="srt" ;;
  esac
  run_tracked_encoder "ffmpeg hardware encode" "${FFMPEG_CMD[@]}" -y -nostdin -v error -stats "${pre[@]}" -i "$src" \
    -map 0:v:0 -map "0:a?" "${REAL_SUBTITLE_MAP_ARGS[@]}" -map_chapters 0 \
    "${vargs[@]}" "${hdr_tags[@]}" -c:a "$acodec" -b:a "$abr" "${aextra[@]}" -c:s "$sub_codec" \
    -max_muxing_queue_size 2048 -f matroska "$dst" || rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$dst" ] && { warn "hw encode empty output: $dst"; rc=1; }
  if [ "$rc" -eq 0 ] && [ "$dst" != "$real_dst" ]; then
    if ! finalize_staged_encode_output "$dst" "$real_dst"; then
      warn "Output staging: failed to move staged hw-encode output to $real_dst"
      rc=1
    fi
  elif [ "$rc" -ne 0 ] && [ "$dst" != "$real_dst" ]; then
    rm -f "$dst" 2>/dev/null
    _cleanup_staged_file_dir "$dst"
  fi
  return "$rc"
}

# Called when x265 itself has just failed to produce a usable output (encode
# failure, validation failure) for a must-eliminate-format source (see
# is_must_eliminate_format). If try_av1_convert stashed an oversized AV1
# candidate for this source, salvage it instead of giving up and leaving the
# undesirable disc image/transport-stream/legacy container in place -- format
# elimination matters more than the size cap here. Echoes nothing; returns 0
# if it salvaged a candidate (caller should treat this as success), 1 if
# there was nothing to salvage (caller should proceed with its own failure).
must_eliminate_fallback_or_fail() {
  local src="$1"
  local title="${2:-}"
  # See try_av1_convert's matching param. Used here (not just $src) for
  # every is_must_eliminate_format gate and for flag_bad_source_for_human,
  # so a disc job's failure gets reported against the real ISO/BDMV, not
  # the temporary extraction symlink (which process_disk deletes right
  # after this returns regardless of outcome).
  local logical_source="${3:-$src}"
  local canonical_out owns_candidate=false
  # Ownership check: the global side-channel can outlive the call that set
  # it (e.g. a validation timeout elsewhere returns without clearing it), so
  # a later, unrelated title could otherwise wrongly consume -- or worse,
  # delete -- a stash that belongs to a DIFFERENT source. Only ever touch the
  # candidate if it's actually the stash this exact src's try_av1_convert
  # would have produced; a foreign candidate is left completely alone (its
  # own source will clean it up itself via try_av1_convert's entry cleanup).
  if [ -n "$MUST_ELIMINATE_AV1_CANDIDATE" ] && [ "$MUST_ELIMINATE_AV1_CANDIDATE" = "$(av1_output_path "$src").must_eliminate_stash" ]; then
    owns_candidate=true
  fi
  if [ "$owns_candidate" = true ] && [ -f "$MUST_ELIMINATE_AV1_CANDIDATE" ] && is_must_eliminate_format "$logical_source"; then
    canonical_out="$(av1_output_path "$src")"
    if mv -f -- "$MUST_ELIMINATE_AV1_CANDIDATE" "$canonical_out" 2>/dev/null; then
      log "x265 failed for must-eliminate format — salvaging oversized AV1 candidate instead: $canonical_out"
      finalize_mkv_output "$canonical_out" "$src" "$title"
      record_conversion_result "$src" "$canonical_out"
      MUST_ELIMINATE_AV1_CANDIDATE=""
      MUST_ELIMINATE_AV1_CANDIDATE_SIZE=""
      return 0
    fi
    warn "Could not restore stashed AV1 candidate to $canonical_out — discarding: $MUST_ELIMINATE_AV1_CANDIDATE"
    rm -f -- "$MUST_ELIMINATE_AV1_CANDIDATE" 2>/dev/null || true
  fi
  if [ "$owns_candidate" = true ]; then
    MUST_ELIMINATE_AV1_CANDIDATE=""
    MUST_ELIMINATE_AV1_CANDIDATE_SIZE=""
  fi
  # Nothing to salvage: both AV1 and x265 genuinely failed to encode/validate
  # for a must-eliminate-format source (not merely oversized). Left alone,
  # the undesirable disc image/transport-stream/legacy container would sit
  # forever with no path forward. Re-encoding is best-effort, but leaving the
  # source in .avi/.mpg/.rmvb/etc. is never acceptable (user decision,
  # 2026-07-30) -- fall back to a plain lossless stream-copy remux into MKV
  # as a floor before giving up entirely. This is deliberately scoped to
  # must-eliminate sources only: an ordinary file (e.g. a ordinary .mp4/.mkv
  # that just doesn't compress well, or fails validation for unrelated
  # reasons) failing both encoders just stays in place for retry, same as
  # always -- this floor only exists to guarantee legacy containers never
  # get stuck.
  #
  # Explicitly excludes disc sources (! is_disk_source "$logical_source"):
  # $src here is a symlink to a temporary LOSSLESS extraction, not the real
  # disc -- "stream-copy remuxing" it would just produce another huge
  # lossless file, defeating the entire point of this floor (a cheap,
  # small container fix for formats ffmpeg can trivially demux, which a
  # raw ISO/BDMV structure never was in the first place -- that's exactly
  # why HandBrake's lossless extraction exists as a separate step). A disc
  # job with no salvageable AV1/x265 candidate has no valid cheap floor;
  # falls through to flag_bad_source_for_human below instead. Team review,
  # 2026-07-31.
  if is_must_eliminate_format "$logical_source" && ! is_disk_source "$logical_source"; then
    local remux_out
    remux_out="$(must_eliminate_remux_path "$src")"
    # Same collision/symlink guards as try_av1_convert/try_x265_convert's
    # entry checks (see the matching comments there) -- this fallback writes
    # to a NEW bare Title.mkv path that those functions never computed or
    # checked, so it needs its own equivalent safety net rather than
    # inheriting theirs.
    if [ "$(canonical_path "$src" 2>/dev/null || printf '%s' "$src")" = "$(canonical_path "$remux_out" 2>/dev/null || printf '%s' "$remux_out")" ]; then
      flag_bad_source_for_human "$logical_source" "must-eliminate remux fallback path collides with the source itself — needs manual rename/review"
      return 1
    elif [ -L "$remux_out" ]; then
      flag_bad_source_for_human "$logical_source" "must-eliminate remux fallback path is an unexpected symlink — needs manual review"
      return 1
    elif [ -e "$remux_out" ]; then
      flag_bad_source_for_human "$logical_source" "must-eliminate remux fallback path already exists and doesn't look like our own output — needs manual review before overwriting"
      return 1
    fi
    log "Both AV1 and x265 failed for must-eliminate format — falling back to plain stream-copy remux: $remux_out"
    if remux_copy_to_mkv "$src" "$remux_out"; then
      MKV_VALIDATE_TIMED_OUT=false
      if validate_mkv_output "$src" "$remux_out"; then
        finalize_mkv_output "$remux_out" "$src" "$title"
        record_conversion_result "$src" "$remux_out"
        return 0
      fi
      if [ "$MKV_VALIDATE_TIMED_OUT" = true ]; then
        warn "Validation timed out for remux fallback $remux_out — leaving in place for retry next run"
        return 1
      fi
      warn "Stream-copy remux fallback failed validation for must-eliminate format: $src"
      remove_output_only "$remux_out"
    else
      warn "Stream-copy remux fallback failed for must-eliminate format: $src"
    fi
    flag_bad_source_for_human "$logical_source" "both AV1 and x265 transcodes failed, and the plain stream-copy remux fallback also failed — cannot eliminate undesirable format automatically"
  elif is_must_eliminate_format "$logical_source"; then
    flag_bad_source_for_human "$logical_source" "both AV1 and x265 transcodes failed on this disc's extracted title, and a disc source has no cheap remux floor — needs manual review"
  fi
  return 1
}
