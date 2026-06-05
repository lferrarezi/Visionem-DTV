#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist"
PKGROOT="${TMPDIR:-/tmp}/siano-tv-pkgroot-$VERSION"
CLEAN_PKGROOT="${TMPDIR:-/tmp}/siano-tv-pkgroot-clean-$VERSION"
PKG_SCRIPTS="${TMPDIR:-/tmp}/siano-tv-pkg-scripts-$VERSION"
APP_NAME="Siano TV Digital"
APP_SUPPORT="$PKGROOT/Library/Application Support/Siano TV Digital"
COMPONENT_PKG="$DIST_DIR/siano-tv-$VERSION-component.pkg"
FINAL_PKG="$DIST_DIR/siano-tv-$VERSION-macos-installer.pkg"
KEEP_COMPONENT_PKG="${KEEP_COMPONENT_PKG:-0}"

cd "$ROOT_DIR"

FW_SOURCE="firmware/isdbt_nova_12mhz_b0.inp"
FW_INSTALL_NAME="isdbt_nova_12mhz_b0.inp"
if [ -f firmware/isdbt_nova_12mhz_b0_official_2010.inp ]; then
    FW_SOURCE="firmware/isdbt_nova_12mhz_b0_official_2010.inp"
    FW_INSTALL_NAME="isdbt_nova_12mhz_b0_official_2010.inp"
fi

if [ ! -f "$FW_SOURCE" ]; then
    echo "Firmware ISDB-Tb ausente: firmware/isdbt_nova_12mhz_b0.inp" >&2
    echo "Execute ./tools/fetch-siano-firmware.sh antes de gerar o instalador." >&2
    exit 1
fi

make clean
make all

mkdir -p "$DIST_DIR"
rm -rf "$PKGROOT" "$CLEAN_PKGROOT" "$PKG_SCRIPTS"
find "$DIST_DIR" -maxdepth 1 -type f \( \
    -name 'siano-tv-*-component.pkg' -o \
    -name 'siano-tv-*-macos-installer.pkg' -o \
    -name 'siano-tv-launcher.applescript' \
\) -delete
mkdir -p "$PKGROOT/usr/local/bin"
mkdir -p "$APP_SUPPORT/firmware"
mkdir -p "$PKGROOT/Applications"

install -m 0755 "$ROOT_DIR/build/siano-tv" "$PKGROOT/usr/local/bin/siano-tv"
install -m 0644 "$ROOT_DIR/$FW_SOURCE" "$APP_SUPPORT/firmware/$FW_INSTALL_NAME"

APP_DIR="$PKGROOT/Applications/$APP_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>Siano TV Digital</string>
	<key>CFBundleExecutable</key>
	<string>siano-tv-launcher</string>
	<key>CFBundleIdentifier</key>
	<string>com.local.sianotv.br.launcher</string>
	<key>CFBundleName</key>
	<string>Siano TV Digital</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>10.15</string>
</dict>
</plist>
PLIST
cat > "$APP_DIR/Contents/MacOS/siano-tv-launcher" <<'SCRIPT'
#!/bin/sh
mkdir -p "$HOME/Movies/SianoTV"
/usr/bin/osascript <<'APPLESCRIPT'
set cmd to "clear; echo 'Siano TV Digital - ISDB-Tb Brasil'; echo; echo '1) Procurando canais brasileiros 1-59...'; /usr/local/bin/siano-tv scan-br; echo; echo 'Para diagnostico amplo, rode:'; echo '  /usr/local/bin/siano-tv scan-br-extended'; echo; echo 'Se ficar rf=1 demod=0, rode:'; echo '  /usr/local/bin/siano-tv diag-br CANAL 2 ~/Movies/SianoTV/diag-canal.csv'; echo; echo 'Para assistir/capturar, use:'; echo '  /usr/local/bin/siano-tv watch-br CANAL 300 ~/Movies/SianoTV/canal.ts'; echo; echo 'Exemplo:'; echo '  /usr/local/bin/siano-tv watch-br 23 300 ~/Movies/SianoTV/canal-23.ts'; echo; echo 'O dispositivo usa antena interna. Ajuste a posicao do dongle perto de janela/area aberta.'; echo; echo 'Pressione ENTER para fechar...'; read resposta"
tell application "Terminal"
	activate
	do script cmd
end tell
APPLESCRIPT
SCRIPT
chmod 0755 "$APP_DIR/Contents/MacOS/siano-tv-launcher"
codesign --force --deep --sign - "$PKGROOT/Applications/$APP_NAME.app" >/dev/null
dot_clean -m "$PKGROOT" >/dev/null 2>&1 || true
xattr -cr "$PKGROOT" >/dev/null 2>&1 || true
ditto --noextattr --norsrc "$PKGROOT" "$CLEAN_PKGROOT"

mkdir -p "$PKG_SCRIPTS"
cat > "$PKG_SCRIPTS/preinstall" <<'SCRIPT'
#!/bin/sh
set -eu
rm -f "/usr/local/bin/siano-tv"
rm -rf "/Applications/Siano TV Digital.app"
rm -rf "/Library/Application Support/Siano TV Digital"
exit 0
SCRIPT
cat > "$PKG_SCRIPTS/postinstall" <<'SCRIPT'
#!/bin/sh
set -eu
find "/usr/local" "/Applications/Siano TV Digital.app" "/Library/Application Support/Siano TV Digital" \
    \( -name '._*' -o -name '.__*' \) -exec rm -rf {} + 2>/dev/null || true
exit 0
SCRIPT
chmod 0755 "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"

COPYFILE_DISABLE=1 pkgbuild \
    --root "$CLEAN_PKGROOT" \
    --scripts "$PKG_SCRIPTS" \
    --identifier "com.local.sianotv.br" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT_PKG"

productbuild \
    --package "$COMPONENT_PKG" \
    --identifier "com.local.sianotv.br.product" \
    --version "$VERSION" \
    "$FINAL_PKG"

if [ "$KEEP_COMPONENT_PKG" != "1" ]; then
    rm -f "$COMPONENT_PKG"
fi

shasum -a 256 "$FINAL_PKG"
echo "$FINAL_PKG"
