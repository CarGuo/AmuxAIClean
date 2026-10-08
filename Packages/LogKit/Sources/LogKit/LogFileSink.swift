import Foundation
import Darwin
import os

/// Stable, body-free diagnostics for the local file logging boundary. The stage/domain/code tuple
/// is safe to persist in Unified Logging or show as technical detail when the file log itself is
/// unavailable; raw `Error.localizedDescription` and the attempted path stay out of that fallback.
public struct LogFileSinkFailure: Swift.Error, Equatable, Sendable {
    public enum Stage: String, Equatable, Hashable, CaseIterable, Sendable {
        case initialization
        case open
        case write
        case prepareAccess = "prepare-access"
        case enumerate
        case export
        case clear
        case retention
        case disabled
    }

    public let stage: Stage
    public let errorDomain: String
    public let errorCode: Int

    public init(stage: Stage, errorDomain: String, errorCode: Int) {
        self.stage = stage
        // v2026.07.18 P2 privacy fix: this tuple is intentionally public in the independent
        // Unified Logging fallback. NSError domains are normally stable identifiers, but the
        // type itself accepts arbitrary strings; normalize unexpected values before they cross
        // that boundary so a malformed/custom domain cannot smuggle a path or user text.
        self.errorDomain = Self.normalizedPublicDomain(errorDomain)
        self.errorCode = errorCode
    }

    static func from(_ error: Error, stage: Stage) -> LogFileSinkFailure {
        if let failure = error as? LogFileSinkFailure { return failure }
        let diagnostic = error as NSError
        return LogFileSinkFailure(
            stage: stage,
            errorDomain: diagnostic.domain,
            errorCode: diagnostic.code
        )
    }

    static let disabled = LogFileSinkFailure(
        stage: .disabled,
        errorDomain: "LogKit.FileSink",
        errorCode: 1
    )

    /// v2026.07.18: callers may reach Help/Settings while the background bootstrap is still
    /// opening the user-owned sink. Keep that state distinct from an explicit disabled state.
    static let initializing = LogFileSinkFailure(
        stage: .initialization,
        errorDomain: "LogKit.FileSink",
        errorCode: 2
    )

    public var diagnosticOrder: Int {
        Self.Stage.allCases.firstIndex(of: stage) ?? Self.Stage.allCases.count
    }

    private static func normalizedPublicDomain(_ domain: String) -> String {
        switch domain {
        case NSCocoaErrorDomain,
             NSPOSIXErrorDomain,
             NSOSStatusErrorDomain,
             "LogKit.FileSink":
            return domain
        default:
            return "UnknownErrorDomain"
        }
    }
}

public enum LogFileSinkHealth: Equatable, Sendable {
    case initializing
    case ready
    case unavailable(LogFileSinkFailure)
    case disabled
}

/// Writer health and maintenance/operation failures are different contracts. A failed retention
/// pass must remain visible without claiming that a still-valid append descriptor is broken.
/// Failures are retained per stage and only a successful retry of that same stage removes them.
public struct LogFileSinkIssueSnapshot: Equatable, Sendable {
    public let failures: [LogFileSinkFailure]

    public init(failures: [LogFileSinkFailure] = []) {
        self.failures = failures.sorted {
            if $0.diagnosticOrder != $1.diagnosticOrder {
                return $0.diagnosticOrder < $1.diagnosticOrder
            }
            if $0.errorDomain != $1.errorDomain { return $0.errorDomain < $1.errorDomain }
            return $0.errorCode < $1.errorCode
        }
    }

    public static let empty = LogFileSinkIssueSnapshot()
    public var isEmpty: Bool { failures.isEmpty }
}

/// Lock-owned health publication primitive. Registering the continuation and enqueueing its
/// initial snapshot happen in the same critical section as transitions, so a concurrent failure
/// can never be delivered before an older `.ready` snapshot and then be overwritten by it.
final class LogFileSinkHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LogFileSinkHealth
    private var continuations: [UUID: AsyncStream<LogFileSinkHealth>.Continuation] = [:]
    private var transitionObserver: (@Sendable (LogFileSinkHealth) -> Void)?

    init(_ initialValue: LogFileSinkHealth) {
        value = initialValue
    }

    var snapshot: LogFileSinkHealth {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func stream(
        onRegisteredWhileLocked: (@Sendable () -> Void)? = nil
    ) -> AsyncStream<LogFileSinkHealth> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
            lock.lock()
            continuations[id] = continuation
            onRegisteredWhileLocked?()
            continuation.yield(value)
            lock.unlock()
        }
    }

    @discardableResult
    func update(_ newValue: LogFileSinkHealth) -> Bool {
        lock.lock()
        guard value != newValue else {
            lock.unlock()
            return false
        }
        value = newValue
        let currentContinuations = Array(continuations.values)
        let observer = transitionObserver
        lock.unlock()
        for continuation in currentContinuations {
            continuation.yield(newValue)
        }
        observer?(newValue)
        return true
    }

    func setTransitionObserver(
        _ observer: (@Sendable (LogFileSinkHealth) -> Void)?
    ) {
        lock.lock()
        transitionObserver = observer
        let current = value
        lock.unlock()
        observer?(current)
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

/// Same lock-owned publication primitive as writer health, specialized for the per-stage issue
/// dictionary so unrelated successful work cannot erase an outstanding retention/export failure.
final class LogFileSinkIssueState: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [LogFileSinkFailure.Stage: LogFileSinkFailure] = [:]
    private var continuations: [UUID: AsyncStream<LogFileSinkIssueSnapshot>.Continuation] = [:]
    private var transitionObserver: (@Sendable (LogFileSinkIssueSnapshot) -> Void)?

    var snapshot: LogFileSinkIssueSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return LogFileSinkIssueSnapshot(failures: Array(failures.values))
    }

    func stream() -> AsyncStream<LogFileSinkIssueSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
            lock.lock()
            continuations[id] = continuation
            continuation.yield(LogFileSinkIssueSnapshot(failures: Array(failures.values)))
            lock.unlock()
        }
    }

    func record(_ failure: LogFileSinkFailure) {
        publishMutation { $0[failure.stage] = failure }
    }

    func clear(_ stage: LogFileSinkFailure.Stage) {
        publishMutation { $0.removeValue(forKey: stage) }
    }

    func replace(with snapshot: LogFileSinkIssueSnapshot) {
        publishMutation { storage in
            storage = Dictionary(uniqueKeysWithValues: snapshot.failures.map { ($0.stage, $0) })
        }
    }

    func setTransitionObserver(
        _ observer: (@Sendable (LogFileSinkIssueSnapshot) -> Void)?
    ) {
        lock.lock()
        transitionObserver = observer
        let current = LogFileSinkIssueSnapshot(failures: Array(failures.values))
        lock.unlock()
        observer?(current)
    }

    private func publishMutation(
        _ mutation: (inout [LogFileSinkFailure.Stage: LogFileSinkFailure]) -> Void
    ) {
        lock.lock()
        let old = LogFileSinkIssueSnapshot(failures: Array(failures.values))
        mutation(&failures)
        let new = LogFileSinkIssueSnapshot(failures: Array(failures.values))
        guard old != new else {
            lock.unlock()
            return
        }
        let currentContinuations = Array(continuations.values)
        let observer = transitionObserver
        lock.unlock()
        for continuation in currentContinuations { continuation.yield(new) }
        observer?(new)
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

/// v2026.07.18 P2 diagnostics boundary: the local file sink cannot report its own failure into
/// that same file. Publish only the closed stage/domain/code tuple to an independent OSLog
/// category; paths, raw errors and localized descriptions remain private and never enter it.
enum LogFileSinkPublicDiagnostics {
    private static let logger = os.Logger(
        subsystem: "com.amux.ai.Clean",
        category: "LogFileSink"
    )

    static func record(_ failure: LogFileSinkFailure) {
        logger.error(
            "file_sink_failure stage=\(failure.stage.rawValue, privacy: .public) domain=\(failure.errorDomain, privacy: .public) code=\(failure.errorCode, privacy: .public)"
        )
    }
}

/// 文件日志 sink —— 按天滚动，超过保留期自动删除旧文件。
///
/// 落盘位置：`~/Library/Logs/AmuxAIClean/AmuxAIClean-YYYY-MM-DD.log`
/// （macOS 标准 user logs，Console.app 也能直接打开）。
///
/// **写入策略**：
/// - 串行 GCD 队列序列化所有 append，保证多线程不交错；
/// - 每天 0 点跨天后下次 append 自动切到新文件（不是定时器，避免 App 后台休眠错过）；
/// - 单条 append 不 fsync，依赖 close 时 OS 刷盘 + 进程退出时关闭句柄。
///
/// **保留策略**：构造时一次扫目录，删除超过 `retentionDays` 的旧文件；之后每天首次
/// append 触发"跨天检查"时再扫一次。开销：一次 contentsOfDirectory + 几次 attributes 查询，
/// 在 7 天 / 单文件几 MB 体量下完全可忽略。
public final class LogFileSink: @unchecked Sendable {

    public let directory: URL
    public let retentionDays: Int
    /// Canonical path frozen at construction. Final-component O_NOFOLLOW is insufficient when a
    /// parent directory is later replaced by a symlink; every access must still resolve here.
    private let canonicalDirectoryPath: String
    private let directoryBoundary: DirectoryBoundary

    private let queue = DispatchQueue(label: "AmuxAIClean.LogFileSink", qos: .utility)
    /// Queue-isolated terminal state. GSYLog enqueues retirement while holding the same facade lock
    /// that routes append, so every facade append for this sink is already ahead of retirement and
    /// no later one can target it. A stale direct package reference queued afterward cannot reopen.
    private var isRetired = false
    /// Directory descriptor frozen by the same O_NOFOLLOW transaction as `handle`. Keeping both
    /// descriptors open is the actual write-safety boundary: a later pathname replacement cannot
    /// redirect bytes already addressed to the verified file inode.
    private var activeDirectoryDescriptor: Int32 = -1
    /// 当前打开的文件句柄。同一天可复用，跨天关闭重开。
    private var handle: FileHandle?
    private var currentDayKey: String = ""
    /// 缓存当前文件 URL，给 UI 「查看今日日志」按钮用。
    private var _currentFileURL: URL?
    /// v2026.07.18 P2 diagnostics fix: stderr is only a last-resort transport and may be invisible
    /// to the user. Keep a typed health snapshot so AppUI can explain why no local log exists.
    private let healthState = LogFileSinkHealthState(.ready)
    private let issueState = LogFileSinkIssueState()
    /// Deterministic package-test seam for otherwise platform-dependent retention failures.
    /// Production construction always supplies nil.
    private let retentionPreflight: (@Sendable () throws -> Void)?
    private let nowProvider: @Sendable () -> Date
    /// v2026.07.19 log-append hot-path regression fix: visibility checks are bounded independently
    /// by throughput and elapsed time. A stable descriptor never follows a replacement pathname,
    /// so per-line path traversal added no write-safety and instead multiplied metadata I/O.
    private let appendValidationLineInterval: Int
    private let appendValidationTimeIntervalNanoseconds: UInt64
    private var appendLinesSinceValidation = 0
    private var nextAppendValidationUptimeNanoseconds: UInt64 = 0
    private var successfulAppendWriteCount = 0
    private var periodicAppendValidationCount = 0
    /// Lines written after the last visible pathname/descriptor identity proof are not yet known
    /// to be reachable from the expected pathname. Retain that one visibility window so an unlink
    /// or replacement discovered at the next boundary can rebind and replay it in original order.
    /// The byte cap prevents a maliciously large log message from creating unbounded retention;
    /// overflow is represented by a durable marker when a safe visible path returns.
    private let visibilityReplayByteCapacity: Int
    private var pendingVisibilityLines: [Data] = []
    private var pendingVisibilityBytes = 0
    private var peakPendingVisibilityBytes = 0
    private var pendingVisibilityDroppedLineCount = 0
    private var pendingVisibilityDroppedByteCount = 0

    static let defaultAppendValidationLineInterval = 256
    static let defaultAppendValidationTimeIntervalNanoseconds: UInt64 = 1_000_000_000
    static let defaultVisibilityReplayByteCapacity = 4 * 1_024 * 1_024

    public convenience init(directory: URL, retentionDays: Int = 7) throws {
        try self.init(
            directory: directory,
            retentionDays: retentionDays,
            retentionPreflight: nil,
            appendValidationLineInterval: Self.defaultAppendValidationLineInterval,
            appendValidationTimeIntervalNanoseconds: Self.defaultAppendValidationTimeIntervalNanoseconds,
            visibilityReplayByteCapacity: Self.defaultVisibilityReplayByteCapacity
        )
    }

    init(
        directory: URL,
        retentionDays: Int = 7,
        retentionPreflight: (@Sendable () throws -> Void)?,
        appendValidationLineInterval: Int = LogFileSink.defaultAppendValidationLineInterval,
        appendValidationTimeIntervalNanoseconds: UInt64 = LogFileSink.defaultAppendValidationTimeIntervalNanoseconds,
        visibilityReplayByteCapacity: Int = LogFileSink.defaultVisibilityReplayByteCapacity,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        // v2026.07.18 P1 root-boundary fix: classify the requested path and traverse/create it
        // component-by-component with openat(O_NOFOLLOW) before any write. FileManager.createDirectory
        // used here previously could follow a parent symlink and mutate an out-of-bound target
        // before the later canonical-path rejection ran.
        let boundary = try Self.makeDirectoryBoundary(for: directory)
        self.directory = directory
        self.retentionDays = retentionDays
        self.canonicalDirectoryPath = boundary.requestedPath
        self.directoryBoundary = boundary
        self.retentionPreflight = retentionPreflight
        self.nowProvider = nowProvider
        self.appendValidationLineInterval = max(1, appendValidationLineInterval)
        self.appendValidationTimeIntervalNanoseconds = max(
            1,
            appendValidationTimeIntervalNanoseconds
        )
        self.visibilityReplayByteCapacity = max(1, visibilityReplayByteCapacity)
        let initialDirectoryDescriptor = try Self.openDirectoryDescriptor(
            boundary: boundary,
            createMissing: true
        )
        Darwin.close(initialDirectoryDescriptor)
        // 启动期同步执行一次清理 + 打开当天文件，避免首次 append 触发的 race
        // （app 启动 → 第一行 log 还没打就 crash，文件就根本不存在）。
        var startupFailure: LogFileSinkFailure?
        queue.sync {
            // v2026.07.18: rotate already performs the startup retention transaction after a
            // successful open. Running purge again here duplicated directory enumeration and,
            // worse, could immediately erase the diagnostic from a failed first pass.
            self.rotateIfNeededLocked(now: nowProvider())
            if case .unavailable(let failure) = self.health {
                startupFailure = failure
            }
        }
        if let startupFailure { throw startupFailure }
    }

    deinit {
        // Last-resort cleanup for a directly owned sink whose caller forgot close/retirement. At
        // deinit no queued closure can remain (append/retirement capture self strongly), so these
        // descriptors are exclusively owned here. Reachability repair belongs to explicit close;
        // deinit must not start new filesystem work or block another queue.
        try? handle?.close()
        if activeDirectoryDescriptor >= 0 {
            Darwin.close(activeDirectoryDescriptor)
        }
    }

    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        // ~/Library/Logs/AmuxAIClean/
        // 注意：macOS 沙盒下 .libraryDirectory 是容器内 Library，非沙盒下是 ~/Library。
        // 当前 App 不开 sandbox，所以 .libraryDirectory 拿到就是 ~/Library。
        let lib = try fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return lib.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AmuxAIClean", isDirectory: true)
    }

    public var currentFileURL: URL? {
        queue.sync { _currentFileURL }
    }

    public func currentFileURLSnapshot() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: _currentFileURL)
            }
        }
    }

    public var health: LogFileSinkHealth {
        healthState.snapshot
    }

    /// Every subscriber receives the current state first, followed by real transitions only.
    /// Buffering the newest value prevents a hidden Settings scene from accumulating stale events.
    public func healthUpdates() -> AsyncStream<LogFileSinkHealth> {
        healthState.stream()
    }

    public var issues: LogFileSinkIssueSnapshot { issueState.snapshot }

    struct AppendValidationDiagnostics: Equatable, Sendable {
        let successfulWriteCount: Int
        let periodicValidationCount: Int
        let peakVisibilityReplayBytes: Int
    }

    /// Deterministic regression seam: tests assert validation grows by fixed batches instead of
    /// relying on wall-clock timing or privileged syscall tracing in CI.
    func appendValidationDiagnosticsForTesting() -> AppendValidationDiagnostics {
        queue.sync {
            AppendValidationDiagnostics(
                successfulWriteCount: successfulAppendWriteCount,
                periodicValidationCount: periodicAppendValidationCount,
                peakVisibilityReplayBytes: peakPendingVisibilityBytes
            )
        }
    }

    /// Deterministic lifecycle seam: tests can hold the serial writer ahead of accepted appends,
    /// release every external strong reference, then prove facade retirement still owns/drains it.
    func enqueueBarrierForTesting(
        entered: @escaping @Sendable () -> Void,
        waitForRelease: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            _ = self
            entered()
            waitForRelease()
        }
    }

    public func issueUpdates() -> AsyncStream<LogFileSinkIssueSnapshot> {
        issueState.stream()
    }

    /// LogKit's process-wide relay installs observers when an asynchronously constructed sink
    /// becomes current. The observer receives an atomic initial snapshot before later changes.
    func setHealthTransitionObserver(
        _ observer: (@Sendable (LogFileSinkHealth) -> Void)?
    ) {
        healthState.setTransitionObserver(observer)
    }

    func setIssueTransitionObserver(
        _ observer: (@Sendable (LogFileSinkIssueSnapshot) -> Void)?
    ) {
        issueState.setTransitionObserver(observer)
    }

    /// Re-validates the exact sink directory and active file before a Finder/UI handoff. This
    /// closes the case where the directory was removed while an already-open handle continued to
    /// accept bytes into an unlinked inode. The caller receives stable facts instead of a silent
    /// `try?`, and a successful call restores `.ready` health.
    public func prepareDirectoryForAccess() async -> Result<URL, LogFileSinkFailure> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: prepareDirectoryForAccessLocked())
            }
        }
    }

    private func prepareDirectoryForAccessLocked() -> Result<URL, LogFileSinkFailure> {
        do {
            let now = nowProvider()
            try ensureCurrentFileVisibleLocked(now: now)
            // Preparing the user-visible directory is also the explicit same-stage retry point
            // for an outstanding retention issue. Retention failure remains a maintenance issue
            // and does not turn this successful access validation into writer unavailability.
            purgeOldFilesLocked(now: now)
            markReady()
            return .success(directory)
        } catch {
            // v2026.07.18 P2 identity fix: a handle into a deleted/replaced directory must never
            // survive a failed revalidation. Otherwise a later successful write would make health
            // look ready while bytes still disappear into an unlinked inode.
            invalidateActiveHandleLocked()
            let failure = markFailure(error, stage: .prepareAccess)
            Self.writeFallbackDiagnostic("prepare log access failed", failure: failure)
            return .failure(failure)
        }
    }


    public func logFiles() async -> Result<[URL], LogFileSinkFailure> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    try ensureCurrentFileVisibleLocked(now: nowProvider())
                } catch {
                    invalidateActiveHandleLocked()
                    let writerFailure = markFailure(error, stage: .write)
                    Self.writeFallbackDiagnostic(
                        "log inventory visibility failed",
                        failure: writerFailure
                    )
                    continuation.resume(returning: .failure(
                        reportOperationFailure(error, stage: .enumerate)
                    ))
                    return
                }
                do {
                    let files = try logFilesLocked()
                    issueState.clear(.enumerate)
                    continuation.resume(returning: .success(files))
                } catch {
                    continuation.resume(returning: .failure(
                        reportOperationFailure(error, stage: .enumerate)
                    ))
                }
            }
        }
    }

    public func exportCombined(to destination: URL) async -> Result<Int, LogFileSinkFailure> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    try ensureCurrentFileVisibleLocked(now: nowProvider())
                } catch {
                    invalidateActiveHandleLocked()
                    let writerFailure = markFailure(error, stage: .write)
                    Self.writeFallbackDiagnostic(
                        "log export visibility failed",
                        failure: writerFailure
                    )
                    continuation.resume(returning: .failure(
                        reportOperationFailure(error, stage: .export)
                    ))
                    return
                }
                do {
                    let count = try exportCombinedLocked(to: destination)
                    issueState.clear(.export)
                    continuation.resume(returning: .success(count))
                } catch {
                    continuation.resume(returning: .failure(
                        reportOperationFailure(error, stage: .export)
                    ))
                }
            }
        }
    }

    @discardableResult
    public func clearLogs() async -> Result<Int, LogFileSinkFailure> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    let count = try clearLogsLocked()
                    issueState.clear(.clear)
                    continuation.resume(returning: .success(count))
                } catch {
                    // clear closes the active handle before deleting. A failure therefore leaves
                    // no proven writer and must update health, unlike read-only export/retention.
                    let failure = markFailure(error, stage: .clear)
                    issueState.record(failure)
                    Self.writeFallbackDiagnostic("clear logs failed", failure: failure)
                    continuation.resume(returning: .failure(failure))
                }
            }
        }
    }

    /// append 一行日志。若跨天会先关旧文件 → 删旧 → 开新文件。
    ///
    /// GSYLog changes its current sink and enqueues retirement under one facade lock, so normal
    /// callers cannot enqueue this method behind retirement on a superseded sink.
    public func append(_ line: String) {
        queue.async { [self] in
            guard !isRetired else {
                LogFileSinkPublicDiagnostics.record(.disabled)
                return
            }
            let now = nowProvider()
            let nowUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            rotateIfNeededLocked(now: now)
            // rotate already emitted the typed open failure and invalidated state. Do not retry
            // the same open again in this append or mislabel it as an additional write failure.
            guard handle != nil else {
                recordPendingVisibilityLineLocked(Data(line.utf8))
                return
            }
            let data = Data(line.utf8)
            do {
                // v2026.07.19 log-append hot-path regression fix: the verified file descriptor is
                // the write-safety boundary. Re-walking the full path for every structured line
                // did not make a replacement path safer, because an open fd cannot be redirected;
                // instead, validate at an explicit bounded boundary and rebind before this line.
                try revalidateActiveBindingIfNeededLocked(
                    now: now,
                    nowUptimeNanoseconds: nowUptimeNanoseconds
                )
                guard let h = handle else {
                    throw Self.posixError(EBADF)
                }
                try h.write(contentsOf: data)
                successfulAppendWriteCount &+= 1
                appendLinesSinceValidation &+= 1
                recordPendingVisibilityLineLocked(data)
            } catch {
                // The current logical line was accepted by the sink. Preserve it even when the
                // boundary rebind or the physical write failed; a later safe pathname can replay
                // it, while the bounded overflow marker makes any capacity loss explicit.
                recordPendingVisibilityLineLocked(data)
                // v2026.07.18 privacy boundary: stderr is another system-managed collection
                // surface. Never echo a raw Cocoa Error there because it may embed the log path.
                invalidateActiveHandleLocked()
                let failure = markFailure(error, stage: .write)
                Self.writeFallbackDiagnostic("file sink write failed", failure: failure)
            }
        }
    }

    /// 主动 flush + close，进程退出 / 测试 teardown 用。
    public func close() {
        queue.sync {
            closePreservingVisibleLogsLocked()
        }
    }

    /// GSYLog replacement/disable owns old sinks until this terminal block has drained every
    /// previously accepted append and closed both descriptors. It is deliberately asynchronous:
    /// configuration never waits for filesystem I/O and never calls queue.sync while holding the
    /// facade lock.
    func retireAfterDraining(_ completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            defer { completion() }
            guard !isRetired else { return }
            isRetired = true
            closePreservingVisibleLogsLocked()
        }
    }

    // MARK: - 私有

    private struct EntryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ information: stat) {
            device = information.st_dev
            inode = information.st_ino
        }
    }

    private struct DirectoryBoundary {
        let basePath: String
        let relativeComponents: [String]
        let requestedPath: String
    }

    private struct CanonicalLogEntry {
        let name: String
        let identity: EntryIdentity
        let modificationSeconds: Int64
    }

    struct DescriptorCopySummary: Equatable {
        let totalBytes: Int64
        let lastByte: UInt8?
        let maximumChunkBytes: Int
    }

    static let exportChunkBytes = 64 * 1_024

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func logFileName(dayKey: String) -> String {
        "AmuxAIClean-\(dayKey).log"
    }

    /// Exact ASCII grammar for files owned by this sink. Prefix/extension matching alone is not
    /// an ownership proof: a matching directory would make FileManager.removeItem recurse.
    private static func isCanonicalLogFileName(_ name: String) -> Bool {
        let prefix = "AmuxAIClean-"
        let suffix = ".log"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let datePart = name.dropFirst(prefix.count).dropLast(suffix.count)
        let bytes = Array(datePart.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return false }
        for index in bytes.indices where index != 4 && index != 7 {
            guard (0x30...0x39).contains(bytes[index]) else { return false }
        }
        guard let year = Int(String(datePart.prefix(4))),
              let month = Int(String(datePart.dropFirst(5).prefix(2))),
              let day = Int(String(datePart.dropFirst(8).prefix(2))) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }

    private static func isDirectory(_ information: stat) -> Bool {
        (information.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isOwnedRegularFile(_ information: stat) -> Bool {
        (information.st_mode & S_IFMT) == S_IFREG && information.st_nlink == 1
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func makeDirectoryBoundary(for directory: URL) throws -> DirectoryBoundary {
        let requested = directory.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let userLogs = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .standardizedFileURL.path
        let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let temporary = temporaryURL.standardizedFileURL.path
        let resolvedTemporary = temporaryURL.resolvingSymlinksInPath().standardizedFileURL.path

        let basePath: String
        if isStrictDescendant(requested, of: userLogs) {
            // Traverse from HOME so Library and Logs themselves must also be real directories.
            basePath = home.path
        } else if isStrictDescendant(requested, of: temporary) {
            // $TMPDIR is an OS-provided trusted base; all caller-controlled descendants still use
            // O_NOFOLLOW. Requiring a child also prevents a sink from clearing the temp root.
            basePath = temporary
        } else if isStrictDescendant(requested, of: resolvedTemporary) {
            basePath = resolvedTemporary
        } else {
            throw posixError(EACCES)
        }

        let relative = String(requested.dropFirst(basePath.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { throw posixError(EACCES) }
        return DirectoryBoundary(
            basePath: basePath,
            relativeComponents: components,
            requestedPath: requested
        )
    }

    private static func isStrictDescendant(_ candidate: String, of root: String) -> Bool {
        candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Traverses from a trusted root descriptor. Every caller-controlled component is opened with
    /// O_NOFOLLOW; missing components are created with mkdirat only after their parent descriptor
    /// is already frozen. No parent symlink can redirect creation, reads, export or clear.
    private static func openDirectoryDescriptor(
        boundary: DirectoryBoundary,
        createMissing: Bool
    ) throws -> Int32 {
        var descriptor = Darwin.open(
            boundary.basePath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError() }

        for component in boundary.relativeComponents {
            var next = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if next < 0, errno == ENOENT, createMissing {
                guard mkdirat(
                    descriptor,
                    component,
                    mode_t(S_IRWXU)
                ) == 0 || errno == EEXIST else {
                    let savedError = errno
                    Darwin.close(descriptor)
                    throw posixError(savedError)
                }
                next = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard next >= 0 else {
                let savedError = errno
                Darwin.close(descriptor)
                throw posixError(savedError)
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    /// Opens the final log-directory component without following a symlink and freezes its
    /// device/inode identity. Every destructive/read operation below is relative to this fd.
    private func openValidatedDirectoryLocked(createIfMissing: Bool) throws -> Int32 {
        guard directory.standardizedFileURL.path == canonicalDirectoryPath else {
            throw Self.posixError(EACCES)
        }
        let descriptor = try Self.openDirectoryDescriptor(
            boundary: directoryBoundary,
            createMissing: createIfMissing
        )
        var pathInformation = stat()
        guard lstat(directory.path, &pathInformation) == 0 else {
            Darwin.close(descriptor)
            throw Self.posixError()
        }
        guard Self.isDirectory(pathInformation) else {
            Darwin.close(descriptor)
            throw Self.posixError(EINVAL)
        }

        var descriptorInformation = stat()
        guard fstat(descriptor, &descriptorInformation) == 0,
              Self.isDirectory(descriptorInformation),
              EntryIdentity(descriptorInformation) == EntryIdentity(pathInformation) else {
            let savedError = errno == 0 ? EAGAIN : errno
            Darwin.close(descriptor)
            throw Self.posixError(savedError)
        }
        return descriptor
    }

    private func directoryPathMatchesLocked(descriptor: Int32) -> Bool {
        var pathInformation = stat()
        var descriptorInformation = stat()
        guard directory.standardizedFileURL.path == canonicalDirectoryPath,
              lstat(directory.path, &pathInformation) == 0,
              fstat(descriptor, &descriptorInformation) == 0,
              Self.isDirectory(pathInformation),
              Self.isDirectory(descriptorInformation) else { return false }
        return EntryIdentity(pathInformation) == EntryIdentity(descriptorInformation)
    }

    private func activeFileMatchesVisiblePathLocked(expectedURL: URL) -> Bool {
        guard let handle,
              activeDirectoryDescriptor >= 0,
              _currentFileURL == expectedURL,
              currentDayKey.isEmpty == false else { return false }

        var handleInformation = stat()
        var pathInformation = stat()
        guard fstat(handle.fileDescriptor, &handleInformation) == 0,
              fstatat(
                activeDirectoryDescriptor,
                expectedURL.lastPathComponent,
                &pathInformation,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              Self.isOwnedRegularFile(handleInformation),
              Self.isOwnedRegularFile(pathInformation),
              directoryPathMatchesLocked(descriptor: activeDirectoryDescriptor) else {
            return false
        }
        return EntryIdentity(handleInformation) == EntryIdentity(pathInformation)
    }

    private func revalidateActiveBindingIfNeededLocked(
        now: Date,
        nowUptimeNanoseconds: UInt64
    ) throws {
        guard appendLinesSinceValidation >= appendValidationLineInterval
                || nowUptimeNanoseconds >= nextAppendValidationUptimeNanoseconds else {
            return
        }
        periodicAppendValidationCount &+= 1
        guard let expectedURL = _currentFileURL else {
            throw Self.posixError(EBADF)
        }
        if !activeFileMatchesVisiblePathLocked(expectedURL: expectedURL) {
            // Invalidate both pinned descriptors before resolving the visible path again. If the
            // new path is a symlink or another foreign entry, O_NOFOLLOW fails closed and the
            // current line is not written to either target.
            invalidateActiveHandleLocked()
            try openActiveFileLocked(now: now)
            purgeOldFilesLocked(now: now)
            markReady()
        } else {
            commitPendingVisibilityWindowLocked(
                nowUptimeNanoseconds: nowUptimeNanoseconds
            )
        }
    }

    private func recordPendingVisibilityLineLocked(_ data: Data) {
        guard data.count <= visibilityReplayByteCapacity,
              pendingVisibilityBytes <= visibilityReplayByteCapacity - data.count else {
            pendingVisibilityDroppedLineCount &+= 1
            pendingVisibilityDroppedByteCount &+= data.count
            return
        }
        pendingVisibilityLines.append(data)
        pendingVisibilityBytes += data.count
        peakPendingVisibilityBytes = max(peakPendingVisibilityBytes, pendingVisibilityBytes)
    }

    /// Replays only the window accepted after the last successful visible identity proof. A
    /// mismatch means the old frozen inode is no longer the expected pathname, so replay cannot
    /// duplicate bytes in the current visible log: it restores them to the newly verified inode.
    /// The buffer remains intact until a post-write identity fence succeeds, allowing repeated
    /// fail-closed attempts (for example while a symlink occupies the pathname) to recover later.
    private func replayPendingVisibilityWindowLocked() throws {
        guard !pendingVisibilityLines.isEmpty || pendingVisibilityDroppedLineCount > 0 else {
            return
        }
        guard let handle else { throw Self.posixError(EBADF) }
        for data in pendingVisibilityLines {
            try handle.write(contentsOf: data)
        }
        if pendingVisibilityDroppedLineCount > 0 {
            let marker = Self.visibilityReplayOverflowMarker(
                droppedLines: pendingVisibilityDroppedLineCount,
                droppedBytes: pendingVisibilityDroppedByteCount
            )
            try handle.write(contentsOf: Data(marker.utf8))
        }
    }

    private func commitPendingVisibilityWindowLocked(nowUptimeNanoseconds: UInt64) {
        pendingVisibilityLines.removeAll(keepingCapacity: true)
        pendingVisibilityBytes = 0
        pendingVisibilityDroppedLineCount = 0
        pendingVisibilityDroppedByteCount = 0
        resetAppendValidationBoundaryLocked(
            nowUptimeNanoseconds: nowUptimeNanoseconds
        )
    }

    private func discardPendingVisibilityWindowLocked() {
        pendingVisibilityLines.removeAll(keepingCapacity: false)
        pendingVisibilityBytes = 0
        pendingVisibilityDroppedLineCount = 0
        pendingVisibilityDroppedByteCount = 0
    }

    private static func visibilityReplayOverflowMarker(
        droppedLines: Int,
        droppedBytes: Int
    ) -> String {
        let timestamp = ISO8601DateFormatter.gsyShared.string(from: Date())
        return "\(timestamp) [WARN] [App] file_log_visibility_replay_overflow "
            + "dropped_lines=\(droppedLines) dropped_bytes=\(droppedBytes) "
            + "(LogFileSink.swift:0)\n"
    }

    private func openActiveFileLocked(now: Date) throws {
        invalidateActiveHandleLocked()
        let today = Self.dayKeyFormatter.string(from: now)
        let fileName = Self.logFileName(dayKey: today)
        guard Self.isCanonicalLogFileName(fileName) else {
            throw Self.posixError(EINVAL)
        }

        let directoryDescriptor = try openValidatedDirectoryLocked(createIfMissing: true)
        var directoryDescriptorOwnedLocally = true
        defer {
            if directoryDescriptorOwnedLocally { Darwin.close(directoryDescriptor) }
        }

        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw Self.posixError() }
        var descriptorOwnedLocally = true
        defer {
            if descriptorOwnedLocally { Darwin.close(descriptor) }
        }

        var descriptorInformation = stat()
        var entryInformation = stat()
        guard fstat(descriptor, &descriptorInformation) == 0,
              fstatat(
                directoryDescriptor,
                fileName,
                &entryInformation,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              Self.isOwnedRegularFile(descriptorInformation),
              Self.isOwnedRegularFile(entryInformation),
              EntryIdentity(descriptorInformation) == EntryIdentity(entryInformation),
              directoryPathMatchesLocked(descriptor: directoryDescriptor) else {
            throw Self.posixError(EAGAIN)
        }

        let expectedURL = directory.appendingPathComponent(fileName, isDirectory: false)
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        descriptorOwnedLocally = false
        activeDirectoryDescriptor = directoryDescriptor
        directoryDescriptorOwnedLocally = false
        currentDayKey = today
        _currentFileURL = expectedURL
        let nowUptime = DispatchTime.now().uptimeNanoseconds
        resetAppendValidationBoundaryLocked(
            nowUptimeNanoseconds: nowUptime
        )
        let hadPendingWindow = !pendingVisibilityLines.isEmpty || pendingVisibilityDroppedLineCount > 0
        try replayPendingVisibilityWindowLocked()
        if hadPendingWindow {
            guard activeFileMatchesVisiblePathLocked(expectedURL: expectedURL) else {
                throw Self.posixError(EAGAIN)
            }
            commitPendingVisibilityWindowLocked(
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }
    }

    private func closePreservingVisibleLogsLocked() {
        do {
            if !pendingVisibilityLines.isEmpty || pendingVisibilityDroppedLineCount > 0 {
                try ensureCurrentFileVisibleLocked(now: nowProvider())
            } else {
                try handle?.synchronize()
            }
        } catch {
            // A hostile/foreign visible path cannot be made safe merely to save logs. Preserve the
            // no-follow boundary, expose the typed failure, and keep the bounded replay window in
            // memory for any owner that later calls prepare/append after restoring a regular path.
            let failure = markFailure(error, stage: .write)
            Self.writeFallbackDiagnostic("file sink close visibility failed", failure: failure)
        }
        invalidateActiveHandleLocked()
    }

    /// Makes the current rolling file reachable from its expected pathname and commits exactly the
    /// pending window only after a post-replay identity fence. This runs solely on the utility
    /// writer queue and is shared by Finder handoff, inventory, export, close and retirement.
    private func ensureCurrentFileVisibleLocked(now: Date) throws {
        let expectedURL = directory.appendingPathComponent(
            Self.logFileName(dayKey: Self.dayKeyFormatter.string(from: now)),
            isDirectory: false
        )
        if let previousURL = _currentFileURL,
           previousURL != expectedURL,
           activeFileMatchesVisiblePathLocked(expectedURL: previousURL) {
            try? handle?.synchronize()
            commitPendingVisibilityWindowLocked(
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }
        let wasAlreadyVisible = activeFileMatchesVisiblePathLocked(expectedURL: expectedURL)
        if !wasAlreadyVisible {
            invalidateActiveHandleLocked()
            try openActiveFileLocked(now: now)
            // The open transaction fenced identity before replay. Re-check only this changed-path
            // branch after replay; a stable path already passed the same proof above and must not
            // pay for a duplicate full metadata walk.
            guard activeFileMatchesVisiblePathLocked(expectedURL: expectedURL) else {
                throw Self.posixError(EAGAIN)
            }
        }
        try handle?.synchronize()
        commitPendingVisibilityWindowLocked(
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    private func invalidateActiveHandleLocked() {
        // Best-effort descriptor cleanup: failure cannot be recovered here, but all in-memory
        // identities are invalidated unconditionally so no later append can reuse stale state.
        try? handle?.close()
        handle = nil
        if activeDirectoryDescriptor >= 0 {
            Darwin.close(activeDirectoryDescriptor)
            activeDirectoryDescriptor = -1
        }
        _currentFileURL = nil
        currentDayKey = ""
        appendLinesSinceValidation = 0
        nextAppendValidationUptimeNanoseconds = 0
    }

    private func resetAppendValidationBoundaryLocked(nowUptimeNanoseconds: UInt64) {
        appendLinesSinceValidation = 0
        let (deadline, overflow) = nowUptimeNanoseconds.addingReportingOverflow(
            appendValidationTimeIntervalNanoseconds
        )
        nextAppendValidationUptimeNanoseconds = overflow ? .max : deadline
    }

    private func rotateIfNeededLocked(now: Date) {
        let today = Self.dayKeyFormatter.string(from: now)
        if today == currentDayKey, handle != nil { return }
        if !currentDayKey.isEmpty,
           today != currentDayKey,
           let previousURL = _currentFileURL,
           activeFileMatchesVisiblePathLocked(expectedURL: previousURL) {
            try? handle?.synchronize()
            commitPendingVisibilityWindowLocked(
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }
        do {
            try openActiveFileLocked(now: now)
            markReady()
            // 跨天时同步触发清理。
            purgeOldFilesLocked(now: now)
        } catch {
            invalidateActiveHandleLocked()
            let failure = markFailure(error, stage: .open)
            Self.writeFallbackDiagnostic("open log file failed", failure: failure)
        }
    }

    @discardableResult
    private func markFailure(
        _ error: Error,
        stage: LogFileSinkFailure.Stage
    ) -> LogFileSinkFailure {
        let failure = LogFileSinkFailure.from(error, stage: stage)
        let didTransition = updateHealth(.unavailable(failure))
        if didTransition {
            LogFileSinkPublicDiagnostics.record(failure)
        }
        return failure
    }

    /// Non-writer operations still need a durable diagnostic, but an export/retention failure
    /// does not prove the active append descriptor is unusable and therefore must not poison its
    /// health state.
    private func reportOperationFailure(
        _ error: Error,
        stage: LogFileSinkFailure.Stage
    ) -> LogFileSinkFailure {
        let failure = LogFileSinkFailure.from(error, stage: stage)
        issueState.record(failure)
        LogFileSinkPublicDiagnostics.record(failure)
        Self.writeFallbackDiagnostic("log file operation failed", failure: failure)
        return failure
    }

    @discardableResult
    private func updateHealth(_ newValue: LogFileSinkHealth) -> Bool {
        healthState.update(newValue)
    }

    private func markReady() {
        _ = updateHealth(.ready)
    }

    private static func writeFallbackDiagnostic(
        _ message: String,
        failure: LogFileSinkFailure
    ) {
        FileHandle.standardError.write(
            Data((
                "[GSYLog] \(message) stage=\(failure.stage.rawValue) "
                    + "domain=\(failure.errorDomain) code=\(failure.errorCode)\n"
            ).utf8)
        )
    }

    private func purgeOldFilesLocked(now: Date) {
        guard retentionDays > 0 else {
            issueState.clear(.retention)
            return
        }
        do {
            try retentionPreflight?()
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            let directoryDescriptor = try openValidatedDirectoryLocked(createIfMissing: false)
            defer { Darwin.close(directoryDescriptor) }
            let activeName = _currentFileURL?.lastPathComponent
            for entry in try canonicalLogEntriesLocked(directoryDescriptor: directoryDescriptor) {
                // 当前正在写的文件不删。
                if entry.name == activeName { continue }
                let modificationDate = Date(
                    timeIntervalSince1970: TimeInterval(entry.modificationSeconds)
                )
                if modificationDate < cutoff {
                    try unlinkCanonicalEntryLocked(
                        entry,
                        directoryDescriptor: directoryDescriptor
                    )
                }
            }
            // v2026.07.18: a retention issue is durable diagnostic state, not writer health.
            // Clear it only after the same retention transaction completes successfully.
            issueState.clear(.retention)
        } catch {
            _ = reportOperationFailure(error, stage: .retention)
        }
    }

    private func logFilesLocked() throws -> [URL] {
        let directoryDescriptor = try openValidatedDirectoryLocked(createIfMissing: false)
        defer { Darwin.close(directoryDescriptor) }
        return try canonicalLogEntriesLocked(directoryDescriptor: directoryDescriptor)
            .map { directory.appendingPathComponent($0.name, isDirectory: false) }
    }

    private func exportCombinedLocked(to destination: URL) throws -> Int {
        try handle?.synchronize()
        let directoryDescriptor = try openValidatedDirectoryLocked(createIfMissing: false)
        defer { Darwin.close(directoryDescriptor) }
        let entries = try canonicalLogEntriesLocked(directoryDescriptor: directoryDescriptor)

        // v2026.07.18 P2 availability fix: daily rolling does not cap file size. Building one
        // aggregate Data (and then an atomic copy of it) made export memory proportional to every
        // retained line. Freeze the user-selected parent directory, stream through a fixed 64 KiB
        // buffer into a 0600 sibling temporary file, then atomically replace the final entry.
        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != ".." else {
            throw Self.posixError(EINVAL)
        }
        let destinationParent = destination.deletingLastPathComponent()
        let destinationStandardized = destination.standardizedFileURL.path.lowercased()
        let destinationResolved = destinationParent
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(destinationName, isDirectory: false)
            .path
            .lowercased()
        let sinkDirectories = [
            canonicalDirectoryPath.lowercased(),
            directory.resolvingSymlinksInPath().standardizedFileURL.path.lowercased(),
        ]
        for sinkDir in sinkDirectories {
            for candidate in [destinationStandardized, destinationResolved] {
                if candidate == sinkDir || Self.isStrictDescendant(candidate, of: sinkDir) {
                    throw Self.posixError(EINVAL)
                }
            }
        }
        let destinationDirectoryDescriptor = Darwin.open(
            destinationParent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard destinationDirectoryDescriptor >= 0 else { throw Self.posixError() }
        defer { Darwin.close(destinationDirectoryDescriptor) }

        var sinkDirStat = stat()
        var destDirStat = stat()
        if fstat(directoryDescriptor, &sinkDirStat) == 0,
           fstat(destinationDirectoryDescriptor, &destDirStat) == 0,
           EntryIdentity(sinkDirStat) == EntryIdentity(destDirStat) {
            throw Self.posixError(EINVAL)
        }

        let temporaryName = ".AmuxAIClean-Logs.\(UUID().uuidString).tmp"
        let outputDescriptor = openat(
            destinationDirectoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard outputDescriptor >= 0 else { throw Self.posixError() }
        var outputIsOpen = true
        var temporaryExists = true
        defer {
            if outputIsOpen { Darwin.close(outputDescriptor) }
            if temporaryExists {
                // Best-effort cleanup of our exact random sibling after a failed export. The
                // destination was never renamed in this branch, so no user-selected file changes.
                _ = unlinkat(destinationDirectoryDescriptor, temporaryName, 0)
            }
        }

        for entry in entries {
            let header = "\n===== \(entry.name) =====\n"
            try Self.writeAll(Array(header.utf8), to: outputDescriptor)
            let copied = try copyCanonicalEntryLocked(
                entry,
                directoryDescriptor: directoryDescriptor,
                outputDescriptor: outputDescriptor
            )
            if copied.totalBytes > 0, copied.lastByte != 0x0A {
                try Self.writeAll([0x0A], to: outputDescriptor)
            }
        }
        guard fsync(outputDescriptor) == 0 else { throw Self.posixError() }
        let closeResult = Darwin.close(outputDescriptor)
        // The descriptor is no longer ours even when close(2) reports an error. Mark ownership
        // before throwing so the failure cleanup cannot accidentally close a reused descriptor.
        outputIsOpen = false
        guard closeResult == 0 else { throw Self.posixError() }
        guard renameat(
            destinationDirectoryDescriptor,
            temporaryName,
            destinationDirectoryDescriptor,
            destinationName
        ) == 0 else {
            throw Self.posixError()
        }
        temporaryExists = false
        return entries.count
    }

    private func clearLogsLocked() throws -> Int {
        invalidateActiveHandleLocked()
        let directoryDescriptor = try openValidatedDirectoryLocked(createIfMissing: true)
        defer { Darwin.close(directoryDescriptor) }
        let entries = try canonicalLogEntriesLocked(directoryDescriptor: directoryDescriptor)
        // Explicit clear is the one operation whose contract intentionally discards queued
        // visibility replay; otherwise reopening below would resurrect lines the user just erased.
        // Do this only after the no-follow directory and inventory transaction succeeds: a
        // symlink/fail-closed attempt has not begun a clear and must retain the recovery window.
        discardPendingVisibilityWindowLocked()
        var removed = 0
        for entry in entries {
            try unlinkCanonicalEntryLocked(entry, directoryDescriptor: directoryDescriptor)
            removed += 1
        }
        rotateIfNeededLocked(now: Date())
        if case .unavailable(let failure) = health {
            throw failure
        }
        return removed
    }

    private func canonicalLogEntriesLocked(
        directoryDescriptor: Int32
    ) throws -> [CanonicalLogEntry] {
        guard directoryPathMatchesLocked(descriptor: directoryDescriptor) else {
            throw Self.posixError(EAGAIN)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard directoryPathMatchesLocked(descriptor: directoryDescriptor) else {
            throw Self.posixError(EAGAIN)
        }

        var entries: [CanonicalLogEntry] = []
        entries.reserveCapacity(names.count)
        for name in names where Self.isCanonicalLogFileName(name) {
            var information = stat()
            if fstatat(
                directoryDescriptor,
                name,
                &information,
                AT_SYMLINK_NOFOLLOW
            ) != 0 {
                if errno == ENOENT {
                    continue
                }
                throw Self.posixError()
            }
            // Matching-name directories, symlinks, devices and hard links are foreign entries.
            // They stay visible on disk but are never read, exported, purged or cleared.
            guard Self.isOwnedRegularFile(information) else { continue }
            entries.append(CanonicalLogEntry(
                name: name,
                identity: EntryIdentity(information),
                modificationSeconds: Int64(information.st_mtimespec.tv_sec)
            ))
        }
        return entries.sorted { $0.name < $1.name }
    }

    private func copyCanonicalEntryLocked(
        _ entry: CanonicalLogEntry,
        directoryDescriptor: Int32,
        outputDescriptor: Int32
    ) throws -> DescriptorCopySummary {
        let descriptor = openat(
            directoryDescriptor,
            entry.name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              Self.isOwnedRegularFile(information),
              EntryIdentity(information) == entry.identity,
              directoryPathMatchesLocked(descriptor: directoryDescriptor) else {
            throw Self.posixError(EAGAIN)
        }

        return try Self.copyDescriptorContents(
            from: descriptor,
            to: outputDescriptor,
            chunkBytes: Self.exportChunkBytes
        )
    }

    /// Internal deterministic seam used by package tests to prove the exporter never retains more
    /// than the configured fixed chunk while preserving byte order across partial reads/writes.
    static func copyDescriptorContents(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        chunkBytes: Int
    ) throws -> DescriptorCopySummary {
        guard chunkBytes > 0 else { throw Self.posixError(EINVAL) }
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        var totalBytes: Int64 = 0
        var lastByte: UInt8?
        var maximumChunkBytes = 0

        while true {
            let readCount: Int = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(sourceDescriptor, storage.baseAddress, chunkBytes)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw Self.posixError()
            }
            maximumChunkBytes = max(maximumChunkBytes, readCount)
            totalBytes += Int64(readCount)
            lastByte = buffer[readCount - 1]
            try buffer.withUnsafeBytes { storage in
                guard let baseAddress = storage.baseAddress else {
                    throw Self.posixError(EFAULT)
                }
                try writeAll(
                    UnsafeRawBufferPointer(start: baseAddress, count: readCount),
                    to: destinationDescriptor
                )
            }
        }
        return DescriptorCopySummary(
            totalBytes: totalBytes,
            lastByte: lastByte,
            maximumChunkBytes: maximumChunkBytes
        )
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { storage in
            try writeAll(storage, to: descriptor)
        }
    }

    private static func writeAll(
        _ bytes: UnsafeRawBufferPointer,
        to descriptor: Int32
    ) throws {
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                bytes.count - offset
            )
            if written < 0 {
                if errno == EINTR { continue }
                throw Self.posixError()
            }
            guard written > 0 else { throw Self.posixError(EIO) }
            offset += written
        }
    }

    /// unlinkat without AT_REMOVEDIR is deliberately non-recursive and never follows a symlink.
    /// The identity check rejects stable replacement; a last-instruction race can at worst unlink
    /// the directory entry itself, never recurse into or delete the replacement target.
    private func unlinkCanonicalEntryLocked(
        _ entry: CanonicalLogEntry,
        directoryDescriptor: Int32
    ) throws {
        var information = stat()
        guard fstatat(
            directoryDescriptor,
            entry.name,
            &information,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        Self.isOwnedRegularFile(information),
        EntryIdentity(information) == entry.identity,
        directoryPathMatchesLocked(descriptor: directoryDescriptor) else {
            throw Self.posixError(EAGAIN)
        }
        guard unlinkat(directoryDescriptor, entry.name, 0) == 0 else {
            throw Self.posixError()
        }
    }
}
