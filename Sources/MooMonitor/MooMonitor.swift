import Foundation
import MooMonitorCrash

#if canImport(UIKit)
import UIKit
#endif

/// 门面。宿主在启动早期调一次 `MooMonitor.install(...)`，之后只通过 `screen` / `capture`
/// 和前后台回调与它交互。任何采集失败都不能抛回宿主。
public final class MooMonitor {

    public static let shared = MooMonitor()

    private let stateLock = NSLock()
    private var isInstalled = false
    private var config: MonitorConfig?
    private var store: EventStore?
    private var uploader: Uploader?
    private var session: SessionMarker?
    private let sessionId = UUID().uuidString
    private var installId = ""

    private var deviceSnapshot: [String: Any] = [:]
    private var screenValue: String?
    private var breadcrumbs: [(at: Date, type: String, name: String)] = []
    private var cachedForeground = true
    private var lastMemoryWarning: Date?
    private var startupTask: Task<Void, Never>?
    private var memoryObserver: NSObjectProtocol?

    public private(set) var disabled = false
    public var installed: Bool { isInstalled && config?.enabled == true && !disabled }

    /// 当前界面名。只用于上报，不参与业务逻辑。
    public var screen: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return screenValue
    }

    private init() {}

    // MARK: - 安装

    public static func install(_ config: MonitorConfig, directory: URL? = nil) {
        shared.install(config, directory: directory)
    }

    public func install(_ config: MonitorConfig, directory: URL? = nil) {
        guard config.enabled, !isInstalled else { return }

        let store = directory.map { EventStore(directory: $0, config: config) } ?? EventStore.forApp(config: config)
        self.config = config
        self.store = store
        self.uploader = Uploader(config: config, store: store)
        self.session = SessionMarker(directory: store.dir, config: config)
        self.deviceSnapshot = DeviceInfo.device()
        self.installId = DeviceInfo.installId(fallbackDirectory: store.dir)
        isInstalled = true

        // token 撤销后服务端会 401/403；同一构建不再打服务器。换构建自动解除，
        // 避免一次临时故障把后续版本永久禁用。
        if let stamp = store.disabledStamp(), stamp.release == config.release, stamp.build == config.build {
            disabled = true
            return
        }
        if store.disabledStamp() != nil { store.clearDisabledStamp() }

        // 先装 C 侧信号处理（打开 fd、缓存 image 表），再处理上次遗留的帧。
        _ = store.crashPath.withCString { moo_crash_install($0) }
        CrashReporter.install { [weak self] name, reason, stack in
            self?.recordException(name: name, reason: reason, stack: stack)
        }

        #if canImport(UIKit)
        cachedForeground = UIApplication.shared.applicationState != .background
        #endif

        let previousBreadcrumbs = loadPersistedBreadcrumbs()
        clearPersistedBreadcrumbs()
        let previous = session?.begin(sessionId: sessionId)
        let frames = store.crashFrames()
        let hasException = FileManager.default.fileExists(atPath: exceptionURL.path)
        let hadCrash = !frames.isEmpty || hasException

        // 上次停在 foreground、这次没有崩溃帧 → 可能是 watchdog / OOM / 上滑强杀。
        // 换了构建不推断：覆盖安装会把旧进程的「前台」状态带过来。
        if let previous, Self.shouldInferTermination(previous: previous, hadCrash: hadCrash, config: config) {
            let occurred = Date(timeIntervalSince1970: Double(previous.updated_at) / 1000)
            let duration = max(0, Date().timeIntervalSince(occurred) * 1000)
            let record = buildRecord(
                kind: "termination",
                name: "unknown",
                message: "进程在前台消失，没有捕获到崩溃帧",
                stack: nil,
                frames: [],
                occurredAt: occurred,
                screen: previous.screen,
                fallbackToCurrentScreen: false,
                breadcrumbOverride: previousBreadcrumbs,
                extras: [
                    "reason": "unknown",
                    "session_state": previous.state,
                    "session_started_at": previous.started_at,
                    "duration_ms": Int(duration),
                ]
            )
            enqueue(record)
        }

        drainExceptionFile()
        drainCrashFrames(frames, screen: previous?.screen, breadcrumbs: previousBreadcrumbs)
        installMemoryObserver()
        addBreadcrumb("lifecycle", "launch")
        scheduleStartupFlush()
    }

    /// 脏退出推断的纯规则：上次停在 foreground、同一构建、且这次没有读到任何崩溃证据。
    /// 换构建不推断：覆盖安装会把旧进程的「前台」状态带过来。
    static func shouldInferTermination(previous: SessionState?, hadCrash: Bool, config: MonitorConfig) -> Bool {
        guard let previous, !hadCrash else { return false }
        return previous.state == SessionMarker.State.foreground.rawValue
            && previous.release == config.release
            && previous.build == config.build
    }

    /// 把 `exception.json` 里由 NSException 处理器写下的记录并入队列。
    private func drainExceptionFile() {
        guard let store, let data = try? Data(contentsOf: exceptionURL),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        if store.appendMerged(record) {
            try? FileManager.default.removeItem(at: exceptionURL)
        }
    }

    /// 把 `crash.bin` 里的帧还原成可读记录并入队列。
    /// 必须在 install 里做：符号化依赖当前进程的 image 表，越早越接近崩溃时的构建。
    private func drainCrashFrames(_ frames: [moo_crash_frame], screen: String?, breadcrumbs: [[String: Any]]) {
        guard let store, !frames.isEmpty else { return }

        var allAppended = true
        for frame in frames {
            var resolved = FrameResolver.resolve(frame)
            // 信号处理器自己的帧不是崩溃现场；_sigtramp 是内核到 handler 的桥，也一并去掉。
            while let name = resolved.first?["function"] as? String,
                  name.contains("moo_crash_handle") || name.contains("_sigtramp") {
                resolved.removeFirst()
            }
            let symbols = resolved.compactMap { $0["function"] as? String }
            let record = buildRecord(
                kind: "crash",
                name: signalName(frame.sig),
                message: "signal \(frame.sig)",
                stack: symbols.joined(separator: "\n"),
                frames: resolved,
                occurredAt: Date(timeIntervalSince1970: Double(frame.timestamp_ms) / 1000),
                screen: screen,
                fallbackToCurrentScreen: false,
                breadcrumbOverride: breadcrumbs,
                extras: [
                    "signal": Int(frame.sig),
                    "thread_id": String(frame.thread_id),
                    "depth": Int(frame.depth),
                    "image_count": Int(frame.image_count),
                ]
            )
            allAppended = store.appendMerged(record) && allAppended
        }

        // 只有全部并入成功才清文件；失败留到下次启动重试，宁可重复也不丢。
        if allAppended { store.resetCrashFile() }
    }

    private func scheduleStartupFlush() {
        startupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.flush()
        }
    }

    private func installMemoryObserver() {
        #if canImport(UIKit)
        guard memoryObserver == nil else { return }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordLowMemory()
        }
        #endif
    }

    // MARK: - 生命周期

    public static func enterForeground() { shared.enterForeground() }
    public static func enterBackground() { shared.enterBackground() }

    public func enterForeground() {
        guard installed else { return }
        stateLock.lock(); cachedForeground = true; stateLock.unlock()
        session?.mark(.foreground)
        addBreadcrumb("lifecycle", "foreground")
    }

    public func enterBackground() {
        guard installed else { return }
        stateLock.lock(); cachedForeground = false; stateLock.unlock()
        session?.mark(.background)
        addBreadcrumb("lifecycle", "background")
        #if canImport(UIKit)
        if Thread.isMainThread {
            flushInBackground()
        } else {
            DispatchQueue.main.async { [weak self] in self?.flushInBackground() }
        }
        #else
        Task { [weak self] in await self?.flush() }
        #endif
    }

    #if canImport(UIKit)
    private func flushInBackground() {
        let task = UIApplication.shared.beginBackgroundTask(withName: "MooMonitor.flush")
        Task { [weak self] in
            await self?.flush()
            if task != .invalid {
                await MainActor.run { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }
    #endif

    private func recordLowMemory() {
        guard installed else { return }
        let now = Date()
        if let last = lastMemoryWarning, now.timeIntervalSince(last) < 3600 { return }
        lastMemoryWarning = now
        addBreadcrumb("lifecycle", "memory_warning")
        enqueue(buildRecord(
            kind: "low_memory",
            name: "MemoryWarning",
            message: nil,
            stack: nil,
            frames: [],
            extras: ["reason": "didReceiveMemoryWarning"]
        ))
    }

    // MARK: - 业务记录

    public static func screen(_ name: String) { shared.setScreen(name) }

    public func setScreen(_ name: String) {
        let clean = String((Redactor.scrub(name) ?? name).prefix(64))
        stateLock.lock()
        screenValue = clean
        stateLock.unlock()
        session?.markScreen(clean)
        addBreadcrumb("screen", clean)
    }

    public static func capture(_ error: Error, extras: [String: Any] = [:]) {
        shared.capture(error, extras: extras)
    }

    /// 业务主动上报（导入失败、同步失败、SQLite 错误等）。默认不采样，由调用点决定。
    public func capture(_ error: Error, extras: [String: Any] = [:]) {
        guard installed, let store else { return }
        var payload = extras
        let ns = error as NSError
        payload["domain"] = ns.domain
        payload["code"] = ns.code
        let record = buildRecord(
            kind: "handled",
            name: String(describing: type(of: error)),
            message: error.localizedDescription,
            stack: Thread.callStackSymbols.joined(separator: "\n"),
            frames: [],
            extras: payload
        )
        store.appendMerged(record)
    }

    public func addBreadcrumb(_ type: String, _ name: String) {
        let entry = (at: Date(), type: String(type.prefix(16)), name: String(name.prefix(64)))
        stateLock.lock()
        breadcrumbs.append(entry)
        if breadcrumbs.count > 30 {
            breadcrumbs.removeFirst(breadcrumbs.count - 30)
        }
        let payload = breadcrumbs.map(Self.breadcrumbJSON)
        stateLock.unlock()
        // 面包屑要跨启动：信号崩溃在下次启动才组装记录，内存里的那 30 条已经没了。
        persistBreadcrumbs(payload)
    }

    private static func breadcrumbJSON(_ entry: (at: Date, type: String, name: String)) -> [String: Any] {
        ["t": ISO8601DateFormatter.moo.string(from: entry.at), "type": entry.type, "name": entry.name]
    }

    private var breadcrumbURL: URL {
        (store?.dir ?? FileManager.default.temporaryDirectory).appendingPathComponent("breadcrumbs.json")
    }

    private func persistBreadcrumbs(_ payload: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: breadcrumbURL, options: [.atomic])
    }

    private func loadPersistedBreadcrumbs() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: breadcrumbURL),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return Array(array.suffix(30))
    }

    private func clearPersistedBreadcrumbs() {
        try? FileManager.default.removeItem(at: breadcrumbURL)
    }

    /// NSException 路径：写到独立文件，不碰队列锁。下次启动再并入队列。
    private func recordException(name: String, reason: String?, stack: [String]) {
        guard installed, let config else { return }
        let record = buildRecord(
            kind: "crash",
            name: name,
            message: reason,
            stack: stack.joined(separator: "\n"),
            frames: [],
            extras: ["sdk_exception": true, "release": config.release, "build": config.build],
            safeContext: true
        )
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        do {
            try data.write(to: exceptionURL, options: [.atomic])
            // 异常处理返回后系统还会 abort 成 SIGABRT；告诉 C 侧不要再写一帧，
            // 否则同一次崩溃会同时出现 NSException 与 SIGABRT 两条记录。
            moo_crash_skip_signal_after_exception()
        } catch {
            // 写失败就让随后的 SIGABRT 路径兜底，至少还能留下一条信号记录。
        }
    }

    // MARK: - 上报

    public static func flush() {
        Task { await shared.flush() }
    }

    public func flush() async {
        guard let uploader else { return }
        let outcome = await uploader.flush()
        if outcome == .disabled {
            disabled = true
        }
    }

    // MARK: - 记录

    private func buildRecord(
        kind: String,
        name: String,
        message: String?,
        stack: String?,
        frames: [[String: Any]],
        occurredAt: Date = Date(),
        screen: String? = nil,
        fallbackToCurrentScreen: Bool = true,
        breadcrumbOverride: [[String: Any]]? = nil,
        extras: [String: Any] = [:],
        safeContext: Bool = false
    ) -> [String: Any] {
        let config = self.config
        // UIApplication / 文件系统只在主线程碰；后台线程 fallback 到缓存值。
        let safe = safeContext || !Thread.isMainThread
        let currentScreen = safe ? screenSnapshot(avoidBlocking: true) : self.screen
        let resolvedScreen = screen ?? (fallbackToCurrentScreen ? currentScreen : nil)
        var context: [String: Any]
        if safe {
            // 异常处理器里不碰 UIApplication / 文件系统：只用安装时缓存和当前内存状态。
            context = ["install_id": installId, "session_id": sessionId]
            if let resolvedScreen { context["screen"] = resolvedScreen }
            stateLock.lock()
            context["foreground"] = cachedForeground
            stateLock.unlock()
        } else {
            context = DeviceInfo.context(installId: installId, sessionId: sessionId, screen: resolvedScreen)
        }

        var record: [String: Any] = [
            "event_id": UUID().uuidString,
            "platform": "ios",
            "kind": kind,
            "severity": severity(for: kind),
            "count": 1,
            "occurred_at": ISO8601DateFormatter.moo.string(from: occurredAt),
            "release": config?.release ?? "",
            "build": config?.build ?? "",
            "env": config?.env ?? "release",
            "exception": [
                "name": Redactor.scrub(name) ?? "Error",
                "message": Redactor.scrub(message ?? "") ?? "",
                "stack": Redactor.scrub(stack ?? "") ?? "",
            ],
            "frames": frames,
            "device": deviceSnapshot.isEmpty ? DeviceInfo.device() : deviceSnapshot,
            "context": context,
        ]

        let crumbs = breadcrumbOverride ?? breadcrumbPayload(avoidBlocking: safe)
        if !crumbs.isEmpty { record["breadcrumbs"] = crumbs }

        var payload = extras
        if !safe, let store, store.dropped > 0 { payload["dropped"] = store.dropped }
        if !payload.isEmpty { record["payload"] = payload }
        return record
    }

    /// 异常处理器里不能为了拿界面名/面包屑去等一把可能已被崩溃线程持有的锁。
    private func screenSnapshot(avoidBlocking: Bool) -> String? {
        if avoidBlocking {
            guard stateLock.try() else { return nil }
        } else {
            stateLock.lock()
        }
        defer { stateLock.unlock() }
        return screenValue
    }

    private func breadcrumbPayload(avoidBlocking: Bool = false) -> [[String: Any]] {
        if avoidBlocking {
            guard stateLock.try() else { return [] }
        } else {
            stateLock.lock()
        }
        let snapshot = breadcrumbs
        stateLock.unlock()
        return snapshot.map(Self.breadcrumbJSON)
    }

    @discardableResult
    private func enqueue(_ record: [String: Any]) -> Bool {
        store?.appendMerged(record) ?? false
    }

    private func severity(for kind: String) -> String {
        switch kind {
        case "crash": return "fatal"
        case "low_memory": return "warning"
        default: return "error"
        }
    }

    private var exceptionURL: URL {
        (store?.dir ?? FileManager.default.temporaryDirectory).appendingPathComponent("exception.json")
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
