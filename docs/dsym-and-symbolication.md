# dSYM 上传与符号化契约（草案）

目标：把崩溃帧从 image_uuid+offset 还原成函数/行号。客户端已具备：
- 信号崩溃帧（PC/LR，最多 2 帧，image_uuid+offset）；
- MetricKit crash/hang 帧解析为紧凑帧（最多 32，image_uuid+offset），不再发送 32KB 原始 JSON（避免 Redactor 2KB/8KB 截断）；
- 服务端可对两类帧用同一套 dSYM 符号化。

## 上传（云端 M2，已实现）
  MONITOR_TOKEN=... RELEASE=0.1.1 BUILD=27 ./scripts/upload-dsyms.sh /path/ShuheApple.xcarchive

POST <endpoint>/api/v1/app-errors/symbols   （能力 app_symbols，CI 私密 token）
- Header: Authorization: Bearer <app_symbols token>（也支持 body token）
- multipart: platform=ios, release, build, kind=dsym, sha256, uuids(逗号分隔), files[]=@dSYM.zip
- 云端只存档到私有盘并登记 app_error_symbols（project+platform+release+build+kind 覆盖式 upsert）。
- 查询: POST <endpoint>/api/v1/app-errors/symbols/check（能力 app_errors，返回 exists/uuid/uuids/sha256）。

## 符号化（Mac 侧，非服务端）
- 云端明确不做服务端 iOS 符号化（生产 Linux 无 atos/dSYM 工具链），dSYM 仅存档。
- Mac 上用 dSYM 本地还原：./scripts/symbolicate.sh <xcarchive> <uuid> <offset> arm64。
- 地址 = __TEXT vmaddr(0x100000000) + offsetIntoBinaryTextSegment；支持信号帧与 MetricKit frames。

## 本地即时定位
  ./scripts/symbolicate.sh /path/ShuheApple.xcarchive <uuid> <offset> arm64

## 状态
客户端解析与脚本已实现；服务端 intake/符号化端点待实现（当前上传会 404）。

## 已知语义/服务端需处理
- 同一崩溃可能同时产生信号崩溃(SIGTRAP…)与 metrickit_crash 两条事件：服务端应按 app+build+session+时间窗合并，避免双报。
- metrickit_app_exit 的各计数是 MXAppExitMetric 的周期累计值：展示/告警必须标"累计"，不要把计数当单次事件次数；如需单周期增量，按 MetricKit 投递周期做差分。
