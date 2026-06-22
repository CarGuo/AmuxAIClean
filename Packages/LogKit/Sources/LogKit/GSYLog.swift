import Foundation
import os

/// GSYCleanMac 统一日志门面。
///
/// 设计目标（v1.3.zzzz Phase 6）：
/// 1) **OSLog 双写**：每条日志同时进入系统 unified logging（Console.app 实时可见）
///    + 文件 sink（[LogFileSink](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LogKit/Sources/LogKit/LogFileSink.swift) 按天滚动到 ~/Library/Logs/GSYCleanMac/）。
/// 2) **关键链路埋点**：扫描启动/取消、删除链路、安全引擎 forbid 命中、网络更新、
///    DB open/migrate/clear/vacuum、TreeBrowser 子树加载——出问题时直接 grep 当天 log。
/// 3) **零依赖**：只依赖 Foundation + os；可被任何下层包（SafetyKit / ScanKit）反向依赖。
/// 4) **Sendable 安全**：内部状态全部由 `LogStateBox` actor 化包装，调用点都是 nonisolated 同步入口。
public enum GSYLog {

    public enum Level: Int, Sendable, Comparable, CustomStringConvertible {
        case debug = 0
        case info = 1
        case notice = 2
        case warning = 3
        case error = 4

        public var description: String {
            switch self {
            case .debug:   return "DEBUG"
            case .info:    return "INFO"
            case .notice:  return "NOTICE"
            case .warning: return "WARN"
            case .error:   return "ERROR"
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var osLogType: OSLogType {
            switch self {
            case .debug:   return .debug
            case .info:    return .info
            case .notice:  return .default
            case .warning: return .default
            case .error:   return .error
            }
        }
    }

    /// 已知子系统枚举。新增链路在此扩展，避免 stringly-typed 漂移。
    public enum Subsystem: String, Sendable, CaseIterable {
        case app        = "App"
        case scan       = "Scan"
        case db         = "DB"
        case tree       = "Tree"
        case safety     = "Safety"
        case trash      = "Trash"
        case operation  = "Operation"
        case flow       = "Flow"
        case updater    = "Updater"
        case settings   = "Settings"
        case regression = "Regression"
        case sentinel   = "Sentinel"
    }

    // MARK: - 配置

    /// 全局默认门槛。Debug build 默认 .debug，Release 默认 .info。
    ///
    /// v1.5.7：原先使用 `nonisolated(unsafe)` 假设"启动期一次性 set"，但生产代码同时存在
    /// 测试中的 `configure(...) / disableFileSink()` 反复调用，理论上构成 data race
    /// （TSAN 在并发跑日志 + 配置切换时会报）。改为以 `os_unfair_lock` 保护 `minimumLevel`
    /// 与 `fileSink` 的读写，避免极端情况下读到撕裂值（fileSink 是引用类型，撕裂可能 ARC 计数错配 → 释放后访问）。
    /// 锁是 < 50ns 量级，对热路径影响可忽略。
    nonisolated(unsafe) private static var _configLock = os_unfair_lock()
    nonisolated(unsafe) private static var _minimumLevel: Level = {
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }()

    /// 文件 sink。可选——只配 OSLog 不落盘也合法。
    nonisolated(unsafe) private static var _fileSink: LogFileSink?

    /// 读取当前 minimumLevel（持锁快照）。
    private static var minimumLevel: Level {
        os_unfair_lock_lock(&_configLock)
        defer { os_unfair_lock_unlock(&_configLock) }
        return _minimumLevel
    }

    /// 读取当前 fileSink（持锁快照，返回的引用本身随后被调用方持有，足够安全）。
    private static var fileSink: LogFileSink? {
        os_unfair_lock_lock(&_configLock)
        defer { os_unfair_lock_unlock(&_configLock) }
        return _fileSink
    }

    /// 主 App 启动期一次性配置。再次调用会替换 fileSink，但旧 sink 会被释放（句柄关闭）。
    public static func configure(minimumLevel: Level = .debug, fileSink: LogFileSink? = nil) {
        os_unfair_lock_lock(&_configLock)
        Self._minimumLevel = minimumLevel
        Self._fileSink = fileSink
        os_unfair_lock_unlock(&_configLock)
    }

    /// 关掉文件落盘（测试场景或用户在 UI 关 debug 落盘）。
    public static func disableFileSink() {
        os_unfair_lock_lock(&_configLock)
        Self._fileSink = nil
        os_unfair_lock_unlock(&_configLock)
    }

    /// 当前文件 sink 的根目录，UI 「打开日志目录」按钮要用。
    public static var currentLogDirectory: URL? { fileSink?.directory }

    /// 当前活跃文件 URL（按天滚动当天那个），UI 「查看今日日志」按钮要用。
    public static func currentLogFileURL() -> URL? { fileSink?.currentFileURL }

    /// 当前所有滚动日志文件，按文件名升序。
    public static func currentLogFiles() -> [URL] { fileSink?.logFiles() ?? [] }

    /// 导出所有滚动日志到一个 UTF-8 文本文件。
    public static func exportLogs(to destination: URL) throws {
        guard let sink = fileSink else { return }
        try sink.exportCombined(to: destination)
    }

    /// 清理所有滚动日志并重新打开当天空日志。
    @discardableResult
    public static func clearLogs() throws -> Int {
        guard let sink = fileSink else { return 0 }
        return try sink.clearLogs()
    }

    // MARK: - 调用入口

    public static func debug(
        _ subsystem: Subsystem,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) { emit(.debug, subsystem, message(), file: file, line: line) }

    public static func info(
        _ subsystem: Subsystem,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) { emit(.info, subsystem, message(), file: file, line: line) }

    public static func notice(
        _ subsystem: Subsystem,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) { emit(.notice, subsystem, message(), file: file, line: line) }

    public static func warning(
        _ subsystem: Subsystem,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) { emit(.warning, subsystem, message(), file: file, line: line) }

    public static func error(
        _ subsystem: Subsystem,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) { emit(.error, subsystem, message(), file: file, line: line) }

    // MARK: - 内部分发

    private static func emit(
        _ level: Level,
        _ subsystem: Subsystem,
        _ message: String,
        file: StaticString,
        line: UInt
    ) {
        guard level >= minimumLevel else { return }
        let logger = osLogger(for: subsystem)
        // OSLog：保持 %{public}@ 让 Console.app 显示明文（日志仅本机持久化，不上报）。
        logger.log(level: level.osLogType, "\(message, privacy: .public)")

        // 文件 sink。
        if let sink = fileSink {
            let line = renderLine(level: level, subsystem: subsystem, message: message, file: file, line: line)
            sink.append(line)
        }
    }

    private static func renderLine(
        level: Level,
        subsystem: Subsystem,
        message: String,
        file: StaticString,
        line: UInt
    ) -> String {
        let ts = ISO8601DateFormatter.gsyShared.string(from: Date())
        // file 用 fileID 形式 "PackageName/File.swift"，截只留 basename。
        let f = "\(file)"
        let basename = f.split(separator: "/").last.map(String.init) ?? f
        return "\(ts) [\(level)] [\(subsystem.rawValue)] \(message) (\(basename):\(line))\n"
    }

    private static let loggerCache = LoggerCache()

    private static func osLogger(for subsystem: Subsystem) -> os.Logger {
        loggerCache.logger(for: subsystem)
    }
}

// MARK: - LoggerCache

/// 进程内 os.Logger 实例缓存。Logger 内部也轻量，但缓存避免每条日志构造一次。
private final class LoggerCache: @unchecked Sendable {
    private let lock = NSLock()
    private var loggers: [GSYLog.Subsystem: os.Logger] = [:]
    private let bundleSubsystem = "com.guoshuyu.cleanmac"

    func logger(for s: GSYLog.Subsystem) -> os.Logger {
        lock.lock(); defer { lock.unlock() }
        if let existing = loggers[s] { return existing }
        let new = os.Logger(subsystem: bundleSubsystem, category: s.rawValue)
        loggers[s] = new
        return new
    }
}

// MARK: - 时间戳

extension ISO8601DateFormatter {
    /// 共享格式化器：ISO8601 + 毫秒。日志单文件常 10w+ 条，重复构造 formatter 是常见性能杀手。
    /// nonisolated(unsafe)：ISO8601DateFormatter 的 string(from:) 在 Apple 文档上是线程安全的
    /// （CFDateFormatter 内部带锁），但 Swift 6 strict concurrency 不能从声明判断。
    nonisolated(unsafe) static let gsyShared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
