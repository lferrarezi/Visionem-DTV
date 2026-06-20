#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="${TMPDIR:-/tmp}/visionem-ts-quality-test-$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT
SAMPLE="$TMP_DIR/sample.ts"
python3 - "$SAMPLE" <<'PY'
import sys
from pathlib import Path
out = Path(sys.argv[1])

def crc32_mpeg(data):
    crc = 0xffffffff
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xffffffff if crc & 0x80000000 else (crc << 1) & 0xffffffff
    return crc

def section_packet(pid, continuity, section):
    payload = bytes([0x00]) + section
    return packet(pid, continuity, payload, payload_start=True)

def packet(pid, continuity, payload, payload_start=False):
    header = bytearray([0x47, 0x40 if payload_start else 0x00, 0x00, 0x10 | (continuity & 0x0f)])
    header[1] |= (pid >> 8) & 0x1f
    header[2] = pid & 0xff
    data = bytes(header) + payload[:184]
    return data + bytes([0xff]) * (188 - len(data))

def pat_section():
    body = bytearray()
    body += bytes([0x00, 0xb0, 0x0d, 0x00, 0x01, 0xc1, 0x00, 0x00])
    body += bytes([0x00, 0x01, 0xe1, 0x00])
    crc = crc32_mpeg(body)
    return bytes(body) + crc.to_bytes(4, 'big')

def pmt_section():
    body = bytearray()
    body += bytes([0x02, 0xb0, 0x17, 0x00, 0x01, 0xc1, 0x00, 0x00])
    body += bytes([0xe2, 0x01, 0xf0, 0x00])
    body += bytes([0x1b, 0xe2, 0x01, 0xf0, 0x00])
    body += bytes([0x0f, 0xe2, 0x02, 0xf0, 0x00])
    crc = crc32_mpeg(body)
    return bytes(body) + crc.to_bytes(4, 'big')

packets = [
    section_packet(0x0000, 0, pat_section()),
    section_packet(0x0100, 0, pmt_section()),
    packet(0x0201, 0, b'V' * 184),
    packet(0x0202, 0, b'A' * 184),
    packet(0x0201, 2, b'V' * 184),  # continuity error: expected 1, got 2
    packet(0x1fff, 0, b'')
]
out.write_bytes(b''.join(packets))
PY
make -C "$ROOT_DIR" build/siano-tv >/dev/null
OUTPUT="$("$ROOT_DIR/build/siano-tv" ts-quality "$SAMPLE")"
printf '%s\n' "$OUTPUT"
grep -q 'packets: 6' <<<"$OUTPUT"
grep -q 'sync_errors: 0' <<<"$OUTPUT"
grep -q 'pat: present' <<<"$OUTPUT"
grep -q 'pmt: present pid=0x0100' <<<"$OUTPUT"
grep -q 'video_pid: 0x0201' <<<"$OUTPUT"
grep -q 'audio_pid: 0x0202' <<<"$OUTPUT"
grep -q 'continuity_errors: 1' <<<"$OUTPUT"
grep -q 'pid 0x0201 packets=2 continuity_errors=1' <<<"$OUTPUT"
