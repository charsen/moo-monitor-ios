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
public enum FrameResolver {

    public static func resolve(_ frame: moo_crash_frame) -> [[String: Any]] {
        let depth = Int(frame.depth)
        guard depth > 0 else { return [] }

        // C 里的定长数组在 Swift 里是元组，不能下标；按字节铺平后再按类型读。
        let offsets = withUnsafeBytes(of: frame.offsets) { Array($0.bindMemory(to: UInt64.self)) }
        let indexes = withUnsafeBytes(of: frame.image_index) { Array($0.bindMemory(to: UInt8.self)) }

        let mainUUID = currentMainExecutableUUID()
        var out: [[String: Any]] = []
        out.reserveCapacity(depth)

        for i in 0..<depth {
            guard i < offsets.count, i < indexes.count else { break }
            let index = Int(indexes[i])
            let uuid = uuidBytes(frame, index)
            guard let base = currentBase(forUUID: uuid) else { continue }
            let address = base + UInt(offsets[i])

            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { continue }

            let raw = info.dli_sname.map { String(cString: $0) } ?? "<unknown>"
            var entry: [String: Any] = [
                "function": demangle(raw) ?? raw,
                "offset": Int(offsets[i]),
                // 不能假设 dyld image 0 永远是主可执行文件；用 LC_UUID 对主程序判定。
                "app": !uuid.isEmpty && uuid == mainUUID,
            ]
            if let fname = info.dli_fname {
                entry["image"] = (String(cString: fname) as NSString).lastPathComponent
            }
            out.append(entry)
        }

        return out
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

    private static func currentBase(forUUID uuid: [UInt8]) -> UInt? {
        guard uuid.count == 16 else { return nil }
        for i in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(i) else { continue }
            if imageUUID(header) == uuid {
                return UInt(bitPattern: header)
            }
        }
        return nil
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
