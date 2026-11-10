# 设计：moo-monitor-ios

> 移动端上报的唯一契约是 `moo-scaffold-cloud/docs/app-monitor.md`。本文只描述 SDK 实现，不另立信封、指纹或数据库契约。

## 1. 定位与约束

iOS/iPadOS 17+、Swift 5.9+，SwiftPM 包；macOS 13+ 用于单测和原生子进程检查。不引入第三方崩溃/网络库。宿主只通过 `MooMonitor` 与 `MonitorConfig` 使用 SDK。

- token 为空或 endpoint 不合法时禁用，不安装采集器、不联网。
- 不采集用户内容、书名、同步凭据、偏好；screen 只接受最长64字节的视图标识符。
- 信号处理器不能调用 Swift、分配内存、加互斥锁或调用 dyld/backtrace。
- SDK 不吞掉致命信号，系统崩溃报告必须仍能生成；实体设备验证与未覆盖项见 NOTES/HANDOFF。
- 未递增 SDK 或宿主版本。

## 2. 模块

| 模块 | 职责 |
|---|---|
| MooMonitorCrash（C） | 安装信号处理、预开文件、缓存 image 表、写定长帧、读取/清源 |
| MooMonitor | 门面、生命周期、内存警告、恢复编排、可取消发送任务 |
| CrashReporter | NSException 的处理链和独立文件 |
| FrameResolver | 按 UUID 找回当前 image、校验地址后解析符号 |
| SessionMarker | starting/foreground/background、构建/环境/设备快照、最后界面 |
| EventStore | 单进程 JSONL 队列、容量、原始行收据、持久状态 |
| Uploader | 串行批次、逐条回执、HTTP策略、退避 |
| Redactor / DeviceInfo | 有界脱敏、设备/安装身份 |

`MonitorCrashProbe` 为 SwiftPM 测试辅助 executable，不是宿主依赖的 library 产品。

## 3. 采集点

| 来源 | 接入 | kind | 当前边界 |
|---|---|---|---|
| ObjC 异常 | NSSetUncaughtExceptionHandler | crash | 独立 exception.json；写成功后抑制随后的重复信号记录；调用此前 handler |
| 致命信号 | SIGABRT/SEGV/BUS/ILL/FPE/TRAP | crash | sigaction + SA_SIGINFO；从内核上下文取 PC，arm64另取 LR；最多2个地址 |
| 内存警告 | UIApplication.didReceiveMemoryWarning | low_memory | 每小时最多1条；不能当作真实 OOM |
| 脏退出 | 下次启动的旧 session | termination | 同构建、旧 foreground 且无崩溃证据；原因 unknown |
| 主动错误 | capture(error, kind:extras:) | handled / webview_gone | 由宿主显式接线，不自动扫描业务 |
| hang / MetricKit | 尚未实现 | — | 见 TODOS，不宣称已覆盖 |

### 3.1 信号路径

安装阶段缓存最多32个 image 的基址、结束地址和 LC_UUID，打开 `crash.bin` 的0600追加 fd。处理器只访问固定缓冲区与缓存，不扫描 dyld、不走 Swift。

处理器用无锁 atomic_flag 防止多个线程同时覆盖共享帧。从 `ucontext` 取故障 PC（arm64另取 LR），按 `[base,end)` 判断 image，保存 offset + UUID；未知 image 用0xFF哨兵。定长结构仍为 version=1，未变更 wire schema。一次 write 后恢复默认处理：硬件同步 fault 返回原现场再次触发默认处理；用户投递/abort 信号重新 raise。

此前实现的 `backtrace()` 已移除；它不具备异步信号安全性，不能因模拟器曾成功就视为安全。这里明确选择有界故障点，**不是完整调用栈**。不遍历可能损坏的栈，不伪造 thread_id。

依据：[Apple 关于自建崩溃采集的说明](https://developer.apple.com/forums/thread/113742)、[sigaction 手册](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/sigaction.2.html)。

### 3.2 NSException

异常处理器不等 SDK 的互斥锁；取不到现场就省略，不能卡住宿主终止。独立 `exception.json` 原子写成功后才抑制 SIGABRT 重复采集，失败则保留 C 路径兜底。记录完成后调用安装前的 NSException handler，再交还系统流程。Swift/Foundation 异常路径是尽力而为，并不具备 C 信号路径的异步安全保证。

### 3.3 符号与旧构建

原始地址只以 image-relative offset + UUID 保存，不能将旧绝对地址直接拿到新进程解析。

FrameResolver 每进程缓存一次当前 image 表；深度/index有上限，偏移加法检查溢出。仅在 UUID 与地址区间均匹配时调用 dladdr，再用 swift_demangle；匹配不到时保留 UUID/offset，不能用新构建猜一个看似合理的符号。没有源码行号；完整栈以系统报告为准，dSYM/atos 另属后续能力。

恢复沿用上次 session 的 release/build/env/session_id/设备快照及最后界面。旧文件缺少的字段为空/unknown，不能拿本次启动信息冒充崩溃时测量。frame 原始字节摘要作为稳定 event_id。

## 4. 落盘与恢复

目录为 `Application Support/monitor/`，标记 excludedFromBackup：

| 文件 | 用途 |
|---|---|
| crash.bin | C 定长追加帧，启动读取最近 maxCrashRecords（最多20） |
| exception.json | 独立 NSException 记录，携带原始 event_id |
| crash-recovery.json | 在入队前冻结恢复记录及原构建/会话；跨启动失败不换身份 |
| queue.jsonl | 待发记录，一行一个独立事件 |
| session.json / breadcrumbs.json | 上次会话与最多30条面包屑 |
| disabled.json / retry.json | 发送身份范围内的撤权/退避状态 |
| dropped.txt / install-id | 丢弃计数、Keychain不可用时的安装身份兜底 |

队列最多200条/2MB，单条最多256KB。超限保留有界的新记录并累加 dropped；条数和字节必须同时满足。首次读取修复坏行、半行和旧版本超限文件；读失败不覆盖源。追加缓存条目/字节数，不为每次事件重扫全文件；轮转/确认使用原子替换。

不再做本地指纹合并：每次发生保留独立 event_id 和日期，由 cloud 聚合 count。相同 event_id 的恢复源重放不重复增加次数。上传冻结原始行收据，确认只移除匹配记录，不能按“队首前N行”删除。

崩溃恢复先持久化 recovery 快照，再入队并同步队列，最后清 crash 源/recovery；失败留源。server event_id 去重仍只有有限窗口，不能承诺永久幂等。安装信号处理前在普通上下文将可读原始帧原子收缩到最近20条，recovery快照也最多20条；若读写失败则保留源、只作有界读取。一次 write 不保证磁盘满/断电时完整成功。

生命周期与界面同值通知合并，面包屑与 session 更新串行，减少重复落盘。

## 5. 发送与退避

- Uploader 为 actor，另有 await 期间的 busy 闸；门面合并并发 flush 任务。
- 每批最多50条/512KB，以缓存的序列化字节数选择前缀，只编码实际批次。每轮最多3批，仍有记录立即接续。
- 按 cloud §4.5 校验真正的布尔 ok、完整唯一整数 index、逐条状态；仅确认终结项，保留 retryable/未知/畸形回执。部分成功不会整批清空。
- 401/403 保留队列、停采停发，C 信号路径也停止写监控帧。禁用标记绑定 endpoint/app/token 的SHA-256摘要，换构建本身不解除撤权，更换发送身份后恢复。
- 400/413/415/422 仅确认当次发送的拒收记录；未知非成功、408、5xx、网络失败保留。
- 429解析秒数/HTTP日期，持久化最早发送时间；常规 Retry-After 不缩短到一小时。异常超大值有十年上界。
- 其它失败按30s/2m/8m/30m退避，最多6次；新进程可重开预算，但不提前突破尚未到期的服务端等待。
- 进程内 Task.sleep 等待可以取消；后台任务过期会取消网络/等待并只结束一次系统 lease。没有 background URLSession，不承诺系统给予固定后台时间。
- 按任务禁止 HTTP 跳转、不发送 cookie、不使用HTTP认证凭据；TLS仍使用系统默认验证。响应流最多读128KB，超限保留队列。

## 6. 脱敏与身份

消息/栈在落盘前清理短 secret 键（含前缀键、引号和多词值）、Bearer/JWT、URL、私有路径与长hex；消息8KB、栈32KB。主动NSError以domain#code区分错误类型，不能只写统一NSError而依赖会被归一化的消息数字。screen只接受固定代码标识符，不能用“截断书名”替代安全边界。

extras 按最多128节点、4层、每容器16项、共享8KB字符串预算遍历，过滤敏感键与非有限数字；不调用任意对象的 description。最终JSON仍不超过8KB；丢弃计数在正常/截断回退中优先保留。预算在展开前执行，不能先指数展开共享对象再检查体积。脱敏按可识别模式工作，不能理解任意自然语言内容，宿主仍需只传可公开的诊断字段。

install_id 为专用 Keychain 随机UUID的SHA-256，Keychain不可用时读写排除备份的本机文件。Keychain可能跨卸载保留，不能宣称重装一定换ID；不使用IDFA/IDFV或宿主账号。

## 7. 书禾 Apple 接线

Xcode 本地 package 为 `../moo-monitor-ios`。`MonitorBridge` 从构建产物读取 token/版本，最早安装；仅 active/实际 background 转发生命周期，inactive 不冒充 background。关键视图只传固定名称。

导入错误只上传固定区域与错误码，不转发原始 localizedDescription/userInfo；WebKit 进程终止记录 webview_gone，不将普通导航失败误标为进程退出。同步/SQLite新增业务接线仍见 TODOS。

token注入沿用宿主现有脚本；Release不读取Debug运行时覆盖，不改现有版本/构建号。

## 8. 测试与边界

- `swift test`：队列、恢复、逐条回执、并发、退避、脱敏、帧边界及独立原生崩溃子进程。
- `tools/device-qa/generate.py` 生成独立Bundle ID的测试App；`run.py --device ... --host <Mac LAN IP>` 使用本机Laravel与独立SQLite、伪造外呼。必须由用户授权真机测试后才执行；脚本只操作该测试包。
- 宿主真实WK终止/阅读恢复的定向hosted证据与产物见宿主BUILD，设备结论见NOTES/HANDOFF。
- 采不到SDK安装前、SIGKILL、系统watchdog/OOM的直接回调；termination只有unknown推断，上滑强杀也可能先写background而不记。
- 最多32个启动image、2个信号地址，没有完整栈/行号，动态后加载image不在缓存；NSException栈另有独立来源。
- 进程扩展尚未适配UIApplication/后台lease，不支持多个采集库同时接管信号，不做跨进程共写。
- 真机验证不能由Mac子进程或模拟器替代，性能单次样本不能作为p95或实际OOM成功率。
