import CryptoKit
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 设备与环境快照。取不到的项就是缺字段，绝不让采集本身抛错。
public enum DeviceInfo {

    public static func device() -> [String: Any] {
        var out: [String: Any] = [
            "os": "iOS",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
                .replacingOccurrences(of: "Version ", with: "")
                .replacingOccurrences(of: " (Build ", with: " (")
                .components(separatedBy: " (").first ?? "",
        ]
        #if canImport(UIKit)
        let device = UIDevice.current
        // 展示用机型号（iPhone16,1），不是 "iPhone" 这种泛化名。
        // 模拟器的 uname 是 arm64/x86_64，退回 UIDevice.model，避免把架构当机型。
        let machine = machineIdentifier()
        out["model"] = (machine == "arm64" || machine == "x86_64" || machine == "i386") ? device.model : (machine ?? device.model)
        out["device_model"] = device.model
        out["manufacturer"] = "Apple"
        out["abi"] = architecture
        #endif
        return out
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func machineIdentifier() -> String? {
        var system = utsname()
        guard uname(&system) == 0 else { return nil }
        return withUnsafeBytes(of: system.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(bytes: bytes, encoding: .utf8)
        }
    }

    public static func context(installId: String, sessionId: String, screen: String?) -> [String: Any] {
        var out: [String: Any] = [
            "install_id": installId,
            "session_id": sessionId,
        ]
        if let screen { out["screen"] = screen }
        #if canImport(UIKit)
        out["foreground"] = UIApplication.shared.applicationState == .active
        #endif
        if let free = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber {
            out["storage_free"] = free.intValue
        }
        return out
    }

    /// 随机 UUID 的 SHA-256，存 Keychain；卸载重装会换。不复用同步凭据的 key。
    ///
    /// Keychain 在首次解锁前/无签名模拟器上可能不可用，这时退回沙盒文件，
    /// 避免每次启动都换一个 install_id，把唯一安装数算虚。
    public static func installId(fallbackDirectory: URL? = nil) -> String {
        let account = "moo-monitor-install"
        let service = "com.mooeen.monitor"
        let fallbackURL = fallbackDirectory?.appendingPathComponent("install-id")

        if let existing = Keychain.read(service: service, account: account) {
            return hash(existing)
        }
        if let fallbackURL, let data = try? Data(contentsOf: fallbackURL),
           let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            Keychain.write(existing, service: service, account: account)
            return hash(existing)
        }

        let raw = UUID().uuidString
        Keychain.write(raw, service: service, account: account)
        if let fallbackURL {
            try? Data(raw.utf8).write(to: fallbackURL, options: [.atomic])
        }
        return hash(raw)
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
