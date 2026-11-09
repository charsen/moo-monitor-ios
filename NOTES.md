# NOTES

已验证的事实、环境要求与坑。**只写已经发生的事**，计划写进 `TODOS.md`，设计写进 `docs/design.md`。

## 环境

- Xcode 15+（iOS 17 SDK），Swift 5.9。
- `swift build` / `swift test` 可在命令行跑；真机验证需要签名与设备。
- MetricKit 数据只在 App Store / TestFlight 分发的包上才有，Debug 侧载基本收不到。

## 已证实（2026-11-09，书禾 Apple 模拟器闭环）

- 信号处理器里的 `memset(&g_frame, ...)` 会把安装时缓存的 `image_uuids` 一起清掉，结果下次启动所有帧都还原不出符号。UUID 必须放在独立的 `g_image_uuids` 静态数组，处理器里再拷回帧。
- `backtrace()` 在信号上下文里首帧是 `moo_crash_handle`；读取端去掉它和 `_sigtramp` 后，`fatalError` 的栈顶是 `Swift._assertionFailure`，再往下能看到宿主的触发闭包。模拟器一次崩溃还原 17 帧，其中 3 帧为 app。
- image 归属必须按 `[base, end)` 判断；不在启动时缓存的 32 个 image 里写 `0xFF` 哨兵并跳过，不能按「最后一个基址小于 addr」猜。i386/x86_64 模拟器同样适用。
- NSException 未捕获后系统会 `abort()` 成 `SIGABRT`；Swift 侧写完 `exception.json` 后必须调用 `moo_crash_skip_signal_after_exception()`，否则同一次崩溃会产出 NSException + SIGABRT 两条记录。写文件失败时不设标记，让信号路径兜底。
- 书禾 Apple Debug 包用本地 mock intake 验证：`fatalError` → 下次启动 `queue.jsonl` 一条 `crash`（17 帧、5 条面包屑、`screen=LibraryView`）→ 启动 10s 后 POST `/api/v1/app-errors/intake`，`X-Project-Token` 44 字符、`sdk.version=0.2.0`、200 后队列清空。
- 未签名的模拟器上 Keychain 返回 `-34018`，`install_id` 原本每次启动都变；现在 Keychain 失败会退回 `monitor/install-id` 文件，模拟器与首解锁前启动都能保持稳定。真机签名构建仍优先 Keychain。
- 宿主 Xcode 的 token 注入脚本如果只在 build phase 里改产物 `Info.plist`，增量构建会先跑脚本、再跑 `ProcessInfoPlistFile`，把 token 覆盖回空。必须把 `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)` 声明为脚本的 `inputPaths`，并设 `alwaysOutOfDate = 1`。

## 真机待验证

- 信号处理器写入后 `raise` 原信号，系统崩溃报告是否仍完整生成（iPhone 与 iPad 各一台）。
- `backtrace()` 在信号上下文的稳定性：连续 20 次人为 `fatalError`，看帧是否都完整。
- 下次启动 `dladdr` + `swift_demangle` 的耗时（影响启动路径，必须测）。
- 上滑强杀后的 `termination` 推断：从 App Switcher 上滑时系统可能先进入 background 再被杀，`background` 状态不记 `termination`，这条要确认是否符合预期。
- 真机 Keychain 在首次解锁前的实际行为；退回文件后 `install_id` 是否稳定。

## 已知边界

- SwiftUI `body` 崩溃的栈里混着大量 SwiftUI 内部帧，`app = true` 过滤后仍可能不好读。
- 首次安装后立刻崩溃的包，队列要等下一次启动才发；用户不再打开就永远不发。
- 扩展（Widget / Share Extension）有独立进程，需要各自 install。
- 地址不在启动时缓存的 32 个 image 内的帧会被丢弃（`0xFF` 哨兵），这是「宁缺毋错」的取舍。
