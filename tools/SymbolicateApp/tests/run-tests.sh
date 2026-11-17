#!/usr/bin/env bash
# SymbolicateApp 离线自测：用桩替换 dwarfdump/xcrun atos，验证帧提取、
# UUID 归一化、地址计算、atos 结果解析与 unsymbolicated 标记。
# 不依赖真实 Xcode 构建，可在任何装了 python3 的 macOS 上跑。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="$HERE/../symbolicate-app.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
mkdir -p "$BIN"

ARCHIVE="$ROOT/Fixture.xcarchive/dSYMs/ShuheApple.app.dSYM"
mkdir -p "$ARCHIVE/Contents/Resources/DWARF"
: > "$ARCHIVE/Contents/Resources/DWARF/ShuheApple"

cat > "$BIN/dwarfdump" <<'STUB'
#!/bin/sh
echo "UUID: 6F7A8B9C-1D2E-3F40-8A9B-0C1D2E3F4A5B (arm64) $2"
STUB

cat > "$BIN/xcrun" <<'STUB'
#!/bin/sh
# 只实现 atos：把地址映射成固定符号，模拟真实 dSYM 解析
if [ "$1" = "atos" ]; then
  shift
  addr=""
  for a in "$@"; do addr=$a; done
  case "$addr" in
    0x10001f428) echo "ShuheApple.ReaderView.load() (in ShuheApple) (ReaderView.swift:42)" ;;
    0x100010000) echo "ShuheApple.App.init() (in ShuheApple) (App.swift:10)" ;;
    0x100002000) echo "type metadata accessor for CoReadingPanel (in ShuheApple) + 0" ;;
    *) echo "$addr (in ShuheApple) + 0" ;;
  esac
  exit 0
fi
echo "unexpected xcrun $*" >&2
exit 1
STUB

chmod +x "$BIN/dwarfdump" "$BIN/xcrun"

PATH="$BIN:$PATH" "$TOOL" "$HERE/../fixtures/issue.frames.json" "$ROOT/Fixture.xcarchive" --pretty > "$ROOT/issue.out.json"

python3 - "$ROOT/issue.out.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert len(data) == 4, data
assert data[0]["image_uuid"] == "6f7a8b9c-1d2e-3f40-8a9b-0c1d2e3f4a5b", data[0]
assert data[0]["symbolicated"] is True, data[0]
assert data[0]["symbol"] == "ShuheApple.ReaderView.load()", data[0]
assert data[0]["file"] == "ReaderView.swift" and data[0]["line"] == 42, data[0]
assert data[1]["symbol"] == "unsymbolicated" and data[1]["symbolicated"] is False, data[1]
assert data[1]["image_uuid"] == "00000000-0000-0000-0000-000000000000", data[1]
assert data[2]["symbolicated"] is True and data[2]["line"] == 10, data[2]
assert data[3]["symbolicated"] is True and data[3]["file"] is None and data[3]["line"] is None, data[3]
assert data[3]["symbol"] == "type metadata accessor for CoReadingPanel", data[3]
print("issue.frames 场景: OK")
PY

PATH="$BIN:$PATH" "$TOOL" "$HERE/../fixtures/payload.frames.json" "$ARCHIVE" --pretty > "$ROOT/payload.out.json"

python3 - "$ROOT/payload.out.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert len(data) == 1, data
assert data[0]["symbolicated"] is True, data
assert data[0]["offset"] == 128040, data
print("payload.frames 场景: OK")
PY

echo "SymbolicateApp: 全部自测通过"
