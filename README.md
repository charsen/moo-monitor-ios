# Moo iOS Monitor

iOS / iPadOS 端异常采集 SDK：ObjC 异常、致命信号、内存警告、脏退出推断、主线程卡死，落盘后批量上报到 [Moo Scaffold Cloud](https://c.mooeen.com)。

与 `moo-monitor-laravel`（PHP）、`moo-go-monitor`（Go）、`moo-monitor-vue`（浏览器）、`moo-android-monitor`（Android）同属一套监控体系，共用 cloud 的 intake 契约。

## 状态

**设计完成，代码未开工。** 设计与边界见 [`docs/design.md`](docs/design.md)，实施顺序见 [`TODOS.md`](TODOS.md)。

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
            endpoint: URL(string: "https://c.mooeen.com")!,
            token: Bundle.main.object(forInfoDictionaryKey: "MOOMonitorToken") as? String ?? "",
            release: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        ))
    }
}
```

token 为空时 SDK 整体禁用，不发任何请求。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/design.md`](docs/design.md) | 采集点、信号处理、符号化、落盘、上报、脱敏、测试、边界 |
| [`AGENTS.md`](AGENTS.md) | 本仓协作与编码约束 |
| [`NOTES.md`](NOTES.md) | 环境、验证边界、已知坑 |
| [`TODOS.md`](TODOS.md) | 分阶段实施清单 |

云端契约（数据表、指纹规则、count 语义、端点与能力）以 `moo-scaffold-cloud/docs/app-monitor.md` 为唯一来源，本仓不复制。

## 首个接入方

书禾 Apple（`/Volumes/dev/wwwroot/shuhe-apple`）。

## 仓库与许可

双远端：gitee `charsen/moo-ios-monitor`（主）、GitHub `charsen/moo-ios-monitor`（镜像）。

MIT，见 [`LICENSE`](LICENSE)。
