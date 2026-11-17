# TODOS

- [ ] 在获准目标设备场景复核操作轨迹、重入保护及进程重启后的Retry-After等待、后台机会与开销；当前仅包内、适配器和类型检查，没有安装或触发实体故障。

## 真机与运行边界

- [ ] iPad实体信号与系统报告复验；Mac子进程/模拟器不能替代。
- [ ] 实际OOM、watchdog、长期休眠、后台窗口到期与物理断网；不以手动内存警告或503替代。
- [ ] 用户上滑强杀的实际生命周期观察：可能先写background，不保证产生termination；只能unknown推断。
- [ ] 真机首解锁前Keychain失败后的install_id稳定性，以及下次启动UUID解析/符号还原耗时。
- [ ] 持续磁盘写失败/无有效帧超限源的实体故障注入；正常启动已原子收缩最近20帧，读写失败路径保留源并有界读取。

## 后续能力

- [x] MetricKit 订阅（crash/hang/app_exit）；栈已解析为紧凑帧并做 OOM/watchdog 归因。仍需真机验证系统投递与本地记录去重。
- [ ] capture的同步/SQLite接线：先限定可公开错误类别，不直接上传localizedDescription或业务数据。
- [ ] hang watchdog，明确调试器/休眠边界。
- [ ] dSYM 上传与服务端符号化（脚本 scripts/upload-dsyms.sh + 契约 docs/dsym-and-symbolication.md 已加；待服务端 intake）。本地即时定位用 scripts/symbolicate.sh。
- [ ] App Extension适配、后加载image与其他崩溃采集器共存策略；当前不支持多进程共写/混装信号处理器。
