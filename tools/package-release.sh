#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist"
PKG_DIR="$DIST_DIR/siano-tv-$VERSION"

cd "$ROOT_DIR"

make clean
make all

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/bin" "$PKG_DIR/firmware" "$PKG_DIR/docs" "$PKG_DIR/tools"

cp build/siano-tv "$PKG_DIR/bin/"
cp README.md VERSION "$PKG_DIR/"
cp docs/*.md "$PKG_DIR/docs/"
cp tools/install-local.sh tools/fetch-siano-firmware.sh "$PKG_DIR/tools/"

if [ -f firmware/isdbt_nova_12mhz_b0.inp ]; then
    cp firmware/isdbt_nova_12mhz_b0.inp "$PKG_DIR/firmware/"
fi

tar -C "$DIST_DIR" -czf "$DIST_DIR/siano-tv-$VERSION-macos-arm64.tar.gz" "siano-tv-$VERSION"
shasum -a 256 "$DIST_DIR/siano-tv-$VERSION-macos-arm64.tar.gz"
