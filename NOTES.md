# NOTES

已验证的事实、环境要求与坑。**只写已经发生的事**，计划写进 `TODOS.md`，设计写进 `docs/design.md`。

## 环境

- Xcode 15+（iOS 17 SDK），Swift 5.9。
- `swift build` / `swift test` 可在命令行跑；真机验证需要签名与设备。
- MetricKit 数据只在 App Store / TestFlight 分发的包上才有，Debug 侧载基本收不到。

## 待验证（M1 开工后回填）

- 信号处理器写入后 `raise` 原信号，系统崩溃报告是否仍完整生成（iPhone 与 iPad 各一台）。
- `backtrace()` 在信号上下文的稳定性：连续 20 次人为 `fatalError`，看帧是否都完整。
- 下次启动 `dladdr` + `swift_demangle` 的耗时（影响启动路径，必须测）。
- 上滑强杀后的 `termination` 推断是否会被后台态误判（应只在 `foreground` 时记）。

## 坑（预判，待证实后转正）

- SwiftUI `body` 崩溃的栈里混着大量 SwiftUI 内部帧，`app = true` 过滤后仍可能不好读。
- 首次安装后立刻崩溃的包，队列要等下一次启动才发；用户不再打开就永远不发。
- 扩展（Widget / Share Extension）有独立进程，需要各自 install。
