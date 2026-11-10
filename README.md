# moo-monitor-ios

iOS / iPadOS 端异常采集 SDK：ObjC 异常、致命信号、内存警告、脏退出推断，落盘后批量上报到 [Moo Scaffold Cloud](https://c.mooeen.com)。主线程卡死（hang watchdog）在 M3。

与 `moo-monitor-laravel`（PHP）、`moo-monitor-go`（Go）、`moo-monitor-vue`（浏览器）、`moo-monitor-android`（Android）同属一套监控体系，共用 cloud 的 intake 契约。

## 状态

**M1 已接入书禾 Apple，本轮完成队列/回执/隐私/信号路径深化；测试证据与真机边界见 HANDOFF。** 设计与边界见 [`docs/design.md`](docs/design.md)，实施顺序见 [`TODOS.md`](TODOS.md)。

## 定位

- SwiftPM 包，两个 target：`MooMonitorCrash`（C，异步信号安全写盘）+ `MooMonitor`（Swift）。
- 不引 PLCrashReporter / KSCrash / Sentry，崩溃路径完全自控。
- 采集失败不影响宿主：信号处理器只做「一次 `write` + 重新抛出原信号」，系统崩溃报告照常生成。

## 快速接入（宿主视角）

```swift
import MooMonitor

@main
struct App: App {
    init() {
        MooMonitor.install(MonitorConfig(
            endpoint: "https://c.mooeen.com",
            token: Bundle.main.object(forInfoDictionaryKey: "MOOMonitorToken") as? String ?? "",
            release: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        ))
    }
}
```

宿主还需在 `scenePhase` 变化时调 `MooMonitor.enterForeground()` / `MooMonitor.enterBackground()`，仅在真正 `.background` 时转发后台，`.inactive` 不等同于退后台；在关键视图 `onAppear` 调 `MooMonitor.screen("ReaderView")`。token 为空时 SDK 整体禁用，不发任何请求。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/design.md`](docs/design.md) | 采集点、信号处理、符号化、落盘、上报、脱敏、测试、边界 |
| [`AGENTS.md`](AGENTS.md) | 本仓协作与编码约束 |
| [`NOTES.md`](NOTES.md) | 环境、验证边界、已知坑 |
| [`TODOS.md`](TODOS.md) | 当前未完成事项 |
| [`HANDOFF.md`](HANDOFF.md) | 本轮修复、测试与产物证据 |

云端契约（数据表、指纹规则、count 语义、端点与能力）以 `moo-scaffold-cloud/docs/app-monitor.md` 为唯一来源，本仓不复制。

## 首个接入方

书禾 Apple（`/Volumes/dev/wwwroot/shuhe-apple`）：Xcode 本地 package 引用 `../moo-monitor-ios`，`App/MonitorBridge.swift` 统一接线，`Inject Build Tokens` 脚本从 `/Volumes/dev/build_tokens` 注入 `MOOMonitorToken`。

## 仓库与许可

双远端：gitee `charsen/moo-monitor-ios`（主）、GitHub `charsen/moo-monitor-ios`（镜像）。

MIT，见 [`LICENSE`](LICENSE)。

信号路径只记录故障PC（arm64另取LR），最多2个地址；不在信号上下文运行 `backtrace()`。完整栈需系统崩溃报告。HTTP 200按逐条回执确认，401/403保留证据并按发送身份停采停发。
