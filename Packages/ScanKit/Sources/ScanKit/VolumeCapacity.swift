import Foundation

/// v1.3：磁盘卷容量信息 + 类系统设置「Macintosh HD - 482.95 GB of 494.38 GB used」展示。
///
/// 数据源：`URL.resourceValues(forKeys:)` 拿
/// - `volumeTotalCapacityKey`（卷总容量）
/// - `volumeAvailableCapacityForImportantUsageKey`（可用，含可释放的 purgeable 空间，
///   与 Finder「关于本机 → 储存空间」一致）
///
/// 为什么不用 statfs？statfs 拿到的可用容量**不含可净化空间** (purgeable，如 Time Machine
/// 本地快照、iCloud 上传后的本地副本)。Finder 显示 482.95 / 494.38 用的是 forImportantUsage，
/// 我们必须对齐它，否则用户会看到"我们说还有 11G，Finder 说还有 50G"。
///
/// 分类组成：
/// - `cleanable`：本 App 在当前会话内"识别为可清理"的字节数（来自 ScanCoordinator 的累计）
/// - `userDocuments`：~/Documents + ~/Desktop + ~/Downloads（粗估，避免扫整盘开销）
/// - `applications`：/Applications + ~/Applications
/// - `systemAndOther`：用 totalCapacity - available - 上述已知三类，兜底放系统/其他
///
/// 注意：分类堆叠条**不要求精确**，目的是给用户"我清完后空闲变多了"的视觉反馈。
/// 跟 ScanCoordinator 联动后，cleanable 段会随用户勾选/删除变化（绿色），其余段保持稳定。
public enum VolumeCapacity {

    public struct Snapshot: Sendable, Equatable {
        public let volumeName: String
        /// 卷总容量（字节）
        public let totalBytes: Int64
        /// 可用容量（含 purgeable，对齐 Finder）
        public let availableBytes: Int64
        /// 已用容量 = totalBytes - availableBytes
        public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

        public init(volumeName: String, totalBytes: Int64, availableBytes: Int64) {
            self.volumeName = volumeName
            self.totalBytes = totalBytes
            self.availableBytes = availableBytes
        }
    }

    /// 探测指定目录所在卷的容量。失败返回 `nil`。
    /// 默认探 `/`，即用户日常理解的"Macintosh HD"。
    public static func probe(at path: String = "/") -> Snapshot? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let total = Int64(values.volumeTotalCapacity ?? 0)
        // forImportantUsage 才是 Finder 口径；不可用时 fallback 到普通 available
        let available: Int64
        if let importantUsage = values.volumeAvailableCapacityForImportantUsage {
            available = importantUsage
        } else if let plain = values.volumeAvailableCapacity {
            available = Int64(plain)
        } else {
            return nil
        }
        let name = values.volumeName ?? "Macintosh HD"

        // 防御：若内核给出 available > total（极小概率，热重挂载窗口）则裁掉
        let safeAvail = min(available, total)
        return Snapshot(volumeName: name, totalBytes: total, availableBytes: safeAvail)
    }
}
