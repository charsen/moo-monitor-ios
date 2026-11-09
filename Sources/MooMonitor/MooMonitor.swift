import Foundation
import MooMonitorCrash

/// 门面。宿主在启动早期调一次 `MooMonitor.shared.install(...)`。
public final class MooMonitor {

    public static let shared = MooMonitor()

    private var config: MonitorConfig?
    private var store: EventStore?
    private var uploader: Uploader?
    private let sessionId = UUID().uuidString
    private lazy var installId = DeviceInfo.installId()

    public private(set) var screen: String?
    public private(set) var disabled = false

    public var installed: Bool { config?.enabled == true && !disabled }

    private init() {}

    public func install(_ config: MonitorConfig) {
        guard config.enabled, self.config == nil else { return }
        self.config = config

        let store = EventStore.forApp(config: config)
        self.store = store
        self.uploader = Uploader(config: config, store: store)

        // 先装 C 侧的信号处理（打开 fd、缓存 image 表），再把上次的帧转成记录。
        _ = store.crashPath.withCString { moo_crash_install($0) }
        drainCrashFrames()

        Task { await flush() }
    }

    /// 把 `crash.bin` 里的帧还原成可读记录并入队列。
    /// 必须在 install 里做：符号化依赖当前进程的 image 表，越早越接近崩溃时的构建。
    private func drainCrashFrames() {
        guard let store, let config else { return }
        let frames = store.crashFrames()
        guard !frames.isEmpty else { return }

        for frame in frames {
            let resolved = FrameResolver.resolve(frame)
            let record = buildRecord(
                config: config,
                kind: "crash",
                name: signalName(frame.sig),
                message: nil,
                stack: resolved.compactMap { $0["function"] as? String }.joined(separator: "\n"),
                frames: resolved,
                extras: ["signal": Int(frame.sig)],
                store: store
            )
            store.append(record)
        }
        store.resetCrashFile()
    }

    /// 业务主动上报（同步失败、解析失败等）。默认不采样，由调用点决定。
    public func capture(_ error: Error, extras: [String: Any] = [:]) {
        guard installed, let store, let config else { return }
        let record = buildRecord(
            config: config,
            kind: "handled",
            name: String(describing: type(of: error)),
            message: error.localizedDescription,
            stack: Thread.callStackSymbols.joined(separator: "\n"),
            frames: [],
            extras: extras,
            store: store
        )
        store.append(record)
    }

    public func setScreen(_ name: String) {
        screen = name
    }

    public func flush() async {
        guard let uploader else { return }
        let outcome = await uploader.flush()
        if outcome == .disabled { disabled = true }
    }

    // MARK: - 记录

    private func buildRecord(
        config: MonitorConfig,
        kind: String,
        name: String,
        message: String?,
        stack: String?,
        frames: [[String: Any]],
        extras: [String: Any],
        store: EventStore
    ) -> [String: Any] {
        var record: [String: Any] = [
            "event_id": UUID().uuidString,
            "platform": "ios",
            "kind": kind,
            "count": 1,
            "occurred_at": ISO8601DateFormatter.moo.string(from: Date()),
            "release": config.release,
            "build": config.build,
            "env": config.env,
            "exception": [
                "name": Redactor.scrub(name) ?? "Error",
                "message": Redactor.scrub(message ?? "") ?? "",
                "stack": Redactor.scrub(stack ?? "") ?? "",
            ],
            "frames": frames,
            "device": DeviceInfo.device(),
            "context": DeviceInfo.context(installId: installId, sessionId: sessionId, screen: screen),
        ]
        var payload = extras
        if store.dropped > 0 { payload["dropped"] = store.dropped }
        if !payload.isEmpty { record["payload"] = payload }
        return record
    }

    private func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(sig)"
        }
    }
}

extension ISO8601DateFormatter {
    static let moo: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
