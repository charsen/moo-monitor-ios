import Foundation

/// 上次会话的落盘标记。进程被 SIGKILL / watchdog / OOM 杀死时没有回调，
/// 只能靠「上次停在 foreground，这次启动却没读到崩溃帧」推断一条 `termination`。
struct SessionState: Codable, Equatable {
    var session_id: String
    var started_at: Int64
    var updated_at: Int64
    var state: String
    var release: String
    var build: String
    /// 上次已知界面名。崩溃发生在下一次启动才组装记录，只能靠这里还原崩溃时界面。
    var env: String? = nil
    var device: [String: String]? = nil
    var screen: String?
}

/// 会话标记文件 `<monitor>/session.json`。
///
/// 不参与崩溃路径：崩溃处理器只写 `crash.bin`，这里全部发生在正常启动/前后台切换。
final class SessionMarker {
    private let lock = NSLock()

    enum State: String {
        case starting
        case foreground
        case background
    }

    private let dir: URL
    private let config: MonitorConfig
    private let device: [String: String]?

    init(directory: URL, config: MonitorConfig, device: [String: String]? = nil) {
        self.dir = directory
        self.config = config
        self.device = device
    }

    private var fileURL: URL { dir.appendingPathComponent("session.json") }

    /// 读取上次会话，然后立即把本次会话写成 `starting`。
    /// 返回的旧状态用于启动时的脏退出推断——必须先读后写。
    func begin(sessionId: String, now: Date = Date()) -> SessionState? {
        lock.lock(); defer { lock.unlock() }
        let previous = read()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        write(SessionState(
            session_id: sessionId,
            started_at: ms,
            updated_at: ms,
            state: State.starting.rawValue,
            release: config.release,
            build: config.build,
            env: config.env,
            device: device,
            screen: nil
        ))
        return previous
    }

    /// 前台/后台切换。只更新状态与时间；进程随时可能在这里之后被杀。
    func mark(_ state: State, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard var current = read() else {
            // 标记文件丢了（清理/首次安装）：补一个本进程的标记，不推断历史。
            write(SessionState(
                session_id: UUID().uuidString,
                started_at: Int64(now.timeIntervalSince1970 * 1000),
                updated_at: Int64(now.timeIntervalSince1970 * 1000),
                state: state.rawValue,
                release: config.release,
                build: config.build,
                env: config.env,
                device: device,
                screen: nil
            ))
            return
        }
        current.state = state.rawValue
        current.updated_at = Int64(now.timeIntervalSince1970 * 1000)
        write(current)
    }

    /// 界面切换时更新。只写一个短字符串，不涉及业务内容。
    func markScreen(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        guard var current = read() else { return }
        guard current.screen != name else { return }
        current.screen = name
        current.updated_at = Int64(Date().timeIntervalSince1970 * 1000)
        write(current)
    }

    func current() -> SessionState? {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func read() -> SessionState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    private func write(_ state: SessionState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        // write(options: .atomic) 会先写临时文件再 rename；前后台切换频率很低，足够便宜。
        try? data.write(to: fileURL, options: [.atomic])
    }
}
