import Foundation
import HeuristicKit

/// HL 行为收集器 —— 把 UI 层 trash/keep 事件喂给 HeuristicEngine 并持久化到磁盘。
///
/// **持久化路径**：`~/Library/Application Support/GSYCleanMac/heuristic.json`
///
/// 设计要点：
/// - actor wrapper，对外只暴露三个 fire-and-forget 入口（trashed / kept / restored）
/// - 启动时若 JSON 已存在则尝试 load；失败不影响功能（HL 是辅助信号，不是关键路径）
/// - 每次 record 后异步 persist —— 即使 App 异常退出也最多丢最近一次行为
public actor HeuristicRecorder {
    private let engine: HeuristicEngine
    private let storeURL: URL
    private var loaded: Bool = false

    public init(engine: HeuristicEngine = HeuristicEngine(),
                storeURL: URL = HeuristicRecorder.defaultStoreURL()) {
        self.engine = engine
        self.storeURL = storeURL
    }

    public static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base: URL
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = support.appendingPathComponent("GSYCleanMac", isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/GSYCleanMac",
                                        isDirectory: true)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("heuristic.json")
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        if FileManager.default.fileExists(atPath: storeURL.path) {
            try? await engine.load(from: storeURL)
        }
    }

    public func recordTrashed(paths: [String], at time: Date = Date()) async {
        await ensureLoaded()
        for p in paths {
            await engine.record(action: .trashedPath(p, timestamp: time))
        }
        try? await engine.persist(to: storeURL)
    }

    public func recordKept(paths: [String], at time: Date = Date()) async {
        await ensureLoaded()
        for p in paths {
            await engine.record(action: .keptPath(p, timestamp: time))
        }
        try? await engine.persist(to: storeURL)
    }

    public func recordRestored(paths: [String], at time: Date = Date()) async {
        await ensureLoaded()
        for p in paths {
            await engine.record(action: .restoredPath(p, timestamp: time))
        }
        try? await engine.persist(to: storeURL)
    }

    public func score(of path: String) async -> Double {
        await ensureLoaded()
        return await engine.score(path: path)
    }
}
