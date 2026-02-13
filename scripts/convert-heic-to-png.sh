#!/bin/bash
# convert-heic-to-png.sh — Convert any HEIC images in a directory to PNG (non-destructive).
#
# Usage:
#   ./scripts/convert-heic-to-png.sh path/to/dir
#
# Notes:
# - Keeps the original .heic files; writes a sibling .png with the same base name.
# - Uses `sips` when available (built-in on macOS), with fallbacks to ImageMagick/ffmpeg if installed.

set -euo pipefail

DIR="${1:-}"
if [ -z "$DIR" ]; then
  echo "Usage: $0 path/to/dir" >&2
  exit 2
fi

if [ ! -d "$DIR" ]; then
  echo "ERROR: directory not found: $DIR" >&2
  exit 1
fi

converter=""
if command -v sips >/dev/null 2>&1; then
  converter="sips"
elif command -v magick >/dev/null 2>&1; then
  converter="magick"
elif command -v ffmpeg >/dev/null 2>&1; then
  converter="ffmpeg"
fi

if [ -z "$converter" ]; then
  echo "ERROR: no HEIC converter found (install ImageMagick or ffmpeg, or use macOS sips)." >&2
  exit 1
fi

shopt -s nullglob
count=0

for f in "$DIR"/*.heic "$DIR"/*.HEIC; do
  out="${f%.*}.png"
  if [ -f "$out" ]; then
    continue
  fi

  case "$converter" in
    sips)
      # sips prints progress; silence it.
      sips -s format png "$f" --out "$out" >/dev/null
      ;;
    magick)
      magick "$f" "$out"
      ;;
    ffmpeg)
      ffmpeg -y -loglevel error -i "$f" "$out"
      ;;
  esac

  count=$((count + 1))
done

if [ $count -gt 0 ]; then
  echo "Converted $count HEIC file(s) to PNG in: $DIR"
fi

