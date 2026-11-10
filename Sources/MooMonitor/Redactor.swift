import Foundation

/// 先限制输入/遍历预算，再脱敏；不能为了截断 payload 先展开巨大共享对象图。
enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"(?i)\b(?:bearer)\s+[^\s,;]+"#, "Bearer ***"),
        (#"(?i)((?<![A-Za-z0-9])(?:password|passwd|pwd|pass|token|secret|api[_-]?key|authorization|signature|sig|cookie|credential)\b\s*["']?\s*[=:]\s*)(?:"[^"]*"|'[^']*'|[^\s&;,"']+)"#, "$1***"),
        (#"\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[jwt]"),
        (#"(?i)(?:https?|file|content)://[^\r\n]+"#, "[url]"),
        (#"(?:/private)?/var/mobile/Containers/[^\r\n]+|/Users/[^\r\n]+|/private/var/[^\r\n]+"#, "~/[path]"),
        (#"\b[0-9A-Fa-f]{32,}\b"#, "[blob]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    private static let secretKey = try! NSRegularExpression(pattern: #"(?i)(password|passwd|pwd|token|secret|api[_-]?key|authorization|signature|cookie|credential)"#)

    static func scrub(_ value: String?) -> String? {
        guard let value else { return nil }
        var out = truncate(value, bytes: 32 * 1024)
        for (regex, replacement) in rules {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        return out
    }

    static func truncate(_ value: String, bytes: Int) -> String {
        if value.utf8.count <= bytes { return value }
        var prefix = value.utf8.prefix(max(0, bytes))
        while String(bytes: prefix, encoding: .utf8) == nil && !prefix.isEmpty { prefix = prefix.dropLast() }
        return String(decoding: prefix, as: UTF8.self)
    }

    static func payload(_ values: [String: Any], dropped: Int = 0) -> [String: Any] {
        var nodes = 128
        var strings = 8 * 1024
        var cleaned = value(values, depth: 0, nodes: &nodes, strings: &strings) as? [String: Any] ?? [:]
        if dropped > 0 { cleaned["dropped"] = dropped }
        guard let data = try? JSONSerialization.data(withJSONObject: cleaned), data.count <= 8 * 1024 else {
            var fallback: [String: Any] = ["__truncated": "oversized"]
            if dropped > 0 { fallback["dropped"] = dropped }
            return fallback
        }
        return cleaned
    }

    private static func value(_ input: Any, depth: Int, nodes: inout Int, strings: inout Int) -> Any {
        guard nodes > 0, strings > 0, depth <= 4 else { return "[truncated]" }
        nodes -= 1
        if let text = input as? String {
            let out = scrub(truncate(text, bytes: min(strings, 2048))) ?? ""
            strings -= out.utf8.count
            return out
        }
        if input is NSNull { return NSNull() }
        if let number = input as? NSNumber {
            return number.doubleValue.isFinite ? number : NSNull()
        }
        if let object = input as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in object.prefix(16) {
                guard nodes > 0, strings > 0 else { break }
                let cleanKey = scrub(truncate(key, bytes: min(strings, 64))) ?? ""
                strings -= cleanKey.utf8.count
                let range = NSRange(key.startIndex..., in: key)
                result[cleanKey] = secretKey.firstMatch(in: key, range: range) != nil ? "***" : value(item, depth: depth + 1, nodes: &nodes, strings: &strings)
            }
            return result
        }
        if let array = input as? [Any] {
            var result: [Any] = []
            for item in array.prefix(16) {
                guard nodes > 0, strings > 0 else { break }
                result.append(value(item, depth: depth + 1, nodes: &nodes, strings: &strings))
            }
            return result
        }
        // 任意对象的 description 可能含书名/凭据，也可能执行宿主代码。
        return "[unsupported]"
    }

    static func screen(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 64,
              value.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}
