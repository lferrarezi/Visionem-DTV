#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FW_DIR="$ROOT_DIR/firmware"

mkdir -p "$FW_DIR"

fetch_text_decoded() {
    name="$1"
    url="$2"
    out="$FW_DIR/$name"
    tmp="$out.base64"

    if [ -f "$out" ]; then
        echo "Already exists: $out"
        return
    fi

    echo "Fetching $name"
    curl -fL "$url" -o "$tmp"
    base64 --decode -i "$tmp" -o "$out"
    rm -f "$tmp"
}

BASE_URL="https://kernel.googlesource.com/pub/scm/linux/kernel/git/firmware/linux-firmware/+/f9b926a6e1d67e09e54adc329c4e76be5f24a895"

fetch_text_decoded "isdbt_nova_12mhz_b0.inp" "$BASE_URL/isdbt_nova_12mhz_b0.inp?format=TEXT"
fetch_text_decoded "dvb_nova_12mhz_b0.inp" "$BASE_URL/dvb_nova_12mhz_b0.inp?format=TEXT"

shasum -a 256 "$FW_DIR"/*.inp
