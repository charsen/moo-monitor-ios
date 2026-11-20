import Foundation

/// The reporting period is the best timestamp MetricKit supplies for these
/// diagnostics. Its end is used for intake and both bounds remain available.
struct MetricKitReport {
    let kind: String
    let name: String
    let message: String
    let period: DateInterval
    let release: String?
    let build: String?
    var frames: [[String: Any]] = []
    var device: [String: String] = [:]
    var extras: [String: Any] = [:]
}

/// A normal-only or empty aggregate does not belong in the issue stream.
/// Background memory pressure is distinct from exceeding the process limit.
enum MetricKitExitHint {
    static func classify(memory: Bool, watchdog: Bool, abnormal: Bool, memoryPressure: Bool,
                         cpuLimit: Bool, backgroundTimeout: Bool, suspendedWithLockedFile: Bool) -> String? {
        if memory { return "oom_suspect" }
        if watchdog { return "watchdog_suspect" }
        if abnormal { return "crash_suspect" }
        if memoryPressure { return "background_memory_pressure" }
        if cpuLimit { return "background_cpu_limit" }
        if backgroundTimeout { return "background_task_timeout" }
        if suspendedWithLockedFile { return "background_suspended_with_locked_file" }
        return nil
    }
}

#if os(iOS) && canImport(MetricKit)
import MetricKit

/// Capture delayed OS reports using their own version and time window.
final class MetricKitObserver: NSObject, MXMetricManagerSubscriber {
    private let sink: (MetricKitReport) -> Void
    private let config: MonitorConfig
    private let appUUID: String?

    init(config: MonitorConfig, appUUID: String?, sink: @escaping (MetricKitReport) -> Void) {
        self.config = config
        self.appUUID = appUUID
        self.sink = sink
    }

    func start() { MXMetricManager.shared.add(self) }

    private func int(_ n: NSNumber?) -> Int { Int(truncating: n ?? NSNumber(value: -1)) }

    private func device(_ metadata: MXMetaData?) -> [String: String] {
        guard let metadata else { return [:] }
        return ["os": "iOS", "os_version": metadata.osVersion, "model": metadata.deviceType,
                "manufacturer": "Apple", "abi": metadata.platformArchitecture]
    }

    private func frames(_ tree: MXCallStackTree, release: String, build: String) -> [[String: Any]] {
        // The currently loaded executable UUID cannot classify an old build's frames.
        let currentUUID = release == config.release && build == config.build ? appUUID : nil
        return MetricKitStackDecoder.frames(from: tree, limit: 32, appUUID: currentUUID)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let start = payload.timeStampBegin, end = payload.timeStampEnd
            guard start <= end else { continue }
            let period = DateInterval(start: start, end: end)
            for crash in payload.crashDiagnostics ?? [] {
                let metadata = crash.metaData
                let release = crash.applicationVersion, build = metadata.applicationBuildVersion
                let stack = frames(crash.callStackTree, release: release, build: build)
                let signal = int(crash.signal)
                let exceptionType = int(crash.exceptionType)
                let reason = crash.terminationReason ?? "-"
                sink(MetricKitReport(kind: "crash", name: "metrickit_crash",
                                     message: "MetricKit crash signal=\(signal) exception=\(exceptionType) reason=\(reason)",
                                     period: period, release: release, build: build, frames: stack, device: device(metadata),
                                     extras: ["subtype": "crash", "signal": signal, "exception_type": exceptionType,
                                              "termination_reason": reason, "frame_count": stack.count]))
            }
            for hang in payload.hangDiagnostics ?? [] {
                let metadata = hang.metaData
                let release = hang.applicationVersion, build = metadata.applicationBuildVersion
                let ms = Int(hang.hangDuration.converted(to: .milliseconds).value)
                let stack = frames(hang.callStackTree, release: release, build: build)
                sink(MetricKitReport(kind: "termination", name: "metrickit_hang", message: "MetricKit hang duration_ms=\(ms)",
                                     period: period, release: release, build: build, frames: stack, device: device(metadata),
                                     extras: ["subtype": "hang", "duration_ms": ms, "frame_count": stack.count]))
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let start = payload.timeStampBegin, end = payload.timeStampEnd
            guard start <= end, let exit = payload.applicationExitMetrics else { continue }
            let fg = exit.foregroundExitData, bg = exit.backgroundExitData
            let memory = fg.cumulativeMemoryResourceLimitExitCount + bg.cumulativeMemoryResourceLimitExitCount
            let watchdog = fg.cumulativeAppWatchdogExitCount + bg.cumulativeAppWatchdogExitCount
            let abnormal = fg.cumulativeBadAccessExitCount + fg.cumulativeIllegalInstructionExitCount +
                fg.cumulativeAbnormalExitCount + bg.cumulativeBadAccessExitCount + bg.cumulativeIllegalInstructionExitCount +
                bg.cumulativeAbnormalExitCount
            guard let hint = MetricKitExitHint.classify(
                memory: memory > 0, watchdog: watchdog > 0, abnormal: abnormal > 0,
                memoryPressure: bg.cumulativeMemoryPressureExitCount > 0, cpuLimit: bg.cumulativeCPUResourceLimitExitCount > 0,
                backgroundTimeout: bg.cumulativeBackgroundTaskAssertionTimeoutExitCount > 0,
                suspendedWithLockedFile: bg.cumulativeSuspendedWithLockedFileExitCount > 0
            ) else { continue }
            // Cumulative totals spanning an update cannot be assigned to a single build.
            let mixed = payload.includesMultipleApplicationVersions
            sink(MetricKitReport(kind: "termination", name: "metrickit_app_exit",
                                 message: "app_exit hint=\(hint) mem=\(memory) watchdog=\(watchdog) abnormal=\(abnormal)",
                                 period: DateInterval(start: start, end: end),
                                 release: mixed ? nil : payload.latestApplicationVersion,
                                 build: mixed ? nil : payload.metaData?.applicationBuildVersion,
                                 device: mixed ? [:] : device(payload.metaData),
                                 extras: ["subtype": "app_exit", "exit_hint": hint,
                                          "multiple_application_versions": mixed,
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
                                          "bg_bad_access": bg.cumulativeBadAccessExitCount,
                                          "bg_abnormal": bg.cumulativeAbnormalExitCount,
                                          "bg_illegal_instruction": bg.cumulativeIllegalInstructionExitCount,
                                          "bg_memory_pressure": bg.cumulativeMemoryPressureExitCount,
                                          "bg_task_timeout": bg.cumulativeBackgroundTaskAssertionTimeoutExitCount,
                                          "bg_suspended_locked_file": bg.cumulativeSuspendedWithLockedFileExitCount]))
        }
    }
}
#endif
