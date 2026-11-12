import Foundation
import CryptoKit
import MooMonitorCrash

#if canImport(UIKit)
import UIKit
#endif

/// 门面。宿主在启动早期调一次 `MooMonitor.install(...)`，之后只通过 `screen` / `capture`
/// 和前后台回调与它交互。任何采集失败都不能抛回宿主。
public final class MooMonitor {

    public static let shared = MooMonitor()

    private let stateLock = NSLock()
    private let breadcrumbLock = NSLock()
    private let captureThreadKey = "MooMonitor.capture." + UUID().uuidString
    private var lastLifecycle: Bool?
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
    private var lastMemoryWarning: TimeInterval?
    private var startupTask: Task<Void, Never>?
    private var memoryObserver: NSObjectProtocol?
    private var flushTask: Task<Void, Never>?
    private var installedFlag = false

    private var disabledValue = false
    public var disabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return disabledValue
    }
    public var installed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return installedFlag && !disabledValue
    }

    /// 当前界面名。只用于上报，不参与业务逻辑。
    public var screen: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return screenValue
    }

    private let runtimeHooks: Bool
    init(runtimeHooks: Bool = true) { self.runtimeHooks = runtimeHooks }

    // MARK: - 安装

    public static func install(_ config: MonitorConfig, directory: URL? = nil) {
        shared.install(config, directory: directory)
    }

    public func install(_ config: MonitorConfig, directory: URL? = nil) {
        guard config.enabled else { return }
        stateLock.lock()
        guard !isInstalled else { stateLock.unlock(); return }
        isInstalled = true
        stateLock.unlock()

        let store = directory.map { EventStore(directory: $0, config: config) } ?? EventStore.forApp(config: config)
        self.config = config
        self.store = store
        self.uploader = Uploader(config: config, store: store)
        self.deviceSnapshot = DeviceInfo.device()
        self.session = SessionMarker(directory: store.dir, config: config, device: deviceSnapshot.compactMapValues { $0 as? String })
        self.installId = DeviceInfo.installId(fallbackDirectory: store.dir)
        deviceSnapshot["storage_free"] = DeviceInfo.context(installId: installId, sessionId: sessionId, screen: nil)["storage_free"]

        if store.isDisabled(for: config) {
            stateLock.lock(); disabledValue = true; stateLock.unlock()
            return
        }
        store.clearDisabledStamp()
        stateLock.lock(); installedFlag = true; stateLock.unlock()

        // 先在普通上下文裁剪旧文件，再打开常驻fd；不能在handler里轮转。
        _ = store.prepareCrashFile()
        if runtimeHooks {
            _ = store.crashPath.withCString { moo_crash_install($0) }
            CrashReporter.install { [weak self] name, reason, stack in
                self?.recordException(name: name, reason: reason, stack: stack)
            }
        }

        #if canImport(UIKit)
        cachedForeground = UIApplication.shared.applicationState != .background
        #endif

        let previousBreadcrumbs = loadPersistedBreadcrumbs()
        clearPersistedBreadcrumbs()
        let previous = session?.current()
        let frames = store.crashFrames()
        let hasException = FileManager.default.fileExists(atPath: exceptionURL.path)
        let hadCrash = !frames.isEmpty || hasException || FileManager.default.fileExists(atPath: store.dir.appendingPathComponent("crash-recovery.json").path)

        // 上次停在 foreground、这次没有崩溃帧 → 可能是 watchdog / OOM / 上滑强杀。
        // 换了构建不推断：覆盖安装会把旧进程的「前台」状态带过来。
        if let previous, Self.shouldInferTermination(previous: previous, hadCrash: hadCrash, config: config) {
            let occurred = Date(timeIntervalSince1970: Double(previous.updated_at) / 1000)
            let duration = max(0, Double(previous.updated_at) - Double(previous.started_at))
            var record = buildRecord(
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
            record["event_id"] = "termination-" + previous.session_id
            var context = record["context"] as? [String: Any] ?? [:]
            context["session_id"] = previous.session_id
            record["context"] = context
            enqueue(record)
        }

        drainExceptionFile()
        drainCrashFrames(frames, previous: previous, breadcrumbs: previousBreadcrumbs)
        _ = session?.begin(sessionId: sessionId)
        if runtimeHooks { installMemoryObserver() }
        addBreadcrumb("lifecycle", "launch")
        if runtimeHooks { scheduleStartupFlush() }
    }

    /// 脏退出推断的纯规则：上次停在 foreground、同一构建、且这次没有读到任何崩溃证据。
    /// 换构建不推断：覆盖安装会把旧进程的「前台」状态带过来。
    static func shouldInferTermination(previous: SessionState?, hadCrash: Bool, config: MonitorConfig) -> Bool {
        guard let previous, !hadCrash,
              previous.started_at >= 0, previous.updated_at >= previous.started_at,
              Double(previous.updated_at) / 1000 <= Date().timeIntervalSince1970 else { return false }
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
        if store.appendMerged(record), store.synchronizeQueue() {
            try? FileManager.default.removeItem(at: exceptionURL)
        }
    }

    /// 把 `crash.bin` 里的帧还原成可读记录并入队列。
    /// 必须在 install 里做：符号化依赖当前进程的 image 表，越早越接近崩溃时的构建。
    private func drainCrashFrames(_ frames: [moo_crash_frame], previous: SessionState?, breadcrumbs: [[String: Any]]) {
        guard let store else { return }
        let recoveryURL = store.dir.appendingPathComponent("crash-recovery.json")
        var recovered = ((try? Data(contentsOf: recoveryURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
        }) ?? []
        var seen = Set(recovered.compactMap { $0["event_id"] as? String })
        for frame in frames {
            var resolved = FrameResolver.resolve(frame)
            // 信号处理器自己的帧不是崩溃现场；_sigtramp 是内核到 handler 的桥，也一并去掉。
            while let name = resolved.first?["function"] as? String,
                  name.contains("moo_crash_handle") || name.contains("_sigtramp") {
                resolved.removeFirst()
            }
            let symbols = resolved.compactMap { $0["function"] as? String }
            var record = buildRecord(
                kind: "crash",
                name: signalName(frame.sig),
                message: "signal \(frame.sig)",
                stack: symbols.joined(separator: "\n"),
                frames: resolved,
                occurredAt: Date(timeIntervalSince1970: min(Double(frame.timestamp_ms) / 1000, Date().timeIntervalSince1970)),
                screen: previous?.screen,
                fallbackToCurrentScreen: false,
                breadcrumbOverride: breadcrumbs,
                extras: [
                    "signal": Int(frame.sig),
                    "depth": Int(frame.depth),
                    "image_count": Int(frame.image_count),
                ]
            )
            let digest = withUnsafeBytes(of: frame) { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
            let id = "signal-" + digest
            record["event_id"] = id
            record["release"] = previous?.release ?? ""
            record["build"] = previous?.build ?? ""
            record["env"] = previous?.env ?? "unknown"
            record["device"] = previous?.device ?? [:]
            var context = record["context"] as? [String: Any] ?? [:]
            context.removeValue(forKey: "storage_free")
            context["session_id"] = previous?.session_id
            context["foreground"] = previous.map { $0.state == "foreground" }
            record["context"] = context
            if seen.insert(id).inserted { recovered.append(record) }
        }

        let cap = min(20, max(1, config?.maxCrashRecords ?? 20))
        if recovered.count > cap {
            let excess = recovered.count - cap
            recovered = Array(recovered.suffix(cap))
            store.noteDropped(excess)
        }
        guard !recovered.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: recovered),
              (try? data.write(to: recoveryURL, options: .atomic)) != nil else { return }
        // 先冻结原构建/会话与稳定 ID，再入队、同步、清源；失败后跨启动仍用同一份记录。
        var allAppended = true
        for record in recovered { allAppended = store.appendMerged(record) && allAppended }
        if allAppended, store.synchronizeQueue(), store.resetCrashFile() {
            try? FileManager.default.removeItem(at: recoveryURL)
        }
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
        stateLock.lock()
        guard lastLifecycle != true else { stateLock.unlock(); return }
        lastLifecycle = true; cachedForeground = true
        session?.mark(.foreground)
        stateLock.unlock()
        addBreadcrumb("lifecycle", "foreground")
    }

    public func enterBackground() {
        guard installed else { return }
        stateLock.lock()
        guard lastLifecycle != false else { stateLock.unlock(); return }
        lastLifecycle = false; cachedForeground = false
        session?.mark(.background)
        stateLock.unlock()
        addBreadcrumb("lifecycle", "background")
        #if canImport(UIKit)
        DispatchQueue.main.async { [weak self] in self?.flushInBackground() }
        #else
        Task { [weak self] in await self?.flush() }
        #endif
    }

    #if canImport(UIKit)
    @MainActor private func flushInBackground() {
        let lease = BackgroundLease()
        lease.identifier = UIApplication.shared.beginBackgroundTask(withName: "MooMonitor.flush") { [weak self, weak lease] in
            self?.cancelFlush()
            lease?.end()
        }
        Task { [weak self] in
            await self?.flush()
            await MainActor.run { lease.end() }
        }
    }

    private func cancelFlush() {
        stateLock.lock(); let task = flushTask; stateLock.unlock()
        task?.cancel()
    }
    #endif

    func recordLowMemory(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard installed else { return }
        stateLock.lock()
        if let last = lastMemoryWarning, now - last < 3600 { stateLock.unlock(); return }
        lastMemoryWarning = now
        stateLock.unlock()
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
        guard installed, let clean = Redactor.screen(name) else { return }
        stateLock.lock()
        guard screenValue != clean else { stateLock.unlock(); return }
        screenValue = clean
        stateLock.unlock()
        session?.markScreen(clean)
        addBreadcrumb("screen", clean)
    }

    public static func capture(_ error: Error, kind: String = "handled", extras: [String: Any] = [:]) {
        shared.capture(error, kind: kind, extras: extras)
    }

    /// 业务主动上报（导入失败、同步失败、SQLite 错误等）。默认不采样，由调用点决定。
    public func capture(_ error: Error, kind: String = "handled", extras: [String: Any] = [:]) {
        guard ["handled", "webview_gone"].contains(kind), installed, let store else { return }
        // NSError bridging can execute CustomNSError/LocalizedError getters.
        // A per-thread gate avoids recursion without locking around host code or
        // suppressing another thread. Native exception/signal paths bypass it.
        let threadState = Thread.current.threadDictionary
        guard threadState[captureThreadKey] == nil else { return }
        threadState[captureThreadKey] = true
        defer { threadState.removeObject(forKey: captureThreadKey) }
        var payload = extras
        let ns = error as NSError
        payload["domain"] = ns.domain
        payload["code"] = ns.code
        let record = buildRecord(
            kind: kind,
            name: Redactor.truncate(Redactor.scrub(ns.domain) ?? "Error", bytes: 192) + "#" + String(ns.code),
            message: error.localizedDescription,
            stack: Thread.callStackSymbols.joined(separator: "\n"),
            frames: [],
            extras: payload
        )
        store.appendMerged(record)
    }

    /// Fixed host code labels only, such as sync / reader.identity.ok. No values
    /// or arbitrary request information; breadcrumbs do not create upload events.
    public static func breadcrumb(_ type: String, _ name: String) { shared.breadcrumb(type, name) }

    public func breadcrumb(_ type: String, _ name: String) {
        guard type.utf8.count <= 16, name.utf8.count <= 64,
              type.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) == (type.startIndex..<type.endIndex),
              name.range(of: "^[a-z][a-z0-9_]*(?:\\.[a-z][a-z0-9_]*){1,5}$", options: .regularExpression) == (name.startIndex..<name.endIndex),
              Redactor.scrub(name) == name else { return }
        appendBreadcrumb(type, name, coalesce: true)
    }

    public func addBreadcrumb(_ type: String, _ name: String) {
        // Keep the existing entry point's occurrence semantics for consumers.
        appendBreadcrumb(type, name, coalesce: false)
    }

    private func appendBreadcrumb(_ type: String, _ name: String, coalesce: Bool) {
        guard installed else { return }
        breadcrumbLock.lock(); defer { breadcrumbLock.unlock() }
        let entry = (at: Date(), type: String((Redactor.scrub(type) ?? "").prefix(16)), name: String((Redactor.scrub(name) ?? "").prefix(64)))
        stateLock.lock()
        // Sync can repeat one request many times. Keep state transitions without
        // rewriting the crash-recovery file for every identical adjacent entry.
        if coalesce, let last = breadcrumbs.last, last.type == entry.type, last.name == entry.name { stateLock.unlock(); return }
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
        // 异常可能发生在持有 stateLock 的线程；不能经 installed 的阻塞 getter。
        guard stateLock.try() else { return }
        let active = installedFlag && !disabledValue
        let config = self.config
        stateLock.unlock()
        guard active, let config else { return }
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
        await currentFlushTask()?.value
    }

    private func currentFlushTask() -> Task<Void, Never>? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard installedFlag, !disabledValue, let uploader else { return nil }
        if let flushTask { return flushTask }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishedFlush() }
            while !Task.isCancelled {
                let outcome = await uploader.flush()
                if outcome == .disabled {
                    self.markDisabled()
                    return
                }
                if outcome == .more { continue }
                guard case .retry(let reason) = outcome,
                      reason != "exhausted", reason != "cancelled", reason != "busy",
                      let state = self.store?.retryState(), state.attempts < 6 else { return }
                let delay = max(1, state.nextAt - Date().timeIntervalSince1970)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
        flushTask = task
        return task
    }

    private func finishedFlush() {
        stateLock.lock(); flushTask = nil; stateLock.unlock()
    }

    private func markDisabled() {
        stateLock.lock(); disabledValue = true; stateLock.unlock()
        moo_crash_set_enabled(0)
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
            if stateLock.try() {
                context["foreground"] = cachedForeground
                stateLock.unlock()
            }
        } else {
            context = ["install_id": installId, "session_id": sessionId]
            if let resolvedScreen { context["screen"] = resolvedScreen }
            stateLock.lock(); context["foreground"] = cachedForeground; stateLock.unlock()
            context["storage_free"] = deviceSnapshot["storage_free"]
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
                "message": Redactor.truncate(Redactor.scrub(message ?? "") ?? "", bytes: 8 * 1024),
                "stack": Redactor.scrub(stack ?? "") ?? "",
            ],
            "frames": frames,
            "device": deviceSnapshot.isEmpty ? DeviceInfo.device() : deviceSnapshot,
            "context": context,
        ]

        let crumbs = breadcrumbOverride ?? breadcrumbPayload(avoidBlocking: safe)
        if !crumbs.isEmpty { record["breadcrumbs"] = crumbs }

        let dropped = safe ? 0 : (store?.dropped ?? 0)
        let payload = Redactor.payload(extras, dropped: dropped)
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
        case "low_memory", "termination": return "warning"
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

#if canImport(UIKit)
@MainActor private final class BackgroundLease {
    var identifier = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
