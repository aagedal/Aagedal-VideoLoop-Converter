#!/bin/bash
# Real-time GROWING file via AVAssetWriter. Usage:
#   bash ~/Movies/grow_avw.sh [codec] [tracks] [seconds] [startTC] [container]
#   codec: h264|hevc|prores   tracks: v|va|vat   startTC: tod|HH:MM:SS:FF   container: mov|mp4
CODEC="${1:-h264}"; TRACKS="${2:-vat}"; DUR="${3:-240}"; TC="${4:-tod}"; CONT="${5:-mov}"
OUT="$HOME/Movies/grow_${CODEC}_${TRACKS}.${CONT}"
"$HOME/Movies/grow_avwriter" "$OUT" "$DUR" 50 "$CODEC" "$TRACKS" "$TC"
