import Foundation

/// v1.3：磁盘卷容量信息 + 类系统设置「Macintosh HD - 482.95 GB of 494.38 GB used」展示。
///
/// 数据源：`URL.resourceValues(forKeys:)` 拿
/// - `volumeTotalCapacityKey`（卷总容量）
/// - `volumeAvailableCapacityKey`（当前普通文件系统可用容量，主显示口径）
/// - `volumeAvailableCapacityForImportantUsageKey`（macOS 估算可供重要用途使用的容量）
///
/// v2026.07.15 根因修正：主 headline、`usedBytes`、容量条和 Available 行必须只使用
/// 普通 `volumeAvailableCapacity`。`forImportantUsage` 会把系统预计可回收的数据计入未来
/// 可用空间，受 MobileAsset、缓存与 APFS 快照当前状态影响，不能替代真实空闲。
/// 两个公开口径存在可信且非负的差值时，只把差值作为独立估算展示；它不是一份可由
/// 本 App 逐文件删除的清单，也不能归因到某个日志标签或目录。
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
        /// 当前普通文件系统可用容量，来自 `volumeAvailableCapacityKey`。
        ///
        /// 这是 headline、`usedBytes`、容量条与 Available 行的唯一可用空间口径；
        /// 禁止用 `volumeAvailableCapacityForImportantUsageKey` 覆盖它。
        public let availableBytes: Int64
        /// macOS 预计可回收容量，来自
        /// `volumeAvailableCapacityForImportantUsage - volumeAvailableCapacity`。
        ///
        /// `nil` 表示两个系统口径不可比较；0 表示系统明确返回了相同口径。
        /// 该值只用于解释，不参与主 used/available 数字，也不是本 App 的清理清单。
        public let estimatedReclaimableBytes: Int64?
        /// 已用容量 = totalBytes - availableBytes
        public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

        /// 仅供解释的“若 macOS 完成预计回收后可用”口径。
        /// 主 UI 不得用它替换 `availableBytes` 或反推 `usedBytes`。
        public var availableIfReclaimedBytes: Int64? {
            guard let estimatedReclaimableBytes else { return nil }
            // init 已把 estimate 钳制到 total - available，求和不会溢出且不超过卷容量。
            return availableBytes + estimatedReclaimableBytes
        }

        public init(volumeName: String,
                    totalBytes: Int64,
                    availableBytes: Int64,
                    estimatedReclaimableBytes: Int64? = nil) {
            // v2026.07.15：在数据边界一次性收敛容量不变量，避免每个 UI 消费者各自
            // 猜测异常值该怎么处理，进而再次混用“普通可用”和“预计可用”。
            let safeTotal = max(0, totalBytes)
            let safeAvailable = min(max(0, availableBytes), safeTotal)
            let safeEstimate: Int64?
            if let estimatedReclaimableBytes, estimatedReclaimableBytes >= 0 {
                safeEstimate = min(estimatedReclaimableBytes, safeTotal - safeAvailable)
            } else {
                safeEstimate = nil
            }
            self.volumeName = volumeName
            self.totalBytes = safeTotal
            self.availableBytes = safeAvailable
            self.estimatedReclaimableBytes = safeEstimate
        }
    }

    /// 把 Foundation 的两个容量口径映射为稳定 Snapshot。
    ///
    /// 保持为独立纯函数，是为了让测试直接锁定“ordinary 是主数、important 只产出差值”
    /// 这一根因合同，而不是依赖测试机当下磁盘状态间接猜测 probe 是否选对字段。
    static func makeSnapshot(
        volumeName: String,
        totalBytes: Int64,
        ordinaryAvailableBytes: Int64?,
        importantUsageAvailableBytes: Int64?
    ) -> Snapshot? {
        // 普通 available 缺失时不能拿 important-usage 冒充真实空闲；宁可让本轮探测
        // 返回 nil 并由实时刷新重试，也不能制造一个口径错误但看似精确的主数字。
        guard let ordinaryAvailableBytes else { return nil }
        let ordinary = max(0, ordinaryAvailableBytes)
        let important = importantUsageAvailableBytes.map { max(0, $0) }
        let reclaimableEstimate: Int64?
        if let important, important >= ordinary {
            reclaimableEstimate = important - ordinary
        } else {
            // 口径缺失或热重挂载窗口中 important < ordinary 时，未知不等于 0。
            reclaimableEstimate = nil
        }
        return Snapshot(
            volumeName: volumeName,
            totalBytes: totalBytes,
            availableBytes: ordinary,
            estimatedReclaimableBytes: reclaimableEstimate
        )
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

        return makeSnapshot(
            volumeName: values.volumeName ?? "Macintosh HD",
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            ordinaryAvailableBytes: values.volumeAvailableCapacity.map(Int64.init),
            importantUsageAvailableBytes: values.volumeAvailableCapacityForImportantUsage
        )
    }
}
