import Foundation

public enum UploadOutcome: Equatable {
    case sent(Int)
    case nothing
    case disabled
    case retry(String)
}

/// 批量上报。每轮最多 3 批，避免一次后台窗口长时间占网。
public final class Uploader {

    private let config: MonitorConfig
    private let store: EventStore
    private let session: URLSession

    public init(config: MonitorConfig, store: EventStore, session: URLSession = .shared) {
        self.config = config
        self.store = store
        self.session = session
    }

    public func flush() async -> UploadOutcome {
        guard config.enabled else { return .disabled }
        guard let url = URL(string: "\(config.endpoint)/api/v1/app-errors/intake") else { return .disabled }

        var total = 0
        for _ in 0..<3 {
            let records = store.pending(limit: 50)
            if records.isEmpty {
                return total > 0 ? .sent(total) : .nothing
            }

            let body: [String: Any] = [
                "app": config.app,
                "sdk": ["name": "moo-monitor-ios", "version": BuildInfo.version, "schema": 1],
                "records": records,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                return .retry("encode")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = data
            request.timeoutInterval = 10
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // token 走头，不进 URL / 访问日志。
            request.setValue(config.token, forHTTPHeaderField: "X-Project-Token")
            request.setValue("ShuheApple/\(config.release)", forHTTPHeaderField: "User-Agent")

            do {
                let (_, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200..<300:
                    store.dropFirst(records.count)
                    total += records.count
                case 401, 403:
                    return .disabled
                case 429:
                    return .retry("429")
                case 500..<600:
                    return .retry("http \(code)")
                default:
                    // 4xx（非 401/403/429）：格式问题，重试也不会成功，丢批避免卡住后面的记录。
                    store.dropFirst(records.count)
                }
            } catch {
                return .retry(String(describing: type(of: error)))
            }
        }

        return .sent(total)
    }
}

public enum BuildInfo {
    public static let version = "0.1.0"
}
