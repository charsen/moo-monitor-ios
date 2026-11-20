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
#   BUILD             必填，构建号（如 27）。release+build 是云端定位符号的键，必填
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
[ -n "$BLD" ] || die "missing BUILD（release+build 是云端定位符号的键）"

for bin in curl zip shasum dwarfdump python3; do
  command -v "$bin" >/dev/null 2>&1 || die "missing command: $bin"
done

# 响应体可能含票据或鉴权信息。日志仅记录请求阶段、HTTP 状态和固定解析错误。
umask 077
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$TMP/cloud-headers"
unset TOKEN MONITOR_TOKEN
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

HTTP=$(curl -q -s --connect-timeout 30 --max-time 600 -o "$TMP/ticket.json" -w '%{http_code}' \
  -X POST "$ENDPOINT/api/v1/uploads/tickets" \
  --header @"$TMP/cloud-headers" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data-binary @"$TMP/ticket_req.json") || die "ticket request failed (network)"
[ "$HTTP" = "200" ] || die "ticket HTTP $HTTP"

# 只把经过形状检查的字段交给 shell。解析器不输出原始异常或响应。
python3 - "$TMP" <<'PYTICKET' 2>/dev/null || die "invalid ticket response"
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
d = json.loads((root / "ticket.json").read_text())
if not isinstance(d, dict) or d.get("ok") is not True:
    sys.exit(1)
upload_id, key, region, token = (d.get(name) for name in ("upload_id", "key", "region", "token"))
if not all(isinstance(v, str) and v and v.isprintable() for v in (upload_id, key, region, token)):
    sys.exit(1)
if not re.fullmatch(r"[A-Za-z0-9_-]+", upload_id) or not re.fullmatch(r"[a-z0-9]+", region):
    sys.exit(1)
(root / "ticket.vals").write_text("\n".join((upload_id, key, region)) + "\n")
(root / "qiniu-token").write_text(token)
PYTICKET

{ read -r UPLOAD_ID; read -r KEY; read -r REGION; } < "$TMP/ticket.vals"

# region -> 七牛上传域名：z0 无后缀，其余带区域后缀。
case "$REGION" in
  z0)            UPLOAD_HOST="https://upload.qiniup.com" ;;
  z1|z2|na0|as0) UPLOAD_HOST="https://upload-$REGION.qiniup.com" ;;
  *) die "unsupported qiniu region" ;;
esac
echo "ticket upload_id=$UPLOAD_ID region=$REGION host=$UPLOAD_HOST"

# 2) 直传七牛：文件字节只经过本机 -> 七牛，不经过 cloud。成功返回 {key,hash}。
HTTP=$(curl -q -s --connect-timeout 30 --max-time 600 -o "$TMP/qiniu.json" -w '%{http_code}' \
  -X POST "$UPLOAD_HOST" \
  -F "token=<$TMP/qiniu-token" \
  --form-string "key=$KEY" \
  -F "file=@$ZIP;type=application/zip") || die "qiniu upload failed (network)"
[ "$HTTP" = "200" ] || die "qiniu HTTP $HTTP"
python3 - "$TMP/qiniu.json" "$KEY" <<'PYQINIU' 2>/dev/null || die "qiniu rejected upload"
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
if not isinstance(d, dict) or d.get("error") or not d.get("hash") or d.get("key") != sys.argv[2]:
    sys.exit(1)
PYQINIU
echo "qiniu upload ok"

# 3) 确认：云端核验对象大小/SHA-256 后登记符号；dSYM 必须带 uuids。
python3 - "$UUIDS" > "$TMP/confirm_req.json" <<'PY'
import json, sys
print(json.dumps({"uuids": [u for u in sys.argv[1].split(",") if u]}))
PY
HTTP=$(curl -q -s --connect-timeout 30 --max-time 600 -o "$TMP/confirm.json" -w '%{http_code}' \
  -X POST "$ENDPOINT/api/v1/uploads/$UPLOAD_ID/confirm" \
  --header @"$TMP/cloud-headers" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data-binary @"$TMP/confirm_req.json") || die "confirm request failed (network)"
[ "$HTTP" = "200" ] || die "confirm HTTP $HTTP"
python3 - "$TMP/confirm.json" "$UPLOAD_ID" <<'PYCONFIRM' 2>/dev/null || die "confirm rejected"
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
if not isinstance(d, dict) or d.get("ok") is not True or str(d.get("upload_id")) != sys.argv[2]:
    sys.exit(1)
PYCONFIRM

echo "done: dSYM uploaded and confirmed (upload_id=$UPLOAD_ID)"
