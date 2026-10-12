#!/usr/bin/env bash
# Self-check for video-shrink.sh: scaling maths, size parsing, bitrate budget,
# and ffmpeg argument assembly. No root, no system changes. The last block does
# one 2-second encode from a generated test pattern — the only way to prove the
# argument array is valid ffmpeg and not merely well-formed strings.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# main() is guarded in video-shrink.sh, so sourcing only loads the functions.
source ./video-shrink.sh
set +e   # allow negative tests (non-zero returns) without aborting

fail=0
check() {
    local desc="$1" expected="$2" got="$3"
    if [[ "$got" == "$expected" ]]; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc — expected [$expected], got [$got]"
        fail=1
    fi
}

# --- scale filter ---
# Landscape scales by height, portrait by width, so "720" is the short side in
# both cases. Getting this backwards turns a 1080x1920 phone clip into 720x1280
# *upscaled* to 1280x2276 — bigger than the source it was meant to shrink.
check "landscape scales by height" "scale=-2:720"  "$(scale_filter 1920 1080 720)"
check "portrait scales by width"   "scale=720:-2"  "$(scale_filter 1080 1920 720)"
check "square scales by height"    "scale=-2:480"  "$(scale_filter 1000 1000 480)"
check "no upscale"                 ""              "$(scale_filter 1280 720 1080)"
check "equal size is a no-op"      ""              "$(scale_filter 1280 720 720)"
check "4:3 source"                 "scale=-2:360"  "$(scale_filter 640 480 360)"
# -2 (not -1) is what keeps the computed side even; yuv420p cannot encode an
# odd dimension and ffmpeg aborts with "width not divisible by 2".
check "odd source still uses -2"   "scale=-2:360"  "$(scale_filter 1921 1081 360)"

# --- size parsing ---
check "25M"     "26214400"   "$(parse_size 25M)"
check "25MB"    "26214400"   "$(parse_size 25MB)"
check "lower m" "26214400"   "$(parse_size 25m)"
check "500k"    "512000"     "$(parse_size 500k)"
check "1.5G"    "1610612736" "$(parse_size 1.5G)"
check "bare bytes" "1048576" "$(parse_size 1048576)"
( parse_size "25 M" )  >/dev/null 2>&1; check "space rejected"   "1" "$?"
( parse_size "big" )   >/dev/null 2>&1; check "garbage rejected" "1" "$?"
( parse_size "25X" )   >/dev/null 2>&1; check "bad unit rejected" "1" "$?"

# --- bitrate budget ---
# 25 MB over 101.84 s = ~2059 kbit/s total; minus 2% overhead and 128k audio.
check "25M/101.84s/128k" "1890" "$(calc_video_kbps 26214400 101.84 128)"
# The audio is a fixed cost. Forgetting to subtract it is how a "25 MB" file
# lands at 26.6 MB and bounces off the upload limit.
check "audio is subtracted" "2018" "$(calc_video_kbps 26214400 101.84 0)"
check "copy audio budget"   "1954" "$(calc_video_kbps 26214400 101.84 64)"
( calc_video_kbps 1048576 101.84 128 ) >/dev/null 2>&1
check "target below audio rejected" "1" "$?"
( calc_video_kbps 26214400 0 128 ) >/dev/null 2>&1
check "zero duration rejected"      "1" "$?"

# --- output naming ---
check "out name"          "/a/b/clip-mobile-720p.mp4"   "$(out_name /a/b/clip.mp4 720)"
check "out name keeps dots" "/a/b/my.clip.v2-mobile-480p.mp4" "$(out_name /a/b/my.clip.v2.mov 480)"
check "out name no dir"   "./clip-mobile-360p.mp4"      "$(out_name clip.mkv 360)"

# --- argument assembly ---
args_of() { printf '%s\n' "${FF_ARGS[@]}"; }
has() { grep -qxF -- "$2" <<<"$1"; echo $?; }

build_args in.mp4 out.mp4 "scale=-2:720" 25 25 h264 26 "" 128k veryfast 0
a="$(args_of)"
check "faststart present"  "0" "$(has "$a" "+faststart")"
check "yuv420p present"    "0" "$(has "$a" "yuv420p")"
check "crf passed through" "0" "$(has "$a" "26")"
check "video stream mapped" "0" "$(has "$a" "0:v:0")"
# The source carries a timecode track; without an explicit map it rides along.
check "audio mapped optionally" "0" "$(has "$a" "0:a:0?")"
check "h264 encoder"       "0" "$(has "$a" "libx264")"
# -r on an unchanged framerate still inserts a frame-rate conversion filter.
check "no -r when fps unchanged" "1" "$(has "$a" "-r")"
check "no bitrate in crf mode"   "1" "$(has "$a" "-b:v")"
check "output is last"     "out.mp4" "${FF_ARGS[-1]}"

build_args in.mp4 out.mp4 "" 15 25 h264 26 "" copy veryfast 0
a="$(args_of)"
check "-r when fps differs" "0" "$(has "$a" "15")"
check "audio copy"          "0" "$(has "$a" "copy")"
check "no -vf when not scaling" "1" "$(has "$a" "-vf")"

build_args in.mp4 out.mp4 "scale=-2:720" 25 25 h265 30 "" 128k medium 0
a="$(args_of)"
check "h265 encoder"  "0" "$(has "$a" "libx265")"
# hev1 (the default tag) shows a black frame in Apple players.
check "hvc1 tag"      "0" "$(has "$a" "hvc1")"

build_args in.mp4 out.mp4 "scale=-2:720" 25 25 h264 "" 1890 128k veryfast 1 /tmp/pl
a="$(args_of)"
check "pass 1 drops audio"     "0" "$(has "$a" "-an")"
check "pass 1 writes no file"  "0" "$(has "$a" "/dev/null")"
check "pass 1 does not map audio" "1" "$(has "$a" "0:a:0?")"
check "pass 1 uses bitrate"    "0" "$(has "$a" "1890k")"
check "pass 1 has no crf"      "1" "$(has "$a" "-crf")"

build_args in.mp4 out.mp4 "scale=-2:720" 25 25 h264 "" 1890 128k veryfast 2 /tmp/pl
a="$(args_of)"
check "pass 2 writes output"   "out.mp4" "${FF_ARGS[-1]}"
check "pass 2 has audio"       "0" "$(has "$a" "-c:a")"
check "pass 2 passlogfile"     "0" "$(has "$a" "/tmp/pl")"
check "tmcd disabled"          "0" "$(has "$a" "-write_tmcd")"

# --- one real encode ---
# Everything above checks strings. This checks that ffmpeg accepts them.
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
    tmpdir=$(mktemp -d)
    src="$tmpdir/src.mp4"
    out="$tmpdir/out.mp4"
    # -timecode gives the source a tmcd track, like the broadcast-delivery files
    # this script is aimed at. It is the case -map does not cover.
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i testsrc=size=1920x1080:rate=25:duration=2 \
        -f lavfi -i sine=frequency=440:duration=2 \
        -timecode 01:00:00:00 \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest "$src" 2>/dev/null
    check "test source has a timecode track" "3" \
        "$(ffprobe -v error -show_entries stream=index -of csv=p=0 -- "$src" 2>/dev/null | wc -l | tr -d ' ')"

    build_args "$src" "$out" "$(scale_filter 1920 1080 720)" 25 25 h264 30 "" 64k ultrafast 0
    ffmpeg "${FF_ARGS[@]}" -loglevel error >/dev/null 2>&1
    check "real encode succeeds" "0" "$?"
    check "real encode is 720p"  "1280x720" \
        "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
            -of csv=p=0:s=x -- "$out" 2>/dev/null)"
    check "real encode kept audio" "aac" \
        "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
            -of csv=p=0 -- "$out" 2>/dev/null)"
    # The source's timecode track must not survive: exactly video + audio.
    check "timecode track dropped" "2" \
        "$(ffprobe -v error -show_entries stream=index -of csv=p=0 -- "$out" 2>/dev/null | wc -l | tr -d ' ')"
    rm -rf "$tmpdir"
else
    echo "SKIP: real encode (ffmpeg not installed)"
fi

echo "----"
if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $fail
