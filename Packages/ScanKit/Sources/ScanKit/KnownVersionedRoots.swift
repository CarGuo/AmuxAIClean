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
              displayName: "versioned-root.apple.ios-device-support.displayName",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "apple.ios-device-support.versioned"),
        Entry(relativePath: "Library/Developer/Xcode/watchOS DeviceSupport",
              displayName: "versioned-root.apple.watchos-device-support.displayName",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "apple.watchos-device-support.versioned"),
        Entry(relativePath: "Library/Developer/Xcode/macOS DeviceSupport",
              displayName: "versioned-root.apple.macos-device-support.displayName",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "apple.macos-device-support.versioned"),
        // —— JetBrains Toolbox apps（对位 Mole clean_dev_jetbrains_toolbox）——
        Entry(relativePath: "Library/Application Support/JetBrains/Toolbox/apps",
              displayName: "versioned-root.jetbrains.toolbox-apps.displayName",
              keepLatest: 1,
              ordering: .semverPreferred,
              ruleID: "jetbrains.toolbox-apps.versioned"),
        // —— Android SDK 子目录（对位 DEVELOPER_ONE_CLICK_PLAN §3）——
        // 三类子目录均为「按版本号扁平排布」，semverPreferred 对位 `34.0.0` / `android-34` / `android-34-ext10` 等。
        // keepLatest 取 2：构建工程实践常并存两套版本（debug 主线 + 备用回归），多了基本是历史升级残留。
        // 注意：Android SDK 安装位置受 ANDROID_HOME / ANDROID_SDK_ROOT 环境变量影响，
        // 这里仅注册 macOS 默认安装路径 `~/Library/Android/sdk`；非默认路径靠用户自定义路径补全（v1.8 UI）。
        Entry(relativePath: "Library/Android/sdk/build-tools",
              displayName: "versioned-root.android.sdk-build-tools.displayName",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "android.sdk-build-tools.versioned"),
        Entry(relativePath: "Library/Android/sdk/platforms",
              displayName: "versioned-root.android.sdk-platforms.displayName",
              keepLatest: 2,
              ordering: .semverPreferred,
              ruleID: "android.sdk-platforms.versioned"),
        Entry(relativePath: "Library/Android/sdk/system-images",
              displayName: "versioned-root.android.sdk-system-images.displayName",
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
              displayName: "versioned-root.jetbrains.caches.displayName",
              keepLatest: 1,
              ordering: .semverPreferred,
              ruleID: "jetbrains.caches.versioned-per-product",
              groupingRegex: #"^([A-Za-z]+)\d{4}\.\d+$"#),
        Entry(relativePath: "Library/Application Support/JetBrains",
              displayName: "versioned-root.jetbrains.app-support.displayName",
              keepLatest: 1,
              ordering: .semverPreferred,
              ruleID: "jetbrains.app-support.versioned-per-product",
              groupingRegex: #"^([A-Za-z]+)\d{4}\.\d+$"#),
        Entry(relativePath: "Library/Logs/JetBrains",
              displayName: "versioned-root.jetbrains.logs.displayName",
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
        /// v1.7 PR-3 分组扫描产物：当 entry.groupingRegex 命中时，这里存原始的 group key
        /// （如 `IntelliJIdea`），UI 端在解析 `displayName` (i18n key) 后再拼到一起；
        /// 非分组场景为 nil。i18n 边界保持在 UI 层。
        public let groupKey: String?

        public var id: String { "\(ruleID)|\(url.path)" }

        public init(url: URL, ruleID: String, displayName: String,
                    collectionRoot: URL, versionName: String, retainedLatest: String,
                    groupKey: String? = nil) {
            self.url = url
            self.ruleID = ruleID
            self.displayName = displayName
            self.collectionRoot = collectionRoot
            self.versionName = versionName
            self.retainedLatest = retainedLatest
            self.groupKey = groupKey
        }
    }

    /// 全部已知版本化根的一次聚合结果。
    ///
    /// `hits` 与旧 [scanAll] 返回值一致；`incompleteIssues` 汇总每个 entry 及每个分组的
    /// 发现缺口。不存在的可选根不是错误，只有“根存在但无法完整读取”才会进入 evidence。
    public struct ScanResult: Sendable, Equatable {
        public let hits: [Hit]
        public let incompleteIssues: [ScanIncompleteIssue]
        /// Cancellation is a transaction terminal state, not a complete empty discovery and
        /// not a filesystem defect. Callers that drive deletion must discard this revision.
        public let wasCancelled: Bool

        public var isComplete: Bool { !wasCancelled && incompleteIssues.isEmpty }

        public init(
            hits: [Hit],
            incompleteIssues: [ScanIncompleteIssue],
            wasCancelled: Bool = false
        ) {
            self.hits = hits
            self.incompleteIssues = Set(incompleteIssues).sorted {
                if $0.path == $1.path { return $0.reason.rawValue < $1.reason.rawValue }
                return $0.path < $1.path
            }
            self.wasCancelled = wasCancelled
        }
    }

    /// 扫描所有已知 collection root，返回可回收的旧版本目录。
    ///
    /// - Parameter home: 用户 home 目录 URL，通常来自 `FileManager.default.homeDirectoryForCurrentUser`
    /// - Returns: 全部命中扁平合并；空数组本身不表示扫描完整，完整性请用 [scanAllWithEvidence]
    public static func scanAll(home: URL) -> [Hit] {
        scanAllWithEvidence(home: home).hits
    }

    /// 扫描全部已知 collection root，并同时返回结构化完整性证据。
    ///
    /// 这是需要驱动删除能力的权威入口；旧 [scanAll] 仅为 API 兼容保留，无法仅凭空数组
    /// 区分“没有旧版本”和“某个存在的根读取失败”。
    public static func scanAllWithEvidence(home: URL) -> ScanResult {
        scanAllWithEvidence(home: home, fileSystem: FileManager.default)
    }

    /// 注入文件系统仅供确定性测试使用。
    static func scanAllWithEvidence(
        home: URL,
        fileSystem: any VersionedRootFileSystem,
        cancellationCheck: () -> Bool = { Task<Never, Never>.isCancelled }
    ) -> ScanResult {
        var result: [Hit] = []
        result.reserveCapacity(64)
        var incompleteIssues: [ScanIncompleteIssue] = []

        for entry in entries {
            // v2026.07.16: this API is synchronous but normally runs inside a cancelled
            // detached task. A Task cancellation does not pre-empt synchronous filesystem
            // calls, so cooperate at every shallow root/group boundary and discard partial
            // candidates as one typed cancelled transaction.
            if cancellationCheck() { return cancelledScanResult }
            let collectionRoot = home.appendingPathComponent(entry.relativePath)
            let options = VersionedRetainScanner.Options(keepLatest: entry.keepLatest,
                                                          ordering: entry.ordering)

            if let regex = entry.groupingRegex {
                // PR-3 分组路径：先按正则 capture group 1 把子目录分桶，每桶独立 detect。
                let groupedResult = scanGroupedWithEvidence(
                    entry: entry,
                    collectionRoot: collectionRoot,
                    options: options,
                    groupingRegex: regex,
                    fileSystem: fileSystem,
                    cancellationCheck: cancellationCheck
                )
                if groupedResult.wasCancelled { return cancelledScanResult }
                result.append(contentsOf: groupedResult.hits)
                incompleteIssues.append(contentsOf: groupedResult.incompleteIssues)
            } else {
                // PR-3 之前的旧行为：整 root 一组，直接 detect。
                let detection = VersionedRetainScanner.detectWithEvidence(
                    collectionRoot: collectionRoot,
                    options: options,
                    fileSystem: fileSystem,
                    cancellationCheck: cancellationCheck
                )
                if detection.wasCancelled { return cancelledScanResult }
                incompleteIssues.append(contentsOf: detection.incompleteIssues)
                for rh in detection.hits {
                    if cancellationCheck() { return cancelledScanResult }
                    result.append(Hit(url: rh.url,
                                      ruleID: entry.ruleID,
                                      displayName: entry.displayName,
                                      collectionRoot: rh.collectionRoot,
                                      versionName: rh.versionName,
                                      retainedLatest: rh.retainedLatest))
                }
            }
        }
        if cancellationCheck() { return cancelledScanResult }
        let scanResult = ScanResult(hits: result, incompleteIssues: incompleteIssues)
        if !scanResult.incompleteIssues.isEmpty {
            let evidence = scanResult.incompleteIssues
                .map { "\($0.path):\($0.reason.rawValue)" }
                .joined(separator: ",")
            GSYLog.warning(.scan, "KnownVersionedRoots incomplete evidence=\(evidence)")
        }
        return scanResult
    }

    /// PR-3 分组扫描内核（仅在 entry.groupingRegex 非 nil 时调用）。
    ///
    /// - 正则编译失败 → warn 一行，**降级为旧行为**（整 root 一组）保证不漏扫；
    /// - 子目录名按 fullMatch 提取 group 1 作为 key（如 `IntelliJIdea2024.1` → `IntelliJIdea`）；
    /// - 未匹配的子目录被忽略（避免把 `.DS_Store` / Toolbox 自身这类无版本号目录误判）；
    /// - 每个 group 内单独跑 [VersionedRetainScanner.detect]，但因 detect 入口要求 collectionRoot
    ///   是真实路径，这里改用其底层排序逻辑（直接复用 detect 的判定语义，避免造临时目录）。
    private static func scanGroupedWithEvidence(
        entry: Entry,
        collectionRoot: URL,
        options: VersionedRetainScanner.Options,
        groupingRegex: String,
        fileSystem: any VersionedRootFileSystem,
        cancellationCheck: () -> Bool
    ) -> ScanResult {
        if cancellationCheck() { return cancelledScanResult }
        let nsRegex: NSRegularExpression
        do {
            nsRegex = try NSRegularExpression(pattern: groupingRegex)
        } catch {
            GSYLog.warning(.scan,
                        "KnownVersionedRoots groupingRegex 编译失败，降级为旧行为 ruleID=\(entry.ruleID) pattern=\(groupingRegex)")
            let detection = VersionedRetainScanner.detectWithEvidence(
                collectionRoot: collectionRoot,
                options: options,
                fileSystem: fileSystem,
                cancellationCheck: cancellationCheck
            )
            if detection.wasCancelled { return cancelledScanResult }
            var hits: [Hit] = []
            hits.reserveCapacity(detection.hits.count)
            for detectedHit in detection.hits {
                if cancellationCheck() { return cancelledScanResult }
                hits.append(Hit(
                    url: detectedHit.url,
                    ruleID: entry.ruleID,
                    displayName: entry.displayName,
                    collectionRoot: detectedHit.collectionRoot,
                    versionName: detectedHit.versionName,
                    retainedLatest: detectedHit.retainedLatest
                ))
            }
            return ScanResult(hits: hits, incompleteIssues: detection.incompleteIssues)
        }

        let rootAttributes: [FileAttributeKey: Any]
        do {
            rootAttributes = try fileSystem.attributesOfItem(atPath: collectionRoot.path)
        } catch {
            if cancellationCheck() { return cancelledScanResult }
            if isFileNotFound(error) {
                return ScanResult(hits: [], incompleteIssues: [])
            }
            let reason: ScanIncompleteReason = VersionedRootErrorClassifier.isPermissionDenied(error)
                ? .permissionDenied
                : .metadataUnavailable
            return ScanResult(
                hits: [],
                incompleteIssues: [ScanIncompleteIssue(path: collectionRoot.path, reason: reason)]
            )
        }
        if cancellationCheck() { return cancelledScanResult }
        guard let rootType = rootAttributes[.type] as? FileAttributeType else {
            return ScanResult(
                hits: [],
                incompleteIssues: [ScanIncompleteIssue(
                    path: collectionRoot.path,
                    reason: .metadataUnavailable
                )]
            )
        }
        guard rootType == .typeDirectory || rootType == .typeSymbolicLink else {
            return ScanResult(hits: [], incompleteIssues: [])
        }

        let children: [String]
        do {
            children = try fileSystem.contentsOfDirectory(atPath: collectionRoot.path)
        } catch {
            if cancellationCheck() { return cancelledScanResult }
            let reason: ScanIncompleteReason = VersionedRootErrorClassifier.isPermissionDenied(error)
                ? .permissionDenied
                : .enumerationFailed
            return ScanResult(
                hits: [],
                incompleteIssues: [ScanIncompleteIssue(path: collectionRoot.path, reason: reason)]
            )
        }
        if cancellationCheck() { return cancelledScanResult }

        // 按 group key 分桶
        var groups: [String: [VersionedRetainScanner.Candidate]] = [:]
        var invalidGroups: Set<String> = []
        var incompleteIssues: [ScanIncompleteIssue] = []
        for name in children {
            if cancellationCheck() { return cancelledScanResult }
            if name.hasPrefix(".") { continue }

            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = nsRegex.firstMatch(in: name, range: range),
                  match.range.location == 0,
                  match.range.length == (name as NSString).length,
                  match.numberOfRanges >= 2,
                  let groupRange = Range(match.range(at: 1), in: name) else {
                continue
            }
            let key = String(name[groupRange])
            let child = collectionRoot.appendingPathComponent(name)

            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileSystem.attributesOfItem(atPath: child.path)
            } catch {
                if cancellationCheck() { return cancelledScanResult }
                invalidGroups.insert(key)
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: VersionedRootErrorClassifier.isPermissionDenied(error)
                        ? .permissionDenied
                        : .metadataUnavailable
                ))
                continue
            }
            if cancellationCheck() { return cancelledScanResult }
            guard let type = attributes[.type] as? FileAttributeType else {
                invalidGroups.insert(key)
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: .metadataUnavailable
                ))
                continue
            }
            if type == .typeSymbolicLink, options.skipSymlinks {
                continue
            }
            guard type == .typeDirectory else { continue }

            let modificationDate = attributes[.modificationDate] as? Date
            if case .modificationDateDescending = options.ordering,
               modificationDate == nil {
                invalidGroups.insert(key)
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: .metadataUnavailable
                ))
                continue
            }
            groups[key, default: []].append(VersionedRetainScanner.Candidate(
                name: name,
                url: child,
                modificationDate: modificationDate
            ))
        }

        var result: [Hit] = []
        result.reserveCapacity(groups.count * 2)

        for (groupKey, candidates) in groups {
            if cancellationCheck() { return cancelledScanResult }
            guard !invalidGroups.contains(groupKey) else { continue }
            guard candidates.count > options.keepLatest else { continue }
            let sorted = VersionedRetainScanner.sort(candidates: candidates,
                                                     ordering: options.ordering)
            let retainCount = options.keepLatest
            let oldCount = sorted.count - retainCount
            let retainedLatest = sorted.last?.name ?? ""
            for i in 0..<oldCount {
                if cancellationCheck() { return cancelledScanResult }
                let old = sorted[i]
                result.append(Hit(url: old.url,
                                  ruleID: entry.ruleID,
                                  displayName: entry.displayName,
                                  collectionRoot: collectionRoot,
                                  versionName: old.name,
                                  retainedLatest: retainedLatest,
                                  groupKey: groupKey))
            }
        }
        if cancellationCheck() { return cancelledScanResult }
        return ScanResult(hits: result, incompleteIssues: incompleteIssues)
    }

    private static var cancelledScanResult: ScanResult {
        ScanResult(hits: [], incompleteIssues: [], wasCancelled: true)
    }

    private static func isFileNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isFileNotFound(underlying)
        }
        return false
    }
}
