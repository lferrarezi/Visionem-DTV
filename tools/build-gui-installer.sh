#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist"
PKGROOT="${TMPDIR:-/tmp}/siano-tv-pkgroot-$VERSION"
APP_NAME="Siano TV Digital"
APP_SUPPORT="$PKGROOT/Library/Application Support/Siano TV Digital"
COMPONENT_PKG="$DIST_DIR/siano-tv-$VERSION-component.pkg"
FINAL_PKG="$DIST_DIR/siano-tv-$VERSION-macos-installer.pkg"

cd "$ROOT_DIR"

if [ ! -f firmware/isdbt_nova_12mhz_b0.inp ]; then
    echo "Firmware ISDB-Tb ausente: firmware/isdbt_nova_12mhz_b0.inp" >&2
    echo "Execute ./tools/fetch-siano-firmware.sh antes de gerar o instalador." >&2
    exit 1
fi

make clean
make all

rm -rf "$PKGROOT" "$COMPONENT_PKG" "$FINAL_PKG"
mkdir -p "$PKGROOT/usr/local/bin"
mkdir -p "$APP_SUPPORT/firmware"
mkdir -p "$PKGROOT/Applications"

install -m 0755 "$ROOT_DIR/build/siano-tv" "$PKGROOT/usr/local/bin/siano-tv"
install -m 0644 "$ROOT_DIR/firmware/isdbt_nova_12mhz_b0.inp" "$APP_SUPPORT/firmware/isdbt_nova_12mhz_b0.inp"

APPLESCRIPT="$DIST_DIR/siano-tv-launcher.applescript"
cat > "$APPLESCRIPT" <<'SCRIPT'
set captureDir to POSIX path of (path to movies folder) & "SianoTV"
do shell script "mkdir -p " & quoted form of captureDir
set cmd to "clear; echo 'Siano TV Digital - ISDB-Tb Brasil'; echo; echo '1) Procurando canais brasileiros...'; /usr/local/bin/siano-tv scan-br; echo; echo 'Para assistir/capturar, use:'; echo '  /usr/local/bin/siano-tv watch-br CANAL 300 ~/Movies/SianoTV/canal.ts'; echo; echo 'Exemplo:'; echo '  /usr/local/bin/siano-tv watch-br 23 300 ~/Movies/SianoTV/canal-23.ts'; echo; echo 'O dispositivo usa antena interna. Ajuste a posicao do dongle perto de janela/area aberta.'; echo; echo 'Pressione ENTER para fechar...'; read resposta"
tell application "Terminal"
	activate
	do script cmd
end tell
SCRIPT

osacompile -o "$PKGROOT/Applications/$APP_NAME.app" "$APPLESCRIPT"
codesign --force --deep --sign - "$PKGROOT/Applications/$APP_NAME.app" >/dev/null
dot_clean -m "$PKGROOT" >/dev/null 2>&1 || true
xattr -cr "$PKGROOT" >/dev/null 2>&1 || true

COPYFILE_DISABLE=1 pkgbuild \
    --root "$PKGROOT" \
    --identifier "com.local.sianotv.br" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT_PKG"

productbuild \
    --package "$COMPONENT_PKG" \
    --identifier "com.local.sianotv.br.product" \
    --version "$VERSION" \
    "$FINAL_PKG"

shasum -a 256 "$FINAL_PKG"
echo "$FINAL_PKG"
