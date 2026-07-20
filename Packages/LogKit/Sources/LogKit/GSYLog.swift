import Foundation
import os

/// GSYCleanMac 统一日志门面。
///
/// 设计目标（v1.3.zzzz Phase 6）：
/// 1) **OSLog 双写**：每条日志同时进入系统 unified logging（Console.app 实时可见）
///    + 文件 sink（[LogFileSink](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LogKit/Sources/LogKit/LogFileSink.swift) 按天滚动到 ~/Library/Logs/AmuxAIClean/）。
/// 2) **关键链路埋点**：扫描启动/取消、删除链路、安全引擎 forbid 命中、网络更新、
///    DB open/migrate/clear/vacuum、TreeBrowser 子树加载——出问题时直接 grep 当天 log。
/// 3) **零依赖**：只依赖 Foundation + os；可被任何下层包（SafetyKit / ScanKit）反向依赖。
/// 4) **Sendable 安全**：全局配置/启动缓冲由 unfair lock 原子交接，具体文件操作由 sink 的
///    utility 串行队列隔离；调用点保持 nonisolated 同步入口。
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
    /// Sink 构造失败时没有实例可以承载 health；保留同一闭集事实供设置页和 Help 菜单读取。
    nonisolated(unsafe) private static var _fileSinkInitializationFailure: LogFileSinkFailure?
    /// v2026.07.18 P1 startup fix: sink construction performs real filesystem work and therefore
    /// happens on a utility task. Until that revision finishes, early file-log lines stay in this
    /// bounded process-memory queue instead of either blocking App.init or disappearing.
    nonisolated(unsafe) private static var _fileSinkIsBootstrapping = false
    nonisolated(unsafe) private static var _startupBufferedLines: [String] = []
    nonisolated(unsafe) private static var _startupDroppedLineCount = 0
    nonisolated(unsafe) private static var _startupBufferCapacity = 256
    /// Every configuration change invalidates callbacks and completions owned by an older sink.
    nonisolated(unsafe) private static var _sinkGeneration: UInt64 = 0

    /// Process-wide relays deliberately outlive each concrete sink. Settings/Help can subscribe
    /// once and still observe background initialization, writer failure, retry, and replacement.
    private static let fileSinkHealthState = LogFileSinkHealthState(.disabled)
    private static let fileSinkIssueState = LogFileSinkIssueState()
    /// Superseded sinks remain process-owned until every append accepted before the configuration
    /// handoff has run and both descriptors have closed. The coordinator never waits under
    /// `_configLock`; it only exposes an async test/termination fence.
    private static let fileSinkRetirementCoordinator = LogFileSinkRetirementCoordinator()

    public struct FileSinkBootstrapRevision: Equatable, Sendable {
        fileprivate let rawValue: UInt64
    }

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

    private struct FileSinkSnapshot {
        let sink: LogFileSink?
        let initializationFailure: LogFileSinkFailure?
        let isBootstrapping: Bool

        var missingSinkFailure: LogFileSinkFailure {
            if isBootstrapping { return .initializing }
            return initializationFailure ?? .disabled
        }
    }

    /// Keep os_unfair_lock calls in a synchronous boundary; Swift correctly rejects direct use of
    /// that C API from an async function even when no suspension occurs inside the critical region.
    private static func fileSinkSnapshot() -> FileSinkSnapshot {
        os_unfair_lock_lock(&_configLock)
        defer { os_unfair_lock_unlock(&_configLock) }
        return FileSinkSnapshot(
            sink: _fileSink,
            initializationFailure: _fileSinkInitializationFailure,
            isBootstrapping: _fileSinkIsBootstrapping
        )
    }

    /// Starts a filesystem-free bootstrap revision. Construct `LogFileSink` on a background task,
    /// then complete or fail the exact returned revision so stale work cannot overwrite a newer
    /// configuration.
    @discardableResult
    public static func beginFileSinkBootstrap(
        minimumLevel: Level = .debug
    ) -> FileSinkBootstrapRevision {
        beginFileSinkBootstrap(minimumLevel: minimumLevel, startupBufferCapacity: 256)
    }

    /// Internal deterministic seam for proving overflow order without producing hundreds of logs.
    @discardableResult
    static func beginFileSinkBootstrap(
        minimumLevel: Level,
        startupBufferCapacity: Int
    ) -> FileSinkBootstrapRevision {
        os_unfair_lock_lock(&_configLock)
        let oldSink = _fileSink
        _sinkGeneration &+= 1
        let revision = FileSinkBootstrapRevision(rawValue: _sinkGeneration)
        _minimumLevel = minimumLevel
        _fileSink = nil
        _fileSinkInitializationFailure = nil
        _fileSinkIsBootstrapping = true
        _startupBufferedLines.removeAll(keepingCapacity: true)
        _startupDroppedLineCount = 0
        _startupBufferCapacity = max(1, startupBufferCapacity)
        fileSinkIssueState.replace(with: .empty)
        _ = fileSinkHealthState.update(.initializing)
        let retiringSink = enqueueRetirementLocked(oldSink, replacingWith: nil)
        os_unfair_lock_unlock(&_configLock)

        detachObservers(from: retiringSink)
        return revision
    }

    /// Installs one successfully constructed background sink and flushes every retained startup
    /// line into its serial queue before any concurrent post-startup line can be enqueued.
    @discardableResult
    public static func completeFileSinkBootstrap(
        _ sink: LogFileSink,
        revision: FileSinkBootstrapRevision
    ) -> Bool {
        os_unfair_lock_lock(&_configLock)
        guard _fileSinkIsBootstrapping, revision.rawValue == _sinkGeneration else {
            let currentSink = _fileSink
            let retiringSink = enqueueRetirementLocked(sink, replacingWith: currentSink)
            os_unfair_lock_unlock(&_configLock)
            // Ownership was handed to this completion API. A rejected stale sink must still close
            // asynchronously, unless the caller passed the exact instance already installed by a
            // newer revision.
            detachObservers(from: retiringSink)
            return false
        }

        _fileSink = sink
        _fileSinkInitializationFailure = nil
        if _startupDroppedLineCount > 0 {
            sink.append(renderStartupDropMarker(count: _startupDroppedLineCount))
        }
        for line in _startupBufferedLines { sink.append(line) }
        _startupBufferedLines.removeAll(keepingCapacity: false)
        _startupDroppedLineCount = 0
        _fileSinkIsBootstrapping = false
        fileSinkIssueState.replace(with: sink.issues)
        _ = fileSinkHealthState.update(sink.health)
        os_unfair_lock_unlock(&_configLock)

        attachObservers(to: sink, generation: revision.rawValue)
        return true
    }

    /// Main-App bootstrap now uses begin/complete. This immediate API remains useful to package
    /// tests and clients which already own a fully constructed sink.
    public static func configure(minimumLevel: Level = .debug, fileSink: LogFileSink? = nil) {
        os_unfair_lock_lock(&_configLock)
        let oldSink = _fileSink
        _sinkGeneration &+= 1
        let generation = _sinkGeneration
        _minimumLevel = minimumLevel
        _fileSink = fileSink
        _fileSinkInitializationFailure = nil
        _fileSinkIsBootstrapping = false
        _startupBufferedLines.removeAll(keepingCapacity: false)
        _startupDroppedLineCount = 0
        fileSinkIssueState.replace(with: fileSink?.issues ?? .empty)
        _ = fileSinkHealthState.update(fileSink?.health ?? .disabled)
        let retiringSink = enqueueRetirementLocked(oldSink, replacingWith: fileSink)
        os_unfair_lock_unlock(&_configLock)

        detachObservers(from: retiringSink)
        if let fileSink { attachObservers(to: fileSink, generation: generation) }
    }

    /// v2026.07.18 P2 diagnostics fix: initialization can fail before a sink exists. Record only
    /// the typed stage/domain/code so the UI can explain the missing file without persisting a raw
    /// Error or path into the system-managed fallback log.
    @discardableResult
    public static func reportFileSinkInitializationFailure(
        _ error: Error,
        revision: FileSinkBootstrapRevision? = nil
    ) -> Bool {
        let failure = LogFileSinkFailure.from(error, stage: .initialization)
        os_unfair_lock_lock(&_configLock)
        if let revision,
           (!_fileSinkIsBootstrapping || revision.rawValue != _sinkGeneration) {
            os_unfair_lock_unlock(&_configLock)
            return false
        }
        let oldSink = _fileSink
        if revision == nil { _sinkGeneration &+= 1 }
        _fileSink = nil
        _fileSinkInitializationFailure = failure
        _fileSinkIsBootstrapping = false
        _startupBufferedLines.removeAll(keepingCapacity: false)
        _startupDroppedLineCount = 0
        fileSinkIssueState.replace(with: .empty)
        _ = fileSinkHealthState.update(.unavailable(failure))
        let retiringSink = enqueueRetirementLocked(oldSink, replacingWith: nil)
        os_unfair_lock_unlock(&_configLock)
        detachObservers(from: retiringSink)
        // The file sink does not exist in this branch. Keep one independent, queryable event in
        // Console using only the normalized closed diagnostic tuple.
        LogFileSinkPublicDiagnostics.record(failure)
        return true
    }

    /// 关掉文件落盘（测试场景或用户在 UI 关 debug 落盘）。
    public static func disableFileSink() {
        os_unfair_lock_lock(&_configLock)
        let oldSink = _fileSink
        _sinkGeneration &+= 1
        _fileSink = nil
        _fileSinkInitializationFailure = nil
        _fileSinkIsBootstrapping = false
        _startupBufferedLines.removeAll(keepingCapacity: false)
        _startupDroppedLineCount = 0
        fileSinkIssueState.replace(with: .empty)
        _ = fileSinkHealthState.update(.disabled)
        let retiringSink = enqueueRetirementLocked(oldSink, replacingWith: nil)
        os_unfair_lock_unlock(&_configLock)
        detachObservers(from: retiringSink)
    }

    /// Package-test seam for proving that configure/disable return immediately while old sinks
    /// still have an explicit, awaitable drain owner. Production code does not need to wait.
    static func waitForFileSinkRetirementsForTesting() async {
        await fileSinkRetirementCoordinator.waitUntilIdle()
    }

    public static var fileSinkHealth: LogFileSinkHealth {
        fileSinkHealthState.snapshot
    }

    /// The stream follows the process-wide lifecycle rather than one replaceable sink instance.
    public static func fileSinkHealthUpdates() -> AsyncStream<LogFileSinkHealth> {
        fileSinkHealthState.stream()
    }

    public static var fileSinkIssues: LogFileSinkIssueSnapshot {
        fileSinkIssueState.snapshot
    }

    public static func fileSinkIssueUpdates() -> AsyncStream<LogFileSinkIssueSnapshot> {
        fileSinkIssueState.stream()
    }

    /// Returns the actual configured sink directory only after it has been revalidated. UI
    /// callers must consume the typed failure and must not reconstruct a parallel path contract.
    public static func prepareLogDirectoryForAccess() async -> Result<URL, LogFileSinkFailure> {
        let snapshot = fileSinkSnapshot()
        if let sink = snapshot.sink { return await sink.prepareDirectoryForAccess() }
        return .failure(snapshot.missingSinkFailure)
    }

    /// 当前文件 sink 的根目录，UI 「打开日志目录」按钮要用。
    public static var currentLogDirectory: URL? { fileSink?.directory }

    /// 当前活跃文件 URL（按天滚动当天那个），UI 「查看今日日志」按钮要用。
    public static func currentLogFileURL() async -> URL? {
        guard let sink = fileSink else { return nil }
        return await sink.currentFileURLSnapshot()
    }

    /// 当前所有滚动日志文件，按文件名升序。
    public static func currentLogFiles() async -> Result<[URL], LogFileSinkFailure> {
        let snapshot = fileSinkSnapshot()
        guard let sink = snapshot.sink else { return .failure(snapshot.missingSinkFailure) }
        return await sink.logFiles()
    }

    /// 导出所有滚动日志到一个 UTF-8 文本文件。
    public static func exportLogs(to destination: URL) async -> Result<Int, LogFileSinkFailure> {
        let snapshot = fileSinkSnapshot()
        guard let sink = snapshot.sink else { return .failure(snapshot.missingSinkFailure) }
        return await sink.exportCombined(to: destination)
    }

    /// 清理所有滚动日志并重新打开当天空日志。
    @discardableResult
    public static func clearLogs() async -> Result<Int, LogFileSinkFailure> {
        let snapshot = fileSinkSnapshot()
        guard let sink = snapshot.sink else { return .failure(snapshot.missingSinkFailure) }
        return await sink.clearLogs()
    }

    private static func attachObservers(to sink: LogFileSink, generation: UInt64) {
        sink.setHealthTransitionObserver { [weak sink] health in
            guard let sink else { return }
            relayHealth(health, from: sink, generation: generation)
        }
        sink.setIssueTransitionObserver { [weak sink] issues in
            guard let sink else { return }
            relayIssues(issues, from: sink, generation: generation)
        }
        // A replacement may have detached this sink between installation and these two observer
        // calls. Re-check after both are attached so that interleaving cannot leave stale callbacks
        // resident on a superseded sink (the generation gate already prevents stale publication).
        os_unfair_lock_lock(&_configLock)
        let isCurrent = generation == _sinkGeneration
            && _fileSink.map { $0 === sink } == true
        os_unfair_lock_unlock(&_configLock)
        if !isCurrent { detachObservers(from: sink) }
    }

    private static func detachObservers(from sink: LogFileSink?) {
        sink?.setHealthTransitionObserver(nil)
        sink?.setIssueTransitionObserver(nil)
    }

    /// Must be called after `_fileSink` has changed and before `_configLock` is released. `emit`
    /// holds that same lock through `sink.append`, therefore all accepted old-sink appends are
    /// already enqueued and retirement is terminal in the serial writer order.
    private static func enqueueRetirementLocked(
        _ oldSink: LogFileSink?,
        replacingWith newSink: LogFileSink?
    ) -> LogFileSink? {
        guard let oldSink,
              newSink.map({ $0 === oldSink }) != true else { return nil }
        fileSinkRetirementCoordinator.retire(oldSink)
        return oldSink
    }

    private static func relayHealth(
        _ health: LogFileSinkHealth,
        from sink: LogFileSink,
        generation: UInt64
    ) {
        os_unfair_lock_lock(&_configLock)
        if generation == _sinkGeneration,
           let currentSink = _fileSink,
           currentSink === sink {
            _ = fileSinkHealthState.update(health)
        }
        os_unfair_lock_unlock(&_configLock)
    }

    private static func relayIssues(
        _ issues: LogFileSinkIssueSnapshot,
        from sink: LogFileSink,
        generation: UInt64
    ) {
        os_unfair_lock_lock(&_configLock)
        if generation == _sinkGeneration,
           let currentSink = _fileSink,
           currentSink === sink {
            fileSinkIssueState.replace(with: issues)
        }
        os_unfair_lock_unlock(&_configLock)
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
        // v2026.07.18 privacy root fix: call sites intentionally include absolute paths and
        // technical errors for the user-owned rolling file log. Unified Logging has a separate,
        // system-managed retention/collection boundary, so publishing the same preformatted
        // string as `.public` leaked every embedded path. Hash the whole message there; the local
        // file remains the explicit diagnostics surface and can still be exported by the user.
        logger.log(level: level.osLogType, "\(message, privacy: .private(mask: .hash))")

        let renderedLine = renderLine(
            level: level,
            subsystem: subsystem,
            message: message,
            file: file,
            line: line
        )

        // v2026.07.18: the configuration lock is also the handoff boundary between startup
        // buffering and the concrete sink queue. Holding it through sink.append (which only
        // enqueues utility work) guarantees that completion flushes retained early lines first.
        os_unfair_lock_lock(&_configLock)
        if let sink = _fileSink {
            sink.append(renderedLine)
        } else if _fileSinkIsBootstrapping {
            if _startupBufferedLines.count >= _startupBufferCapacity {
                _startupBufferedLines.removeFirst()
                _startupDroppedLineCount += 1
            }
            _startupBufferedLines.append(renderedLine)
        }
        os_unfair_lock_unlock(&_configLock)
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

    private static func renderStartupDropMarker(count: Int) -> String {
        let timestamp = ISO8601DateFormatter.gsyShared.string(from: Date())
        return "\(timestamp) [WARN] [App] startup_file_log_buffer_dropped count=\(count) (GSYLog.swift:0)\n"
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
    private let bundleSubsystem = "com.amux.ai.Clean"

    func logger(for s: GSYLog.Subsystem) -> os.Logger {
        lock.lock(); defer { lock.unlock() }
        if let existing = loggers[s] { return existing }
        let new = os.Logger(subsystem: bundleSubsystem, category: s.rawValue)
        loggers[s] = new
        return new
    }
}

/// Owns the asynchronous tail of every replaced file sink. `retire(_:)` is called only after the
/// facade has swapped `_fileSink` under its configuration lock. Because `emit` accepts/enqueues an
/// append under that same lock, all old-sink work is necessarily ahead of the terminal retirement
/// block and no later facade append can target it.
private final class LogFileSinkRetirementCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingCount = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func retire(_ sink: LogFileSink) {
        lock.lock()
        pendingCount &+= 1
        lock.unlock()

        sink.retireAfterDraining { [self] in
            finishOne()
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard pendingCount > 0 else {
                lock.unlock()
                continuation.resume()
                return
            }
            idleWaiters.append(continuation)
            lock.unlock()
        }
    }

    private func finishOne() {
        lock.lock()
        precondition(pendingCount > 0, "unbalanced LogFileSink retirement")
        pendingCount -= 1
        let waiters: [CheckedContinuation<Void, Never>]
        if pendingCount == 0 {
            waiters = idleWaiters
            idleWaiters.removeAll(keepingCapacity: false)
        } else {
            waiters = []
        }
        lock.unlock()
        for waiter in waiters { waiter.resume() }
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
