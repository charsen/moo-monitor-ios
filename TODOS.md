# TODOS

## 建仓

- [x] 目录、README、AGENTS、NOTES、设计文档（2026-11-09）
- [ ] 建远端仓库（gitee `charsen/moo-monitor-ios`，与其它 monitor 仓一致）并推送首个提交
- [x] `Package.swift` 骨架：`MooMonitorCrash`（C）+ `MooMonitor`（Swift），`swift test` 12 条通过

## M1（未开工）

- [x] `MooMonitorCrash`：定长帧结构、`moo_crash_install`、`moo_crash_handle`、一次 `write` + `raise`
- [x] `CrashReporter`：安装 6 个信号 + `NSSetUncaughtExceptionHandler`
- [x] `FrameResolver`：下次启动 `dladdr` + `swift_demangle`，`app` 标记按 `LC_UUID`
- [ ] `SessionMarker`：`starting/foreground/background` 三态与 `termination` 推断
- [x] `EventStore`：JSONL 队列、200 条 / 2MB 轮转、`dropped`
- [x] `Uploader` + 触发点（启动 10s、退后台、手动）
- [x] `Redactor`、`DeviceInfo`、`Breadcrumbs`
- [x] 单测：EventStore / Redactor / Uploader（12 条）
- [ ] 真机：`fatalError`、强制解包 nil、上滑强杀三条闭环
- [ ] 真机：确认系统崩溃报告仍生成（红线，不通过不算完成）
- [ ] 依赖 cloud 侧 M1（`moo-scaffold-cloud/docs/app-monitor.md` §11）先落地

## M2

- [ ] MetricKit 订阅与本地记录去重
- [ ] `applicationDidReceiveMemoryWarning` → `low_memory`
- [ ] `capture()` 在宿主三处接线：导入失败、同步失败、SQLite 错误

## M3

- [ ] hang watchdog（只记时长与最后界面）
- [ ] dSYM 上传
- [ ] `Tools/SymbolicateApp`：`atos` 补行号后回写 `src_frames`
