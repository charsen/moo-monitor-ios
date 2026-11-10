import Foundation

/// 安装时冻结处理链；异常发生时不等待任何可能被崩溃线程持有的锁。
enum CrashReporter {
    private static var handler: ((String, String?, [String]) -> Void)?
    private static var previous: NSUncaughtExceptionHandler?

    static func install(_ handler: @escaping (String, String?, [String]) -> Void) {
        self.handler = handler
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(mooExceptionHandler)
    }

    fileprivate static func handle(_ exception: NSException) {
        handler?(exception.name.rawValue, exception.reason, exception.callStackSymbols)
        previous?(exception)
    }
}

private func mooExceptionHandler(_ exception: NSException) { CrashReporter.handle(exception) }
