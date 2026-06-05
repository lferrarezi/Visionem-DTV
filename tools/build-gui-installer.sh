#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist"
PKGROOT="${TMPDIR:-/tmp}/siano-tv-pkgroot-$VERSION"
CLEAN_PKGROOT="${TMPDIR:-/tmp}/siano-tv-pkgroot-clean-$VERSION"
PKG_SCRIPTS="${TMPDIR:-/tmp}/siano-tv-pkg-scripts-$VERSION"
COMPONENT_DIR="${TMPDIR:-/tmp}/siano-tv-component-$VERSION"
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
rm -rf "$PKGROOT" "$CLEAN_PKGROOT" "$PKG_SCRIPTS" "$COMPONENT_DIR"
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
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$DIR/SianoTVPlayer"
SCRIPT
chmod 0755 "$APP_DIR/Contents/MacOS/siano-tv-launcher"
install -m 0755 "$ROOT_DIR/build/SianoTVPlayer" "$APP_DIR/Contents/MacOS/SianoTVPlayer"
codesign --force --deep --sign - "$PKGROOT/Applications/$APP_NAME.app" >/dev/null
dot_clean -m "$PKGROOT" >/dev/null 2>&1 || true
xattr -cr "$PKGROOT" >/dev/null 2>&1 || true
ditto --noextattr --norsrc "$PKGROOT" "$CLEAN_PKGROOT"
dot_clean -m "$CLEAN_PKGROOT" >/dev/null 2>&1 || true
xattr -cr "$CLEAN_PKGROOT" >/dev/null 2>&1 || true
find "$CLEAN_PKGROOT" \( -name '._*' -o -name '.__*' \) -exec rm -rf {} + 2>/dev/null || true

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

mkdir -p "$COMPONENT_DIR/scripts-root"
cp "$PKG_SCRIPTS/preinstall" "$COMPONENT_DIR/scripts-root/preinstall"
cp "$PKG_SCRIPTS/postinstall" "$COMPONENT_DIR/scripts-root/postinstall"
chmod 0755 "$COMPONENT_DIR/scripts-root/preinstall" "$COMPONENT_DIR/scripts-root/postinstall"
mkbom "$CLEAN_PKGROOT" "$COMPONENT_DIR/Bom"
(
    cd "$CLEAN_PKGROOT"
    find . -print | sort | cpio -o -H odc 2>/dev/null | gzip -c > "$COMPONENT_DIR/Payload"
)
(
    cd "$COMPONENT_DIR/scripts-root"
    find . -print | sort | cpio -o -H odc 2>/dev/null | gzip -c > "$COMPONENT_DIR/Scripts"
)
PAYLOAD_FILES="$(find "$CLEAN_PKGROOT" -mindepth 1 | wc -l | tr -d ' ')"
INSTALL_KB="$(du -sk "$CLEAN_PKGROOT" | awk '{print $1}')"
cat > "$COMPONENT_DIR/PackageInfo" <<PACKAGEINFO
<?xml version="1.0" encoding="utf-8"?>
<pkg-info overwrite-permissions="true" relocatable="false" identifier="com.local.sianotv.br" postinstall-action="none" version="$VERSION" format-version="2" install-location="/" auth="root">
    <payload numberOfFiles="$PAYLOAD_FILES" installKBytes="$INSTALL_KB"/>
    <bundle path="./Applications/$APP_NAME.app" id="com.local.sianotv.br.launcher" CFBundleShortVersionString="$VERSION" CFBundleVersion="$VERSION"/>
    <bundle-version>
        <bundle id="com.local.sianotv.br.launcher"/>
    </bundle-version>
    <upgrade-bundle>
        <bundle id="com.local.sianotv.br.launcher"/>
    </upgrade-bundle>
    <update-bundle/>
    <atomic-update-bundle/>
    <strict-identifier>
        <bundle id="com.local.sianotv.br.launcher"/>
    </strict-identifier>
    <relocate>
        <bundle id="com.local.sianotv.br.launcher"/>
    </relocate>
    <scripts>
        <preinstall file="./preinstall" timeout="600"/>
        <postinstall file="./postinstall" timeout="600"/>
    </scripts>
</pkg-info>
PACKAGEINFO
(
    cd "$COMPONENT_DIR"
    xar --compression none -cf "$COMPONENT_PKG" Bom PackageInfo Payload Scripts
)

productbuild \
    --package "$COMPONENT_PKG" \
    --identifier "com.local.sianotv.br.product" \
    --version "$VERSION" \
    "$FINAL_PKG"

if [ "$KEEP_COMPONENT_PKG" != "1" ]; then
    rm -f "$COMPONENT_PKG"
fi

if pkgutil --payload-files "$FINAL_PKG" | grep -E '(^|/)\._|(^|/)\.__' >/dev/null; then
    echo "Instalador contem arquivos AppleDouble; pacote rejeitado." >&2
    exit 1
fi

shasum -a 256 "$FINAL_PKG"
echo "$FINAL_PKG"
