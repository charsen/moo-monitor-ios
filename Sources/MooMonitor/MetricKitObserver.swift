import Foundation
#if os(iOS) && canImport(MetricKit)
import MetricKit

/// MetricKit 采集：系统在下次启动投递诊断/指标负载，覆盖信号处理器抓不到的
/// OOM（内存超限）、watchdog、hang。复用 crash/termination 两类 kind；
/// 栈解析为紧凑帧（MetricKitStackDecoder），供云端按 dSYM 符号化。
@available(iOS 14.0, *)
final class MetricKitObserver: NSObject, MXMetricManagerSubscriber {
    typealias Sink = (_ kind: String, _ name: String, _ message: String, _ extras: [String: Any]) -> Void
    private let sink: Sink
    private let appUUID: String?

    init(appUUID: String? = nil, sink: @escaping Sink) {
        self.appUUID = appUUID
        self.sink = sink
    }

    func start() { MXMetricManager.shared.add(self) }

    private func int(_ n: NSNumber?) -> Int { Int(truncating: n ?? NSNumber(value: -1)) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let frames = MetricKitStackDecoder.frames(from: crash.callStackTree, limit: 32, appUUID: appUUID)
                let signal = int(crash.signal)
                let exceptionType = int(crash.exceptionType)
                let reason = crash.terminationReason ?? "-"
                sink("crash", "metrickit_crash",
                     "MetricKit crash signal=\(signal) exception=\(exceptionType) reason=\(reason)",
                     ["subtype": "crash", "signal": signal, "exception_type": exceptionType,
                      "termination_reason": reason, "frame_count": frames.count, "frames": frames])
            }
            for hang in payload.hangDiagnostics ?? [] {
                let ms = Int(hang.hangDuration.converted(to: .milliseconds).value)
                let frames = MetricKitStackDecoder.frames(from: hang.callStackTree, limit: 32, appUUID: appUUID)
                sink("termination", "metrickit_hang", "MetricKit hang duration_ms=\(ms)",
                     ["subtype": "hang", "duration_ms": ms, "frame_count": frames.count, "frames": frames])
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exit = payload.applicationExitMetrics else { continue }
            let fg = exit.foregroundExitData, bg = exit.backgroundExitData
            let fgMemory = fg.cumulativeMemoryResourceLimitExitCount + bg.cumulativeMemoryResourceLimitExitCount
            let watchdog = fg.cumulativeAppWatchdogExitCount + bg.cumulativeAppWatchdogExitCount
            let abnormal = fg.cumulativeBadAccessExitCount + fg.cumulativeIllegalInstructionExitCount + fg.cumulativeAbnormalExitCount
            let hint: String
            if fgMemory > 0 { hint = "oom_suspect" }
            else if watchdog > 0 { hint = "watchdog_suspect" }
            else if abnormal > 0 { hint = "crash_suspect" }
            else { hint = "normal" }
            sink("termination", "metrickit_app_exit",
                 "app_exit hint=\(hint) mem=\(fgMemory) watchdog=\(watchdog) abnormal=\(abnormal)",
                 ["subtype": "app_exit", "exit_hint": hint,
                  "fg_normal": fg.cumulativeNormalAppExitCount,
                  "fg_watchdog": fg.cumulativeAppWatchdogExitCount,
                  "fg_memory": fg.cumulativeMemoryResourceLimitExitCount,
                  "fg_bad_access": fg.cumulativeBadAccessExitCount,
                  "fg_abnormal": fg.cumulativeAbnormalExitCount,
                  "fg_illegal_instruction": fg.cumulativeIllegalInstructionExitCount,
                  "bg_normal": bg.cumulativeNormalAppExitCount,
                  "bg_memory": bg.cumulativeMemoryResourceLimitExitCount,
                  "bg_watchdog": bg.cumulativeAppWatchdogExitCount,
                  "bg_cpu": bg.cumulativeCPUResourceLimitExitCount])
        }
    }
}
#endif
