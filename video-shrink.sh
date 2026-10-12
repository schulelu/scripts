#!/usr/bin/env bash
#
# video-shrink.sh — re-encode a video down to a mobile-sized file
#
# A wrapper around ffmpeg, not a replacement for it: it probes the source,
# offers the resize/fps/quality choices that actually matter on a phone, prints
# the ffmpeg command it assembled, and runs it. The printed command is half the
# point — copy it if you want to run the same encode without this script.
#
set -euo pipefail

SCRIPT_NAME="video-shrink"
SCRIPT_VERSION="1.0.0"

# --- Configuration ---
DEFAULT_HEIGHT="720"      # 720p is the sweet spot: fills a phone screen, ~1/6 the bits of 1080p
DEFAULT_CRF="26"          # x264 CRF for 720p mobile. Lower = better = bigger.
DEFAULT_CRF_H265="30"     # x265 CRF numbers are not x264 numbers; ~+4 is the same quality
DEFAULT_AUDIO="128k"
DEFAULT_PRESET="veryfast"
DEFAULT_CODEC="h264"
# Mux overhead: the container and its index are not free, and the rate control
# only aims at the video stream. 2% keeps a --target-size run under the limit.
OVERHEAD_PCT="2"

# --- Color Output ---
RED=""
GREEN=""
YELLOW=""
CYAN=""
BOLD=""
RESET=""

function color_init() {
    # TERM check too: inside a tty with no TERM set (cron -t, some CI runners)
    # tput exits non-zero and set -e would take the whole script down with it.
    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        CYAN=$(tput setaf 6)
        BOLD=$(tput bold)
        RESET=$(tput sgr0)
    fi
}

function log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local color=""

    case "$level" in
        INFO)   color="$GREEN" ;;
        WARN)   color="$YELLOW" ;;
        ERROR)  color="$RED" ;;
        PHASE)  color="${BOLD}${CYAN}" ;;
    esac

    echo "${color}[${level}]${RESET} ${msg}"
}

function die() {
    # stderr, not stdout: several functions return their value via stdout inside
    # $( ), and an error written there would be silently captured instead of shown.
    log_msg ERROR "$@" >&2
    exit 1
}

function confirm() {
    local prompt="$1"
    # Read from /dev/tty so a piped stdin does not silently auto-answer.
    if [[ ! -t 0 && ! -e /dev/tty ]]; then
        log_msg WARN "No terminal available — declining: $prompt"
        return 1
    fi
    echo -n "${YELLOW}${prompt} [y/N]${RESET} "
    local answer
    read -r answer </dev/tty
    [[ "$answer" =~ ^[Yy]$ ]]
}

function ask() {
    # Prompt with a default; empty answer keeps the default. Prints to stderr so
    # the answer can be captured with $( ).
    local prompt="$1" default="$2" answer
    if [[ "$OPT_YES" == "true" || ( ! -t 0 && ! -e /dev/tty ) ]]; then
        printf '%s\n' "$default"
        return 0
    fi
    echo -n "${CYAN}${prompt}${RESET} [${BOLD}${default}${RESET}]: " >&2
    read -r answer </dev/tty
    printf '%s\n' "${answer:-$default}"
}

function require_deps() {
    local dep missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]} — install with: apt-get install ffmpeg"
    fi
}

# --- Cleanup ---

TMPFILES=()

function cleanup() {
    local f
    for f in "${TMPFILES[@]+"${TMPFILES[@]}"}"; do
        [[ -n "$f" ]] && rm -f -- "$f" "$f"-*.log "$f"-*.log.mbtree
    done
    return 0
}

# --- Probing ---

function probe_video() {
    # "W H FPS DURATION VIDEO_KBPS ACODEC AUDIO_KBPS" on stdout. One ffprobe call,
    # not five: each one re-opens and re-indexes the file.
    local file="$1"
    [[ -f "$file" ]] || die "No such file: $file"

    local dump
    dump="$(ffprobe -v error -show_entries \
        "stream=codec_type,codec_name,width,height,r_frame_rate,bit_rate:format=duration,bit_rate" \
        -of default -- "$file" 2>/dev/null)" \
        || die "ffprobe could not read '$file' — is it a video?"

    [[ -n "$dump" ]] || die "ffprobe found no streams in '$file'"

    # One pass over the key=value dump, keeping the first video and the first
    # audio stream — the only two we ever map. The [STREAM] markers are what
    # makes this unambiguous: codec_type arrives *after* codec_name, and
    # bit_rate means something different inside [FORMAT], so the fields are
    # buffered per section and only claimed once the section ends.
    awk -F= '
        function flush() {
            if (t == "video" && !gotv) { gotv=1; w=cw; h=ch; fr=cfr; vb=cbr }
            if (t == "audio" && !gota) { gota=1; ac=cname; ab=cbr }
            t=""; cw=""; ch=""; cfr=""; cbr=""; cname=""
        }
        /^\[STREAM\]/  { sec="stream"; next }
        /^\[\/STREAM\]/ { flush(); sec=""; next }
        /^\[FORMAT\]/  { sec="format"; next }
        /^\[\/FORMAT\]/ { sec=""; next }
        sec=="stream" && $1=="codec_type"   { t=$2 }
        sec=="stream" && $1=="codec_name"   { cname=$2 }
        sec=="stream" && $1=="width"        { cw=$2 }
        sec=="stream" && $1=="height"       { ch=$2 }
        sec=="stream" && $1=="r_frame_rate" { cfr=$2 }
        sec=="stream" && $1=="bit_rate"     { cbr=$2 }
        sec=="format" && $1=="duration"     { d=$2 }
        sec=="format" && $1=="bit_rate"     { fb=$2 }
        END {
            split(fr, p, "/")
            fps = (p[2] > 0) ? p[1]/p[2] : 0
            # Some muxers report no per-stream bitrate. Falling back to the
            # container rate is wrong by the size of the audio, but a displayed
            # 0 Mbit/s is wrong by everything.
            if (vb+0 == 0) vb = fb
            printf "%d %d %.3f %.3f %d %s %d\n",
                w, h, fps, d, (vb+0)/1000, (ac == "" ? "none" : ac), (ab+0)/1000
        }' <<<"$dump"
}

function human_size() {
    local bytes="$1"
    awk -v b="$bytes" 'BEGIN {
        if (b >= 1073741824) printf "%.2f GB\n", b/1073741824
        else if (b >= 1048576) printf "%.1f MB\n", b/1048576
        else printf "%.0f kB\n", b/1024
    }'
}

function show_source() {
    local file="$1" w="$2" h="$3" fps="$4" dur="$5" vkbps="$6" acodec="$7" akbps="$8"
    local bytes
    bytes=$(stat -c %s -- "$file")

    echo
    echo "${BOLD}SOURCE${RESET}  $(basename -- "$file")"
    printf '  %-12s %s\n' "size"       "$(human_size "$bytes")"
    printf '  %-12s %dx%d (%s)\n' "resolution" "$w" "$h" "$(orientation "$w" "$h")"
    printf '  %-12s %s\n' "framerate"  "$(awk -v f="$fps" 'BEGIN{printf "%g fps", f}')"
    printf '  %-12s %s\n' "duration"   "$(awk -v d="$dur" 'BEGIN{printf "%d:%05.2f", int(d/60), d%60}')"
    printf '  %-12s %s\n' "video"      "$(awk -v k="$vkbps" 'BEGIN{printf "%.2f Mbit/s", k/1000}')"
    if [[ "$acodec" == "none" ]]; then
        printf '  %-12s %s\n' "audio"  "(none)"
    else
        printf '  %-12s %s @ %s kbit/s\n' "audio" "$acodec" "$akbps"
    fi
    echo
}

function orientation() {
    [[ "$2" -gt "$1" ]] && { echo "portrait"; return; }
    echo "landscape"
}

# --- Pure helpers ---

function scale_filter() {
    # Landscape scales by height, portrait by the short side (its width), so
    # "720p" means the same number of pixels across either way. -2 lets ffmpeg
    # pick the other side and keeps it even, which yuv420p requires.
    # Empty output = source is already at or below the target: no scaling.
    local sw="$1" sh="$2" target="$3"
    local short=$(( sw < sh ? sw : sh ))

    [[ "$target" -ge "$short" ]] && return 0

    if [[ "$sh" -gt "$sw" ]]; then
        printf 'scale=%d:-2\n' "$target"
    else
        printf 'scale=-2:%d\n' "$target"
    fi
}

function parse_size() {
    # "25M" / "25MB" / "1.5G" / "20000k" / "1048576" -> bytes.
    local s="${1^^}"
    local num unit
    [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)(K|KB|M|MB|G|GB|B)?$ ]] \
        || die "Cannot parse size '$1' — use e.g. 25M, 500k, 1.5G"
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]:-B}"

    local mult=1
    case "$unit" in
        K|KB) mult=1024 ;;
        M|MB) mult=1048576 ;;
        G|GB) mult=1073741824 ;;
    esac
    awk -v n="$num" -v m="$mult" 'BEGIN{ printf "%d\n", n*m }'
}

function calc_video_kbps() {
    # Total budget minus the audio track, minus mux overhead. The audio is a
    # fixed cost: subtract it before handing the rest to the video encoder, or
    # the file lands over the limit by exactly the size of the audio.
    local bytes="$1" dur="$2" audio_kbps="$3"
    [[ $(awk -v d="$dur" 'BEGIN{print (d > 0)}') == 1 ]] || die "Cannot compute bitrate: unknown duration"

    local kbps
    kbps=$(awk -v b="$bytes" -v d="$dur" -v a="$audio_kbps" -v o="$OVERHEAD_PCT" \
        'BEGIN{ printf "%d\n", (b*8/d/1000) * (1 - o/100) - a }')

    [[ "$kbps" -ge 64 ]] || die "Target size too small for a ${dur}s clip with ${audio_kbps}k audio (leaves ${kbps}k for video) — raise --target-size or lower --audio"
    printf '%s\n' "$kbps"
}

function out_name() {
    local in="$1" height="$2"
    local dir base
    dir="$(dirname -- "$in")"
    base="$(basename -- "$in")"
    base="${base%.*}"
    printf '%s/%s-mobile-%sp.mp4\n' "$dir" "$base" "$height"
}

function build_args() {
    # Fills the global FF_ARGS array with everything after "ffmpeg".
    # pass: 0 = single (CRF or 1-pass ABR), 1 = analysis pass, 2 = final pass.
    local in="$1" out="$2" vf="$3" fps="$4" src_fps="$5" codec="$6" \
          crf="$7" vkbps="$8" audio="$9" preset="${10}" pass="${11}" passlog="${12:-}"

    local enc="libx264" profile=("-profile:v" "main" "-level" "4.0")
    if [[ "$codec" == "h265" ]]; then
        enc="libx265"
        # hvc1 instead of the default hev1: Apple players show a black frame otherwise.
        profile=("-tag:v" "hvc1")
    fi

    FF_ARGS=(-hide_banner -y -i "$in")
    # Map explicitly: sources carry timecode and data tracks that have no business
    # in a mobile file, and "everything by default" is not what -i gives you anyway.
    FF_ARGS+=(-map 0:v:0)
    [[ "$pass" != "1" ]] && FF_ARGS+=(-map "0:a:0?")

    [[ -n "$vf" ]] && FF_ARGS+=(-vf "$vf")
    # Only touch the framerate when it actually changes — -r on an unchanged rate
    # still forces a frame-rate conversion filter.
    [[ "$fps" != "$src_fps" ]] && FF_ARGS+=(-r "$fps")

    FF_ARGS+=(-c:v "$enc" -preset "$preset" "${profile[@]}" -pix_fmt yuv420p)

    if [[ -n "$vkbps" ]]; then
        FF_ARGS+=(-b:v "${vkbps}k" -maxrate "$(( vkbps * 2 ))k" -bufsize "$(( vkbps * 4 ))k")
    else
        FF_ARGS+=(-crf "$crf")
    fi

    if [[ "$pass" == "1" ]]; then
        # x265 spells its pass flag differently, and only inside -x265-params.
        if [[ "$codec" == "h265" ]]; then
            FF_ARGS+=(-x265-params "pass=1:stats=${passlog}")
        else
            FF_ARGS+=(-pass 1 -passlogfile "$passlog")
        fi
        FF_ARGS+=(-an -f null /dev/null)
        return 0
    fi

    if [[ "$pass" == "2" ]]; then
        if [[ "$codec" == "h265" ]]; then
            FF_ARGS+=(-x265-params "pass=2:stats=${passlog}")
        else
            FF_ARGS+=(-pass 2 -passlogfile "$passlog")
        fi
    fi

    if [[ "$audio" == "copy" ]]; then
        FF_ARGS+=(-c:a copy)
    elif [[ "$audio" == "none" ]]; then
        FF_ARGS+=(-an)
    else
        FF_ARGS+=(-c:a aac -b:a "$audio" -ac 2)
    fi

    # faststart moves the index to the front: playback starts before the whole
    # file has arrived, which is the entire difference on a phone over mobile data.
    # write_tmcd=0 because -map alone does not stop a timecode track: the mp4
    # muxer re-creates one from the stream metadata, and it lands in the output
    # as an unknown data stream that some mobile players refuse to open.
    FF_ARGS+=(-movflags +faststart -write_tmcd 0 "$out")
}

function show_command() {
    echo
    echo "${BOLD}COMMAND${RESET}"
    printf '  ffmpeg'
    printf ' %q' "${FF_ARGS[@]}"
    echo
    echo
}

# --- Wizard ---

function pick_height() {
    # Menu of standard heights, source first, upscales left out — re-encoding
    # 720p up to 1080p costs bits and adds nothing.
    local sw="$1" sh="$2"
    local short=$(( sw < sh ? sw : sh ))
    local -a heights=() labels=()
    local default_idx=1 h idx=0 n=0

    for h in 1080 720 540 480 360; do
        [[ "$h" -gt "$short" ]] && continue
        n=$((n + 1))
        heights+=("$h")
        local w
        if [[ "$sh" -gt "$sw" ]]; then
            w=$(awk -v a="$sh" -v b="$sw" -v t="$h" 'BEGIN{printf "%d", int(a*t/b/2)*2}')
            labels+=("${h}p  (${h}x${w})")
        else
            w=$(awk -v a="$sw" -v b="$sh" -v t="$h" 'BEGIN{printf "%d", int(a*t/b/2)*2}')
            labels+=("${h}p  (${w}x${h})")
        fi
        [[ "$h" == "$short" ]] && labels[$((n-1))]="${labels[$((n-1))]}  = source, no resize"
        [[ "$h" == "$DEFAULT_HEIGHT" ]] && default_idx="$n"
    done

    # Source shorter than 360p: nothing to offer but itself.
    if [[ "$n" -eq 0 ]]; then
        printf '%s\n' "$short"
        return 0
    fi

    echo "${BOLD}RESIZE${RESET}" >&2
    for idx in $(seq 0 $((n - 1))); do
        printf '  %d) %s\n' "$((idx + 1))" "${labels[$idx]}" >&2
    done
    printf '  %d) custom height\n' "$((n + 1))" >&2

    local choice
    choice="$(ask "  choose" "$default_idx")"
    if [[ "$choice" == "$((n + 1))" ]]; then
        choice="$(ask "  height in pixels" "$DEFAULT_HEIGHT")"
        [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 16 ]] || die "Invalid height '$choice'"
        printf '%s\n' "$choice"
        return 0
    fi
    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$n" ]] || die "Invalid choice '$choice'"
    printf '%s\n' "${heights[$((choice - 1))]}"
}

# --- Commands ---

function cmd_info() {
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh info <file>"
    require_deps ffprobe

    local w h fps dur vkbps acodec akbps
    read -r w h fps dur vkbps acodec akbps <<<"$(probe_video "$1")"
    show_source "$1" "$w" "$h" "$fps" "$dur" "$vkbps" "$acodec" "$akbps"
}

OPT_HEIGHT=""
OPT_FPS=""
OPT_CRF=""
OPT_TARGET=""
OPT_AUDIO=""
OPT_CODEC=""
OPT_PRESET="$DEFAULT_PRESET"
OPT_YES="false"

function cmd_mobile() {
    require_deps ffmpeg ffprobe stat

    local in="" out=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scale|--height) OPT_HEIGHT="${2:-}"; shift 2 ;;
            --fps)            OPT_FPS="${2:-}"; shift 2 ;;
            --crf)            OPT_CRF="${2:-}"; shift 2 ;;
            --target-size)    OPT_TARGET="${2:-}"; shift 2 ;;
            --audio)          OPT_AUDIO="${2:-}"; shift 2 ;;
            --codec)          OPT_CODEC="${2:-}"; shift 2 ;;
            --preset)         OPT_PRESET="${2:-}"; shift 2 ;;
            -y|--yes)         OPT_YES="true"; shift ;;
            -*)               die "Unknown option: $1" ;;
            *)
                if [[ -z "$in" ]]; then in="$1"
                elif [[ -z "$out" ]]; then out="$1"
                else die "Unexpected argument: $1"
                fi
                shift ;;
        esac
    done

    [[ -n "$in" ]] || die "Usage: $SCRIPT_NAME.sh mobile <file> [out.mp4] [options]"

    local w h fps dur vkbps acodec akbps
    read -r w h fps dur vkbps acodec akbps <<<"$(probe_video "$in")"
    show_source "$in" "$w" "$h" "$fps" "$dur" "$vkbps" "$acodec" "$akbps"

    local src_fps
    src_fps=$(awk -v f="$fps" 'BEGIN{printf "%g", f}')

    # --- height ---
    local height="$OPT_HEIGHT"
    if [[ -z "$height" ]]; then
        if [[ "$OPT_YES" == "true" || ( ! -t 0 && ! -e /dev/tty ) ]]; then
            local short=$(( w < h ? w : h ))
            height=$(( DEFAULT_HEIGHT < short ? DEFAULT_HEIGHT : short ))
        else
            height="$(pick_height "$w" "$h")"
        fi
    fi
    [[ "$height" =~ ^[0-9]+$ ]] || die "Invalid height '$height'"

    # --- fps ---
    local target_fps="$OPT_FPS"
    [[ -n "$target_fps" ]] || target_fps="$(ask "FPS      (source ${src_fps}, or 30/24/15)" "$src_fps")"
    [[ "$target_fps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "Invalid fps '$target_fps'"
    # Never raise the framerate: duplicating frames costs bits and buys nothing.
    if [[ $(awk -v t="$target_fps" -v s="$src_fps" 'BEGIN{print (t > s)}') == 1 ]]; then
        log_msg WARN "Source is only ${src_fps} fps — keeping it instead of upsampling to ${target_fps}"
        target_fps="$src_fps"
    fi

    # --- quality: CRF or target size ---
    local codec="$OPT_CODEC"
    local crf="$OPT_CRF" target="$OPT_TARGET"
    if [[ -z "$crf" && -z "$target" ]]; then
        local answer
        answer="$(ask "QUALITY  crf 23=better / 26=default / 28=smaller, or a size like 25M" "$DEFAULT_CRF")"
        if [[ "$answer" =~ ^[0-9]+$ && "$answer" -le 51 ]]; then
            crf="$answer"
        else
            target="$answer"
        fi
    fi

    # --- audio ---
    local audio="$OPT_AUDIO"
    if [[ "$acodec" == "none" ]]; then
        audio="none"
    elif [[ -z "$audio" ]]; then
        audio="$(ask "AUDIO    128k / 96k / 64k / copy" "$DEFAULT_AUDIO")"
    fi
    [[ "$audio" =~ ^([0-9]+k|copy|none)$ ]] || die "Invalid audio '$audio' — use 128k, 96k, 64k, copy or none"

    # --- codec ---
    [[ -n "$codec" ]] || codec="$(ask "CODEC    h264 (plays everywhere) / h265 (~30% smaller, patchier support)" "$DEFAULT_CODEC")"
    [[ "$codec" == "h264" || "$codec" == "h265" ]] || die "Invalid codec '$codec' — h264 or h265"
    # x265's CRF scale is not x264's: the same number is a visibly worse picture.
    [[ -z "$OPT_CRF" && -n "$crf" && "$codec" == "h265" && "$crf" == "$DEFAULT_CRF" ]] && crf="$DEFAULT_CRF_H265"

    # --- output path ---
    [[ -n "$out" ]] || out="$(out_name "$in" "$height")"
    [[ "$(readlink -f -- "$out")" != "$(readlink -f -- "$in")" ]] || die "Output would overwrite the source: $out"
    if [[ -e "$out" && "$OPT_YES" != "true" ]]; then
        confirm "$out exists — overwrite?" || die "Aborted"
    fi

    local vf
    vf="$(scale_filter "$w" "$h" "$height")"
    [[ -n "$vf" ]] || log_msg INFO "Source is already ${height}p or smaller — not scaling"

    # --- assemble and run ---
    local audio_kbps=0
    [[ "$audio" =~ ^([0-9]+)k$ ]] && audio_kbps="${BASH_REMATCH[1]}"
    [[ "$audio" == "copy" ]] && audio_kbps="$akbps"

    if [[ -n "$target" ]]; then
        local bytes vkbps_target passlog
        bytes="$(parse_size "$target")"
        vkbps_target="$(calc_video_kbps "$bytes" "$dur" "$audio_kbps")"
        passlog="$(mktemp -u -t "${SCRIPT_NAME}-pass.XXXXXX")"
        TMPFILES+=("$passlog")

        log_msg INFO "Target $(human_size "$bytes") → ${vkbps_target} kbit/s video + ${audio_kbps} kbit/s audio (2-pass)"
        build_args "$in" "$out" "$vf" "$target_fps" "$src_fps" "$codec" "" "$vkbps_target" "$audio" "$OPT_PRESET" 2 "$passlog"
        show_command
        [[ "$OPT_YES" == "true" ]] || confirm "Encode now?" || die "Aborted"

        log_msg PHASE "Pass 1 of 2 (analysis)"
        build_args "$in" "$out" "$vf" "$target_fps" "$src_fps" "$codec" "" "$vkbps_target" "$audio" "$OPT_PRESET" 1 "$passlog"
        ffmpeg "${FF_ARGS[@]}" || die "Pass 1 failed"

        log_msg PHASE "Pass 2 of 2 (encode)"
        build_args "$in" "$out" "$vf" "$target_fps" "$src_fps" "$codec" "" "$vkbps_target" "$audio" "$OPT_PRESET" 2 "$passlog"
        ffmpeg "${FF_ARGS[@]}" || die "Pass 2 failed"
    else
        build_args "$in" "$out" "$vf" "$target_fps" "$src_fps" "$codec" "$crf" "" "$audio" "$OPT_PRESET" 0
        show_command
        [[ "$OPT_YES" == "true" ]] || confirm "Encode now?" || die "Aborted"

        log_msg PHASE "Encoding"
        ffmpeg "${FF_ARGS[@]}" || die "Encode failed"
    fi

    local in_bytes out_bytes
    in_bytes=$(stat -c %s -- "$in")
    out_bytes=$(stat -c %s -- "$out")
    log_msg INFO "Wrote $out"
    log_msg INFO "$(human_size "$in_bytes") → $(human_size "$out_bytes") ($(awk -v a="$in_bytes" -v b="$out_bytes" 'BEGIN{printf "%.0f%% smaller", (1-b/a)*100}'))"
}

# --- usage / dispatch ---

function usage() {
    cat <<EOF
${BOLD}$SCRIPT_NAME.sh${RESET} v$SCRIPT_VERSION — re-encode a video down to a mobile-sized file

${BOLD}USAGE${RESET}
    ./$SCRIPT_NAME.sh <command> [args]

${BOLD}COMMANDS${RESET}
    info <file>                 Show resolution, fps, duration, bitrates, size.
    mobile <file> [out.mp4]     Show the source, ask for the settings, print the
                                ffmpeg command, encode. Output defaults to
                                <name>-mobile-<height>p.mp4 next to the source.

${BOLD}OPTIONS${RESET} (mobile) — any you pass are not asked for
    --scale <h>        Target height, e.g. 720. Portrait video scales by its
                       short side, so 720 means 720 across either way.
                       Never upscales. (default: $DEFAULT_HEIGHT)
    --fps <n>          Output framerate (default: keep the source's).
    --crf <n>          Quality, 18-32. Lower is better and bigger.
                       (default: $DEFAULT_CRF for h264, $DEFAULT_CRF_H265 for h265)
    --target-size <s>  Hard size cap, e.g. 25M / 500k / 1.5G. Switches to a
                       2-pass encode at the bitrate that fits. Overrides --crf.
    --audio <rate>     128k / 96k / 64k / copy / none (default: $DEFAULT_AUDIO)
    --codec h264|h265  h264 plays everywhere; h265 is ~30% smaller but Firefox
                       and older Android will not touch it. (default: $DEFAULT_CODEC)
    --preset <p>       x264/x265 preset: ultrafast … veryslow. Slower = smaller
                       at the same quality. (default: $DEFAULT_PRESET)
    -y, --yes          No prompts: take the defaults and encode.

${BOLD}CRF OR TARGET SIZE${RESET}
    CRF asks for a quality and lets the size land where it lands — the right
    default, because an easy clip then costs fewer bits instead of being padded
    up to a number. Use --target-size only when something else imposes the limit
    (a mail attachment, a Discord upload, a 25 MB form field).

${BOLD}EXAMPLES${RESET}
    # What am I dealing with
    ./$SCRIPT_NAME.sh info ~/Downloads/clip.mp4

    # Ask me everything (720p / crf 26 / 128k aac by default)
    ./$SCRIPT_NAME.sh mobile ~/Downloads/clip.mp4

    # Same, no questions
    ./$SCRIPT_NAME.sh mobile ~/Downloads/clip.mp4 --yes

    # Must fit in a 25 MB upload
    ./$SCRIPT_NAME.sh mobile ~/Downloads/clip.mp4 --target-size 25M --yes

    # Small as it goes and still universally playable
    ./$SCRIPT_NAME.sh mobile ~/Downloads/clip.mp4 --scale 480 --fps 24 \\
        --crf 30 --audio 64k --preset slow --yes
EOF
}

function main() {
    color_init
    trap cleanup EXIT

    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local cmd="$1"; shift

    case "$cmd" in
        info)           cmd_info "$@" ;;
        mobile|shrink)  cmd_mobile "$@" ;;
        help|--help|-h) usage ;;
        --version)      echo "$SCRIPT_NAME $SCRIPT_VERSION" ;;
        *)              log_msg ERROR "Unknown command: $cmd"; usage; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
