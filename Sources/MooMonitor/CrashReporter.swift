import Foundation

/// `NSSetUncaughtExceptionHandler` 只在 ObjC 异常穿出主 runloop 时触发；
/// 纯 Swift 的 `fatalError` / 数组越界 / 强制解包 nil 走信号路径，不在这里。
///
/// 异常处理器是普通上下文（不是信号上下文），可以分配内存、拼 JSON、写队列。
/// 写完直接返回，让系统原来的终止流程继续——不调用 `exit`，也不吞掉异常。
enum CrashReporter {

    private static var handler: ((String, String?, [String]) -> Void)?
    private static let lock = NSLock()

    static func install(_ handler: @escaping (String, String?, [String]) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
        NSSetUncaughtExceptionHandler(mooExceptionHandler)
    }

    fileprivate static func handle(_ exception: NSException) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(exception.name.rawValue, exception.reason, exception.callStackSymbols)
    }
}

/// C 函数入口：`NSSetUncaughtExceptionHandler` 只接受无捕获的函数指针。
private func mooExceptionHandler(_ exception: NSException) {
    CrashReporter.handle(exception)
}
