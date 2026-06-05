#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/captures"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT_DIR"

system_profiler SPUSBDataType > "$OUT_DIR/system_profiler-usb-$STAMP.txt"
ioreg -p IOUSB -l -w 0 > "$OUT_DIR/ioreg-usb-$STAMP.txt"

echo "Saved:"
echo "  $OUT_DIR/system_profiler-usb-$STAMP.txt"
echo "  $OUT_DIR/ioreg-usb-$STAMP.txt"

