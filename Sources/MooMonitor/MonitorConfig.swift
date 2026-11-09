import Foundation

/// SDK 配置。token 为空即整体禁用——没有凭据就不发请求。
public struct MonitorConfig {
    public var endpoint: String
    public var token: String
    public var app: String
    public var release: String
    public var build: String
    public var env: String
    public var maxQueueRecords: Int
    public var maxQueueBytes: Int
    public var maxCrashRecords: Int

    public init(
        endpoint: String = "https://c.mooeen.com",
        token: String,
        app: String = "shuhe",
        release: String = "",
        build: String = "",
        env: String = "release",
        maxQueueRecords: Int = 200,
        maxQueueBytes: Int = 2 * 1024 * 1024,
        maxCrashRecords: Int = 20
    ) {
        self.endpoint = endpoint
        self.token = token
        self.app = app
        self.release = release
        self.build = build
        self.env = env
        self.maxQueueRecords = maxQueueRecords
        self.maxQueueBytes = maxQueueBytes
        self.maxCrashRecords = maxCrashRecords
    }

    public var enabled: Bool { !token.isEmpty && !endpoint.isEmpty }
}
