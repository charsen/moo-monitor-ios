# dSYM 上传与符号化契约（草案）

目标：把崩溃帧从 image_uuid+offset 还原成函数/行号。客户端已具备：
- 信号崩溃帧（PC/LR，最多 2 帧，image_uuid+offset）；
- MetricKit crash/hang 帧解析为紧凑帧（最多 64，image_uuid+offset），不再发送 32KB 原始 JSON（避免 Redactor 2KB/8KB 截断）；
- 服务端可对两类帧用同一套 dSYM 符号化。

## 上传
  MONITOR_TOKEN=... RELEASE=0.1.1 BUILD=27 APP=shuhe ./scripts/upload-dsyms.sh /path/ShuheApple.xcarchive

POST <endpoint>/api/v1/app-dsyms/intake
- Header: Authorization: Bearer <客户端token>
- multipart: app, release, build, sha256(整包), uuids(逗号分隔), archive(zip 内含 dSYMs/*.dSYM)
- 幂等键建议: app+release+build+sha256

## 服务端符号化
- 按 frame.image_uuid 匹配已上传 dSYM；
- 地址 = __TEXT vmaddr(0x100000000) + offsetIntoBinaryTextSegment；
- atos 解析函数名与行号；未匹配保留 uuid+offset 并标记 unsymbolicated；
- 同时支持信号帧与 MetricKit frames: [{image_uuid, offset, app}]。

## 本地即时定位
  ./scripts/symbolicate.sh /path/ShuheApple.xcarchive <uuid> <offset> arm64

## 状态
客户端解析与脚本已实现；服务端 intake/符号化端点待实现（当前上传会 404）。
