#!/usr/bin/env python3
"""SymbolicateApp 的 JSON 适配层。

shell 入口（symbolicate-app.sh）负责调用 Xcode 工具链：用 dwarfdump 建立
UUID -> DWARF 二进制索引、逐帧调用 atos。本助手只做两件与 JSON 形状相关的
工作，避免在 bash 里拼接/解析 JSON：

  extract  <issue.json> <image-base> <work-dir>
      读取 moo-cloud get_issue JSON，定位 issue.frames 或 payload.frames，
      规范化后写 <work-dir>/frames.json 与 <work-dir>/frames.tsv，
      供 shell 逐帧调用 atos。

  assemble <issue.json> <work-dir> [--pretty]
      读取 <work-dir>/frames.json 和 shell 抓取的 <work-dir>/atos/<i>.out，
      把 symbol/file/line 合并回原始帧对象，输出 JSON 数组。

只用 Python 标准库，符合“避免第三方依赖”的约束。
"""

import json
import os
import re
import sys


def die(message):
    sys.stderr.write("symbolicate_app: %s\n" % message)
    sys.exit(2)


def normalize_uuid(value):
    """UUID 统一成小写无连字符，用于和 dwarfdump 输出比较。"""
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower().replace("-", "")
    return normalized or None


def parse_offset(value):
    """offset 允许十进制整数、十进制字符串或 0x 十六进制字符串。"""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            return int(text, 16) if text.lower().startswith("0x") else int(text, 10)
        except ValueError:
            return None
    return None


def _iter_frame_lists(node, path):
    """递归找出所有 dict 里的 frames 列表，记录其路径。"""
    if isinstance(node, dict):
        for key, value in node.items():
            child = path + (key,)
            if key == "frames" and isinstance(value, list):
                yield child, value
            else:
                yield from _iter_frame_lists(value, child)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from _iter_frame_lists(value, path + (index,))


def locate_frames(doc):
    """优先取 issue.frames，其次 payload.frames，最后任意 frames。

    moo-cloud get_issue 可能直接给 {issue:{frames}} 或 {payload:{frames}}，
    也可能包在 data/structuredContent 等信封里，递归查找即可覆盖。
    """
    candidates = list(_iter_frame_lists(doc, ()))
    if not candidates:
        die("输入 JSON 中没有找到 frames 数组（期望 issue.frames 或 payload.frames）")

    def priority(item):
        path = item[0]
        score = 0.0
        if "issue" in path:
            score += 2.0
        if "payload" in path:
            score += 1.0
        # 路径越短越可能是顶层帧列表
        score -= len(path) * 0.001
        return score

    candidates.sort(key=priority, reverse=True)
    path, frames = candidates[0]
    sys.stderr.write("symbolicate_app: 使用帧路径 %s（%d 帧）\n" % (".".join(map(str, path)), len(frames)))
    return frames


def parse_atos(text):
    """解析单帧 atos 输出，返回 (symbol, file, line) 或 None。

    典型输出：ShuheApple.ReaderView.load() (in ShuheApple) (ReaderView.swift:42)
    未解析时 atos 会给出 0xADDR (in Image) + N，此时视为 unsymbolicated。
    """
    # 兼容三种真实 atos 形态：
    #   symbol (in Image) (File.swift:42)   —— 有符号与行号
    #   symbol (in Image) + 0               —— 有符号但无行号
    #   0xADDR (in Image) + 4096            —— 只有地址（无符号）
    pattern = re.compile(
        r"^(?P<symbol>.*?) \(in [^)]*\)(?: \+ 0x[0-9a-fA-F]+| \+ \d+)?(?: \((?P<file>.+?):(?P<line>\d+)\))?$"
    )
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        match = pattern.match(line)
        if not match:
            return None
        symbol = match.group("symbol").strip()
        file_name = match.group("file")
        line_no = match.group("line")
        # 以 0x 开头说明 atos 只回了地址，没有符号名
        if not symbol or symbol.startswith("0x"):
            return None
        return symbol, file_name, int(line_no) if line_no else None
    return None


def cmd_extract(input_path, image_base_text, work_dir):
    try:
        base = int(image_base_text, 16) if image_base_text.lower().startswith("0x") else int(image_base_text, 10)
    except ValueError:
        die("--image-base 不是合法整数: %s" % image_base_text)

    with open(input_path, "r", encoding="utf-8") as handle:
        doc = json.load(handle)

    frames = locate_frames(doc)
    manifest = []
    tsv_lines = []
    for index, frame in enumerate(frames):
        entry = {"index": index, "frame": frame}
        if not isinstance(frame, dict):
            entry.update({"uuid": None, "uuid_norm": None, "offset": None, "addr": None, "note": "frame 不是对象"})
            manifest.append(entry)
            continue
        uuid_raw = frame.get("image_uuid") or frame.get("binary_uuid") or frame.get("uuid")
        uuid_norm = normalize_uuid(uuid_raw)
        offset = parse_offset(frame.get("offset"))
        entry["uuid"] = uuid_raw
        entry["uuid_norm"] = uuid_norm
        entry["offset"] = offset
        if uuid_norm and offset is not None:
            addr = base + offset
            entry["addr"] = "0x%x" % addr
            tsv_lines.append("%d\t%s\t%s" % (index, uuid_norm, entry["addr"]))
        else:
            entry["addr"] = None
            entry["note"] = "缺少 image_uuid 或 offset"
        manifest.append(entry)

    with open(os.path.join(work_dir, "frames.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False)
    with open(os.path.join(work_dir, "frames.tsv"), "w", encoding="utf-8") as handle:
        handle.write("".join(line + "\n" for line in tsv_lines))
    sys.stderr.write("symbolicate_app: 可解析帧 %d / 总帧 %d\n" % (len(tsv_lines), len(manifest)))


def cmd_assemble(input_path, work_dir, pretty):
    with open(os.path.join(work_dir, "frames.json"), "r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    results = []
    for entry in manifest:
        frame = entry.get("frame")
        item = dict(frame) if isinstance(frame, dict) else {}
        index = entry.get("index")
        symbol = None
        file_name = None
        line_no = None
        note = None
        symbolicated = False

        out_path = os.path.join(work_dir, "atos", "%s.out" % index)
        note_path = os.path.join(work_dir, "atos", "%s.note" % index)
        if entry.get("addr") and os.path.isfile(out_path):
            with open(out_path, "r", encoding="utf-8", errors="replace") as handle:
                parsed = parse_atos(handle.read())
            if parsed:
                symbol, file_name, line_no = parsed
                symbolicated = True

        if not symbolicated:
            symbol = "unsymbolicated"
            if os.path.isfile(note_path):
                with open(note_path, "r", encoding="utf-8", errors="replace") as handle:
                    note = handle.read().strip() or None
            if note is None:
                note = entry.get("note") or "atos 未能解析出符号"

        item["symbol"] = symbol
        item["file"] = file_name
        item["line"] = line_no
        item["symbolicated"] = symbolicated
        if not symbolicated:
            item["note"] = note
        results.append(item)

    json.dump(results, sys.stdout, ensure_ascii=False, indent=2 if pretty else None)
    sys.stdout.write("\n")


def main(argv):
    if len(argv) < 2:
        die("用法: symbolicate_app.py {extract|assemble} ...")
    command = argv[1]
    if command == "extract":
        if len(argv) != 5:
            die("用法: symbolicate_app.py extract <issue.json> <image-base> <work-dir>")
        cmd_extract(argv[2], argv[3], argv[4])
    elif command == "assemble":
        args = argv[2:]
        if len(args) < 2:
            die("用法: symbolicate_app.py assemble <issue.json> <work-dir> [--pretty]")
        cmd_assemble(args[0], args[1], "--pretty" in args[2:])
    else:
        die("未知子命令: %s" % command)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
