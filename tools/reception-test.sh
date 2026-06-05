#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CAPTURE_DIR="$ROOT_DIR/captures"
mkdir -p "$CAPTURE_DIR"

cd "$ROOT_DIR"

make all

if ! ./build/siano-tv version | grep -q "firmware id: 5"; then
    ./build/siano-tv firmware-load firmware/isdbt_nova_12mhz_b0.inp
    sleep 1
fi

SCAN_LOG="$CAPTURE_DIR/reception-scan-$(date +%Y%m%d-%H%M%S).txt"
./build/siano-tv scan-isdbt | tee "$SCAN_LOG" || true

# Sao Paulo common UHF candidates plus channel 14 baseline.
FREQUENCIES="527142857 533142857 557142857 581142857 473142857"

for freq in $FREQUENCIES; do
    out="$CAPTURE_DIR/reception-$freq.ts"
    rm -f "$out"
    ./build/siano-tv capture-isdbt "$freq" 15 "$out" || true
    bytes="$(wc -c < "$out" | tr -d ' ')"
    echo "$freq -> $bytes bytes"

    if [ "$bytes" -gt 0 ]; then
        if command -v ffplay >/dev/null 2>&1; then
            ffplay -fflags nobuffer -flags low_delay -framedrop "$out"
            exit 0
        fi

        if [ -d /Applications/VLC.app ]; then
            open -a VLC "$out"
            exit 0
        fi

        echo "Captured TS with data: $out"
        exit 0
    fi
done

echo "No MPEG-TS data captured. Check antenna placement/cable and rerun:"
echo "  $ROOT_DIR/tools/reception-test.sh"
exit 1

