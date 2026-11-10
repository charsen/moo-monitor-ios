import Darwin
import Foundation
import MachO
import MooMonitorCrash

@_silgen_name("swift_demangle")
private func _swift_demangle(
    _ mangledName: UnsafePointer<CChar>?,
    _ mangledNameLength: Int,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<Int>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?

/// 把崩溃帧里的「image UUID + 偏移」还原成函数名。
///
/// 关键点：崩溃时存的是**偏移**不是绝对地址。iOS 每次启动都做 ASLR，
/// 旧绝对地址在新进程里指向随机内存，直接 dladdr 会给出一个看起来很像真的
/// 错误函数名——比没有符号更糟。所以这里先按 UUID 找回当前基址再加偏移。
///
/// 仍然没有行号：行号在 dSYM 里，设备上不解析 DWARF。要行号走 Mac 侧 atos。
enum FrameResolver {

    static func resolve(_ frame: moo_crash_frame) -> [[String: Any]] {
        let depth = min(Int(frame.depth), Int(MOO_CRASH_MAX_DEPTH))
        guard depth > 0, frame.image_count <= MOO_CRASH_MAX_IMAGES else { return [] }
        let offsets = withUnsafeBytes(of: frame.offsets) { Array($0.bindMemory(to: UInt64.self)) }
        let indexes = withUnsafeBytes(of: frame.image_index) { Array($0.bindMemory(to: UInt8.self)) }
        let mainUUID = currentMainExecutableUUID()
        var out: [[String: Any]] = []
        out.reserveCapacity(depth)
        for i in 0..<depth {
            let index = Int(indexes[i])
            guard index < Int(frame.image_count), index < Int(MOO_CRASH_MAX_IMAGES) else { continue }
            let uuid = uuidBytes(frame, index)
            guard uuid.count == 16, uuid.contains(where: { $0 != 0 }) else { continue }
            let hex = uuid.map { String(format: "%02x", $0) }.joined()
            // 版本更换或地址畸形时保留原始 UUID/offset；不能丢掉证据或解析成别的 image。
            var entry: [String: Any] = [
                "function": "\(hex)+0x\(String(offsets[i], radix: 16))",
                "image_uuid": hex, "offset": String(offsets[i]), "app": uuid == mainUUID,
            ]
            if let image = images.first(where: { $0.uuid == uuid }), offsets[i] <= UInt64(UInt.max - image.base) {
                let address = image.base + UInt(offsets[i])
                var info = Dl_info()
                if address < image.end, dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
                   let found = info.dli_fbase, UInt(bitPattern: found) == image.base {
                    if let raw = info.dli_sname {
                        let name = String(cString: raw)
                        entry["function"] = demangle(name) ?? name
                    }
                    if let name = info.dli_fname { entry["image"] = (String(cString: name) as NSString).lastPathComponent }
                }
            }
            out.append(entry)
        }
        return out
    }

    private struct Image { let uuid: [UInt8]; let base: UInt; let end: UInt }
    // 每个进程取一次表，不能为每个帧重复扫描所有 image 并解析 LC_UUID。
    private static let images: [Image] = (0..<_dyld_image_count()).compactMap { index in
        guard let header = _dyld_get_image_header(index) else { return nil }
        let base = UInt(bitPattern: header)
        var end = base
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == LC_SEGMENT_64 {
                let segment = cursor.assumingMemoryBound(to: segment_command_64.self).pointee
                let address = UInt(truncatingIfNeeded: segment.vmaddr &+ segment.vmsize) &+ UInt(bitPattern: _dyld_get_image_vmaddr_slide(index))
                if address > end { end = address }
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return Image(uuid: imageUUID(header), base: base, end: end)
    }

    /// C 里的 `uint8_t image_uuids[16][16]` 在 Swift 里是一串定长元组，
    /// 直接按下标取会很难写；按字节铺平后切第 index 段更稳。
    private static func uuidBytes(_ frame: moo_crash_frame, _ index: Int) -> [UInt8] {
        withUnsafeBytes(of: frame.image_uuids) { raw -> [UInt8] in
            let bytes = Array(raw)
            let start = index * 16
            guard start + 16 <= bytes.count else { return [] }
            return Array(bytes[start..<(start + 16)])
        }
    }

    private static func currentMainExecutableUUID() -> [UInt8] {
        guard let header = _dyld_get_image_header(0) else { return [] }
        return imageUUID(header)
    }

    private static func imageUUID(_ header: UnsafePointer<mach_header>) -> [UInt8] {
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let cmd = cursor.assumingMemoryBound(to: load_command.self)
            if cmd.pointee.cmd == LC_UUID {
                let uuid = cursor.assumingMemoryBound(to: uuid_command.self)
                return withUnsafeBytes(of: uuid.pointee.uuid) { Array($0) }
            }
            cursor = cursor.advanced(by: Int(cmd.pointee.cmdsize))
        }
        return []
    }

    private static func demangle(_ symbol: String) -> String? {
        guard symbol.hasPrefix("_$s") || symbol.hasPrefix("$s") else { return nil }
        return symbol.withCString { cstr in
            guard let demangled = _swift_demangle(cstr, strlen(cstr), nil, nil, 0) else { return nil }
            defer { free(demangled) }
            return String(cString: demangled)
        }
    }
}
