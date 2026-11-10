# iOS 监控深化复核（2026-11-10）

## 结果与范围

- 本轮修复 SDK、书禾 Apple 接入，补全本机 Laravel 契约回归、模拟器和 iPhone 13 隔离测试。后端没有生产代码变更。
- 监控实现使用 `fix-monitor-ios-reliability`。起点：SDK `ba50228`，Apple `a861303`，cloud `01b50b3`。本记录保留实现与验证证据，提交/合并状态以 Git 引用为准；本轮不含推送或部署。
- SDK 保持 `0.2.0`，书禾保持 `0.1.1(13)`；独立 QA 包为 `com.mooeen.monitor.ios.deviceqa` / `0.2.0(1)`，使用固定测试 token、本机独立 SQLite，未访问生产服务或修改现有书禾 App、书籍、进度。
- SDK 与监控定向验证通过；宿主全量仍有 5 项既有失败，原始源码签名基线可复现，不能宣称全仓全绿。

## 修复内容

1. 验证逐条回执的 index、状态与完整性；HTTP 200、坏 JSON、部分成功不再导致未持久化事件丢失。以原始行收据确认，避免上传期间追加、轮转或坏行引发误删。
2. 不再本地合并不同事件，由服务端聚合；崩溃恢复保留稳定 event_id，重放不重复计数。恢复快照冻结原构建、会话、环境与设备，不用新版本标注旧崩溃。
3. 队列同时限制 200 条 / 2 MB，修复坏行与半行。追加使用缓存计数，批次使用缓存编码长度；actor 内另设 busy 闸，门面合并发送任务，自动接续多批。
4. 401/403 保留证据并停采停发，禁用与退避按 endpoint/app/token 摘要隔离；新 token 可恢复。Retry-After 跨启动保留，后台时间到期会取消请求和等待。
5. 按任务拒绝跳转、禁用 cookie、响应流限制 128 KB；非 TLS 认证挑战以空凭据继续，正确获取 401。真实回环 HTTP 回归覆盖这些行为。
6. 落盘前脱敏短凭据、多词凭据、Bearer/JWT、私有文件名；extras 遍历有共享节点、深度、容器及字节预算，不调用任意对象 description。screen 仅接受代码标识。
7. C 信号处理移除非异步信号安全的 backtrace，仅从 ucontext 读取 PC（arm64 加 LR），最多两个地址；预分配缓冲与 atomic_flag 防并发覆盖。恢复默认终止流程，硬件故障返回原故障点重新触发。
8. 原始崩溃文件启动时有界收缩，坏帧不遮住后续有效帧；入队 fsync 成功后才清源，reset 失败保留恢复日志。UUID/offset 失配保留原始证据，避免 ASLR/升级后错误符号化。
9. NSException 独立原子落盘并调用原 handler，避免重复 SIGABRT；异常时间字段先校验，损坏 session 不推断脏退出。termination 使用 warning 与原会话信息。
10. 宿主只在真正 background 时通知监控；固定区域、单调时钟限流、CustomNSError 保留原码而不带私密描述；WebKit 内容进程退出单独记录 webview_gone。

当前设计见 [design](docs/design.md)，上报契约仍以 [cloud 文档](../moo-scaffold-cloud/docs/app-monitor.md)为准。

## 自动检查

| 范围 | 实际结果 | 证据 |
|---|---|---|
| SDK Debug 全量 | 63 项通过 | `/tmp/moo-monitor-ios-release-review-debug.log` |
| SDK Release 全量 | 63 项通过 | `/tmp/moo-monitor-ios-release-review-release.log` |
| 最后加长符号名脱敏回归 | Redactor 7 项通过 | `/tmp/moo-monitor-ios-final-redactor.log` |
| C 严格编译与静态分析 | 通过 | `clang -Wall -Wextra -Werror -fsyntax-only`；`/tmp/moo-monitor-ios-c-analysis.plist` |
| cloud 定向集成 | 34 项 / 214 断言通过；修改测试文件 Pint 通过 | `/tmp/moo-monitor-ios-cloud-contract.log` |
| 书禾 Core 全量 | 总计 421 项，跳过 8 项，0 失败 | `/tmp/shuhe-apple-core-full.log` |
| 书禾签名 hosted 全量 | 177 项：172 通过，5 失败 | `../shuhe-apple/build/monitor-review/FullHostedSigned.xcresult` |
| 原始源码签名基线 | 同样复现这 5 项失败 | `../shuhe-apple/build/monitor-baseline/BaselineFailures.xcresult` |

SDK 包含独立 C 子进程 segv/trap/abort、禁用/reset、坏帧、恢复写失败、并发发送、回执/容量/脱敏边界与真实 URLSession HTTP 策略测试。子进程结果不能替代 iOS 系统报告。

hosted 中真实 WebContent 退出与阅读恢复、监控 NSError 桥接均通过。既有测试夹具 `SyncExperienceIntegrationTests` 仅移除已废弃 leave 参数并补 highlights，修复编译漂移；未修改同步业务。

以下既有失败保留原断言，另列入宿主 TODOS：

- `SyncParityTests/testDavBatchHandlerUsesCapturedReviewsAfterListChanges`
- `SyncParityTests/testDavPartialReportStaysPartialAfterSuccessfulReaderBridge`
- `SyncParityTests/testReaderMetadataAdoptLabelAndHandlerUpdateLocalBook`
- `SyncParityTests/testReaderPreserveLabelAndHandlerKeepLocalContent`
- `SyncParityTests/testUnavailableBooksViewRendersRestoreAndDeleteAtLargeType`

其中 4 项 AX 按钮发现为空，1 项 DAV pending 投影为零。基线由两仓原 HEAD 导出，仅修复上述夹具编译参数，运行时源码与原 HEAD 一致。初次未签名 hosted 另有 Keychain -34018，使用模拟器 ad-hoc 签名后恢复，未放宽断言。

## iPhone 13 与模拟器

- 最新模拟器：`build/simulator-qa-e639cfp9/`，9 场景全部通过，189 次事件入库；日志 `/tmp/moo-monitor-ios-comprehensive-simulator.log`。
- iPhone 13 / iOS 26.6.2：`build/iphone-qa-w05mx4jd/`，9 场景全部通过，189 次事件入库；`results.json`、`summary.json`、`requests.jsonl` 保存断言与请求。
- 场景：采集脱敏与入库；180 条按 50/50/50/30 自动续发；部分回执只补失败项；429 延迟（真机实测 3.153 秒）；503 跨 3 次启动保持同 event_id 后补传；401 保留、新 token 恢复；fatalError、强制解包 nil、NSException 崩溃后恢复与系统报告。
- 真机复用现有通配开发 profile 与签名身份，没有注册设备或新建证书。QA 包安装、运行成功，完成后已卸载；独立 PHP 监听已停止。本轮专用模拟器已关闭并删除，未动其他模拟器。

三份真机系统报告已下载到 `build/iphone-qa-w05mx4jd/reports/`，核对摘要为 `system-report-summary.json`：

| 报告 | 信号 / 类型 | 故障线程帧数 | Last Exception Backtrace |
|---|---|---:|---:|
| `MonitorQa-2026-11-10-142428.ips` | SIGTRAP / EXC_BREAKPOINT | 21 | 0 |
| `MonitorQa-2026-11-10-142437.ips` | SIGTRAP / EXC_BREAKPOINT | 20 | 0 |
| `MonitorQa-2026-11-10-142446.ips` | SIGABRT / EXC_CRASH | 31 | 23 |

三份均匹配 QA Bundle ID、`0.2.0(1)` 和本机二进制 UUID `f2002ba6-7475-3d6f-982d-71a05fb49ec8`。SDK 信号记录只提供 2 个 PC/LR 地址，系统完整调用栈仍生成；不将二者混为 SDK 完整栈能力。

最初真机因锁屏、随后因 QA 夹具缺少 scene 配置/过早从非 active 状态请求本地网络而失败；修正夹具前台入口后通过。参见 [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。未修改系统安全策略。重跑方法见 [QA 工具说明](tools/device-qa/README.md)。

## 性能与构建产物

- 同一 Mac、Debug、1000 个不同事件 / 512 字节 payload，原 HEAD 与当前各串行采样 3 次：旧中位数 **4901.251 ms**，新中位数 **85.133 ms**。原始值见 `build/monitor-performance-final.json`，日志 `/tmp/moo-monitor-perf-final-{before,after}-{1,2,3}.log`。只代表合成队列追加，不代表 iPhone、启动 p95 或整体性能。
- 独立书禾 Debug arm64、Release x86_64/arm64 均构建并严格验签；版本不变，最终产物没有测试插件，Release 不含 Debug 崩溃钩子。路径、大小、SHA-256 与签名见 [BUILD](../shuhe-apple/docs/BUILD.md) 和 `../shuhe-apple/build/monitor-review/artifacts-final.json`。
- QA 真机包 `build/device-qa/DerivedData/Build/Products/Debug-iphoneos/MonitorQa.app`：arm64 / iphoneos / Apple Development；目录 853905 字节，主文件 838176 字节，SHA-256 `313b0cbcb4655e2620365a436beb39c3f7292d3650a4325fbe65fb99c74ac3e1`，严格验签、安装与报告 UUID 匹配通过；元数据见真机证据目录 `artifact.json`。
- 构建中开发卷满导致一次 lipo errno28；仅清理本轮新建失败产物、基线 DerivedData 与任务编译缓存后重建成功。保留源码、日志、xcresult 和最终产品。基线产物核验后清理的事实标在 artifacts-final.json；不作为可分发产物。

## 后续修订：共享客户端 token

- 用户确认反馈与监控可共用 token。本机实际文件 `/Volumes/dev/build_tokens` 已有各平台共享标签，旧独立标签已移除；两端构建接线已同步，SDK 和后端运行代码无需改变。
- Apple 注入同一值到 `ShuheFeedbackToken` / `MOOMonitorToken`；Android Release 注入同一值到 `FEEDBACK_TOKEN` / `MOO_MONITOR_TOKEN`。Android Debug 默认留空，显式隔离覆盖保留。
- Apple 实际构建阶段命令的 5 种 plist 注入情况通过；Android 实际 Gradle BuildConfig 的 4 种情况通过；cloud 既有共享能力测试 1 项 / 8 断言通过。未发送生产请求，未重新出包或安装，前述 App/QA 产物没有更改。
- Android 本次从 `b3147f4` 新建同名任务分支，Apple/SDK/cloud 延续已有任务分支；本地合并交付状态以 Git 引用为准，未执行推送。两端来源、优先级与证据见各自 BUILD。

## 剩余边界

未验证实际 OOM、watchdog、物理断网、长期后台、上滑强杀与 iPad 实体；503 不等于真实断网。当前未提供 MetricKit、hang、dSYM 行号、扩展多进程或其他崩溃采集器共存能力。SDK 只缓存启动时最多 32 个 image，信号栈仅 PC/LR；后续事项见 [TODOS](TODOS.md)。
