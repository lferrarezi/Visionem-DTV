#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-/Users/lferrarezi/Downloads/Infinito PenTV/Mini_PENTV_USB/Linux/isdbt_nova_12mhz_b0.inp}"
DEST="$ROOT_DIR/firmware/isdbt_nova_12mhz_b0_official_2010.inp"

if [ ! -f "$SOURCE" ]; then
    echo "Firmware oficial nao encontrado: $SOURCE" >&2
    exit 1
fi

install -m 0644 "$SOURCE" "$DEST"
shasum -a 256 "$DEST"
echo "$DEST"
