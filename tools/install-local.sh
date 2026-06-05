#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"

cd "$ROOT_DIR"

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required to install libusb and ffmpeg."
    exit 1
fi

if ! brew list libusb >/dev/null 2>&1; then
    brew install libusb
fi

if ! command -v ffplay >/dev/null 2>&1; then
    brew install ffmpeg
fi

if [ ! -f firmware/isdbt_nova_12mhz_b0.inp ]; then
    ./tools/fetch-siano-firmware.sh
fi

make install PREFIX="$PREFIX"

echo "Installed:"
echo "  $PREFIX/bin/siano-tv"
echo "  $PREFIX/share/siano-tv/firmware"
echo
echo "Try:"
echo "  $PREFIX/bin/siano-tv version"
echo "  $PREFIX/bin/siano-tv watch-isdbt 527142857 120 captures/watch.ts"
