# dSYM 上传与符号化契约（草案）

目标：把崩溃帧从 image_uuid+offset 还原成函数/行号。客户端已具备：
- 信号崩溃帧（PC/LR，最多 2 帧，image_uuid+offset）；
- MetricKit crash/hang 帧解析为紧凑帧（最多 32，image_uuid+offset），不再发送 32KB 原始 JSON（避免 Redactor 2KB/8KB 截断）；
- 服务端可对两类帧用同一套 dSYM 符号化。

## 上传
  MONITOR_TOKEN=... RELEASE=0.1.1 BUILD=27 APP=shuhe ./scripts/upload-dsyms.sh /path/ShuheApple.xcarchive

<<<<<<< Updated upstream
POST <endpoint>/api/v1/app-dsyms/intake
- Header: Authorization: Bearer <客户端token>
- multipart: app, release, build, sha256(整包), uuids(逗号分隔), archive(zip 内含 dSYMs/*.dSYM)
- 幂等键建议: app+release+build+sha256
=======
POST <endpoint>/api/v1/app-errors/symbols   （能力 app_errors 或 app_symbols；业务要求原 app_errors token 可用）
- Header: Authorization: Bearer <token>（也支持 body token）
- multipart: platform=ios, release, build, kind=dsym, sha256, uuids(逗号分隔), files[]=@dSYM.zip
- 云端只存档到私有盘并登记 app_error_symbols（project+platform+release+build+kind 覆盖式 upsert）。
- 查询: POST <endpoint>/api/v1/app-errors/symbols/check（能力 app_errors，返回 exists/uuid/uuids/sha256）。
>>>>>>> Stashed changes

## 服务端符号化
- 按 frame.image_uuid 匹配已上传 dSYM；
- 地址 = __TEXT vmaddr(0x100000000) + offsetIntoBinaryTextSegment；
- atos 解析函数名与行号；未匹配保留 uuid+offset 并标记 unsymbolicated；
- 同时支持信号帧与 MetricKit frames: [{image_uuid, offset, app}]。

## 本地即时定位
  ./scripts/symbolicate.sh /path/ShuheApple.xcarchive <uuid> <offset> arm64

## 状态
客户端解析与脚本已实现；服务端 intake/符号化端点待实现（当前上传会 404）。

## 已知语义/服务端需处理
- 同一崩溃可能同时产生信号崩溃(SIGTRAP…)与 metrickit_crash 两条事件：服务端应按 app+build+session+时间窗合并，避免双报。
- metrickit_app_exit 的各计数是 MXAppExitMetric 的周期累计值：展示/告警必须标"累计"，不要把计数当单次事件次数；如需单周期增量，按 MetricKit 投递周期做差分。
