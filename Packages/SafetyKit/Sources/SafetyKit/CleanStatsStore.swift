import Foundation
import LogKit

/// Mole 对齐 M3-T6：累计清理统计 + 趋势可视化数据源。
///
/// 对标 Mole `core/history.sh` 的"累计释放空间 / 历史记录"概念，但走更
/// SwiftUI-friendly 的 actor + 按日聚合（day buckets）结构：
///
///   - **Event 流**：每次成功清理事件追加一条 `Event(timestamp, bytesReclaimed, category)`
///   - **按日聚合**：默认查询 30 天趋势返回 `[DayBucket(day, totalBytes, eventCount)]`
///   - **类别分布**：30 天内 / 全部，按 `category` 聚合 `[CategoryBucket]`
///   - **累计总量**：`totalBytesReclaimed()` —— 永不归零（除非 reset）
///
/// 持久化：JSON 文件 `~/Library/Application Support/AmuxAIClean/clean_stats.json`，
/// 用户可手编。文件包含 events 数组 + version + 滚动 windows（避免无限增长，
/// 保留最近 365 天 + 全量累计 totalBytes）。
///
/// 测试注入：`storageURL: nil` 走纯内存；指向临时文件做持久化往返。
public actor CleanStatsStore {

    public struct Event: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let timestamp: Date
        public let bytesReclaimed: Int64
        public let bytesTrashed: Int64
        public let category: String

        public init(id: UUID = UUID(), timestamp: Date = Date(),
                    bytesReclaimed: Int64, bytesTrashed: Int64 = 0, category: String) {
            self.id = id
            self.timestamp = timestamp
            self.bytesReclaimed = bytesReclaimed
            self.bytesTrashed = bytesTrashed
            self.category = category
        }

        private enum CodingKeys: String, CodingKey {
            case id, timestamp, bytesReclaimed, bytesTrashed, category
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(UUID.self, forKey: .id)
            self.timestamp = try container.decode(Date.self, forKey: .timestamp)
            self.bytesReclaimed = try container.decode(Int64.self, forKey: .bytesReclaimed)
            self.bytesTrashed = try container.decodeIfPresent(Int64.self, forKey: .bytesTrashed) ?? 0
            self.category = try container.decode(String.self, forKey: .category)
        }
    }

    public struct DayBucket: Sendable, Hashable {
        public let day: Date          // 当天 00:00（calendar startOfDay）
        public let totalBytes: Int64
        public let eventCount: Int
    }

    public struct CategoryBucket: Sendable, Hashable {
        public let category: String
        public let totalBytes: Int64
        public let eventCount: Int
    }

    private struct Persisted: Codable {
        let version: Int
        let lifetimeTotalBytes: Int64
        let lifetimeTrashedBytes: Int64?
        let events: [Event]
    }

    /// 保留窗口：超出 retentionDays 的事件落档时丢弃，但 `lifetimeTotalBytes` 保留。
    public let retentionDays: Int

    /// 默认 `~/Library/Application Support/AmuxAIClean/clean_stats.json`。
    public static let defaultStorageURL: URL? = {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else { return nil }
        return appSupport
            .appendingPathComponent("AmuxAIClean", isDirectory: true)
            .appendingPathComponent("clean_stats.json")
    }()

    public static let shared = CleanStatsStore(storageURL: defaultStorageURL)

    private let storageURL: URL?
    private let calendar: Calendar
    private var inMemoryEvents: [Event] = []
    private var lifetimeBytes: Int64 = 0
    private var lifetimeTrashedBytes: Int64 = 0
    private var loaded = false

    public init(storageURL: URL?, retentionDays: Int = 365,
                calendar: Calendar = .init(identifier: .gregorian)) {
        self.storageURL = storageURL
        self.retentionDays = retentionDays
        var cal = calendar
        cal.timeZone = TimeZone.current
        self.calendar = cal
    }

    // MARK: - 写入

    public func record(bytesReclaimed: Int64, category: String,
                       timestamp: Date = Date()) async {
        loadIfNeeded()
        guard bytesReclaimed > 0 else {
            GSYLog.debug(.app, "CleanStatsStore 忽略 0 字节事件 category=\(category)")
            return
        }
        let event = Event(timestamp: timestamp,
                          bytesReclaimed: bytesReclaimed,
                          bytesTrashed: 0,
                          category: category)
        inMemoryEvents.append(event)
        lifetimeBytes &+= bytesReclaimed
        pruneIfNeeded()
        await persist()
    }

    /// 记录移入废纸篓的事件：同卷移入废纸篓尚未释放物理磁盘空间，因此单独统计 `bytesTrashed`，
    /// 不直接虚增 `totalBytesReclaimed()`（除非显式传入已确认实际释放的 `bytesReclaimed`）。
    public func recordTrashed(bytesTrashed: Int64,
                              bytesReclaimed: Int64 = 0,
                              category: String,
                              timestamp: Date = Date()) async {
        loadIfNeeded()
        guard bytesTrashed > 0 || bytesReclaimed > 0 else {
            GSYLog.debug(.app, "CleanStatsStore 忽略 0 字节移入废纸篓事件 category=\(category)")
            return
        }
        let clampedReclaimed = max(0, bytesReclaimed)
        let clampedTrashed = max(0, bytesTrashed)
        let event = Event(timestamp: timestamp,
                          bytesReclaimed: clampedReclaimed,
                          bytesTrashed: clampedTrashed,
                          category: category)
        inMemoryEvents.append(event)
        lifetimeBytes &+= clampedReclaimed
        lifetimeTrashedBytes &+= clampedTrashed
        pruneIfNeeded()
        await persist()
    }

    /// 清空数据（保留 retentionDays 设置）。`alsoResetLifetime=true` 同时把累计归零。
    public func reset(alsoResetLifetime: Bool = false) async {
        loadIfNeeded()
        inMemoryEvents.removeAll()
        if alsoResetLifetime {
            lifetimeBytes = 0
            lifetimeTrashedBytes = 0
        }
        await persist()
    }

    // MARK: - 读取

    public func totalBytesReclaimed() -> Int64 {
        loadIfNeeded()
        return lifetimeBytes
    }

    public func totalBytesTrashed() -> Int64 {
        loadIfNeeded()
        return lifetimeTrashedBytes
    }

    public func events() -> [Event] {
        loadIfNeeded()
        return inMemoryEvents
    }

    /// 按天聚合。`days=30` 返回近 30 天（含今天）的 DayBucket 数组，按日期升序。
    /// 没有事件的那一天**不**会出现（调用方按需补 0）。
    public func dailyTrend(days: Int, referenceDate: Date = Date()) -> [DayBucket] {
        loadIfNeeded()
        let endDay = calendar.startOfDay(for: referenceDate)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay) else {
            return []
        }
        let filtered = inMemoryEvents.filter { event in
            let day = calendar.startOfDay(for: event.timestamp)
            return day >= startDay && day <= endDay
        }
        var bucketMap: [Date: (Int64, Int)] = [:]
        for ev in filtered {
            let day = calendar.startOfDay(for: ev.timestamp)
            let prev = bucketMap[day] ?? (0, 0)
            bucketMap[day] = (prev.0 &+ ev.bytesReclaimed, prev.1 + 1)
        }
        return bucketMap
            .map { DayBucket(day: $0.key, totalBytes: $0.value.0, eventCount: $0.value.1) }
            .sorted { $0.day < $1.day }
    }

    /// 按类别聚合。`days=nil` -> 全量（事件流内的，不含已被 retention 抹掉的远古）。
    public func categoryDistribution(days: Int? = nil, referenceDate: Date = Date())
    -> [CategoryBucket]
    {
        loadIfNeeded()
        let scope: [Event]
        if let days {
            let endDay = calendar.startOfDay(for: referenceDate)
            guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay) else {
                return []
            }
            scope = inMemoryEvents.filter { event in
                let day = calendar.startOfDay(for: event.timestamp)
                return day >= startDay && day <= endDay
            }
        } else {
            scope = inMemoryEvents
        }
        var map: [String: (Int64, Int)] = [:]
        for ev in scope {
            let prev = map[ev.category] ?? (0, 0)
            map[ev.category] = (prev.0 &+ ev.bytesReclaimed, prev.1 + 1)
        }
        return map
            .map { CategoryBucket(category: $0.key, totalBytes: $0.value.0, eventCount: $0.value.1) }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: - 持久化

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = storageURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try decoder.decode(Persisted.self, from: data)
            inMemoryEvents = persisted.events
            lifetimeBytes = persisted.lifetimeTotalBytes
            lifetimeTrashedBytes = persisted.lifetimeTrashedBytes
                ?? persisted.events.reduce(0) { $0 &+ $1.bytesTrashed }
            GSYLog.info(.app,
                        "CleanStats loaded events=\(inMemoryEvents.count) lifetime=\(lifetimeBytes) trashed=\(lifetimeTrashedBytes)")
        } catch {
            GSYLog.warning(.app, "CleanStats 加载失败 err=\(error)")
        }
    }

    private func pruneIfNeeded() {
        guard retentionDays > 0 else { return }
        let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: Date())
            ?? Date.distantPast
        inMemoryEvents.removeAll { $0.timestamp < cutoff }
    }

    private func persist() async {
        guard let url = storageURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let persisted = Persisted(version: 1,
                                      lifetimeTotalBytes: lifetimeBytes,
                                      lifetimeTrashedBytes: lifetimeTrashedBytes,
                                      events: inMemoryEvents)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: url, options: .atomic)
        } catch {
            GSYLog.warning(.app, "CleanStats 持久化失败 err=\(error)")
        }
    }
}
