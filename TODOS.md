# TODOS

## 建仓

- [x] 目录、README、AGENTS、NOTES、设计文档（2026-11-09）
- [x] 双远端（gitee 主、GitHub 镜像）与首个提交
- [x] `Package.swift` 骨架：`MooMonitorCrash`（C）+ `MooMonitor`（Swift）

## M1（已接入书禾 Apple）

- [x] `MooMonitorCrash`：定长帧、`moo_crash_install`、`moo_crash_handle`、一次 `write` + `raise`
- [x] 信号处理器缓存 image UUID / 基址 / 结束地址；UUID 单独缓存，避免被 `memset` 清掉
- [x] `CrashReporter`：`NSSetUncaughtExceptionHandler`；NSException 后跳过重复 SIGABRT
- [x] `FrameResolver`：下次启动按 `LC_UUID` 找回基址 + `dladdr` + `swift_demangle`，`app` 按主程序 UUID
- [x] `SessionMarker`：`starting/foreground/background`、界面名、`termination` 推断（同构建）
- [x] `EventStore`：JSONL 队列、200 条 / 2MB 轮转、`dropped` 持久化、同指纹合并
- [x] `Uploader`：50 条 / 512KB 分批、401/403 清队列并禁用、429 `Retry-After`、6 次退避
- [x] 触发点：启动 10s、退后台（`beginBackgroundTask`）、手动 `flush()`
- [x] `low_memory`（1 小时 1 条）、`capture()`、screen、跨启动持久化 breadcrumbs
- [x] `Redactor`、`DeviceInfo`（机型 / ABI / 系统版本）
- [x] 单测：EventStore / Redactor / Uploader / SessionMarker（23 条）
- [x] 书禾 Apple 接入：本地 package、门面调用、生命周期与界面名、token 注入
- [x] 模拟器闭环：`fatalError` → 下次启动还原帧；NSException 只产一条；mock intake 200 清队列
- [ ] 真机：`fatalError`、强制解包 nil、上滑强杀三条闭环
- [ ] 真机：确认系统崩溃报告仍生成（红线，不通过不算完成）
- [x] cloud 侧 M1 代码已落地；生产 `/api/v1/app-errors/intake` 无 token 返回 401，有效 token 写入与后台列表待验

## M2

- [ ] MetricKit 订阅与本地记录去重
- [x] `applicationDidReceiveMemoryWarning` → `low_memory`
- [ ] `capture()` 其余宿主接线：同步失败、SQLite 错误（导入失败已接）

## M3

- [ ] hang watchdog（只记时长与最后界面）
- [ ] dSYM 上传
- [ ] `Tools/SymbolicateApp`：`atos` 补行号后回写 `src_frames`
