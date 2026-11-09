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
        out["model"] = device.model
        out["manufacturer"] = "Apple"
        #endif
        return out
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
    public static func installId() -> String {
        let account = "moo-monitor-install"
        let service = "com.mooeen.monitor"
        if let existing = Keychain.read(service: service, account: account) {
            return hash(existing)
        }
        let raw = UUID().uuidString
        Keychain.write(raw, service: service, account: account)
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
