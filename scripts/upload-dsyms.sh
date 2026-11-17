#!/bin/sh
set -e
[ $# -ge 1 ] || { echo "usage: upload-dsyms.sh <xcarchive>" >&2; exit 2; }
SRC=$1
ENDPOINT=$MONITOR_ENDPOINT; [ -n "$ENDPOINT" ] || ENDPOINT=https://c.mooeen.com
TOKEN=$MONITOR_TOKEN; [ -n "$TOKEN" ] || { echo "missing MONITOR_TOKEN（原 app_errors token 也可）" >&2; exit 2; }
REL=$RELEASE; BLD=$BUILD
[ -n "$REL" ] || { echo "missing RELEASE" >&2; exit 2; }
[ -n "$BLD" ] || BLD=""
[ -d "$SRC/dSYMs" ] || { echo "no dSYMs in $SRC" >&2; exit 2; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ZIP="$TMP/dsyms.zip"
( cd "$SRC" && zip -qry "$ZIP" dSYMs )
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
UUIDS=$(for d in "$SRC"/dSYMs/*.dSYM; do dwarfdump --uuid "$d" 2>/dev/null | awk '{print $2}'; done | paste -sd, -)
echo "size=$(stat -f%z "$ZIP") sha256=$SHA uuids=$UUIDS"
curl -fsS -X POST "$ENDPOINT/api/v1/app-errors/symbols" \
  -H "Authorization: Bearer $TOKEN" \
  -F "platform=ios" -F "release=$REL" -F "build=$BLD" -F "kind=dsym" \
  -F "sha256=$SHA" -F "uuids=$UUIDS" \
  -F "files[]=@$ZIP;type=application/zip" \
  -w '\nHTTP %{http_code}\n'
