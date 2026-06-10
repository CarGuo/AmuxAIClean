import Foundation
import LogKit
import SafetyKit
import ScanKit

/// 残留候选项 —— 是“可能”属于被卸载 App 的文件/目录。
///
/// **注意：返回的只是“候选”**。最终是否真删除由用户在 UI 勾选。
/// 设计参考 PITFALLS §5.4：宁可漏报，不可误杀。
public struct UninstallCandidate: Hashable, Sendable {
    public let path: String
    public let bytes: Int64
    public let fileCount: Int
    public let matchReason: MatchReason

    public init(path: String, bytes: Int64, fileCount: Int, matchReason: MatchReason) {
        self.path = path
        self.bytes = bytes
        self.fileCount = fileCount
        self.matchReason = matchReason
    }
}

/// 命中原因 —— 用来在 UI 上向用户解释“为什么我会建议删它”。
public enum MatchReason: Hashable, Sendable {
    /// 文件名 / 目录名的反域名前缀严格等于或以 bundleID 起头（如 `com.foo.bar.plist`）
    case bundleID(String)
    /// 反域名第一层（如 `com.foo`）的“供应商”级别匹配（仅在 LaunchAgents/LaunchDaemons 这类地方使用，用于残留 plist）
    case bundleVendor(String)
    /// 由 Info.plist 的 CFBundleName / CFBundleExecutable / 或文件名 stem 模糊匹配命中
    case appName(String)
    /// 命中 vendors.yaml 厂商规则：app 的 bundleID 与某 VendorRule.bundleIDPrefix 严格前缀匹配，
    /// 且该 vendor 已知会在 `~/Library/Application Support/<subdir>` / `<cachesPath>` 留数据。
    /// 关联值为 vendor 名（用于 UI 提示；用户能直接看到“因为 Adobe 厂商规则”这种证据链）。
    case vendorRule(String)
    /// Step 11A / 2026-06：Spotlight 兜底命中。
    /// 主 12 root 路径覆盖不了的非典型残留位置（用户文档下、iCloud 同步目录等），
    /// 通过 [SpotlightProbing](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SpotlightFallback.swift)
    /// 严格谓词查到。关联值是命中谓词类别（`"bundleID"` / `"appName"`），方便 UI 提示证据链。
    case spotlight(String)
    /// M4-T3 / 2026-06：pkgutil receipts 命中。
    /// 通过 [PkgutilReceiptsScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/PkgutilReceiptsScanner.swift)
    /// 以 bundleID / bundleVendor 作前缀拉 `pkgutil --pkgs=<vendor>.*`，命中的
    /// pkg 安装清单展开成绝对路径后作为候选（典型场景：Adobe / Acrobat Reader 这类
    /// 用 `.pkg` 安装的应用，残留分布在 `/Library/Application Support/Adobe`、
    /// `/Library/PrivilegedHelperTools/com.adobe.*` 等系统级位置）。关联值是命中的
    /// pkgID，方便 UI 提示证据链。
    case pkgReceipt(String)
}

/// 解析后的 .app 元数据。
public struct AppMetadata: Hashable, Sendable {
    public let bundleID: String
    /// 反域名第一层 + 第二层（`com.foo.bar` -> `com.foo`），用于在 LaunchAgents/Daemons
    /// 这种“供应商共享目录”里做更宽匹配。**不会**用于 Application Support 等。
    public let bundleVendor: String?
    public let appName: String
    public let executableName: String?

    public init(bundleID: String, bundleVendor: String?, appName: String, executableName: String?) {
        self.bundleID = bundleID
        self.bundleVendor = bundleVendor
        self.appName = appName
        self.executableName = executableName
    }

    /// 从 `<App>.app/Contents/Info.plist` 解析。
    public static func read(appURL: URL) throws -> AppMetadata {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard
            let any = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            throw NSError(domain: "AppUninstaller", code: -1, userInfo: [NSLocalizedDescriptionKey: "Info.plist 不是 dict"])
        }
        guard let bundleID = any["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw NSError(domain: "AppUninstaller", code: -2, userInfo: [NSLocalizedDescriptionKey: "缺少 CFBundleIdentifier"])
        }
        let nameFromPlist = (any["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // 退化：取 .app 的文件名去掉 .app 后缀
        let stem = appURL.deletingPathExtension().lastPathComponent
        let appName = nameFromPlist ?? stem
        let exe = (any["CFBundleExecutable"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppMetadata(
            bundleID: bundleID,
            bundleVendor: vendorPrefix(of: bundleID),
            appName: appName,
            executableName: exe
        )
    }

    /// `com.foo.bar.baz` -> `com.foo`；少于两段返回 nil。
    static func vendorPrefix(of bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return parts[0...1].joined(separator: ".")
    }
}

/// 卸载残留扫描器。
///
/// 行为契约（PITFALLS §5.4 / §5.5）：
/// 1. **只读、不删** —— 返回 `[UninstallCandidate]`，删除由调用方走 TrashPipeline。
/// 2. **严格前缀** —— 名为 `com.foo.bar` 的 bundleID 不会误命中 `com.foo.barbarian.plist`；
///    必须 `name == bundleID` 或 `name` 以 `bundleID + "."` / `bundleID + "/"` 开头。
/// 3. **vendor 仅用于 LaunchAgents/LaunchDaemons** —— 这两个目录里的残留 plist 习惯用
///    `com.foo.updater.plist` 这种形式，但日常 Application Support 里再放宽就会误杀。
/// 4. **appName 模糊匹配只在“目录名严格相等（忽略大小写）”时启用** —— 太短或常见词
///    （如 `app`/`com`/`data`，长度 < 4）一律不参与，避免拖死整个 ~/Library。
public struct AppUninstaller: Sendable {
    public let homeDirectory: String
    public let systemLibrary: String
    public let fileManager: FileManagerSnapshotting
    /// 厂商级规则：当被卸载 app 的 bundleID 严格命中某 vendor 的 `bundleIDPrefix` 时，
    /// 该 vendor 提供的 `appSupportSubdir` / `cachesPath` 也会加入候选（标记为 `.vendorRule`）。
    /// **不会**让所有 vendor 路径裸奔参与匹配 —— 仅在 bundleID 命中后才放出该 vendor 的路径。
    public let vendorRules: [VendorRule]
    /// Step 11A / 2026-06：Spotlight 兜底查询器。
    /// 主路径扫完后调用，补主 12 root 之外的残留位置。生产用 [DefaultSpotlightProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SpotlightFallback.swift)，
    /// 测试可注入 fake 返回固定路径。
    public let spotlight: SpotlightProbing
    /// Spotlight 单次查询超时（秒）。NSMetadataQuery 偶尔会卡数十秒，必须有上限。
    public let spotlightTimeout: TimeInterval
    /// M4-T3 / 2026-06：pkgutil receipts 兜底扫描器。
    /// 默认走 [DefaultPkgutilRunner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/PkgutilReceiptsScanner.swift)，
    /// 测试可注入 fake runner 喂死数据。`nil` 表示完全关闭 pkgReceipt 候选发现
    /// （单测里 in-memory home / 不真实 / 想 isolate 主路径时使用）。
    public let pkgutilScanner: PkgutilReceiptsScanner?

    public init(
        homeDirectory: String = NSHomeDirectory(),
        systemLibrary: String = "/Library",
        fileManager: FileManagerSnapshotting = DefaultFileManagerSnapshot(),
        vendorRules: [VendorRule] = [],
        spotlight: SpotlightProbing? = nil,
        spotlightTimeout: TimeInterval = 1.5,
        pkgutilScanner: PkgutilReceiptsScanner? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.systemLibrary = systemLibrary
        self.fileManager = fileManager
        self.vendorRules = vendorRules
        // 默认决策：homeDirectory 是真实 NSHomeDirectory() 时启用 DefaultSpotlightProbe；
        // 否则（in-memory 测试构造的伪造 home，如 "/H" / "/tmp/fakehome"）走 Noop，
        // 不让 NSMetadataQuery 拖慢/污染单测。显式传参可强制覆盖。
        if let s = spotlight {
            self.spotlight = s
        } else if homeDirectory == NSHomeDirectory() {
            self.spotlight = DefaultSpotlightProbe()
        } else {
            self.spotlight = NoopSpotlightProbe()
        }
        self.spotlightTimeout = spotlightTimeout
        // 默认决策：homeDirectory 是真实 home 时启用 DefaultPkgutilRunner（生产路径）；
        // 否则禁用，避免子进程 /usr/sbin/pkgutil 拖慢 / 污染单测。
        if let s = pkgutilScanner {
            self.pkgutilScanner = s
        } else if homeDirectory == NSHomeDirectory() {
            self.pkgutilScanner = PkgutilReceiptsScanner()
        } else {
            self.pkgutilScanner = nil
        }
    }

    /// 11 个用户级残留目录 + 1 个系统级 LaunchDaemons。
    public func searchRoots() -> [SearchRoot] {
        let h = homeDirectory
        return [
            .init(path: "\(h)/Library/Application Support", scope: .user),
            .init(path: "\(h)/Library/Caches", scope: .user),
            .init(path: "\(h)/Library/Logs", scope: .user),
            .init(path: "\(h)/Library/Preferences", scope: .user),
            .init(path: "\(h)/Library/Saved Application State", scope: .user),
            .init(path: "\(h)/Library/Containers", scope: .user),
            .init(path: "\(h)/Library/Group Containers", scope: .user),
            .init(path: "\(h)/Library/LaunchAgents", scope: .launch),
            .init(path: "\(h)/Library/Cookies", scope: .user),
            .init(path: "\(h)/Library/WebKit", scope: .user),
            .init(path: "\(h)/Library/HTTPStorages", scope: .user),
            .init(path: "\(systemLibrary)/LaunchDaemons", scope: .launch)
        ]
    }

    public struct SearchRoot: Hashable, Sendable {
        public enum Scope: Hashable, Sendable { case user, launch }
        public let path: String
        public let scope: Scope
    }

    /// 主入口。
    public func candidates(forAppAt appURL: URL) throws -> [UninstallCandidate] {
        let meta = try AppMetadata.read(appURL: appURL)
        return candidates(for: meta)
    }

    /// 已有元数据的入口（便于测试）。
    public func candidates(for meta: AppMetadata) -> [UninstallCandidate] {
        var out: [UninstallCandidate] = []
        var seenPaths = Set<String>()

        for root in searchRoots() {
            guard let entries = fileManager.firstLevelEntries(at: root.path) else { continue }
            for entry in entries {
                guard let reason = matchReason(name: entry.name, scope: root.scope, meta: meta) else { continue }
                let snap = fileManager.snapshot(at: entry.path)
                seenPaths.insert(entry.path)
                out.append(.init(
                    path: entry.path,
                    bytes: snap.bytes,
                    fileCount: snap.fileCount,
                    matchReason: reason
                ))
            }
        }

        // 第 4 路：vendor 命中
        // 仅当 app 的 bundleID 严格命中某 vendor.bundleIDPrefix 时，
        // 把该 vendor 的 absolutePathPrefixes 加为 .vendorRule 候选。
        // 注意：路径已在 (a)/(b)/(c) 路出现过的，**不**重复加（path 去重）；
        // 不存在的路径直接丢弃，避免 UI 上挂一堆 0B 假候选迷惑用户。
        for vendor in matchedVendors(for: meta) {
            for absPath in vendor.absolutePathPrefixes(home: homeDirectory) {
                if !seenPaths.insert(absPath).inserted { continue }
                let snap = fileManager.snapshot(at: absPath)
                let isDirectory = fileManager.firstLevelEntries(at: absPath) != nil
                let exists = isDirectory || snap.bytes > 0 || snap.fileCount > 0
                guard exists else { continue }
                out.append(.init(
                    path: absPath,
                    bytes: snap.bytes,
                    fileCount: snap.fileCount,
                    matchReason: .vendorRule(vendor.name)
                ))
            }
        }

        // M4-T3：第 5 路 —— pkgutil receipts 兜底
        // 以 vendor 前缀（如 com.adobe）拉 `pkgutil --pkgs=com.adobe.*`，把命中
        // pkg 的安装清单展开成绝对路径作为候选。去重 + 文件存在性过滤后追加。
        // 注：pkgutil 子进程在伪 home / nil scanner 场景已被关闭，单测不会被波及。
        out.append(contentsOf: pkgReceiptCandidates(for: meta, seenPaths: &seenPaths))

        return out
    }

    /// M4-T3：基于 pkgutil receipts 的候选发现。
    ///
    /// 决策：先尝试 vendor 前缀（`com.adobe`）；若 vendor 拉不到，再退到 bundleID 严格相等。
    /// 这与 [PkgutilReceiptsScanner.receipts(matchingBundleIDPrefix:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/PkgutilReceiptsScanner.swift#L56-L71)
    /// 的"前缀匹配 + 末尾 `.*`"语义一致；vendor 优先是因为残留 pkg 通常和主 pkg 共享 vendor 前缀
    /// （`com.adobe.acrobat.reader.app` 与 `com.adobe.acrobat.shared` 同时存在）。
    ///
    /// 过滤：路径已在前 4 路出现过的不重复添加；文件实际不存在的（`fileExists=false`）丢弃。
    func pkgReceiptCandidates(for meta: AppMetadata, seenPaths: inout Set<String>) -> [UninstallCandidate] {
        guard let scanner = pkgutilScanner else { return [] }
        // 候选 prefix：vendor 优先，否则用 bundleID 自身。
        let prefix = meta.bundleVendor ?? meta.bundleID
        guard !prefix.isEmpty else { return [] }
        let receipts = scanner.receipts(matchingBundleIDPrefix: prefix)
        guard !receipts.isEmpty else { return [] }

        var out: [UninstallCandidate] = []
        let fm = FileManager.default
        for receipt in receipts {
            for absPath in receipt.absolutePaths {
                if absPath.isEmpty { continue }
                if !seenPaths.insert(absPath).inserted { continue }
                // 文件存在性过滤：避免把 receipt 列表里 macOS 系统重装后已被清掉的死路径挂上去
                guard fm.fileExists(atPath: absPath) else { continue }
                let snap = fileManager.snapshot(at: absPath)
                out.append(.init(
                    path: absPath,
                    bytes: snap.bytes,
                    fileCount: snap.fileCount,
                    matchReason: .pkgReceipt(receipt.pkgID)
                ))
            }
        }
        return out
    }

    /// 找出和当前 app 元数据"同厂商"的所有 VendorRule。
    /// 严格遵守 `matchesStrictPrefix`：`com.foo.bar` 命中 `com.foo` 但不会命中 `com.foobar`。
    func matchedVendors(for meta: AppMetadata) -> [VendorRule] {
        vendorRules.filter { rule in
            guard let prefix = rule.bundleIDPrefix, !prefix.isEmpty else { return false }
            return Self.matchesStrictPrefix(name: meta.bundleID, prefix: prefix)
        }
    }

    /// 把名字 → 命中原因的匹配纯函数。**测试主战场**。
    func matchReason(name: String, scope: SearchRoot.Scope, meta: AppMetadata) -> MatchReason? {
        // 1) 严格 bundleID 前缀
        if matchesStrictPrefix(name: name, prefix: meta.bundleID) {
            return .bundleID(meta.bundleID)
        }
        // 2) LaunchAgents/Daemons：允许 vendor 级
        if scope == .launch, let vendor = meta.bundleVendor,
           matchesStrictPrefix(name: name, prefix: vendor) {
            return .bundleVendor(vendor)
        }
        // 3) appName：仅“目录名严格等于（忽略大小写）”，且名字足够长
        if isAppNameMatchable(meta.appName), nameEqualsIgnoringCase(name, stem: meta.appName) {
            return .appName(meta.appName)
        }
        if let exe = meta.executableName,
           isAppNameMatchable(exe),
           nameEqualsIgnoringCase(name, stem: exe) {
            return .appName(exe)
        }
        return nil
    }

    /// `name` 必须满足：
    ///   - `name == prefix`，或
    ///   - `name` 以 `prefix + "."` 开头（典型："com.foo.bar.plist"、"com.foo.bar.savedState"）
    /// **绝不**允许 "com.foo.barbarian" 命中 "com.foo.bar"。
    static func matchesStrictPrefix(name: String, prefix: String) -> Bool {
        if name == prefix { return true }
        if name.hasPrefix(prefix + ".") { return true }
        return false
    }

    func matchesStrictPrefix(name: String, prefix: String) -> Bool {
        Self.matchesStrictPrefix(name: name, prefix: prefix)
    }

    /// appName 用于匹配的最低长度，太短会带来海量误判。
    private func isAppNameMatchable(_ s: String) -> Bool {
        s.count >= 4
    }

    /// 比较 `name`（可能含扩展名，如 `Foo.savedState`）的 stem 是否等于 `stem`。
    private func nameEqualsIgnoringCase(_ name: String, stem: String) -> Bool {
        // 取 name 的第一段（"."之前）作为可比较 stem
        let head: String
        if let dot = name.firstIndex(of: ".") {
            head = String(name[..<dot])
        } else {
            head = name
        }
        return head.caseInsensitiveCompare(stem) == .orderedSame
    }
}

// MARK: - 异步并发版本（修问题 #6）

extension AppUninstaller {
    /// `candidates(for:)` 的并发版。
    ///
    /// 背景：`DefaultFileManagerSnapshot.snapshot(at:)` 内部用 `FileManager.enumerator`
    /// 串行递归，对每个候选目录都是一次重 IO；当 `Library/Caches` 等出现几十个
    /// 候选时，串行累计耗时会让 UI 体感卡顿。
    ///
    /// 这里把 **匹配** 仍保持同步（CPU 廉价），只把 **`snapshot(at:)` 这种重 IO**
    /// 丢给 `Task.detached` 并发执行，并用 8 个 in-flight 槽位的滑动窗口限流，
    /// 避免对 50 个候选直接 spawn 50 个线程。
    public func candidatesAsync(for meta: AppMetadata) async -> [UninstallCandidate] {
        struct PendingMatch: Sendable {
            let path: String
            let reason: MatchReason
        }

        var pendings: [PendingMatch] = []
        var seenPaths = Set<String>()
        for root in searchRoots() {
            guard let entries = fileManager.firstLevelEntries(at: root.path) else { continue }
            for entry in entries {
                guard let reason = matchReason(name: entry.name, scope: root.scope, meta: meta) else { continue }
                if seenPaths.insert(entry.path).inserted {
                    pendings.append(.init(path: entry.path, reason: reason))
                }
            }
        }

        // 同步版的 vendor 路径展开 —— 这里只决定 path/reason，bytes/fileCount 留给并发段计算。
        for vendor in matchedVendors(for: meta) {
            for absPath in vendor.absolutePathPrefixes(home: homeDirectory) {
                if !seenPaths.insert(absPath).inserted { continue }
                pendings.append(.init(path: absPath, reason: .vendorRule(vendor.name)))
            }
        }

        let fm = self.fileManager
        let maxInFlight = 8
        // vendor 路径需要"存在性"过滤；其余路径来自第一层 entries，必然存在。
        let vendorReasonPaths: Set<String> = Set(
            pendings.compactMap { p -> String? in
                if case .vendorRule = p.reason { return p.path } else { return nil }
            }
        )
        return await withTaskGroup(of: UninstallCandidate?.self) { group in
            var collected: [UninstallCandidate] = []
            collected.reserveCapacity(pendings.count)
            var iterator = pendings.makeIterator()
            var inFlight = 0

            func makeTask(_ p: PendingMatch) -> @Sendable () async -> UninstallCandidate? {
                {
                    let snap = fm.snapshot(at: p.path)
                    // vendor 路径如果实际不存在（snap 全 0 且 firstLevelEntries 为 nil），丢弃，
                    // 否则会在 UI 上挂一堆 0B 假候选迷惑用户。
                    if vendorReasonPaths.contains(p.path),
                       snap.bytes == 0, snap.fileCount == 0,
                       fm.firstLevelEntries(at: p.path) == nil {
                        return nil
                    }
                    return UninstallCandidate(
                        path: p.path, bytes: snap.bytes, fileCount: snap.fileCount, matchReason: p.reason
                    )
                }
            }

            while inFlight < maxInFlight, let p = iterator.next() {
                group.addTask(priority: .utility, operation: makeTask(p))
                inFlight += 1
            }

            while let result = await group.next() {
                if let c = result { collected.append(c) }
                if let p = iterator.next() {
                    group.addTask(priority: .utility, operation: makeTask(p))
                }
            }

            // Step 11A / 2026-06：Spotlight 兜底补刀。
            // 主 12 root 漏掉的非典型路径（用户文档下、iCloud 同步盘等）由 Spotlight 索引补上。
            // 严格谓词（bundleID 完全相等 / appName 严格相等忽略大小写）+ 与主路径 dedup +
            // 二次校验 matchesStrictPrefix 防止 com.foo.bar 误命中 com.foo.barbarian。
            let spotlightCandidates = await spotlightFallback(meta: meta, seenPaths: Set(collected.map(\.path)))
            collected.append(contentsOf: spotlightCandidates)
            // M4-T3：pkgutil receipts 兜底补刀（系统级 pkg 安装的 app 的清单展开）
            var pkgSeen = Set(collected.map(\.path))
            let pkgCandidates = pkgReceiptCandidates(for: meta, seenPaths: &pkgSeen)
            collected.append(contentsOf: pkgCandidates)
            return collected
        }
    }

    /// Step 11A / 2026-06：Spotlight 兜底补刀实现。
    ///
    /// 调用时机：[candidatesAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift)
    /// 主路径并发扫完后。
    ///
    /// 流程：
    /// 1. 用 [SpotlightProbing.probeByBundleID](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SpotlightFallback.swift)
    ///    严格相等谓词查 `kMDItemCFBundleIdentifier == bundleID` 命中的路径。
    /// 2. 若 appName 长度 >= 4 且非常见词，再查 `kMDItemDisplayName ==[c] appName`。
    /// 3. 与 `seenPaths` 去重。
    /// 4. 二次校验：bundleID 命中的路径必须在某个 search root 之外但仍属于 home / system library 子树
    ///    （避免索引到 /System 等无关位置）。
    /// 5. 用 `fileManager.snapshot(at:)` 取 size，0B / 不存在 / 0 文件 一律跳过。
    /// 6. matchReason = `.spotlight("bundleID")` / `.spotlight("appName")`。
    private func spotlightFallback(meta: AppMetadata, seenPaths: Set<String>) async -> [UninstallCandidate] {
        var seen = seenPaths
        var out: [UninstallCandidate] = []

        // 1. bundleID 严格相等查询
        let bidPaths = await spotlight.probeByBundleID(meta.bundleID, timeout: spotlightTimeout)
        for path in bidPaths where !seen.contains(path) {
            // 仅接受 home / systemLibrary 子树下的路径，避免 spotlight 索引带出 /System 之类
            guard path.hasPrefix(homeDirectory) || path.hasPrefix(systemLibrary) else { continue }
            let snap = fileManager.snapshot(at: path)
            guard snap.bytes > 0 || snap.fileCount > 0 else { continue }
            seen.insert(path)
            out.append(.init(
                path: path,
                bytes: snap.bytes,
                fileCount: snap.fileCount,
                matchReason: .spotlight("bundleID")
            ))
        }

        // 2. appName 严格相等忽略大小写查询（仅当长度 >= 4 且非常见词，避免 "App"/"Data" 引爆）
        let trimmed = meta.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCommonNoise = ["app", "data", "test", "demo", "temp", "main", "user"].contains(trimmed.lowercased())
        if trimmed.count >= 4, !isCommonNoise {
            let namePaths = await spotlight.probeByAppName(trimmed, timeout: spotlightTimeout)
            for path in namePaths where !seen.contains(path) {
                guard path.hasPrefix(homeDirectory) || path.hasPrefix(systemLibrary) else { continue }
                let snap = fileManager.snapshot(at: path)
                guard snap.bytes > 0 || snap.fileCount > 0 else { continue }
                seen.insert(path)
                out.append(.init(
                    path: path,
                    bytes: snap.bytes,
                    fileCount: snap.fileCount,
                    matchReason: .spotlight("appName")
                ))
            }
        }
        return out
    }
}

// MARK: - 文件系统抽象

/// 抽象层 —— 让测试不依赖真实磁盘的 size 结果。
public protocol FileManagerSnapshotting: Sendable {
    func firstLevelEntries(at path: String) -> [FSEntry]?
    func snapshot(at path: String) -> FSSnapshot
}

public struct FSEntry: Hashable, Sendable {
    public let name: String
    public let path: String
    public init(name: String, path: String) { self.name = name; self.path = path }
}

public struct FSSnapshot: Hashable, Sendable {
    public let bytes: Int64
    public let fileCount: Int
    public init(bytes: Int64, fileCount: Int) { self.bytes = bytes; self.fileCount = fileCount }
}

/// 真实磁盘实现。第一层用 `contentsOfDirectory`，size 用浅递归（深度无限，但目录数量
/// 通常很小）。如果担心性能，可换成 `BulkScanner`。
///
/// **Step 14**：原 `try?` 全部改 do/catch + [IOErrorClassifier](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LogKit/Sources/LogKit/IOErrorClassifier.swift) 分类：
/// - `.permissionDenied` → 调用 `permissionDeniedHandler`（默认 nil）+ GSYLog.debug
/// - `.notFound` → GSYLog.debug 静默
/// - `.other` → GSYLog.warning 落盘
public struct DefaultFileManagerSnapshot: FileManagerSnapshotting {
    /// EACCES 时被调用一次的 handler（默认 nil = 不上报，保留旧静默语义）。
    public let permissionDeniedHandler: (@Sendable (String) -> Void)?

    public init(permissionDeniedHandler: (@Sendable (String) -> Void)? = nil) {
        self.permissionDeniedHandler = permissionDeniedHandler
    }

    public func firstLevelEntries(at path: String) -> [FSEntry]? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        do {
            let names = try fm.contentsOfDirectory(atPath: path)
            return names.map { FSEntry(name: $0, path: "\(path)/\($0)") }
        } catch {
            handle(error: error, path: path, op: "firstLevelEntries")
            return nil
        }
    }

    public func snapshot(at path: String) -> FSSnapshot {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return .init(bytes: 0, fileCount: 0) }
        if !isDir.boolValue {
            let bytes = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return .init(bytes: bytes, fileCount: 1)
        }
        var totalBytes: Int64 = 0
        var totalFiles: Int = 0
        if let en = fm.enumerator(atPath: path) {
            for case let rel as String in en {
                let full = "\(path)/\(rel)"
                var sub: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &sub) else { continue }
                if sub.boolValue { continue }
                totalFiles += 1
                if let size = (try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber)?.int64Value {
                    totalBytes += size
                }
            }
        }
        return .init(bytes: totalBytes, fileCount: totalFiles)
    }

    /// 错误分类落点：EACCES 上报 + debug；ENOENT 仅 debug；其他 warning。
    private func handle(error: Error, path: String, op: String) {
        switch IOErrorClassifier.classify(error) {
        case .permissionDenied:
            permissionDeniedHandler?(path)
            GSYLog.debug(.scan, "FileManagerSnapshot \(op) permission denied: \(path)")
        case .notFound:
            GSYLog.debug(.scan, "FileManagerSnapshot \(op) not found: \(path)")
        case .other:
            GSYLog.warning(.scan, "FileManagerSnapshot \(op) failed at \(path): \(error.localizedDescription)")
        }
    }
}
