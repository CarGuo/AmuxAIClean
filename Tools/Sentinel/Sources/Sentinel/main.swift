import Foundation
import CoreServices

/// GSYCleanMac Sentinel Daemon
///
/// 后台守护进程，负责两个场景的发现：
///
/// **场景 1 · 卸载残留发现**：
///   FSEventStream 监听 `~/.Trash`，检测 `.app` / `.bundle` 进入废纸篓，
///   触发 `gsycleanmac://uninstall?path=...` 唤起主 App 跳到 UninstallScreen。
///
/// **场景 2 · 推荐清理发现**：
///   FSEventStream 监听 4 个清理热点：
///   - `~/Downloads`
///   - `~/Library/Caches`
///   - `~/Library/Developer/Xcode/DerivedData`
///   - 配置中追加的 node_modules / Pods 等
///   累积事件到 rolling top-100 ringbuffer，写到
///   `~/Library/Application Support/GSYCleanMac/sentinel-pending.json`，
///   持续 5GB 增量阈值后触发 `gsycleanmac://action/scan/full`。
///
/// 设计：参见 [docs/SENTINEL_DESIGN.md].
///
/// 入口约束：
/// - 仅依赖 Foundation + CoreServices（不引 SwiftUI / GRDB / AppUI / SafetyKit）
/// - 目标 RSS < 5 MB / CPU < 1%（静默期）
/// - 单文件 main.swift 可独立 `swift run gsycleanmac-sentinel` 验证逻辑

let log = SentinelLog.shared
log.info("Sentinel daemon starting (pid=\(getpid()))")

let supportDir = SentinelPaths.supportDirectory
try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

let pendingPath = supportDir.appendingPathComponent("sentinel-pending.json").path
let ringBuffer = HotspotRingBuffer(capacity: 100, persistPath: pendingPath)
ringBuffer.loadFromDisk()

let dispatcher = URLSchemeDispatcher()
let trashListener = TrashListener(dispatcher: dispatcher)
let hotspotListener = HotspotListener(ringBuffer: ringBuffer, dispatcher: dispatcher)

trashListener.start()
hotspotListener.start()

log.info("Sentinel daemon ready, entering run loop")
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
        home.appendingPathComponent("Library/Application Support/GSYCleanMac")
    }
}

// MARK: - 简易日志（os.log 太重，daemon 极简打印 stderr 即可）

final class SentinelLog: @unchecked Sendable {
    static let shared = SentinelLog()
    private let queue = DispatchQueue(label: "com.guoshuyu.cleanmac.sentinel.log")

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
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let ts = formatter.string(from: Date())
            FileHandle.standardError.write(Data("[\(ts)] [\(level)] \(message)\n".utf8))
        }
    }
}

// MARK: - Trash 监听

final class TrashListener: @unchecked Sendable {
    private let dispatcher: URLSchemeDispatcher
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.guoshuyu.cleanmac.sentinel.trash", qos: .utility)
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
    private let queue = DispatchQueue(label: "com.guoshuyu.cleanmac.sentinel.ring", qos: .utility)
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
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: persistPath)) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([HotspotEvent].self, from: data) {
                events = decoded
                SentinelLog.shared.info("RingBuffer loaded \(decoded.count) events from disk")
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
    private let queue = DispatchQueue(label: "com.guoshuyu.cleanmac.sentinel.hotspot", qos: .utility)
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

final class URLSchemeDispatcher: @unchecked Sendable {
    func openUninstall(path: String) {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            SentinelLog.shared.warn("openUninstall percent-encoding failed: \(path)")
            return
        }
        guard let url = URL(string: "gsycleanmac://uninstall?path=\(encoded)") else {
            SentinelLog.shared.warn("openUninstall URL construct failed: \(path)")
            return
        }
        SentinelLog.shared.info("Dispatching uninstall: \(url.absoluteString)")
        Self.openURL(url)
    }

    func openScanFull() {
        guard let url = URL(string: "gsycleanmac://action/scan/full") else { return }
        SentinelLog.shared.info("Dispatching scan/full: \(url.absoluteString)")
        Self.openURL(url)
    }

    /// 用 `/usr/bin/open` 间接拉起主 App，避免 daemon 直接 link AppKit。
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
