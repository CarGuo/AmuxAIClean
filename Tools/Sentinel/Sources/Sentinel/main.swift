import Darwin
import Foundation
import CoreServices

/// AmuxAIClean Sentinel Login Agent
///
/// 登录用户态后台进程，负责两个场景的发现。必须以登录用户身份运行，确保
/// `homeDirectoryForCurrentUser` 指向该用户的 Trash/Downloads，而不是 `/var/root`：
///
/// **场景 1 · 卸载残留发现**：
///   FSEventStream 监听 `~/.Trash`，检测 `.app` / `.bundle` 进入废纸篓，
///   触发 `amuxaiclean://uninstall?path=...` 唤起主 App 跳到 UninstallScreen。
///
/// **场景 2 · 推荐清理发现**：
///   FSEventStream 监听 3 个清理热点：
///   - `~/Downloads`
///   - `~/Library/Caches`
///   - `~/Library/Developer/Xcode/DerivedData`
///   累积事件到 rolling top-100 ringbuffer，写到
///   `~/Library/Application Support/AmuxAIClean/sentinel-pending.json`，
///   持续 5GB 增量阈值后触发 `amuxaiclean://action/scan/full`。
///
/// 设计：参见 [docs/SENTINEL_DESIGN.md].
///
/// 入口约束：
/// - 仅依赖 Foundation + CoreServices（不引 SwiftUI / AppUI / SafetyKit）
/// - 目标 RSS < 5 MB / CPU < 1%（静默期）
/// - 单文件 main.swift 可独立 `swift run amuxaiclean-sentinel` 验证逻辑

// v2026.07.18 P1 root-domain boundary: this must remain the first executable statement.
// Historical LaunchDaemons are migration-only; a stale root job must not initialize a Home
// path, log sink, persistence file or listener from the current user-Agent implementation.
if geteuid() == 0 {
    let diagnostic = "AmuxAIClean Sentinel refuses privileged execution\n"
    diagnostic.withCString { bytes in
        _ = Darwin.write(STDERR_FILENO, bytes, strlen(bytes))
    }
    _exit(EX_NOPERM)
}

let log = SentinelLog.shared
log.info("Sentinel user agent starting (pid=\(getpid())) home=\(FileManager.default.homeDirectoryForCurrentUser.path)")

let supportDir = SentinelPaths.supportDirectory
do {
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
} catch {
    // v2026.07.18：持久化目录失败会让候选证据丢失，不能用 try? 静默伪装成功。
    log.error("Sentinel support directory creation failed: \(error)")
}

let pendingPath = supportDir.appendingPathComponent("sentinel-pending.json").path
let ringBuffer = HotspotRingBuffer(capacity: 100, persistPath: pendingPath)
ringBuffer.loadFromDisk()

let dispatcher = URLSchemeDispatcher()
let trashListener = TrashListener(dispatcher: dispatcher)
let hotspotListener = HotspotListener(ringBuffer: ringBuffer, dispatcher: dispatcher)

trashListener.start()
hotspotListener.start()

log.info("Sentinel user agent ready, entering run loop")
CFRunLoopRun()

// MARK: - 路径常量

enum SentinelPaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var trashDirectory: URL {
        home.appendingPathComponent(".Trash")
    }

    static var hotspots: [URL] {
        [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
        ]
    }

    static var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/AmuxAIClean")
    }
}

// MARK: - 用户态本地日志

/// `@unchecked Sendable` synchronization basis: `queue` exclusively owns the timer callback,
/// retention timestamp and every filesystem write. Immutable path/timing constants are fixed
/// before the singleton is published.
final class SentinelLog: @unchecked Sendable {
    static let shared = SentinelLog()
    private let queue = DispatchQueue(label: "com.amux.ai.Clean.sentinel.log")
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AmuxAIClean", isDirectory: true)
    private static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let pruneCheckInterval: TimeInterval = 60 * 60
    // v2026.07.18 build fix: DispatchSourceTimer accepts a TimeInterval for cadence but its
    // leeway uses DispatchTimeInterval, which has no `.minutes` case on supported toolchains.
    private static let pruneLeewaySeconds = 10 * 60
    private let retentionTimer: DispatchSourceTimer
    /// Accessed only on `queue`; the timer and emit path share the same serialization boundary.
    private var lastPruneCheck = Date.distantPast

    private init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        retentionTimer = timer
        queue.sync { pruneExpiredLogsIfNeeded(now: Date(), force: true) }
        // v2026.07.18: a Login Agent may stay alive for weeks. Startup-only pruning violates the
        // seven-day privacy contract, so both an hourly timer and the next write after wake check
        // retention. The serial queue owns every mutable field behind @unchecked Sendable.
        timer.schedule(
            deadline: .now() + Self.pruneCheckInterval,
            repeating: Self.pruneCheckInterval,
            leeway: .seconds(Self.pruneLeewaySeconds)
        )
        timer.setEventHandler { [weak self] in
            self?.pruneExpiredLogsIfNeeded(now: Date())
        }
        timer.resume()
    }

    func info(_ message: @autoclosure @escaping () -> String) {
        emit("INFO ", message())
    }

    func warn(_ message: @autoclosure @escaping () -> String) {
        emit("WARN ", message())
    }

    func error(_ message: @autoclosure @escaping () -> String) {
        emit("ERROR", message())
    }

    private func emit(_ level: String, _ message: String) {
        queue.async {
            let now = Date()
            self.pruneExpiredLogsIfNeeded(now: now)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let ts = formatter.string(from: now)
            let data = Data("[\(ts)] [\(level)] \(message)\n".utf8)
            do {
                let url = self.dailyLogURL(for: now)
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                // v2026.07.18 privacy boundary: stderr is system managed and has no retention
                // contract we control. Do not mirror the original message because it commonly
                // contains absolute paths; emit only a stable failure marker.
                FileHandle.standardError.write(Data("Sentinel local log write failed\n".utf8))
            }
        }
    }

    private func dailyLogURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return directory.appendingPathComponent(
            "AmuxAIClean-Sentinel-\(formatter.string(from: date)).log"
        )
    }

    private func pruneExpiredLogsIfNeeded(now: Date, force: Bool = false) {
        guard force || now.timeIntervalSince(lastPruneCheck) >= Self.pruneCheckInterval else {
            return
        }
        lastPruneCheck = now
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let cutoff = now.addingTimeInterval(-Self.retention)
            for file in files where file.lastPathComponent.hasPrefix("AmuxAIClean-Sentinel-") {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified < cutoff else { continue }
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            // Best-effort retention cleanup: preserve monitor behavior and expose only a local
            // technical diagnostic. No user data or raw error crosses into the App UI.
            FileHandle.standardError.write(Data("Sentinel log setup failed\n".utf8))
        }
    }
}

// MARK: - Trash 监听

final class TrashListener: @unchecked Sendable {
    private let dispatcher: URLSchemeDispatcher
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.amux.ai.Clean.sentinel.trash", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?
    private var pendingPaths: Set<String> = []

    init(dispatcher: URLSchemeDispatcher) {
        self.dispatcher = dispatcher
    }

    func start() {
        let path = SentinelPaths.trashDirectory.path
        guard FileManager.default.fileExists(atPath: path) else {
            SentinelLog.shared.warn("Trash directory missing: \(path)")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: UInt32 = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let listener = Unmanaged<TrashListener>.fromOpaque(info).takeUnretainedValue()
                guard let pathsArr = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
                let flagsBuf = UnsafeBufferPointer(start: flags, count: count)
                listener.handleEvents(paths: pathsArr, flags: Array(flagsBuf))
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )

        guard let stream else {
            SentinelLog.shared.error("FSEventStreamCreate failed for trash")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        SentinelLog.shared.info("TrashListener started: \(path)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, flag) in zip(paths, flags) {
            guard TrashListener.isAppBundle(path: path) else { continue }
            // 只关心新建事件（用户拖入）
            let isCreated = (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
            let isRenamed = (flag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
            guard isCreated || isRenamed else { continue }
            pendingPaths.insert(path)
        }
        guard !pendingPaths.isEmpty else { return }
        scheduleDebounce()
    }

    private func scheduleDebounce() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.pendingPaths
            self.pendingPaths.removeAll()
            for path in snapshot {
                self.dispatcher.openUninstall(path: path)
            }
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// 判定路径是否是 .app / .bundle 形态。
    static func isAppBundle(path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".app") || lower.hasSuffix(".bundle")
    }
}

// MARK: - Hotspot 监听

struct HotspotEvent: Codable, Hashable {
    let path: String
    let detectedAt: Date
    let sizeHint: Int64?
}

final class HotspotRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let persistPath: String
    private let queue = DispatchQueue(label: "com.amux.ai.Clean.sentinel.ring", qos: .utility)
    private var events: [HotspotEvent] = []

    init(capacity: Int, persistPath: String) {
        self.capacity = capacity
        self.persistPath = persistPath
    }

    func append(_ event: HotspotEvent) {
        queue.sync {
            events.removeAll(where: { $0.path == event.path })
            events.append(event)
            while events.count > capacity {
                events.removeFirst()
            }
            persistLocked()
        }
    }

    func snapshot() -> [HotspotEvent] {
        queue.sync { events }
    }

    func loadFromDisk() {
        queue.sync {
            let url = URL(fileURLWithPath: persistPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode([HotspotEvent].self, from: data)
                events = decoded
                SentinelLog.shared.info("RingBuffer loaded \(decoded.count) events from disk")
            } catch {
                // v2026.07.18：损坏或不可读的候选文件保留在原位，记录错误供诊断；
                // 不用空数组覆盖它，也不把读取失败伪装成“没有历史事件”。
                SentinelLog.shared.error("RingBuffer load failed: \(error)")
            }
        }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(events)
            try data.write(to: URL(fileURLWithPath: persistPath), options: .atomic)
        } catch {
            SentinelLog.shared.error("RingBuffer persist failed: \(error)")
        }
    }
}

final class HotspotListener: @unchecked Sendable {
    private let ringBuffer: HotspotRingBuffer
    private let dispatcher: URLSchemeDispatcher
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.amux.ai.Clean.sentinel.hotspot", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?
    private var pendingEvents: [HotspotEvent] = []
    /// 累计 5GB 后触发推荐扫描通知
    private static let openURLBytesThreshold: Int64 = 5 * 1024 * 1024 * 1024
    private var bytesSinceLastNotify: Int64 = 0

    init(ringBuffer: HotspotRingBuffer, dispatcher: URLSchemeDispatcher) {
        self.ringBuffer = ringBuffer
        self.dispatcher = dispatcher
    }

    func start() {
        let paths = SentinelPaths.hotspots.map(\.path).filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard !paths.isEmpty else {
            SentinelLog.shared.warn("No hotspot directories exist")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: UInt32 = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let listener = Unmanaged<HotspotListener>.fromOpaque(info).takeUnretainedValue()
                guard let pathsArr = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
                let flagsBuf = UnsafeBufferPointer(start: flags, count: count)
                listener.handleEvents(paths: pathsArr, flags: Array(flagsBuf))
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        )

        guard let stream else {
            SentinelLog.shared.error("FSEventStreamCreate failed for hotspots")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        let joined = paths.joined(separator: ", ")
        SentinelLog.shared.info("HotspotListener started: \(joined)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        let now = Date()
        for (path, flag) in zip(paths, flags) {
            // 黑名单：Spotlight / fseventsd 内部目录
            if HotspotListener.isBlacklisted(path: path) { continue }
            let isCreated = (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
            let isModified = (flag & UInt32(kFSEventStreamEventFlagItemModified)) != 0
            guard isCreated || isModified else { continue }
            let size = HotspotListener.fileSize(path: path)
            if let s = size {
                bytesSinceLastNotify += s
            }
            pendingEvents.append(HotspotEvent(path: path, detectedAt: now, sizeHint: size))
        }
        guard !pendingEvents.isEmpty else { return }
        scheduleDebounce()
    }

    private func scheduleDebounce() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.pendingEvents
            self.pendingEvents.removeAll()
            for event in snapshot {
                self.ringBuffer.append(event)
            }
            // 阈值触发推荐扫描通知
            if self.bytesSinceLastNotify >= HotspotListener.openURLBytesThreshold {
                self.bytesSinceLastNotify = 0
                self.dispatcher.openScanFull()
            }
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }

    static func isBlacklisted(path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("/.spotlight-v100/")
            || lower.contains("/.fseventsd/")
            || lower.contains("/.documentrevisions-v100/")
            || lower.hasSuffix(".tmp")
    }

    static func fileSize(path: String) -> Int64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Int64(st.st_size)
    }
}

// MARK: - URL Scheme dispatcher（拉起主 App）

final class URLSchemeDispatcher: Sendable {
    func openUninstall(path: String) {
        // v2026.07.18: `.urlQueryAllowed` still contains delimiters such as `&`; hand-built query
        // text therefore truncates legal filenames. URLQueryItem owns escaping and round-trips
        // ampersands, hashes, question marks, plus signs, spaces and Unicode as one value.
        var components = URLComponents()
        components.scheme = "amuxaiclean"
        components.host = "uninstall"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else {
            SentinelLog.shared.warn("openUninstall URL construct failed: \(path)")
            return
        }
        SentinelLog.shared.info("Dispatching uninstall: \(url.absoluteString)")
        Self.openURL(url)
    }

    func openScanFull() {
        guard let url = URL(string: "amuxaiclean://action/scan/full") else { return }
        SentinelLog.shared.info("Dispatching scan/full: \(url.absoluteString)")
        Self.openURL(url)
    }

    /// 用 `/usr/bin/open` 间接拉起主 App，避免后台 Agent 直接 link AppKit。
    private static func openURL(_ url: URL) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-g", url.absoluteString]
        do {
            try task.run()
        } catch {
            SentinelLog.shared.error("open launch failed: \(error)")
        }
    }
}
