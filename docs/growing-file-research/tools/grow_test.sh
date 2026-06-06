#!/bin/bash
# Live-growing codec/container matrix test for Resolve/Premiere growing-clip detection.
# Usage: bash ~/Movies/grow_test.sh <variant> [seconds]
#   variants: h264-ts h264-mp4 h264-mov hevc-ts hevc-mp4 prores-mov mpeg2-ts
# Import the output into Resolve ~5s after it starts; watch if the clip AUTO-GROWS.
P="$1"; DUR="${2:-240}"; cd "$HOME/Movies" || exit 1
case "$P" in
  h264-ts)    OUT="grow_h264.ts";    V="-c:v h264_videotoolbox -pix_fmt yuv420p -b:v 12M"; A="-c:a aac -b:a 192k"; FMT="-flush_packets 1 -f mpegts";;
  h264-mp4)   OUT="grow_h264.mp4";   V="-c:v h264_videotoolbox -tag:v avc1 -pix_fmt yuv420p -b:v 12M"; A="-c:a aac -b:a 192k"; FMT="-movflags +frag_keyframe+empty_moov+default_base_moof -f mp4";;
  h264-mov)   OUT="grow_h264.mov";   V="-c:v h264_videotoolbox -tag:v avc1 -pix_fmt yuv420p -b:v 12M"; A="-c:a pcm_s16le"; FMT="-movflags +frag_keyframe -f mov";;
  hevc-ts)    OUT="grow_hevc.ts";    V="-c:v hevc_videotoolbox -tag:v hvc1 -pix_fmt yuv420p -b:v 12M"; A="-c:a aac -b:a 192k"; FMT="-flush_packets 1 -f mpegts";;
  hevc-mp4)   OUT="grow_hevc.mp4";   V="-c:v hevc_videotoolbox -tag:v hvc1 -pix_fmt yuv420p -b:v 12M"; A="-c:a aac -b:a 192k"; FMT="-movflags +frag_keyframe+empty_moov+default_base_moof -f mp4";;
  prores-mov) OUT="grow_prores.mov"; V="-c:v prores_videotoolbox -profile:v 1 -pix_fmt p210"; A="-c:a pcm_s16le"; FMT="-movflags +frag_keyframe -f mov";;
  mpeg2-ts)   OUT="grow_mpeg2.ts";   V="-c:v mpeg2video -pix_fmt yuv420p -b:v 20M"; A="-c:a mp2 -b:a 384k"; FMT="-flush_packets 1 -f mpegts";;
  *) echo "usage: grow_test.sh {h264-ts|h264-mp4|h264-mov|hevc-ts|hevc-mp4|prores-mov|mpeg2-ts} [seconds]"; exit 1;;
esac
rm -f "$OUT"
echo ">>> Writing $OUT for ${DUR}s. Import into Resolve ~5s after this line; watch for auto-grow. Ctrl-C to stop."
ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc2=size=1920x1080:rate=50" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t "$DUR" $V -g 50 $A -timecode 00:00:00:00 $FMT "$OUT"
echo ">>> done: $OUT"
