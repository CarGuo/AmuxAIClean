import Foundation

/// Time Machine 失败 / 中断备份扫描器（Step 12A / AUDIT §4.2 P1）。
///
/// macOS Time Machine 备份目标盘内部布局：
/// ```
/// <volumeRoot>/
///   Backups.backupdb/
///     <HostName>/
///       2026-06-04-080000/             # 已成功的快照
///       2026-06-04-101234.inProgress/  # 中断的快照（孤儿）
///       Latest -> 2026-06-04-080000    # 软链
/// ```
///
/// `.inProgress` 后缀目录是 backupd 在备份**进行中**临时持有的目录。正常完成会被
/// 重命名为不带后缀的 timestamp；但当系统崩溃 / 强制断电 / TM 盘被强制拔出时，
/// 这种孤儿目录会永远留在原地，浪费数十至数百 GB。
///
/// **保护设计**：mtime 在 `safetyWindowHours`（默认 24h）以内的 `.inProgress` 目录
/// 视为"可能正属于活跃 backupd 进程"，**绝不**返回到 hits；只有 mtime > 安全窗的才
/// 视为孤儿候选。整个扫描器走只读 + 保守语义，不直接删除任何东西，仅产出 dryRun 候选。
public actor TimeMachineFailedBackupScanner {

    public struct Hit: Sendable, Hashable, Identifiable {
        public let url: URL
        public let host: String
        public let modificationDate: Date
        public let ageHours: TimeInterval
        public var id: String { url.path }

        public init(url: URL, host: String, modificationDate: Date, ageHours: TimeInterval) {
            self.url = url
            self.host = host
            self.modificationDate = modificationDate
            self.ageHours = ageHours
        }
    }

    public struct Options: Sendable {
        public var safetyWindowHours: TimeInterval
        public var now: Date
        public init(safetyWindowHours: TimeInterval = 24, now: Date = Date()) {
            self.safetyWindowHours = safetyWindowHours
            self.now = now
        }
        public static let `default` = Options()
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    public func discover(volumeRoot: URL) async -> [Hit] {
        let opts = options
        return await Task.detached(priority: .userInitiated) {
            TimeMachineFailedBackupScanner.detect(volumeRoot: volumeRoot, options: opts)
        }.value
    }

    public nonisolated static func detect(
        volumeRoot: URL,
        options: Options = .default
    ) -> [Hit] {
        let fm = FileManager.default
        let dbRoot = volumeRoot.appendingPathComponent("Backups.backupdb", isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dbRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let hosts = try? fm.contentsOfDirectory(
            at: dbRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var hits: [Hit] = []
        let cutoff = options.now.addingTimeInterval(-options.safetyWindowHours * 3600)

        for hostDir in hosts {
            var hostIsDir: ObjCBool = false
            guard fm.fileExists(atPath: hostDir.path, isDirectory: &hostIsDir),
                  hostIsDir.boolValue else { continue }

            guard let entries = try? fm.contentsOfDirectory(
                at: hostDir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                guard entry.lastPathComponent.hasSuffix(".inProgress") else { continue }
                var entryIsDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir),
                      entryIsDir.boolValue else { continue }

                let attrs = try? fm.attributesOfItem(atPath: entry.path)
                guard let mtime = attrs?[.modificationDate] as? Date else { continue }
                guard mtime <= cutoff else { continue } // 安全窗内 → 跳过

                let ageHours = options.now.timeIntervalSince(mtime) / 3600
                hits.append(Hit(
                    url: entry,
                    host: hostDir.lastPathComponent,
                    modificationDate: mtime,
                    ageHours: ageHours
                ))
            }
        }
        return hits
    }
}
