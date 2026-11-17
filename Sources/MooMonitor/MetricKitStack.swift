import Foundation
#if os(iOS) && canImport(MetricKit)
import MetricKit
#endif

/// 把 MetricKit 的 callStackTree 解析成紧凑帧（image_uuid + offset）。
/// 只保留 attributed 线程、深度/数量受限，体积远小于原始 JSON，
/// 不会触发 Redactor 的 2KB/8KB 截断；服务端可按 dSYM 对这组帧符号化。
enum MetricKitStackDecoder {
    static func frames(fromJSON data: Data, limit: Int = 64, appUUID: String? = nil) -> [[String: Any]] {
        guard limit > 0,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let stacks = (root["callStacks"] as? [[String: Any]]) ?? []
        let chosen = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first
        guard let stack = chosen, let roots = stack["callStackRootFrames"] as? [[String: Any]] else { return [] }
        var out: [[String: Any]] = []
        out.reserveCapacity(limit)
        func walk(_ nodes: [[String: Any]]) {
            for node in nodes {
                if out.count >= limit { return }
                if let uuid = node["binaryUUID"] as? String,
                   let offset = node["offsetIntoBinaryTextSegment"] as? Int {
                    let hex = uuid.replacingOccurrences(of: "-", with: "").lowercased()
                    var entry: [String: Any] = ["image_uuid": hex, "offset": offset]
                    if let appUUID { entry["app"] = (hex == appUUID) }
                    out.append(entry)
                }
                if let sub = node["subFrames"] as? [[String: Any]] { walk(sub) }
            }
        }
        walk(roots)
        return out
    }
}

#if os(iOS) && canImport(MetricKit)
extension MetricKitStackDecoder {
    static func frames(from tree: MXCallStackTree, limit: Int = 64, appUUID: String? = nil) -> [[String: Any]] {
        frames(fromJSON: tree.jsonRepresentation(), limit: limit, appUUID: appUUID)
    }
}
#endif
