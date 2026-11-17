#!/usr/bin/env bash
# SymbolicateApp —— Mac 批量符号化 CLI。
#
# 输入一份 moo-cloud get_issue JSON（含 issue.frames 或 payload.frames，帧形如
# {image_uuid, offset, app}）与一个 xcarchive（含 dSYMs/）或 .dSYM 目录；
# 逐帧按 image_uuid 匹配 dSYM 里的 DWARF 二进制，用
#   atos -arch arm64 -l 0x100000000 (0x100000000 + offset)
# 还原出 symbol/file/line，最后输出 JSON 数组（保留原帧字段）。
#
# 设计：bash 负责 Xcode 工具链调用（批量时先用 dwarfdump 预建 UUID 索引，
# 避免每帧重扫所有 dSYM），python3 只做 JSON 读写与 atos 文本解析，
# 不引第三方依赖。单帧场景仍可用 scripts/symbolicate.sh。
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PY_HELPER="$SCRIPT_DIR/symbolicate_app.py"

usage() {
  cat >&2 <<'EOF'
usage: symbolicate-app.sh <issue.json> <xcarchive | dSYMs-dir | *.dSYM> [options]

  逐帧符号化 moo-cloud get_issue JSON 里的 issue.frames 或 payload.frames。
  frame 形如 {"image_uuid": "...", "offset": 123, "app": "..."}。

options:
  --arch <arch>        atos 架构，默认 arm64
  --image-base <hex>   镜像基址，默认 0x100000000
  --output <file>      输出文件（默认打印到 stdout）
  --pretty             美化 JSON
  -h, --help           显示帮助

依赖：python3 与 Xcode 命令行工具（dwarfdump、xcrun atos）。
EOF
}

die() { echo "symbolicate-app: $*" >&2; exit 2; }

ARCH=arm64
IMAGE_BASE=0x100000000
OUTPUT=""
PRETTY=0

NP=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --arch) [ $# -ge 2 ] || die "--arch 需要参数"; ARCH=$2; shift 2 ;;
    --image-base) [ $# -ge 2 ] || die "--image-base 需要参数"; IMAGE_BASE=$2; shift 2 ;;
    --output) [ $# -ge 2 ] || die "--output 需要参数"; OUTPUT=$2; shift 2 ;;
    --pretty) PRETTY=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do NP=$((NP+1)); if [ "$NP" -eq 1 ]; then INPUT=$1; elif [ "$NP" -eq 2 ]; then SRC=$1; else die "多余参数 $1"; fi; shift; done ;;
    -*) die "未知选项 $1" ;;
    *)
      NP=$((NP+1))
      if [ "$NP" -eq 1 ]; then INPUT=$1; elif [ "$NP" -eq 2 ]; then SRC=$1; else die "多余参数 $1"; fi
      shift ;;
  esac
done

[ "$NP" -eq 2 ] || { usage; exit 2; }

command -v python3 >/dev/null 2>&1 || die "找不到 python3"
command -v dwarfdump >/dev/null 2>&1 || die "找不到 dwarfdump（先安装 Xcode 命令行工具）"
command -v xcrun >/dev/null 2>&1 || die "找不到 xcrun（先安装 Xcode 命令行工具）"
[ -f "$INPUT" ] || die "issue JSON 不存在: $INPUT"
[ -e "$SRC" ] || die "dSYM 来源不存在: $SRC"

# 定位 dSYM：支持 .xcarchive（内含 dSYMs/）、普通目录、或单个 .dSYM 包
DSYM_ROOT=$SRC
SINGLE_DSYM=0
if [ -d "$SRC" ]; then
  case "$SRC" in
    *.dSYM) SINGLE_DSYM=1 ;;
  esac
  if [ -d "$SRC/dSYMs" ]; then DSYM_ROOT="$SRC/dSYMs"; fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/atos"

INDEX="$WORK/dsym-index.tsv"
: > "$INDEX"

# DWARF 文件名不一定是 bundle 名（ShuheApple.app.dSYM 里的二进制叫 ShuheApple），
# 所以直接取 Contents/Resources/DWARF 下的第一个文件，而不是按 bundle 名猜。
add_dsym() {
  d=$1
  bin=""
  for f in "$d/Contents/Resources/DWARF"/*; do
    if [ -f "$f" ]; then bin=$f; break; fi
  done
  if [ -z "$bin" ]; then
    echo "symbolicate-app: 跳过 $d（缺 DWARF 二进制）" >&2
    return 0
  fi
  uuid=$(dwarfdump --uuid "$d" 2>/dev/null | awk '{print $2}' | head -1 | tr 'A-F' 'a-f' | tr -d '-')
  if [ -z "$uuid" ]; then
    echo "symbolicate-app: 跳过 $d（读不到 UUID）" >&2
    return 0
  fi
  printf '%s\t%s\n' "$uuid" "$bin" >> "$INDEX"
}

if [ "$SINGLE_DSYM" -eq 1 ]; then
  add_dsym "$SRC"
else
  found=0
  for d in "$DSYM_ROOT"/*.dSYM; do
    if [ -d "$d" ]; then
      add_dsym "$d"
      found=1
    fi
  done
  [ "$found" -eq 1 ] || die "在 $DSYM_ROOT 下没有找到 .dSYM"
fi
[ -s "$INDEX" ] || die "没有可用的 dSYM（缺 DWARF 二进制或 UUID）"

# python 解析输入 JSON，写出规范化帧清单与可解析帧 TSV
python3 "$PY_HELPER" extract "$INPUT" "$IMAGE_BASE" "$WORK"

# 逐帧查找 dSYM 并调用 atos：原始输出落 atos/<i>.out，失败原因落 atos/<i>.note
while IFS=$'\t' read -r idx uuid addr; do
  [ -n "$idx" ] || continue
  bin=$(awk -F'\t' -v target="$uuid" '$1 == target { print $2; exit }' "$INDEX")
  if [ -z "$bin" ]; then
    printf 'no dSYM matching uuid %s\n' "$uuid" > "$WORK/atos/$idx.note"
    continue
  fi
  if ! xcrun atos -o "$bin" -arch "$ARCH" -l "$IMAGE_BASE" "$addr" \
      > "$WORK/atos/$idx.out" 2> "$WORK/atos/$idx.err"; then
    printf 'atos 失败: %s\n' "$(cat "$WORK/atos/$idx.err")" > "$WORK/atos/$idx.note"
  fi
done < "$WORK/frames.tsv"

# 合并结果并输出
set -- assemble "$INPUT" "$WORK"
if [ "$PRETTY" -eq 1 ]; then set -- "$@" --pretty; fi
if [ -n "$OUTPUT" ]; then
  python3 "$PY_HELPER" "$@" > "$OUTPUT"
  echo "symbolicate-app: 已写入 $OUTPUT" >&2
else
  python3 "$PY_HELPER" "$@"
fi
