# 隔离设备测试

生成独立 `com.mooeen.monitor.ios.deviceqa` 应用，以本机 Laravel 和临时 SQLite 检查采集、回执、重试、跨启动保留与真实崩溃。仅使用固定测试 token，不读取生产凭据；不启动或覆盖书禾 App。

从 SDK 根目录生成与构建（沿用 QA `0.2.0(1)`）：

```bash
python3 tools/device-qa/generate.py
xcodebuild -project build/device-qa/MonitorQa.xcodeproj -scheme MonitorQa \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/device-qa/DerivedData CODE_SIGNING_ALLOWED=NO build
python3 tools/device-qa/run.py --device <UDID> --host <Mac局域网地址>
```

真机需保持解锁，允许 Monitor QA 的本地网络提示。脚本使用现有 `shuhe-apple/signing/profiles/ios-team-wildcard.mobileprovision`，先检查目标设备在 profile 中，再签名；其他本机身份可传 `--profile` / `--identity`，不注册证书或设备。后端默认同级 `moo-scaffold-cloud`，需已安装其 Composer 依赖；可传 `--cloud`。

模拟器改用 `-sdk iphonesimulator -destination 'generic/platform=iOS Simulator'` 构建，再运行 `run.py --simulator --device <专用模拟器UDID> --host 127.0.0.1`。模拟器必须已启动，不把其结果计为实体设备通过。

夹具使用 SwiftUI scene，并等 UIApplication.active 才启动请求，避免首次本地网络授权在后台被系统拒绝。它会保持屏幕常亮并控制 SDK 的测试生命周期，不依赖强制重启推断脏退出。

脚本输出 `EVIDENCE` 目录，保存请求、逐场景结果、SQLite 与产物签名/哈希；失败时保存安全诊断。finally 停止本次 PHP 服务并卸载 QA 包。崩溃场景会造成测试包真实退出；系统报告列表必须增加，随后应从 systemCrashLogs 下载新增 `.ips` 并核对 Bundle ID、版本、UUID 与线程栈，不能只凭报告数量认定采集红线通过。

9 个场景及最近实测证据见 [HANDOFF](../../HANDOFF.md)。503 只模拟服务不可用，不等同于物理断网；测试不覆盖实际 OOM、watchdog 或系统长期后台调度。
