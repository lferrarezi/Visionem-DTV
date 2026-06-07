#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION")"

cd "$ROOT_DIR"

make clean
make all

./build/siano-tv channels-br >/tmp/visionem-validate-channels.txt
./build/siano-tv usb-state >/tmp/visionem-validate-usb-state.txt || true

if [ -f "dist/visionem-dtv-$VERSION-macos-installer.pkg" ]; then
    if pkgutil --payload-files "dist/visionem-dtv-$VERSION-macos-installer.pkg" | grep -E '(^|/)\._|(^|/)\.__' >/dev/null; then
        echo "Instalador contem arquivos AppleDouble." >&2
        exit 1
    fi
fi

echo "Visionem DTV $VERSION release validation ok"
