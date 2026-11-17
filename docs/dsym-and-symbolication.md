# dSYM 上传与符号化契约

目标：把崩溃帧从 image_uuid+offset 还原成函数/行号。客户端已具备：
- 信号崩溃帧（PC/LR，最多 2 帧，image_uuid+offset）；
- MetricKit crash/hang 帧解析为紧凑帧（最多 32，image_uuid+offset），不再发送 32KB 原始 JSON（避免 Redactor 2KB/8KB 截断）。

## 上传（云端 M2，直传三步）
  MONITOR_TOKEN=... RELEASE=0.1.1 BUILD=27 ./scripts/upload-dsyms.sh /path/ShuheApple.xcarchive

脚本把 dSYMs 打包成 zip，自动算 size/sha256 与每个 dSYM 的 LC_UUID，然后走三步（cloud 只签票据，文件本体客户端直达七牛）：

1. `POST <endpoint>/api/v1/uploads/tickets`（Header `Authorization: Bearer <token>`，能力 app_errors 或 app_symbols）
   - JSON: `{business:"app_symbols", platform:"ios", release, build, kind:"dsym", original_name, file_size, sha256, uuids:[...]}`
   - 返回: `{ok, upload_id, key, region, token, expires_at}`
2. 直传七牛（不经 cloud）：`POST https://upload.qiniup.com`（z0）或 `https://upload-z1|z2|na0|as0.qiniup.com`
   - multipart: `token=<上传 token>, key=<key>, file=@<dSYM.zip>`
   - 上传成功返回 `{key, hash}`
3. `POST <endpoint>/api/v1/uploads/{upload_id}/confirm`（Header `Authorization: Bearer <token>`）
   - JSON: `{uuids:[...]}`（iOS dSYM 必填）；返回 `ok=true` 即完成。

- 云端只签票据、登记并核验对象大小/SHA-256（project+platform+release+build+kind 覆盖式 upsert），不接收文件字节。
- region → 上传域名：z0→upload.qiniup.com；z1/z2/na0/as0→upload-<region>.qiniup.com。
- 查询是否已有某 release 符号: `POST <endpoint>/api/v1/app-errors/symbols/check`（只读，能力 app_errors，返回 exists/uuid/uuids/sha256）。

## 符号化（Mac 侧，非服务端）
- 云端明确不做服务端 iOS 符号化（生产 Linux 无 atos/dSYM 工具链），dSYM 仅存档。
- Mac 上用 dSYM 本地还原：./scripts/symbolicate.sh <xcarchive> <uuid> <offset> arm64（单帧）。
- 批量：./tools/SymbolicateApp/symbolicate-app.sh <issue.json> <xcarchive|dSYMs> [--pretty]，逐帧输出 JSON 数组（保留 image_uuid/offset，新增 symbol/file/line，未匹配标 unsymbolicated）。
- 地址 = __TEXT vmaddr(0x100000000) + offsetIntoBinaryTextSegment；支持信号帧与 MetricKit frames。

## 已知语义/服务端需处理
- 同一崩溃可能同时产生信号崩溃(SIGTRAP…)与 metrickit_crash 两条事件：服务端应按 app+build+session+时间窗合并，避免双报。
- metrickit_app_exit 的各计数是 MXAppExitMetric 的周期累计值：展示/告警必须标"累计"，不要把计数当单次事件次数；如需单周期增量，按 MetricKit 投递周期做差分。
