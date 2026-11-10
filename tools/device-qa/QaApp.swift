import SwiftUI
import MooMonitor

@main @MainActor struct MonitorQaApp: App {
    @State private var started = false
    init() {
        let args = ProcessInfo.processInfo.arguments
        let endpoint = args.dropFirst(2).first ?? "http://127.0.0.1:18765"
        let token = args.dropFirst(3).first ?? "moo_deviceqa_only_20261110_token_A"
        MooMonitor.install(MonitorConfig(endpoint: endpoint, token: token, release: "qa-old", build: "1", env: "debug"))
    }

    private func runScenario() {
        UIApplication.shared.isIdleTimerDisabled = true
        let args = ProcessInfo.processInfo.arguments
        let endpoint = args.dropFirst(2).first ?? "http://127.0.0.1:18765"
        MooMonitor.enterForeground()
        MooMonitor.screen("DeviceQaView")
        let mode = args.dropFirst().first ?? "status"
        Task {
            var diagnostics: [String: Any] = ["application_state": UIApplication.shared.applicationState.rawValue]
            if let url = URL(string: endpoint + "/qa/summary") {
                var request = URLRequest(url: url); request.timeoutInterval = 5
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    diagnostics["http"] = (response as? HTTPURLResponse)?.statusCode ?? 0
                } catch {
                    let error = error as NSError
                    diagnostics["domain"] = error.domain; diagnostics["code"] = error.code
                    let detail = String(describing: error.userInfo).lowercased()
                    diagnostics["local_network_denied"] = detail.contains("local network prohibited") || detail.contains("localnetworkdenied")
                }
            }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("qa-network.json")
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics) { try? data.write(to: url, options: .atomic) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // 非崩溃场景结束前写干净生命周期；runner的强制重启不能制造额外termination。
            if !["fatal", "unwrapped", "exception"].contains(mode) { MooMonitor.enterBackground() }
            switch mode {
            case "fatal": fatalError("monitor-fixture")
            case "unwrapped": let value: Int? = nil; _ = value!
            case "exception": NSException(name: .init("MonitorQaException"), reason: "fixture", userInfo: nil).raise()
            case "handled", "batch", "pair", "queue":
                for _ in 0..<(mode == "batch" ? 180 : (mode == "pair" ? 2 : 1)) {
                    MooMonitor.capture(NSError(domain: "qa", code: 7, userInfo: [NSLocalizedDescriptionKey: "fixture token=tiny file:///private/var/test book.txt"]), extras: ["area": "qa", "token": "tiny"])
                }
                if mode == "queue" { report(mode) }
                else { Task { await MooMonitor.shared.flush(); report(mode) } }
            case "drain": Task { await MooMonitor.shared.flush(); report(mode) }
            default: report(mode)
            }
        }
    }
    var body: some Scene {
        // 生命周期由各QA动作显式控制，runner的强制重启不应制造额外termination。
        WindowGroup {
            Text("Monitor QA").task {
                guard !started else { return }
                started = true
                while UIApplication.shared.applicationState != .active {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                runScenario()
            }
        }
    }
}

private func report(_ mode: String) {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("monitor")
    let queue = (try? String(contentsOf: base.appendingPathComponent("queue.jsonl"), encoding: .utf8)) ?? ""
    let payload: [String: Any] = ["nonce": ProcessInfo.processInfo.arguments.dropFirst(4).first ?? "", "mode": mode, "disabled": MooMonitor.shared.disabled,
        "pending": queue.split(separator: "\n").count, "queue": queue, "at": Date().timeIntervalSince1970]
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("qa-summary.json")
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
}
