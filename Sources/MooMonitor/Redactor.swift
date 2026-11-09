import Foundation

/// 客户端脱敏。服务端还会再过一遍，这里是第一道。
public enum Redactor {
    private static let secretQuery = try! NSRegularExpression(
        pattern: "([?&](?:password|pwd|token|secret|api_key|apikey|authorization|sig|signature)=)[^&\\s]+",
        options: [.caseInsensitive]
    )
    private static let url = try! NSRegularExpression(pattern: "https?://\\S+")
    private static let container = try! NSRegularExpression(
        pattern: "/var/mobile/Containers/Data/Application/[0-9A-Fa-f-]+"
    )
    private static let blob = try! NSRegularExpression(pattern: "[A-Za-z0-9+/_\\-]{32,}={0,2}")

    public static func scrub(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return value }
        var out = value
        out = replace(secretQuery, in: out) { text, match in
            let key = (text as NSString).substring(with: match.range(at: 1))
            return key + "***"
        }
        out = replace(url, in: out) { _, _ in "[url]" }
        out = replace(container, in: out) { _, _ in "~" }
        out = replace(blob, in: out) { _, _ in "[blob]" }
        return out
    }

    private static func replace(
        _ regex: NSRegularExpression,
        in text: String,
        transform: (String, NSTextCheckingResult) -> String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let r = Range(match.range, in: text) else { continue }
            result += text[cursor..<r.lowerBound]
            result += transform(text, match)
            cursor = r.upperBound
        }
        result += text[cursor...]
        return result
    }
}
