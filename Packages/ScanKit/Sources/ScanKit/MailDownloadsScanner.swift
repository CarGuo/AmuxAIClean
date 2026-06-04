import Foundation

/// Mail Downloads 旧附件扫描器（Step 12B / AUDIT §4.2 P1 / line 116 + 434）。
///
/// macOS Mail.app 在以下两类路径下保留用户已下载 / 已查看附件的本地副本：
///   1) 沙盒容器（10.13+）：
///      `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/<UUID>/<file>`
///   2) 历史路径：`~/Library/Mail Downloads/<UUID>/<file>`（旧 macOS / 部分迁移用户）
///
/// 这些副本删除后**不会**影响 `~/Library/Mail/V*/` 中的原始邮件存档。但删除是
/// 用户感知层面的"丢东西"高危动作，因此走严格 30 天双轴龄过滤：
///   - mtime <  now - ageDays  AND  atime <  now - ageDays  → 候选（两轴都老）
///   - 任一时间戳在 ageDays 窗内 → 排除（用户近期改写或读过）
///
/// **保护设计**：
///   - 只产出 dryRun 候选，不直接删；UI 层走二次确认
///   - 边界严格：`age > ageDays` 而非 `>=`，正好 30 天的不命中
///   - container 不存在 / 为空 → 返回空，不抛错
///   - 子目录递归（Mail.app 偶尔嵌套 UUID/UUID/<file>）
public actor MailDownloadsScanner {

    public struct Hit: Sendable, Hashable, Identifiable {
        public let url: URL
        public let sizeBytes: UInt64
        public let modificationDate: Date
        public let accessDate: Date
        public let ageDays: Double
        public var id: String { url.path }

        public init(
            url: URL,
            sizeBytes: UInt64,
            modificationDate: Date,
            accessDate: Date,
            ageDays: Double
        ) {
            self.url = url
            self.sizeBytes = sizeBytes
            self.modificationDate = modificationDate
            self.accessDate = accessDate
            self.ageDays = ageDays
        }
    }

    public struct Options: Sendable {
        public var ageDays: Double
        public var now: Date
        public init(ageDays: Double = 30, now: Date = Date()) {
            self.ageDays = ageDays
            self.now = now
        }
        public static let `default` = Options()
    }

    private let options: Options
    public init(options: Options = .default) { self.options = options }

    public func discover(containerRoots: [URL]) async -> [Hit] {
        let opts = options
        return await Task.detached(priority: .userInitiated) {
            MailDownloadsScanner.detect(containerRoots: containerRoots, options: opts)
        }.value
    }

    public nonisolated static func detect(
        containerRoots: [URL],
        options: Options = .default
    ) -> [Hit] {
        let fm = FileManager.default
        var hits: [Hit] = []
        let cutoff = options.now.addingTimeInterval(-options.ageDays * 86400)

        for root in containerRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .fileSizeKey,
                    .contentModificationDateKey, .contentAccessDateKey,
                ],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .fileSizeKey,
                    .contentModificationDateKey, .contentAccessDateKey,
                ])
                guard let v = values, v.isRegularFile == true else { continue }
                guard let mtime = v.contentModificationDate else { continue }
                let atime = v.contentAccessDate ?? mtime

                guard mtime < cutoff, atime < cutoff else { continue }

                let size = UInt64(v.fileSize ?? 0)
                let ageDays = options.now.timeIntervalSince(max(mtime, atime)) / 86400
                hits.append(Hit(
                    url: url,
                    sizeBytes: size,
                    modificationDate: mtime,
                    accessDate: atime,
                    ageDays: ageDays
                ))
            }
        }
        return hits
    }
}
