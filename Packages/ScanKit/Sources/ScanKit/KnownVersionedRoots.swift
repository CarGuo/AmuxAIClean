import Foundation

/// Mole 对齐 M3-T1：已知"按版本号保留最新 N 个"的 collection root 注册表。
///
/// 与 [VersionedRetainScanner] 的关系：
/// - 本文件只是**配置 + 注册表**（路径 + keepLatest + Ordering + displayName）；
/// - VersionedRetainScanner 才是**执行器**（对单个 root 找出可回收的旧版本子目录）；
/// - 之所以拆开：路径列表会持续增长（DeviceSupport / Toolbox / 未来 Android SDK build-tools 等），
///   把数据收敛到独立文件方便后续从 vendors.yaml 注释抽取自动生成。
///
/// 设计原则：
/// - **只列已经在 vendors.yaml 标注过 "适配 VersionedRetainScanner" 的路径**——这是
///   两端一致性的硬约束，避免代码端列了一条 yaml 没标注的 path 造成 UI/Engine 误删；
/// - **collectionRoot 必须是用户级且存在概率高**（DeviceSupport / Toolbox），系统级
///   或低概率路径不入注册表；
/// - **keepLatest 与 Ordering 严格对齐 yaml 注释中标的值**：
///     - DeviceSupport 三条：keepLatest=2, semverPreferred
///     - JetBrains Toolbox apps：keepLatest=1, semverPreferred
public enum KnownVersionedRoots {

    /// 一条已知版本化收集根。
    public struct Entry: Sendable, Hashable {
        /// 用户 `~` 之后的相对路径（不含 `~/`），调用方拿到 home 后自行拼接成绝对 URL
        public let relativePath: String
        /// 展示名（UI 列表用），i18n 留给上层
        public let displayName: String
        /// 保留最新几版
        public let keepLatest: Int
        /// 排序策略；对位 yaml 注释里标的值
        public let ordering: VersionedRetainScanner.Ordering
        /// 规则 ID（与 vendors.yaml 的 vendor 名一致 + 子键），用于 perRoot 渲染 / 日志聚合
        public let ruleID: String

        public init(relativePath: String,
                    displayName: String,
                    keepLatest: Int,
                    ordering: VersionedRetainScanner.Ordering,
                    ruleID: String) {
            self.relativePath = relativePath
            self.displayName = displayName
            self.keepLatest = keepLatest
            self.ordering = ordering
            self.ruleID = ruleID
        }
    }

    /// 全部已知版本化 collection root。
    ///
    /// 维护原则：**新增条目时必须同步在 vendors.yaml 对应 path 后加注释**：
    /// `# 适配 VersionedRetainScanner（keepLatest=N + semverPreferred）`
    /// 否则 [KnownVersionedRootsConsistencyTests] 会红灯。
    public static let entries: [Entry] = [
        // —— Apple DeviceSupport 三条（对位 Mole clean_xcode_device_support）——
        Entry(relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
              displayName: "Xcode · iOS DeviceSupport（旧版本）",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "apple.ios-device-support.versioned"),
        Entry(relativePath: "Library/Developer/Xcode/watchOS DeviceSupport",
              displayName: "Xcode · watchOS DeviceSupport（旧版本）",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "apple.watchos-device-support.versioned"),
        Entry(relativePath: "Library/Developer/Xcode/macOS DeviceSupport",
              displayName: "Xcode · macOS DeviceSupport（旧版本）",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "apple.macos-device-support.versioned"),
        // —— JetBrains Toolbox apps（对位 Mole clean_dev_jetbrains_toolbox）——
        Entry(relativePath: "Library/Application Support/JetBrains/Toolbox/apps",
              displayName: "JetBrains Toolbox（旧版本）",
              keepLatest: 1,
              ordering: .semverPreferred,
              ruleID: "jetbrains.toolbox-apps.versioned"),
    ]

    // MARK: - 辅助

    /// 对每个已知 entry 调用 VersionedRetainScanner.detect，并返回所有旧版本目录连同 ruleID。
    ///
    /// 这里**走同步 detect** 是有意为之：本扫描入口预期只在用户主动点击"老版本残留"按钮时调用，
    /// 命中数极少（DeviceSupport 通常 ≤ 10，Toolbox ≤ 30），同步遍历总耗时 < 100ms，比 actor
    /// 化的 discover 入口少一层 Task 切换开销。
    public struct Hit: Sendable, Hashable, Identifiable {
        public let url: URL
        public let ruleID: String
        public let displayName: String
        public let collectionRoot: URL
        public let versionName: String
        /// 被保留的最新一版的名字（来自 VersionedRetainScanner.Hit.retainedLatest），
        /// UI 可显示「将保留：xxx」帮助用户对账
        public let retainedLatest: String

        public var id: String { "\(ruleID)|\(url.path)" }

        public init(url: URL, ruleID: String, displayName: String,
                    collectionRoot: URL, versionName: String, retainedLatest: String) {
            self.url = url
            self.ruleID = ruleID
            self.displayName = displayName
            self.collectionRoot = collectionRoot
            self.versionName = versionName
            self.retainedLatest = retainedLatest
        }
    }

    /// 扫描所有已知 collection root，返回可回收的旧版本目录。
    ///
    /// - Parameter home: 用户 home 目录 URL，通常来自 `FileManager.default.homeDirectoryForCurrentUser`
    /// - Returns: 全部命中扁平合并；空数组表示无可回收
    public static func scanAll(home: URL) -> [Hit] {
        var result: [Hit] = []
        result.reserveCapacity(64)

        var fileManager = FileManager.default
        _ = fileManager // suppress "never mutated" warning for forward compat

        for entry in entries {
            let collectionRoot = home.appendingPathComponent(entry.relativePath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: collectionRoot.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }
            let options = VersionedRetainScanner.Options(keepLatest: entry.keepLatest,
                                                          ordering: entry.ordering)
            let rawHits = VersionedRetainScanner.detect(collectionRoot: collectionRoot,
                                                        options: options)
            for rh in rawHits {
                result.append(Hit(url: rh.url,
                                  ruleID: entry.ruleID,
                                  displayName: entry.displayName,
                                  collectionRoot: rh.collectionRoot,
                                  versionName: rh.versionName,
                                  retainedLatest: rh.retainedLatest))
            }
        }
        return result
    }
}
