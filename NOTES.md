# NOTES

已验证的事实、环境要求与坑。**只写已经发生的事**，计划写进 `TODOS.md`，设计写进 `docs/design.md`。

## 环境

- Xcode 15+（iOS 17 SDK），Swift 5.9。
- `swift build` / `swift test` 可在命令行跑；真机验证需要签名与设备。
- MetricKit 数据只在 App Store / TestFlight 分发的包上才有，Debug 侧载基本收不到。

## 已证实（2026-11-09，书禾 Apple 模拟器闭环）

- 信号处理器里的 `memset(&g_frame, ...)` 会把安装时缓存的 `image_uuids` 一起清掉，结果下次启动所有帧都还原不出符号。UUID 必须放在独立的 `g_image_uuids` 静态数组，处理器里再拷回帧。
- 旧实现（2026-11-10 已移除）的 `backtrace()` 在信号上下文里首帧是 `moo_crash_handle`；读取端去掉它和 `_sigtramp` 后，`fatalError` 的栈顶是 `Swift._assertionFailure`，再往下能看到宿主的触发闭包。模拟器一次崩溃还原 17 帧，其中 3 帧为 app。
- image 归属必须按 `[base, end)` 判断；不在启动时缓存的 32 个 image 里写 `0xFF` 哨兵并跳过，不能按「最后一个基址小于 addr」猜。i386/x86_64 模拟器同样适用。
- NSException 未捕获后系统会 `abort()` 成 `SIGABRT`；Swift 侧写完 `exception.json` 后必须调用 `moo_crash_skip_signal_after_exception()`，否则同一次崩溃会产出 NSException + SIGABRT 两条记录。写文件失败时不设标记，让信号路径兜底。
- 书禾 Apple Debug 包用本地 mock intake 验证：`fatalError` → 下次启动 `queue.jsonl` 一条 `crash`（17 帧、5 条面包屑、`screen=LibraryView`）→ 启动 10s 后 POST `/api/v1/app-errors/intake`，`X-Project-Token` 44 字符、`sdk.version=0.2.0`、200 后队列清空。
- 未签名的模拟器上 Keychain 返回 `-34018`，`install_id` 原本每次启动都变；现在 Keychain 失败会退回 `monitor/install-id` 文件，模拟器与首解锁前启动都能保持稳定。真机签名构建仍优先 Keychain。
- 宿主 Xcode 的 token 注入脚本如果只在 build phase 里改产物 `Info.plist`，增量构建会先跑脚本、再跑 `ProcessInfoPlistFile`，把 token 覆盖回空。必须把 `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)` 声明为脚本的 `inputPaths`，并设 `alwaysOutOfDate = 1`。

## 真机复验（2026-11-10）

- iPhone 13 独立 QA 包的 fatalError、强制解包 nil、NSException 均完成采集、下次启动恢复与本机 Laravel 入库；三个系统报告的 Bundle ID、版本、二进制 UUID 均匹配，保留故障线程栈及 NSException Backtrace。证据见 [HANDOFF](HANDOFF.md)，iPad 与其他边界见 [TODOS](TODOS.md)。
- QA 包缺少 scene 配置或在 UIApplication.active 之前请求本地端点，会被本地网络权限拦截且本机收不到请求；补 scene 并等 active 后正常。该问题在测试夹具修复，未更改系统安全策略。

## 已知边界

- SwiftUI `body` 崩溃的栈里混着大量 SwiftUI 内部帧，`app = true` 过滤后仍可能不好读。
- 首次安装后立刻崩溃的包，队列要等下一次启动才发；用户不再打开就永远不发。
- 扩展（Widget / Share Extension）有独立进程，需要各自 install。
- 地址不在启动时缓存的 32 个 image 内时使用 `0xFF` 哨兵并跳过；已缓存的 UUID 在下次启动失配时保留 UUID/offset 原始证据。

## 可靠性复核（2026-11-10）

- HTTP200不能代表逐条成功；旧实现会删除未持久化记录。现在验证完整唯一index回执，使用原始行收据；上传期间轮转/追加不再移动确认对象。
- 本地指纹合并会与上传中的不可变快照相冲突，导致增量被重复计数；当前保留独立事件，由服务端聚合。恢复源用稳定event_id，重放不增加count。
- 旧实现的字节轮转只裁条数，少量大记录仍会超2MB；现按两种预算同时保留。追加不重扫全文，批次按缓存的JSON长度选择前缀，减少重复序列化。
- 旧C读取遇到一条坏帧就停止，后续有效崩溃会被遮住；失败用例复现后，改为在定长边界跳过坏帧，保留后续有效帧。
- C信号路径已改为内核PC/LR，不再使用backtrace；只能给出最多两个地址，不能将历史17帧模拟器结果当作当前能力。系统报告红线以本轮实体证据为准。
- 崩溃补传不能用新版本/session重新标注旧故障；recovery快照在入队前冻结原构建/环境/会话/设备和稳定ID，写失败可跨启动重放。
- Keychain可能跨卸载保留。install_id优先专用Keychain并维护本机fallback，不能宣称重装一定换ID；不复用宿主账号凭据。
- 宿主的inactive不等于background；调用控制中心等短暂失焦不应抹掉前台退出推断。相同界面/生命周期通知合并，内存警告与宿主错误限流使用单调时钟。
- 本机合成追加基准、全量单测、宿主hosted与iPhone13状态的日志和边界集中在HANDOFF；Mac子进程崩溃不能替代iOS系统报告验证。

- 真实回环HTTP用例证实：取消HTTP认证挑战会将401变成NSURLError，错误地继续重试；当前非TLS挑战以空凭据继续获取401响应，再按撤权保留队列并禁用。跳转/cookie的实际URLSession用例同时通过。
- 原始NSError类型无法区分Cocoa错误码，且服务端会归一化消息数字；当前以domain#code分组。宿主CustomNSError显式桥接原错误码，只含固定区域/码，不带原userInfo。
- quoted/prefixed多词凭据、超大payload回退丢失dropped、termination本地severity错误均由失败用例复现后修复；计数与warning口径和cloud对齐。
