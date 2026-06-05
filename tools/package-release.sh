#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist"
PKG_DIR="$DIST_DIR/siano-tv-$VERSION"

cd "$ROOT_DIR"

make clean
make all

mkdir -p "$DIST_DIR"
find "$DIST_DIR" -maxdepth 1 \( \
    -type d -name 'siano-tv-*' -o \
    -type f -name 'siano-tv-*-macos-arm64.tar.gz' \
\) -exec rm -rf {} +
mkdir -p "$PKG_DIR/bin" "$PKG_DIR/firmware" "$PKG_DIR/docs" "$PKG_DIR/tools" "$PKG_DIR/apps"

cp build/siano-tv "$PKG_DIR/bin/"
cp README.md VERSION "$PKG_DIR/"
cp docs/*.md "$PKG_DIR/docs/"
cp tools/install-local.sh tools/fetch-siano-firmware.sh tools/import-official-linux-firmware.sh tools/build-gui-installer.sh "$PKG_DIR/tools/"
mkdir -p "$PKG_DIR/apps/SianoTVPlayer/Sources"
cp apps/SianoTVPlayer/Package.swift "$PKG_DIR/apps/SianoTVPlayer/"
cp apps/SianoTVPlayer/Sources/main.swift "$PKG_DIR/apps/SianoTVPlayer/Sources/"

if [ -f firmware/isdbt_nova_12mhz_b0_official_2010.inp ]; then
    cp firmware/isdbt_nova_12mhz_b0_official_2010.inp "$PKG_DIR/firmware/"
elif [ -f firmware/isdbt_nova_12mhz_b0.inp ]; then
    cp firmware/isdbt_nova_12mhz_b0.inp "$PKG_DIR/firmware/"
fi

tar -C "$DIST_DIR" -czf "$DIST_DIR/siano-tv-$VERSION-macos-arm64.tar.gz" "siano-tv-$VERSION"
rm -rf "$PKG_DIR"
shasum -a 256 "$DIST_DIR/siano-tv-$VERSION-macos-arm64.tar.gz"
