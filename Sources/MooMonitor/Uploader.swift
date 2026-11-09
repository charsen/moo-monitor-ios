import Foundation

public enum UploadOutcome: Equatable {
    case sent(Int)
    case nothing
    case disabled
    case retry(String)
}

/// 批量上报。每轮最多 3 批，避免一次后台窗口长时间占网。
///
/// 重试状态跨启动持久化：5xx / 网络错误按 30s → 2m → 8m → 30m 退避，最多 6 次；
/// 6 次后本次进程不再尝试，下次启动重新开始。429 优先用服务端 `Retry-After`。
public final class Uploader {

    private static let maxRecordsPerBatch = 50
    private static let maxBatchBytes = 512 * 1024
    private static let backoff: [TimeInterval] = [30, 120, 480, 1800, 1800, 1800]

    private let config: MonitorConfig
    private let store: EventStore
    private let session: URLSession
    private var exhausted = false

    public init(config: MonitorConfig, store: EventStore, session: URLSession = .shared) {
        self.config = config
        self.store = store
        self.session = session
        // 上一次进程已经把 6 次退避用完：新进程从第一档重新开始，别让一次坏网络永久停发。
        if let state = store.retryState(), state.attempts >= Self.backoff.count {
            store.clearRetryState()
        }
    }

    public func flush() async -> UploadOutcome {
        guard config.enabled else { return .disabled }
        if let stamp = store.disabledStamp(),
           stamp.release == config.release,
           stamp.build == config.build {
            return .disabled
        }
        guard !exhausted else { return .retry("exhausted") }

        let base = config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/v1/app-errors/intake") else { return .disabled }

        if let retry = store.retryState(), retry.nextAt > Date().timeIntervalSince1970 {
            return .retry("backoff")
        }

        var total = 0
        for _ in 0..<3 {
            let candidates = store.pending(limit: Self.maxRecordsPerBatch)
            if candidates.isEmpty {
                return total > 0 ? .sent(total) : .nothing
            }

            let records = fit(candidates)
            guard !records.isEmpty else {
                // 单条就超过批次上限：服务端会 422，丢掉避免永远堵住后面。
                store.dropFirst(1)
                continue
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
            request.timeoutInterval = 15
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // token 走头，不进 URL / 访问日志。
            request.setValue(config.token, forHTTPHeaderField: "X-Project-Token")
            request.setValue("\(config.app)/\(config.release)", forHTTPHeaderField: "User-Agent")

            do {
                let (responseData, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                switch code {
                case 200..<300:
                    if let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                       let ok = object["ok"] as? Bool, !ok {
                        // 服务端说整批失败（信封/项目问题）：保留记录并退避，别静默丢。
                        scheduleRetry(after: nil, reason: "ok=false")
                        return .retry("ok=false")
                    }
                    store.dropFirst(records.count)
                    store.clearRetryState()
                    exhausted = false
                    total += records.count
                case 401, 403:
                    // 契约：撤权/换 token 后停止发送并持久化禁用；留着队列只会让每次启动都打服务器。
                    store.clearQueue()
                    store.setDisabledStamp(release: config.release, build: config.build)
                    store.clearRetryState()
                    return .disabled
                case 408:
                    scheduleRetry(after: nil, reason: "408")
                    return .retry("408")
                case 429:
                    scheduleRetry(after: retryAfter(http), reason: "429")
                    return .retry("429")
                case 500..<600:
                    scheduleRetry(after: nil, reason: "http \(code)")
                    return .retry("http \(code)")
                default:
                    // 其余 4xx（422/400/413/415…）是格式问题，重试不会成功，丢批避免卡住后面的记录。
                    store.dropFirst(records.count)
                    store.clearRetryState()
                    return total > 0 ? .sent(total) : .nothing
                }
            } catch {
                scheduleRetry(after: nil, reason: String(describing: type(of: error)))
                return .retry(String(describing: type(of: error)))
            }
        }

        return .sent(total)
    }

    /// 按 512KB 上限裁剪本批；至少保留一条。单条超限由调用方丢弃。
    private func fit(_ candidates: [[String: Any]]) -> [[String: Any]] {
        var records = candidates
        while records.count > 1 {
            let body: [String: Any] = ["app": config.app, "sdk": ["name": "moo-monitor-ios"], "records": records]
            guard let data = try? JSONSerialization.data(withJSONObject: body), data.count > Self.maxBatchBytes else {
                return records
            }
            records.removeLast()
        }
        guard let first = records.first else { return [] }
        let body: [String: Any] = ["app": config.app, "sdk": ["name": "moo-monitor-ios"], "records": [first]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        return data.count > Self.maxBatchBytes ? [] : records
    }

    private func scheduleRetry(after override: TimeInterval?, reason: String) {
        let previous = store.retryState()?.attempts ?? 0
        let attempts = previous + 1
        guard attempts < Self.backoff.count else {
            exhausted = true
            store.setRetryState(EventStore.RetryState(attempts: attempts, nextAt: 0, reason: reason))
            return
        }
        let delay = max(1, min(override ?? Self.backoff[attempts - 1], 3600))
        store.setRetryState(EventStore.RetryState(
            attempts: attempts,
            nextAt: Date().timeIntervalSince1970 + delay,
            reason: reason
        ))
    }

    private func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

public enum BuildInfo {
    public static let version = "0.2.0"
}
