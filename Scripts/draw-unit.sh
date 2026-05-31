#!/usr/bin/env bash
# Render a unit type in all 8 facings via OpenDUNE's REAL sprite path (GUI_DrawSprite to an off-screen
# GFX buffer — no SDL), to a PNG. The ground truth for "how does OpenDUNE draw unit X facing direction Y".
# Cells left→right = orientation8 0..7 = N, NE, E, SE, S, SW, W, NW.
#
# Usage: Scripts/draw-unit.sh <unitType> [outPng]
#   unitType: g_table_unitInfo index (e.g. 9 = Combat Tank, 19 = Rocket).
# Needs the install (sprites live in DUNE.PAK) + the oracle. Run with the sandbox disabled.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TYPE="${1:?usage: draw-unit.sh <unitType> [outPng]}"
OUT="${2:-$REPO/Code/.build/draw/unit$TYPE.png}"
INSTALL="${INSTALL:-$REPO/Repositories/patched_107_unofficial}"
DATADIR="$REPO/Code/.build/scengen"
ORACLE="$REPO/Repositories/OpenDUNE/bin/opendune"

"$REPO/Scripts/build-oracle.sh" >/dev/null

# Stage the data dir (the SHPs are inside DUNE.PAK).
mkdir -p "$DATADIR"
for f in "$INSTALL"/*; do ln -sf "$f" "$DATADIR/$(basename "$f")"; done

mkdir -p "$(dirname "$OUT")"
PPM="${OUT%.png}.ppm"
"$ORACLE" --parity-draw="$TYPE" --parity-data-dir="$DATADIR" --parity-draw-out="$PPM" 2>&1 | grep -E 'o8 |drew' || true

# PPM (P6) -> 5x nearest-neighbour PNG (stdlib only).
python3 - "$PPM" "$OUT" <<'PY'
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read(); assert d[:2] == b'P6'
i = 2; v = []
while len(v) < 3:
    while d[i] in b' \t\n\r': i += 1
    s = i
    while d[i] not in b' \t\n\r': i += 1
    v.append(int(d[s:i]))
i += 1; w, h, _ = v; px = d[i:i + w*h*3]; scale = 5; W, H = w*scale, h*scale
rows = bytearray()
for y in range(H):
    rows.append(0)
    for x in range(W):
        o = ((y//scale)*w + (x//scale))*3; rows += px[o:o+3]
def chunk(t, dd):
    c = t + dd; return struct.pack('>I', len(dd)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
open(sys.argv[2], 'wb').write(
    b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b''))
print("wrote", sys.argv[2])
PY
