#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Visionem DTV"
PROCESS_NAME="SianoTVPlayer"
BUNDLE_ID="com.local.visionemdtv.br.dev"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT_DIR/macOS"
VERSION="$(cat "$MACOS_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist/dev"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
INFO_PLIST="$APP_CONTENTS/Info.plist"

usage() {
  echo "usage: $0 [run|--verify|--logs|--debug]" >&2
  exit 2
}

stop_existing() {
  pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
  pkill -f 'Visionem DTV.app/Contents/MacOS' >/dev/null 2>&1 || true
  pkill -f 'visionem-dtv-hls' >/dev/null 2>&1 || true
  pkill -f 'visionem-dtv-audio' >/dev/null 2>&1 || true
}

stage_app() {
  cd "$MACOS_DIR"
  make all

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES/firmware"
  cp "$MACOS_DIR/build/SianoTVPlayer" "$APP_MACOS/SianoTVPlayer"
  cp "$MACOS_DIR/build/siano-tv" "$APP_MACOS/siano-tv-real"
  chmod 0755 "$APP_MACOS/SianoTVPlayer" "$APP_MACOS/siano-tv-real"

  cat > "$APP_MACOS/siano-tv" <<'WRAPPER'
#!/bin/sh
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FW="$DIR/../Resources/firmware/isdbt_nova_12mhz_b0_official_2010.inp"
if [ ! -f "$FW" ]; then
  FW="$DIR/../Resources/firmware/isdbt_nova_12mhz_b0.inp"
fi
if [ -f "$FW" ]; then
  export SIANO_TV_FIRMWARE="$FW"
fi
exec "$DIR/siano-tv-real" "$@"
WRAPPER
  chmod 0755 "$APP_MACOS/siano-tv"

  if [ -f "$MACOS_DIR/firmware/isdbt_nova_12mhz_b0_official_2010.inp" ]; then
    cp "$MACOS_DIR/firmware/isdbt_nova_12mhz_b0_official_2010.inp" "$APP_RESOURCES/firmware/"
  elif [ -f "$MACOS_DIR/firmware/isdbt_nova_12mhz_b0.inp" ]; then
    cp "$MACOS_DIR/firmware/isdbt_nova_12mhz_b0.inp" "$APP_RESOURCES/firmware/"
  fi
  if [ -f "$MACOS_DIR/assets/Visionem.icns" ]; then
    cp "$MACOS_DIR/assets/Visionem.icns" "$APP_RESOURCES/Visionem.icns"
  fi

  cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Visionem DTV</string>
  <key>CFBundleExecutable</key>
  <string>SianoTVPlayer</string>
  <key>CFBundleIconFile</key>
  <string>Visionem</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Visionem DTV</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.15</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_existing
stage_app

case "$MODE" in
  run)
    open_app
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$PROCESS_NAME" >/dev/null
    echo "Visionem DTV $VERSION launched from $APP_BUNDLE"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --debug|debug)
    lldb -- "$APP_MACOS/SianoTVPlayer"
    ;;
  *)
    usage
    ;;
esac
