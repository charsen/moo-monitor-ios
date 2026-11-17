#!/bin/sh
set -eu
[ $# -ge 3 ] || { echo "usage: symbolicate.sh <archive|dSYMs> <uuid> <offset> [arch]" >&2; exit 2; }
SRC=$1; UUID_RAW=$2; OFF=$3; ARCH=arm64; if [ $# -ge 4 ]; then ARCH=$4; fi
UUID=$(printf '%s' "$UUID_RAW" | tr 'A-F' 'a-f' | tr -d '-')
DIR=$SRC; if [ -d "$SRC/dSYMs" ]; then DIR="$SRC/dSYMs"; fi
BIN=""
for d in "$DIR"/*.dSYM; do
  [ -d "$d" ] || continue
  U=$(dwarfdump --uuid "$d" 2>/dev/null | awk '{print $2}' | head -1 | tr 'A-F' 'a-f' | tr -d '-')
  if [ "$U" = "$UUID" ]; then BIN="$d/Contents/Resources/DWARF/$(basename "$d" .dSYM)"; break; fi
done
[ -n "$BIN" ] || { echo "no dSYM matching uuid $UUID under $DIR" >&2; exit 2; }
FULL=$(python3 -c "import sys;print(hex(int(sys.argv[1],0)+0x100000000))" "$OFF")
xcrun atos -o "$BIN" -arch "$ARCH" -l 0x100000000 "$FULL"
