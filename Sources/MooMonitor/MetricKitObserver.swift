import Foundation
#if os(iOS) && canImport(MetricKit)
import MetricKit

/// MetricKit 采集：系统在下次启动投递诊断/指标负载，覆盖信号处理器抓不到的
/// OOM（内存超限）、watchdog、hang。只把摘要写入现有事件队列（复用 crash /
/// termination 两类 kind），不新增服务端 kind。
@available(iOS 14.0, *)
final class MetricKitObserver: NSObject, MXMetricManagerSubscriber {
    typealias Sink = (_ kind: String, _ name: String, _ message: String, _ extras: [String: Any]) -> Void
    private let sink: Sink
    init(sink: @escaping Sink) { self.sink = sink }

    func start() { MXMetricManager.shared.add(self) }

    private func int(_ n: NSNumber?) -> Int { Int(truncating: n ?? NSNumber(value: -1)) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                sink("crash", "metrickit_crash", "MetricKit crash diagnostic", [
                    "subtype": "crash",
                    "signal": int(crash.signal),
                    "exception_type": int(crash.exceptionType),
                    "termination_reason": crash.terminationReason ?? "",
                    "stack": tree(crash.callStackTree),
                ])
            }
            for hang in payload.hangDiagnostics ?? [] {
                sink("termination", "metrickit_hang", "MetricKit hang diagnostic", [
                    "subtype": "hang",
                    "duration_ms": Int(hang.hangDuration.converted(to: .milliseconds).value),
                    "stack": tree(hang.callStackTree),
                ])
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exit = payload.applicationExitMetrics else { continue }
            let fg = exit.foregroundExitData, bg = exit.backgroundExitData
            sink("termination", "metrickit_app_exit", "MetricKit app exit metric", [
                "subtype": "app_exit",
                "fg_normal": fg.cumulativeNormalAppExitCount,
                "fg_watchdog": fg.cumulativeAppWatchdogExitCount,
                "fg_memory": fg.cumulativeMemoryResourceLimitExitCount,
                "fg_bad_access": fg.cumulativeBadAccessExitCount,
                "fg_abnormal": fg.cumulativeAbnormalExitCount,
                "fg_illegal_instruction": fg.cumulativeIllegalInstructionExitCount,
                "bg_normal": bg.cumulativeNormalAppExitCount,
                "bg_memory": bg.cumulativeMemoryResourceLimitExitCount,
                "bg_watchdog": bg.cumulativeAppWatchdogExitCount,
                "bg_cpu": bg.cumulativeCPUResourceLimitExitCount,
            ])
        }
    }

    private func tree(_ t: MXCallStackTree) -> String {
        String(decoding: t.jsonRepresentation().prefix(32 * 1024), as: UTF8.self)
    }
}
#endif
