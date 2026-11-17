# SymbolicateApp —— Mac 批量符号化 CLI

把 moo-cloud `get_issue` 返回的崩溃帧（`image_uuid` + `offset`）在 Mac 上用本地
dSYM 批量还原成 `symbol/file/line`。云端不做服务端 iOS 符号化（生产 Linux 无
atos/dSYM 工具链），dSYM 只存档，符号化在本机完成，见
[`docs/dsym-and-symbolication.md`](../../docs/dsym-and-symbolication.md)。

## 组成

| 文件 | 作用 |
|---|---|
| `symbolicate-app.sh` | bash 入口：参数处理、dSYM 定位、`dwarfdump` 建 UUID 索引、逐帧调用 `atos` |
| `symbolicate_app.py` | python3 适配层：解析输入 JSON、回填 `symbol/file/line` 并输出 JSON 数组（仅标准库） |
| `fixtures/` | 示例 issue JSON：`issue.frames.json`、`payload.frames.json` |
| `tests/run-tests.sh` | 离线自测：用桩替换 `dwarfdump`/`xcrun atos`，无需真实构建 |

不引第三方依赖，只要求 python3 与 Xcode 命令行工具（`dwarfdump`、`xcrun atos`）。

## 用法

```bash
# 用 xcarchive（内含 dSYMs/）
tools/SymbolicateApp/symbolicate-app.sh crash.json /path/ShuheApple.xcarchive --pretty

# 或直接指向 .dSYM 目录 / 单个 .dSYM
tools/SymbolicateApp/symbolicate-app.sh crash.json /path/DerivedData/.../dSYMs
tools/SymbolicateApp/symbolicate-app.sh crash.json /path/ShuheApple.app.dSYM

# 写文件
tools/SymbolicateApp/symbolicate-app.sh crash.json /path/ShuheApple.xcarchive --output frames.json
```

选项：`--arch <arch>`（默认 `arm64`）、`--image-base <hex>`（默认 `0x100000000`）、
`--output <file>`、`--pretty`。

## 输入

moo-cloud `get_issue` JSON，帧在 `issue.frames` 或 `payload.frames`（也兼容包在
`data` / `structuredContent` 等信封里的同级结构）。帧形如：

```json
{ "image_uuid": "6f7a8b9c-1d2e-3f40-8a9b-0c1d2e3f4a5b", "offset": 128040, "app": "ShuheApple" }
```

`offset` 支持十进制整数、十进制字符串或 `0x` 十六进制字符串。

## 输出

JSON 数组，逐帧保留原字段（如 `image_uuid`、`offset`、`app`），并新增：

- `symbol`：函数名；未匹配到 dSYM 或 atos 解不出时为 `"unsymbolicated"`；
- `file` / `line`：源码文件与行号，未解析时为 `null`；
- `symbolicated`：布尔，是否成功；
- `note`：仅失败帧带，说明原因（如 `no dSYM matching uuid ...`）。

```json
[
  {
    "image_uuid": "6f7a8b9c-1d2e-3f40-8a9b-0c1d2e3f4a5b",
    "offset": 128040,
    "app": "ShuheApple",
    "symbol": "ShuheApple.ReaderView.load()",
    "file": "ReaderView.swift",
    "line": 42,
    "symbolicated": true
  },
  {
    "image_uuid": "00000000-0000-0000-0000-000000000000",
    "offset": 4096,
    "app": "UIKitCore",
    "symbol": "unsymbolicated",
    "file": null,
    "line": null,
    "symbolicated": false,
    "note": "no dSYM matching uuid 00000000000000000000000000000000"
  }
]
```

## 解析规则

- UUID 比较前统一小写并去掉连字符；`dwarfdump --uuid` 取第一行。
- 地址 = `image_base(默认 0x100000000) + offset`，与
  `atos -arch arm64 -l 0x100000000 <addr>` 一致。
- DWARF 二进制取 `<dSYM>/Contents/Resources/DWARF/` 下的文件，不按 bundle 名猜
  （`ShuheApple.app.dSYM` 里的二进制叫 `ShuheApple`）。
- 批量时先用 `dwarfdump` 建一次 `UUID -> 二进制` 索引，避免每帧重扫所有 dSYM。
- 单帧快速排查仍可用 [`scripts/symbolicate.sh`](../../scripts/symbolicate.sh)；
  本工具与其共用同一 `dwarfdump`/`atos` 契约。

## 自测

```bash
bash tools/SymbolicateApp/tests/run-tests.sh
```

用桩 `dwarfdump`/`xcrun` 覆盖：issue.frames 多帧、payload.frames、UUID 大写/连字符归一化、
十六进制 offset、无匹配 dSYM 标 unsymbolicated。
