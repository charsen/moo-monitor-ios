import Foundation

internal enum UploadOutcome: Equatable {
    case sent(Int), nothing, disabled, more
    case retry(String)
}

/// actor 保护状态，显式 busy 闸防止 await 网络期间重入发送同一批。
actor Uploader {
    private static let maxBatchBytes = 512 * 1024
    private static let backoff: [TimeInterval] = [30, 120, 480, 1800, 1800, 1800]
    private let config: MonitorConfig
    private let store: EventStore
    private let session: URLSession
    private let policy = RequestPolicy()
    private var busy = false
    private var exhausted = false

    init(config: MonitorConfig, store: EventStore, session: URLSession = .shared) {
        self.config = config
        self.store = store
        self.session = session
        if var retry = store.retryState() {
            if retry.identity != EventStore.identity(config) {
                store.clearRetryState()
            } else if retry.attempts != 0 {
                // New process, fresh failure budget; preserve the absolute wait.
                // Six old attempts otherwise also stop the facade awaiting it.
                retry.attempts = 0
                store.setRetryState(retry)
            }
        }
        // 新进程可重新开始重试预算，但不能提前突破服务端尚未到期的 Retry-After。
    }

    func flush() async -> UploadOutcome {
        guard config.enabled, !store.isDisabled(for: config) else { return .disabled }
        guard !busy else { return .retry("busy") }
        busy = true
        defer { busy = false }
        guard !exhausted else { return .retry("exhausted") }
        if let retry = store.retryState(), retry.nextAt > Date().timeIntervalSince1970 { return .retry("backoff") }

        let base = config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/v1/app-errors/intake") else { return .disabled }
        var total = 0
        for _ in 0..<3 {
            if Task.isCancelled { return .retry("cancelled") }
            let batch = store.readBatch(limit: 50)
            guard batch.readable else { return retry("queue read") }
            if batch.records.isEmpty { return total > 0 ? .sent(total) : .nothing }
            var size = encode([])?.count ?? Self.maxBatchBytes
            var count = 0
            for bytes in batch.encodedSizes {
                let next = size + bytes + (count == 0 ? 0 : 1)
                guard next <= Self.maxBatchBytes else { break }
                size = next; count += 1
            }
            let records = Array(batch.records.prefix(count))
            let data = count > 0 ? encode(records) : nil
            guard let data, data.count <= Self.maxBatchBytes else {
                guard store.acknowledge(batch, indexes: [0]) else { return retry("acknowledgement") }
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.httpBody = data
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(config.token, forHTTPHeaderField: "X-Project-Token")
            request.setValue("\(config.app)/\(config.release)", forHTTPHeaderField: "User-Agent")
            do {
                let (stream, response) = try await session.bytes(for: request, delegate: policy)
                defer { stream.task.cancel() }
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                switch code {
                case 200..<300:
                    var responseData = Data()
                    for try await byte in stream {
                        guard responseData.count < 128 * 1024 else { return retry("response too large") }
                        responseData.append(byte)
                    }
                    guard let confirmed = confirmedIndexes(responseData, count: records.count) else { return retry("invalid response") }
                    guard !confirmed.isEmpty else { return retry("partial response") }
                    guard store.acknowledge(batch, indexes: confirmed) else { return retry("acknowledgement") }
                    total += confirmed.count
                    if confirmed.count < records.count { return retry("partial response") }
                    store.clearRetryState()
                case 401, 403:
                    store.setDisabledStamp(config: config)
                    store.clearRetryState()
                    return .disabled
                case 400, 413, 415, 422:
                    guard store.acknowledge(batch, indexes: Array(records.indices)) else { return retry("acknowledgement") }
                    store.clearRetryState()
                case 429:
                    return retry("429", after: retryAfter(http))
                default:
                    return retry("http \(code)")
                }
            } catch {
                if Task.isCancelled { return .retry("cancelled") }
                return retry(String(describing: type(of: error)))
            }
        }
        return store.pending(limit: 1).isEmpty ? .sent(total) : .more
    }

    private func encode(_ records: [[String: Any]]) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "app": config.app,
            "sdk": ["name": "moo-monitor-ios", "version": BuildInfo.version, "schema": 1],
            "records": records,
        ])
    }

    private func confirmedIndexes(_ data: Data, count: Int) -> [Int]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID(), ok.boolValue,
              let results = object["results"] as? [[String: Any]], results.count == count else { return nil }
        var seen = Set<Int>()
        var confirmed: [Int] = []
        for item in results {
            guard let n = item["index"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < Double(count),
                  n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
            let index = n.intValue
            guard seen.insert(index).inserted, let status = item["status"] as? String else { return nil }
            switch status {
            case "saved", "created", "updated", "duplicate", "filtered": confirmed.append(index)
            case "skipped":
                if let retryable = item["retryable"] as? NSNumber, CFGetTypeID(retryable) == CFBooleanGetTypeID(), !retryable.boolValue {
                    confirmed.append(index)
                }
            default: return nil
            }
        }
        return confirmed
    }

    private func retry(_ reason: String, after override: TimeInterval? = nil) -> UploadOutcome {
        let previous = max(0, store.retryState()?.attempts ?? 0)
        let attempts = min(previous, Self.backoff.count) + 1
        let delay = override ?? Self.backoff[min(attempts - 1, Self.backoff.count - 1)]
        exhausted = attempts >= Self.backoff.count
        store.setRetryState(.init(attempts: attempts, nextAt: Date().timeIntervalSince1970 + max(1, delay),
                                  reason: reason, identity: EventStore.identity(config)))
        return .retry(reason)
    }

    private func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return min(seconds, 315_576_000) // 有界十年，绝不把常规服务端退避缩短为一小时。
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return min(315_576_000, max(0, date.timeIntervalSinceNow))
    }
}

/// 按任务禁止跳转、cookie 与认证挑战，公开 token 不能被带往另一个地址。
private final class RequestPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .useCredential, nil)
    }
}

enum BuildInfo { static let version = "0.2.0" }
