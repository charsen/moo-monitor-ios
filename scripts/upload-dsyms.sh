#!/bin/sh
# 上传 dSYM 到 Moo Cloud：三步直传（cloud 只签票据，文件本体由客户端直达七牛）。
#   1) POST {endpoint}/api/v1/uploads/tickets  取 upload_id / key / region / 七牛 token
#   2) POST https://upload[-region].qiniup.com  multipart 直传 dSYM.zip（不经 cloud）
#   3) POST {endpoint}/api/v1/uploads/{upload_id}/confirm  上报 uuids 并核验落盘
#
# 环境变量：
#   MONITOR_TOKEN     必填，具备 app_errors 或 app_symbols 能力的 token（Authorization: Bearer）
#   MONITOR_ENDPOINT  可选，默认 https://c.mooeen.com
#   RELEASE           必填，营销版本号（如 0.1.1）
#   BUILD             可选，构建号（如 27）
#
# 用法：MONITOR_TOKEN=... RELEASE=0.1.1 BUILD=27 ./scripts/upload-dsyms.sh <xcarchive>
set -eu

die() { echo "upload-dsyms: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: upload-dsyms.sh <xcarchive>"
SRC=$1
[ -d "$SRC/dSYMs" ] || die "no dSYMs in $SRC"

ENDPOINT=${MONITOR_ENDPOINT:-https://c.mooeen.com}
ENDPOINT=${ENDPOINT%/}
TOKEN=${MONITOR_TOKEN:-}
[ -n "$TOKEN" ] || die "missing MONITOR_TOKEN（app_errors 或 app_symbols token）"
REL=${RELEASE:-}
[ -n "$REL" ] || die "missing RELEASE"
BLD=${BUILD:-}

for bin in curl zip shasum dwarfdump python3; do
  command -v "$bin" >/dev/null 2>&1 || die "missing command: $bin"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ZIP="$TMP/dsyms.zip"
NAME="dsyms.zip"

# 打包 dSYMs，并算出 zip 的 size/sha256 与各 dSYM 的 LC_UUID。
( cd "$SRC" && zip -qry "$ZIP" dSYMs ) || die "zip dSYMs failed"
SIZE=$(stat -f%z "$ZIP")
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
UUIDS=$(for d in "$SRC"/dSYMs/*.dSYM; do
  [ -d "$d" ] || continue
  dwarfdump --uuid "$d" 2>/dev/null | awk '{print $2}'
done | paste -sd, -)
[ -n "$UUIDS" ] || die "no dSYM LC_UUID found under $SRC/dSYMs"
echo "package size=$SIZE sha256=$SHA"
echo "uuids=$UUIDS"

# 1) 签票据：cloud 只登记元信息并签发七牛上传 token，不接收文件字节。
python3 - "$REL" "$BLD" "$SHA" "$UUIDS" "$SIZE" "$NAME" > "$TMP/ticket_req.json" <<'PY'
import json, sys
rel, bld, sha, uuids, size, name = sys.argv[1:7]
print(json.dumps({
    "business": "app_symbols",
    "platform": "ios",
    "release": rel,
    "build": bld,
    "kind": "dsym",
    "original_name": name,
    "file_size": int(size),
    "sha256": sha,
    "uuids": [u for u in uuids.split(",") if u],
}))
PY

HTTP=$(curl -sS -o "$TMP/ticket.json" -w '%{http_code}' \
  -X POST "$ENDPOINT/api/v1/uploads/tickets" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data-binary @"$TMP/ticket_req.json") || die "ticket request failed (network)"
[ "$HTTP" = "200" ] || die "ticket HTTP $HTTP: $(cat "$TMP/ticket.json")"

# 解析票据响应；缺字段直接失败，输出可读原因。
python3 - "$TMP/ticket.json" "$TMP/ticket.vals" <<'PY' || die "invalid ticket response: $(cat "$TMP/ticket.json")"
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get("ok"):
    raise SystemExit("ticket not ok: %r" % (d,))
lines = []
for key in ("upload_id", "key", "region", "token"):
    v = d.get(key)
    if v in (None, ""):
        raise SystemExit("ticket missing %s: %r" % (key, d))
    lines.append(str(v))
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PY

# 逐行读取，避免 token 里的特殊字符被 shell 再解释。
{ read -r UPLOAD_ID; read -r KEY; read -r REGION; read -r QTOKEN; } < "$TMP/ticket.vals"

# region -> 七牛上传域名：z0 无后缀，其余带区域后缀。
case "$REGION" in
  z0)            UPLOAD_HOST="https://upload.qiniup.com" ;;
  z1|z2|na0|as0) UPLOAD_HOST="https://upload-$REGION.qiniup.com" ;;
  *) die "unsupported qiniu region: $REGION" ;;
esac
echo "ticket upload_id=$UPLOAD_ID region=$REGION host=$UPLOAD_HOST"

# 2) 直传七牛：文件字节只经过本机 -> 七牛，不经过 cloud。成功返回 {key,hash}。
HTTP=$(curl -sS -o "$TMP/qiniu.json" -w '%{http_code}' \
  -X POST "$UPLOAD_HOST" \
  -F "token=$QTOKEN" \
  -F "key=$KEY" \
  -F "file=@$ZIP;type=application/zip") || die "qiniu upload failed (network)"
[ "$HTTP" = "200" ] || die "qiniu HTTP $HTTP: $(cat "$TMP/qiniu.json")"
python3 - "$TMP/qiniu.json" <<'PY' || die "qiniu rejected upload: $(cat "$TMP/qiniu.json")"
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("error"):
    raise SystemExit(d["error"])
if not d.get("hash") or not d.get("key"):
    raise SystemExit("missing key/hash: %r" % (d,))
PY
echo "qiniu upload ok"

# 3) 确认：云端核验对象大小/SHA-256 后登记符号；dSYM 必须带 uuids。
python3 - "$UUIDS" > "$TMP/confirm_req.json" <<'PY'
import json, sys
print(json.dumps({"uuids": [u for u in sys.argv[1].split(",") if u]}))
PY
HTTP=$(curl -sS -o "$TMP/confirm.json" -w '%{http_code}' \
  -X POST "$ENDPOINT/api/v1/uploads/$UPLOAD_ID/confirm" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data-binary @"$TMP/confirm_req.json") || die "confirm request failed (network)"
[ "$HTTP" = "200" ] || die "confirm HTTP $HTTP: $(cat "$TMP/confirm.json")"
python3 - "$TMP/confirm.json" <<'PY' || die "confirm rejected: $(cat "$TMP/confirm.json")"
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get("ok"):
    raise SystemExit(json.dumps(d, ensure_ascii=False))
PY

echo "done: dSYM uploaded and confirmed (upload_id=$UPLOAD_ID)"
