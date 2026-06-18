import Foundation
import LogKit

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
        /// v1.7 PR-3 新增：子目录名分组正则（可选）。
        ///
        /// - `nil`（默认）：整 `collectionRoot` 下所有子目录视为单一组，行为完全等同 PR-3 之前；
        /// - 非 nil：对每个子目录名 fullMatch，提取**第一个 capture group** 作为 group key；
        ///   未匹配的子目录会被忽略（不参与排序、也不会被识别为旧版本）。
        ///   每组独立排序 + 应用 keepLatest，避免跨产品比版本号（典型场景：
        ///   `~/Library/Caches/JetBrains` 下并存 `IntelliJIdea2024.1` / `PyCharm2024.2` / `WebStorm2023.3`，
        ///   按产品名分组后 IDEA 与 PyCharm 各自独立保留最新 N 版）。
        ///
        /// **降级保护**：若正则编译失败（NSRegularExpression init 抛错），
        /// [scanAll](x-source-tag://KnownVersionedRoots.scanAll) 会 warn 一行日志，
        /// 然后**降级为 nil 行为**（整 root 一组）以保证不丢扫描；测试 [KnownVersionedRootsGroupingTests] 覆盖。
        public let groupingRegex: String?

        public init(relativePath: String,
                    displayName: String,
                    keepLatest: Int,
                    ordering: VersionedRetainScanner.Ordering,
                    ruleID: String,
                    groupingRegex: String? = nil) {
            self.relativePath = relativePath
            self.displayName = displayName
            self.keepLatest = keepLatest
            self.ordering = ordering
            self.ruleID = ruleID
            self.groupingRegex = groupingRegex
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
        // —— Android SDK 子目录（对位 DEVELOPER_ONE_CLICK_PLAN §3）——
        // 三类子目录均为「按版本号扁平排布」，semverPreferred 对位 `34.0.0` / `android-34` / `android-34-ext10` 等。
        // keepLatest 取 2：构建工程实践常并存两套版本（debug 主线 + 备用回归），多了基本是历史升级残留。
        // 注意：Android SDK 安装位置受 ANDROID_HOME / ANDROID_SDK_ROOT 环境变量影响，
        // 这里仅注册 macOS 默认安装路径 `~/Library/Android/sdk`；非默认路径靠用户自定义路径补全（v1.8 UI）。
        Entry(relativePath: "Library/Android/sdk/build-tools",
              displayName: "Android SDK · build-tools（旧版本）",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "android.sdk-build-tools.versioned"),
        Entry(relativePath: "Library/Android/sdk/platforms",
              displayName: "Android SDK · platforms（旧版本）",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "android.sdk-platforms.versioned"),
        Entry(relativePath: "Library/Android/sdk/system-images",
              displayName: "Android SDK · system-images（旧版本）",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "android.sdk-system-images.versioned"),
        // —— JetBrains 跨产品分组三条（v1.7 PR-3，对位 vendors.yaml JetBrains 节）——
        // 同 root 下并存多个产品（IntelliJIdea / PyCharm / WebStorm / GoLand / Rider /
        // CLion / DataGrip / RubyMine / PhpStorm / AppCode），按 `^([A-Za-z]+)\d{4}\.\d+$`
        // 分组后每产品独立保留最新 keepLatest 版。
        // keepLatest=1：JetBrains IDE 大版本年更新（2024.1 → 2024.2 → 2024.3），用户通常只用最新一档。
        // 不匹配的子目录（如 Toolbox 自身、consentOptions）不会被识别（fullMatch 兜底）。
        Entry(relativePath: "Library/Caches/JetBrains",
              displayName: "JetBrains · 索引/编译缓存（旧版本）",
              keepLatest: 1,
              ordering: .semverPreferred,
              ruleID: "jetbrains.caches.versioned-per-product",
              groupingRegex: #"^([A-Za-z]+)\d{4}\.\d+$"#),
        Entry(relativePath: "Library/Application Support/JetBrains",
              displayName: "JetBrains · 配置(部分)（旧版本）",
              keepLatest: 1,
              ordering: .semverPreferred,
              ruleID: "jetbrains.app-support.versioned-per-product",
              groupingRegex: #"^([A-Za-z]+)\d{4}\.\d+$"#),
        Entry(relativePath: "Library/Logs/JetBrains",
              displayName: "JetBrains · 日志（旧版本）",
              keepLatest: 1,
              ordering: .semverPreferred,
              ruleID: "jetbrains.logs.versioned-per-product",
              groupingRegex: #"^([A-Za-z]+)\d{4}\.\d+$"#),
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

        for entry in entries {
            let collectionRoot = home.appendingPathComponent(entry.relativePath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: collectionRoot.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }
            let options = VersionedRetainScanner.Options(keepLatest: entry.keepLatest,
                                                          ordering: entry.ordering)

            if let regex = entry.groupingRegex {
                // PR-3 分组路径：先按正则 capture group 1 把子目录分桶，每桶独立 detect。
                result.append(contentsOf: scanGrouped(entry: entry,
                                                      collectionRoot: collectionRoot,
                                                      options: options,
                                                      groupingRegex: regex))
            } else {
                // PR-3 之前的旧行为：整 root 一组，直接 detect。
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
        }
        return result
    }

    /// PR-3 分组扫描内核（仅在 entry.groupingRegex 非 nil 时调用）。
    ///
    /// - 正则编译失败 → warn 一行，**降级为旧行为**（整 root 一组）保证不漏扫；
    /// - 子目录名按 fullMatch 提取 group 1 作为 key（如 `IntelliJIdea2024.1` → `IntelliJIdea`）；
    /// - 未匹配的子目录被忽略（避免把 `.DS_Store` / Toolbox 自身这类无版本号目录误判）；
    /// - 每个 group 内单独跑 [VersionedRetainScanner.detect]，但因 detect 入口要求 collectionRoot
    ///   是真实路径，这里改用其底层排序逻辑（直接复用 detect 的判定语义，避免造临时目录）。
    private static func scanGrouped(entry: Entry,
                                    collectionRoot: URL,
                                    options: VersionedRetainScanner.Options,
                                    groupingRegex: String) -> [Hit] {
        let fm = FileManager.default
        guard let nsRegex = try? NSRegularExpression(pattern: groupingRegex) else {
            GSYLog.warning(.scan,
                        "KnownVersionedRoots groupingRegex 编译失败，降级为旧行为 ruleID=\(entry.ruleID) pattern=\(groupingRegex)")
            let rawHits = VersionedRetainScanner.detect(collectionRoot: collectionRoot,
                                                        options: options)
            return rawHits.map {
                Hit(url: $0.url, ruleID: entry.ruleID, displayName: entry.displayName,
                    collectionRoot: $0.collectionRoot, versionName: $0.versionName,
                    retainedLatest: $0.retainedLatest)
            }
        }

        guard let children = try? fm.contentsOfDirectory(atPath: collectionRoot.path) else {
            return []
        }

        // 按 group key 分桶
        var groups: [String: [(name: String, url: URL)]] = [:]
        for name in children {
            if name.hasPrefix(".") { continue }
            let child = collectionRoot.appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &childIsDir),
                  childIsDir.boolValue else { continue }

            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = nsRegex.firstMatch(in: name, range: range),
                  match.range.location == 0,
                  match.range.length == (name as NSString).length,
                  match.numberOfRanges >= 2,
                  let groupRange = Range(match.range(at: 1), in: name) else {
                continue
            }
            let key = String(name[groupRange])
            groups[key, default: []].append((name, child))
        }

        var result: [Hit] = []
        result.reserveCapacity(groups.count * 2)

        for (groupKey, candidates) in groups {
            guard candidates.count > options.keepLatest else { continue }
            let sorted = VersionedRetainScanner.sort(candidates: candidates,
                                                     ordering: options.ordering)
            let retainCount = options.keepLatest
            let oldCount = sorted.count - retainCount
            let retainedLatest = sorted.last?.name ?? ""
            for i in 0..<oldCount {
                let old = sorted[i]
                result.append(Hit(url: old.url,
                                  ruleID: entry.ruleID,
                                  displayName: "\(entry.displayName) · \(groupKey)",
                                  collectionRoot: collectionRoot,
                                  versionName: old.name,
                                  retainedLatest: retainedLatest))
            }
        }
        return result
    }
}
