# 设计：moo-monitor-ios

> 上报契约以 `moo-scaffold-cloud/docs/app-monitor.md` 为准（数据表、指纹、count 语义、端点与能力）。本文只写 SDK 侧的采集、符号化、落盘、上报与边界。

## 1. 定位

iOS / iPadOS 的进程内异常采集库。与 `moo-monitor-android` 对齐同一份上报格式，云端不区分语言。

不做的事：

- 不做服务端符号化（生产机是 Linux，没有 `atos` / dSYM 工具链）。
- 不替换宿主的崩溃处理：信号处理器写完帧后恢复默认处理并重新抛出，让系统照常生成崩溃报告。
- 不承诺覆盖系统级终止（watchdog、OOM、用户强杀），只能事后推断，见 §4.4。

## 2. 前提与约束

| 项 | 值 | 影响 |
|---|---|---|
| 部署目标 | iOS 17.0 | MetricKit 的 `MXCrashDiagnostic` / `MXHangDiagnostic` 可用（iOS 14+） |
| 语言 | Swift 5 + C | 崩溃路径必须用 C，见 §3.1 |
| 依赖 | 无 | 不引第三方崩溃库 |
| 构建 | Release 带 dSYM | M3 的 Mac 侧 `atos` 才有得解析 |
| 后台 | 无特殊 entitlement | 补发只在启动与退后台时争取时间 |

## 3. 模块结构

```
Package.swift
Sources/
  MooMonitorCrash/                 C 目标：异步信号安全的写盘
    moo_crash_writer.c
    include/moo_crash_writer.h
  MooMonitor/                      Swift 目标
    MooMonitor.swift               门面：install / capture / screen / flush
    MonitorConfig.swift
    CrashReporter.swift            信号 + NSException 安装、二进制帧读取
    SessionMarker.swift            脏退出推断
    AppErrorEvent.swift            记录模型（Codable）
    EventStore.swift               JSONL 队列、上限、丢弃计数
    Uploader.swift                 URLSession 批量上报
    FrameResolver.swift            下次启动 dladdr + swift_demangle
    Breadcrumbs.swift
    Redactor.swift
    DeviceInfo.swift
    MetricKitCollector.swift       MXCrashDiagnostic / MXHangDiagnostic（M2）
Tests/MooMonitorTests/
Tools/SymbolicateApp/              M3：Mac 上用 atos 补行号
```

```swift
products: [
    .library(name: "MooMonitor", targets: ["MooMonitor"]),
],
targets: [
    .target(name: "MooMonitorCrash"),
    .target(name: "MooMonitor", dependencies: ["MooMonitorCrash"]),
    .testTarget(name: "MooMonitorTests", dependencies: ["MooMonitor"]),
]
```

## 4. 采集点

| 来源 | 钩子 | `kind` | 备注 |
|---|---|---|---|
| ObjC 异常 | `NSSetUncaughtExceptionHandler` | `crash` | 只在 ObjC 桥接/三方库抛时触发 |
| 致命信号 | `SIGABRT` `SIGSEGV` `SIGBUS` `SIGILL` `SIGFPE` `SIGTRAP` | `crash` | Swift `fatalError`、数组越界、强制解包 nil 都走这里 |
| 内存警告 | `applicationDidReceiveMemoryWarning` | `low_memory` | 1 小时 1 条 |
| 脏退出推断 | 下次启动比对 session 标记 | `termination` | 前台被杀、OOM、watchdog 只能推断 |
| 主线程卡死 | 后台线程 ping 主队列 | `hang` | M3；只记时长与最后界面 |
| 系统诊断 | MetricKit `MXCrashDiagnostic` | `crash` | M2；Apple 回传，含 watchdog 与 OOM 分类 |
| 业务主动上报 | `MooMonitor.capture(error)` | `handled` | 默认关闭，调用点显式开 |

### 4.1 为什么信号处理写在 C 里

信号处理器运行在**被中断的线程**上，只能调用异步信号安全函数。Swift 的字符串拼接、`Codable`、`Data` 都可能分配内存、加锁、触发 ARC——在被中断的 malloc 上再 malloc 会死锁或二次崩溃，结果是「加了监控之后崩溃报告反而没了」。

所以 C 里只做一件事：把预分配的定长结构体用**一次** `write(2)` 写进预打开的 fd，然后恢复默认处理并 `raise` 原信号。

```c
typedef struct {
    uint32_t magic;        // 'MOOC'
    uint16_t version;      // 1
    uint16_t kind;         // 1=signal 2=exception
    int32_t  sig;
    uint64_t timestamp_ms;
    uint64_t thread_id;
    uint32_t depth;
    uint32_t image_count;
    uint64_t offsets[64];      // 相对所在 image 基址的偏移，不是绝对地址
    uint8_t  image_index[64];  // 每个 offset 属于哪个 image
    uint8_t  image_uuids[16][16];
} moo_crash_frame;
```

- `moo_crash_install(path)`：`open(path, O_WRONLY|O_CREAT|O_APPEND, 0600)`，fd 常驻，结构体放静态区；同时把当前 image 表（UUID + 基址）缓存到静态数组。
- `moo_crash_handle(sig)`：`memset` → 填 `sig` / 时间 / 线程 → `backtrace()` 取 64 个地址 → 用**缓存**的 image 表算 offset 与 image_index → 一次 `write` → `signal(sig, SIG_DFL); raise(sig);`。
- 处理器里不调用 `_dyld_image_count` / `_dyld_get_image_header`：dyld 内部有锁，信号恰好落在持锁线程会死锁。image 表只在启动时取一次。
- `backtrace()` 在信号上下文里属于「事实标准但非 POSIX 保证」，这是所有进程内采集器共同的取舍，不假装没有。

### 4.2 NSException

`NSSetUncaughtExceptionHandler` 里是普通上下文，可以用 Swift 组装 JSON 落盘。记录 `name` / `reason` / `callStackSymbols`，写完直接返回，让系统继续终止进程。

### 4.3 记录构造

崩溃帧在**下次启动**才变成完整记录，分两步：

1. **崩溃时**（C）：落 `offset = address - image_base` 与 `image_uuid`，不存绝对地址，几十字节到 1KB。
2. **下次启动**（Swift）：按 UUID 找回当前进程里同一个 image 的基址，`runtime_addr = new_base + offset`，再 `dladdr` 取符号 → `swift_demangle` 还原 Swift 名 → 组装完整 JSON 进队列。

**为什么不能直接存绝对地址**：iOS 每次启动都做 ASLR，同一函数在新进程里的绝对地址和上次完全不同。把崩溃时的绝对地址拿到下次启动去 `dladdr`，命中的是随机内存，轻则取不到符号，重则读到别人的镜像区间、给出一个看起来很像真的错误函数名——比没有符号更糟。

```swift
// 崩溃时（C）：只记相对基址的偏移
frame.offsets[i] = address - image_bases[imageIndex];
memcpy(frame.image_uuids[imageIndex], uuid, 16);

// 下次启动（Swift）：按 UUID 找回当前基址，再加偏移
guard let base = currentImageBase(uuid: frame.imageUUIDs[i]) else { continue }
let addr = base + frame.offsets[i]
var info = Dl_info()
guard dladdr(UnsafeRawPointer(bitPattern: addr), &info) != 0 else { continue }
let name = info.dli_sname.map { String(cString: $0) } ?? "<unknown>"
let pretty = demangle(name) ?? name
```

`app = true`：`image_uuid` 等于主可执行文件的 `LC_UUID`。

**没有行号。** 行号在 dSYM 里，设备上不解析 DWARF——那是几十 MB 的解析，启动时做不起。M3 用 Mac 上的 `atos` 补。

### 4.4 脏退出推断

启动时读 `Application Support/monitor/session.json`：

```json
{ "session_id": "…", "started_at": 1762…, "state": "foreground", "release": "0.1.1", "build": "12" }
```

- 启动写 `starting`，进前台写 `foreground`，进后台写 `background`。
- 下次启动时：上一条是 `foreground` 且本地**没有**对应时间的崩溃帧 → 记一条 `termination`（`payload.reason = "unknown"`，带 `duration_ms`）。
- 上一条是 `background` → 系统正常回收，不记。

这条覆盖 iOS 上最常见的「用着用着没了」：watchdog、OOM、用户上滑强杀。分不清是哪一种，所以 `kind` 就叫 `termination`，不假装是 crash。

### 4.5 MetricKit（M2）

`MXMetricManager.shared.add(subscriber)`，收 `MXCrashDiagnostic`、`MXHangDiagnostic`、`MXAppExitMetric`。

- 覆盖进程内拿不到的部分：watchdog 终止、OOM、系统强杀。
- 代价：Apple 侧聚合后回传，通常延迟到**次日**，且要求用户在「分析与改进」里开启共享。不是实时通道。
- 只取 `callStackTree` 的帧（已符号化的 JSON）、`terminationReason`、`virtualMemoryRegionInfo`，其余丢弃。
- 与本地 `crash` 按「同 release + 同 30 分钟窗口 + 同 `exceptionType`」去重，避免一条崩溃出现两次。

## 5. 落盘

`Application Support/monitor/`：

| 文件 | 内容 |
|---|---|
| `crash.bin` | 崩溃帧（定长结构体，可多条追加） |
| `queue.jsonl` | 待发记录，一行一条 |
| `session.json` | 脏退出标记 |

- 队列上限 200 条 / 2MB，超限保留最后 150 条并累加 `dropped`。
- `crash.bin` 上限 20 帧，超了覆盖最旧的；同一指纹 1 小时内最多写 10 帧。坏版本「启动即崩」时没有这个闸，一小时内能写出上千条同一条崩溃。
- 目录标 `isExcludedFromBackup = true`：这些数据不该进 iCloud 备份。

## 6. 上报

- `URLSession.shared` + `dataTask`；后台时用 `beginBackgroundTask` 争取时间（系统约 30 秒）。
- 触发：启动后 10 秒、`scenePhase` 变 `.background`、宿主后台刷新回调、手动 `flush()`。
- 批次 ≤50 条 / ≤512KB；发送前按指纹合并 `count`。
- 状态码：`2xx` 删批；`401/403` 清队列并持久化 `disabled`；`422` 丢批；`429` 读 `Retry-After`；`5xx`/网络错误退避 `30s → 2m → 8m → 30m`，最多 6 次。
- 不用 background `URLSession`：崩溃上报不值得为它引一套独立会话生命周期。

## 7. 脱敏

- 路径：`/var/mobile/Containers/Data/Application/<UUID>/…` → `~/…`。
- URL query 键名命中 `password|pwd|token|secret|api_key|authorization|sig` → `***`。
- 消息里的长 hex/base64 → `[blob]`。
- `install_id`：Keychain 里随机 UUID 的 SHA-256，卸载重装会换；不复用宿主的同步凭据 key。
- 不上报：用户内容、书籍路径、同步凭据、用户偏好。

## 8. 接入

```swift
MooMonitor.install(MonitorConfig(
    endpoint: URL(string: "https://c.mooeen.com")!,
    token: Bundle.main.object(forInfoDictionaryKey: "MOOMonitorToken") as? String ?? "",
    release: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
    build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
))
```

界面追踪：`MooMonitor.screen("ReaderView")`，在关键视图 `onAppear` 调一次，只传视图名。

Token 从构建配置注入，**不进源码、不进 git**：

- `Config/Monitor.xcconfig`（`.gitignore`）里 `MOO_MONITOR_TOKEN = …`
- `Info.plist` 加 `MOOMonitorToken = $(MOO_MONITOR_TOKEN)`
- 构建时 `xcodebuild MOO_MONITOR_TOKEN="$(cat /Volumes/dev/build_tokens/shuhe-monitor)"`

## 9. 分发

M1 用**本地 SwiftPM 包**：宿主 Xcode 工程把本目录作为 package 引用（`XCLocalSwiftPackageReference`），不发布、不改宿主的依赖流程。等第二个宿主出现再谈发布。

## 10. 测试

| 层 | 内容 |
|---|---|
| 单元 | `EventStore`：追加、轮转、`dropped`、损坏行跳过 |
| 单元 | `FrameResolver`：构造地址与 image 区间，断言符号与 `app` 标记 |
| 单元 | `Uploader`：`URLProtocol` 桩，覆盖 200/401/422/500 |
| 单元 | `SessionMarker`：三种状态转移（前台→崩溃、前台→消失、后台→消失） |
| 真机 | `fatalError("monitor-test")`，杀进程后重启，确认队列里有可读栈 |
| 真机 | 强制解包 nil 与数组越界，确认 C 路径写出帧且系统崩溃报告仍然生成 |
| 真机 | 前台直接上滑强杀，重启后确认 `termination` 一条，且不是 `crash` |

**必须验证「加了监控之后系统崩溃报告还在」**——信号处理器写错最常见的后果就是把原报告吞掉。

## 11. 分阶段

- **M1**：信号 + NSException 采集、二进制帧、下次启动符号化、队列与上报。
- **M2**：MetricKit 订阅与去重、内存警告、`capture()` 业务接线。
- **M3**：hang watchdog、dSYM 上传、`Tools/SymbolicateApp`（`atos` 补行号后回写 `src_frames`）。

## 12. 边界

- 采不到：`main()` 之前、动态库加载阶段的崩溃；被 `SIGKILL` 的进程；用户关闭「共享分析」时的 MetricKit 数据。
- 没有行号，只有函数名 + 偏移。要行号必须走 M3 的 Mac 侧 `atos`。
- `hang` 只能测到「主线程多久没响应」，拿不到主线程当时的栈——在 iOS 上取其它线程栈需要 Mach `thread_get_state`，代码量与风险都不值得放进 M3 之前。
- 崩溃帧定长：栈深超过 64 帧、image 超过 16 个的部分丢失。
- 多进程扩展（App Extension）需各自 install，本库不做跨进程汇总。
