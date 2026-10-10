import Darwin
import Dispatch
import Foundation
import LogKit
import SafetyKit
import ScanKit
import Security

/// 残留候选项 —— 是“可能”属于被卸载 App 的文件/目录。
///
/// **注意：返回的只是“候选”**。最终是否真删除由用户在 UI 勾选。
/// 设计参考 PITFALLS §5.4：宁可漏报，不可误杀。
public struct UninstallCandidate: Hashable, Sendable {
    public let path: String
    public let bytes: Int64
    public let fileCount: Int
    /// 来自扫描时的真实文件类型；删除链路不得再用 fileCount 猜测目录。
    public let isDirectory: Bool
    /// 候选容量快照是否穷尽。partial 只允许展示下界，不能作为普通删除证据。
    public let snapshotCompletion: FSSnapshotCompletionStatus
    /// 结构化保留预算、权限、枚举与 metadata 缺口，避免把 0B/部分 bytes 伪装成完整值。
    public let snapshotIssues: [FSSnapshotIssue]
    /// v2026.07.18：扫描时 no-follow 冻结的磁盘对象身份。路径只是展示/寻址文本，
    /// 真删除能力必须把这个身份一路带到 recycle 紧邻边界再次比较。
    public let objectIdentity: TrashObjectIdentity?
    public let matchReason: MatchReason

    public init(
        path: String,
        bytes: Int64,
        fileCount: Int,
        isDirectory: Bool = false,
        snapshotCompletion: FSSnapshotCompletionStatus = .complete,
        snapshotIssues: [FSSnapshotIssue] = [],
        objectIdentity: TrashObjectIdentity? = nil,
        matchReason: MatchReason
    ) {
        self.path = path
        self.bytes = bytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.snapshotCompletion = snapshotCompletion
        self.snapshotIssues = snapshotIssues
        self.objectIdentity = objectIdentity
        self.matchReason = matchReason
    }

    public init(path: String, snapshot: FSSnapshot, matchReason: MatchReason) {
        self.init(
            path: path,
            bytes: snapshot.bytes,
            fileCount: snapshot.fileCount,
            isDirectory: snapshot.isDirectory,
            snapshotCompletion: snapshot.completion,
            snapshotIssues: snapshot.issues,
            objectIdentity: snapshot.objectIdentity,
            matchReason: matchReason
        )
    }

    public var hasCompleteSnapshot: Bool {
        snapshotCompletion == .complete && snapshotIssues.isEmpty
    }

    public var hasStableDeletionIdentity: Bool {
        guard let objectIdentity else { return false }
        let expectedType = isDirectory ? UInt16(S_IFDIR) : UInt16(S_IFREG)
        return objectIdentity.fileType == expectedType
    }
}

/// v2026.07.18：卸载发现的每个来源都必须留下 typed terminal evidence。空候选只有在
/// `incompleteIssues` 为空时才表示“完整扫描后没有残留”；权限、索引超时、pkg 命令失败
/// 与选择身份漂移不能再共用一个无语义的空数组。
public struct UninstallDiscoveryIssue: Error, Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        case primaryRoot
        case vendorRule
        case spotlightBundleID
        case spotlightAppName
        case pkgReceipt
        case selectedAppIdentity
    }

    public enum Stage: String, Hashable, Sendable {
        case rootMetadata
        case rootEnumeration
        case candidateSnapshot
        case queryStart
        case queryGathering
        case packageList
        case packageInfo
        case packageFiles
        case receiptValidation
        case identityValidation
        case cancellation
    }

    public enum Reason: Hashable, Sendable {
        case permissionDenied
        case enumerationFailed
        case metadataUnavailable
        case fileBudgetExceeded(limit: Int)
        case timeBudgetExceeded(limitMilliseconds: Int64)
        case issueCollectionLimitExceeded(limit: Int)
        case queryStartFailed
        case timedOut
        case resultCountLimitExceeded(limit: Int)
        case extractionTimeLimitExceeded(limitMilliseconds: Int64)
        case cancelled
        case identityUnavailable
        case identityMismatch(claimedBundleID: String, actualBundleID: String)
        case receiptOwnershipAmbiguous
        case pkgutil(PkgutilCommandFailure)

        fileprivate var sortKey: String {
            switch self {
            case .permissionDenied: return "permissionDenied"
            case .enumerationFailed: return "enumerationFailed"
            case .metadataUnavailable: return "metadataUnavailable"
            case .fileBudgetExceeded(let limit): return "fileBudgetExceeded:\(limit)"
            case .timeBudgetExceeded(let limit): return "timeBudgetExceeded:\(limit)"
            case .issueCollectionLimitExceeded(let limit): return "issueCollectionLimitExceeded:\(limit)"
            case .queryStartFailed: return "queryStartFailed"
            case .timedOut: return "timedOut"
            case .resultCountLimitExceeded(let limit):
                return "resultCountLimitExceeded:\(limit)"
            case .extractionTimeLimitExceeded(let limit):
                return "extractionTimeLimitExceeded:\(limit)"
            case .cancelled: return "cancelled"
            case .identityUnavailable: return "identityUnavailable"
            case .identityMismatch(let claimed, let actual):
                return "identityMismatch:\(claimed):\(actual)"
            case .receiptOwnershipAmbiguous: return "receiptOwnershipAmbiguous"
            case .pkgutil(let failure): return "pkgutil:\(String(describing: failure))"
            }
        }
    }

    public let source: Source
    public let stage: Stage
    /// File-backed stages carry an absolute path. Global pkg list/query stages may leave this nil;
    /// pkg-scoped stages use `pkgID` instead of pretending a package identifier is a file path.
    public let path: String?
    public let pkgID: String?
    public let reason: Reason

    public init(
        source: Source,
        stage: Stage,
        path: String? = nil,
        pkgID: String? = nil,
        reason: Reason
    ) {
        self.source = source
        self.stage = stage
        self.path = path
        self.pkgID = pkgID
        self.reason = reason
    }
}

/// App URL 与列表阶段读到的 metadata 是一个不可拆分的选择声明。扫描生产边界仍会重读
/// Info.plist；声明与磁盘当前 bundle ID 不一致时整轮 fail closed。
public struct UninstallSelectedAppIdentity: Hashable, Sendable {
    public let appURL: URL
    public let claimedMetadata: AppMetadata
    /// Destructive authority is never optional. `InstalledApp` may omit identity for old read-only
    /// fixtures, but such a value cannot be promoted into an uninstall capability.
    public let expectedFileIdentity: InstalledAppFileIdentity

    public init(
        appURL: URL,
        metadata: AppMetadata,
        expectedFileIdentity: InstalledAppFileIdentity
    ) {
        self.appURL = appURL
        self.claimedMetadata = metadata
        self.expectedFileIdentity = expectedFileIdentity
    }

    public init?(installedApp: InstalledApp) {
        guard let fileIdentity = installedApp.fileIdentity else { return nil }
        self.init(
            appURL: installedApp.appURL,
            metadata: installedApp.metadata,
            expectedFileIdentity: fileIdentity
        )
    }
}

/// v2026.07.18：残留发现第一层目录同样属于可取消 producer，而不是一次不可中断的
/// `readdir`。预算是整轮共享值；任一预算终态都会保留 typed incomplete，并停止后续根。
public struct UninstallPrimaryDiscoveryLimits: Sendable, Equatable {
    public let maxVisitedEntries: Int
    public let maxDuration: TimeInterval

    public init(maxVisitedEntries: Int = 100_000, maxDuration: TimeInterval = 2) {
        self.maxVisitedEntries = max(0, maxVisitedEntries)
        self.maxDuration = maxDuration.isNaN || maxDuration <= 0 ? 0 : maxDuration
    }
}

/// Source proof carried by the uninstall intent. It is deliberately separate from the selected
/// `.app` identity: the App proves which product was scanned, while every candidate identity proves
/// which exact directory entry the user reviewed. Neither proof can substitute for the other.
public struct UninstallCandidateVerificationRequest: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let path: String
        let identity: TrashObjectIdentity
    }

    let entries: [Entry]

    init?(candidates: [UninstallCandidate]) {
        guard !candidates.isEmpty else { return nil }
        var seen = Set<String>()
        var frozen: [Entry] = []
        frozen.reserveCapacity(candidates.count)
        for candidate in candidates {
            let path = DeletionIntentCandidate.pathIdentity(candidate.path)
            guard seen.insert(path).inserted,
                  candidate.hasCompleteSnapshot,
                  candidate.hasStableDeletionIdentity,
                  let identity = candidate.objectIdentity else { return nil }
            frozen.append(Entry(path: path, identity: identity))
        }
        self.entries = frozen
    }

    private init(entries: [Entry]) {
        self.entries = entries
    }

    var paths: [String] { entries.map(\.path) }

    func matchesExactTargets(_ paths: [String]) -> Bool {
        paths.map(DeletionIntentCandidate.pathIdentity) == self.paths
    }

    func matchesExactCandidates(_ candidates: [DeletionIntentCandidate]) -> Bool {
        guard candidates.count == entries.count else { return false }
        return zip(candidates, entries).allSatisfy { candidate, entry in
            candidate.standardizedPath == entry.path
                && candidate.sourceObjectIdentity.map(entry.identity.matches) == true
        }
    }

    func restricting(to paths: [String]) -> UninstallCandidateVerificationRequest? {
        let normalized = paths.map(DeletionIntentCandidate.pathIdentity)
        let wanted = Set(normalized)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        guard !normalized.isEmpty,
              wanted.count == normalized.count,
              wanted.isSubset(of: Set(byPath.keys)) else { return nil }
        let restricted = normalized.compactMap { byPath[$0] }
        guard restricted.count == normalized.count else { return nil }
        return UninstallCandidateVerificationRequest(entries: restricted)
    }

    /// Compare scan-time proof with the identity reserved by the persistent submission ledger.
    /// The ledger rechecks this same identity beside every concrete AppKit claim, closing later
    /// replacement windows without duplicating filesystem policy here.
    func changedPaths(comparedTo current: [String: TrashObjectIdentity]) -> [String] {
        DeletionExecutionIdentity.changedPaths(
            expected: entries.map { (path: $0.path, identity: $0.identity) }, reserved: current
        )
    }
}

/// 一轮卸载候选发现的权威结果。候选和 pkg receipt 缺口来自同一轮，调用方可以像数组
/// 一样遍历候选，但不能再把 `isEmpty` 单独解释为“完整且没有残留”。
public struct UninstallCandidateDiscoveryResult: Sendable, Equatable, RandomAccessCollection {
    public typealias Element = UninstallCandidate
    public typealias Index = Int

    public let candidates: [UninstallCandidate]
    public let incompleteIssues: [UninstallDiscoveryIssue]
    public let pkgReceiptIncompleteIssues: [PkgutilReceiptsScanner.IncompleteIssue]

    public var isDiscoveryComplete: Bool {
        incompleteIssues.isEmpty && candidates.allSatisfy(\.hasCompleteSnapshot)
    }
    public var startIndex: Int { candidates.startIndex }
    public var endIndex: Int { candidates.endIndex }

    public subscript(position: Int) -> UninstallCandidate {
        candidates[position]
    }

    public init(
        candidates: [UninstallCandidate],
        incompleteIssues: [UninstallDiscoveryIssue] = [],
        pkgReceiptIncompleteIssues: [PkgutilReceiptsScanner.IncompleteIssue] = []
    ) {
        self.candidates = candidates
        let pkgIssues = Array(Set(pkgReceiptIncompleteIssues)).sorted {
            if $0.stage != $1.stage { return $0.stage.rawValue < $1.stage.rawValue }
            return ($0.pkgID ?? "") < ($1.pkgID ?? "")
        }
        self.pkgReceiptIncompleteIssues = pkgIssues
        self.incompleteIssues = Array(Set(
            incompleteIssues
                + pkgIssues.map(Self.discoveryIssue)
                + candidates.flatMap(Self.candidateDiscoveryIssues)
        )).sorted(by: Self.issueOrder)
    }

    private static func candidateDiscoveryIssues(
        _ candidate: UninstallCandidate
    ) -> [UninstallDiscoveryIssue] {
        let source: UninstallDiscoveryIssue.Source
        switch candidate.matchReason {
        case .bundleID, .bundleVendor, .appName: source = .primaryRoot
        case .vendorRule: source = .vendorRule
        case .spotlight(let kind):
            source = kind == "bundleID" ? .spotlightBundleID : .spotlightAppName
        case .pkgReceipt: source = .pkgReceipt
        }
        var issues = candidate.snapshotIssues.map { issue -> UninstallDiscoveryIssue in
            let stage: UninstallDiscoveryIssue.Stage
            switch issue.stage {
            case .rootMetadata: stage = .rootMetadata
            case .enumeration: stage = .rootEnumeration
            case .entryMetadata, .budget: stage = .candidateSnapshot
            case .cancellation: stage = .cancellation
            }
            let reason: UninstallDiscoveryIssue.Reason
            switch issue.reason {
            case .fileBudgetExceeded(let limit): reason = .fileBudgetExceeded(limit: limit)
            case .timeBudgetExceeded(let limit): reason = .timeBudgetExceeded(limitMilliseconds: limit)
            case .permissionDenied: reason = .permissionDenied
            case .enumerationFailed: reason = .enumerationFailed
            case .metadataUnavailable: reason = .metadataUnavailable
            case .cancelled: reason = .cancelled
            case .issueCollectionLimitExceeded(let limit):
                reason = .issueCollectionLimitExceeded(limit: limit)
            }
            return UninstallDiscoveryIssue(
                source: source,
                stage: stage,
                path: issue.path,
                reason: reason
            )
        }
        if candidate.snapshotCompletion != .complete, issues.isEmpty {
            issues.append(UninstallDiscoveryIssue(
                source: source,
                stage: candidate.snapshotCompletion == .cancelled
                    ? .cancellation
                    : .candidateSnapshot,
                path: candidate.path,
                reason: candidate.snapshotCompletion == .cancelled
                    ? .cancelled
                    : .metadataUnavailable
            ))
        }
        return issues
    }

    private static func discoveryIssue(
        _ issue: PkgutilReceiptsScanner.IncompleteIssue
    ) -> UninstallDiscoveryIssue {
        let stage: UninstallDiscoveryIssue.Stage
        switch issue.stage {
        case .packageList: stage = .packageList
        case .packageInfo: stage = .packageInfo
        case .files: stage = .packageFiles
        case .receiptValidation: stage = .receiptValidation
        }
        return UninstallDiscoveryIssue(
            source: .pkgReceipt,
            stage: stage,
            pkgID: issue.pkgID,
            reason: .pkgutil(issue.reason)
        )
    }

    private static func issueOrder(
        _ lhs: UninstallDiscoveryIssue,
        _ rhs: UninstallDiscoveryIssue
    ) -> Bool {
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        if lhs.stage != rhs.stage { return lhs.stage.rawValue < rhs.stage.rawValue }
        if lhs.path != rhs.path { return (lhs.path ?? "") < (rhs.path ?? "") }
        if lhs.pkgID != rhs.pkgID { return (lhs.pkgID ?? "") < (rhs.pkgID ?? "") }
        return lhs.reason.sortKey < rhs.reason.sortKey
    }
}

/// 卸载候选的可选补充来源。首屏可以只读取本地 receipt 而不等待 Spotlight；
/// 完整的应用占用扫描则显式选择 `.all`。每一位都对应独立、可审计的数据来源。
public struct UninstallDiscoveryFallbacks: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let spotlight = UninstallDiscoveryFallbacks(rawValue: 1 << 0)
    public static let pkgReceipts = UninstallDiscoveryFallbacks(rawValue: 1 << 1)
    public static let all: UninstallDiscoveryFallbacks = [.spotlight, .pkgReceipts]
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
    /// 只查询选中 App 的 exact bundleID namespace，并要求同一 receipt 实际列出
    /// 该 `.app` 或其内部路径作为产品锚点。候选只能是 receipt 内含 bundleID / 产品名
    /// 组件的最小产品专属根；共享祖先、其他 `.app`、选中 bundle 内部逐文件都不进入
    /// related cleanup。关联值是命中的 pkgID，方便 UI 提示证据链。
    case pkgReceipt(String)
}

/// v2026.07.15：Info.plist 的产品级解析失败保持为语义值，避免扫描 worker 在
/// App 语言切换前后把某一种语言的 `NSLocalizedDescription` 固化进错误对象。
/// 文件读取/PropertyList 解码抛出的系统错误仍原样向上传递。
public enum AppMetadataReadError: Error, Hashable, Sendable {
    case propertyListIsNotDictionary
    case missingBundleIdentifier

    public func message(locale: Locale) -> String {
        switch self {
        case .propertyListIsNotDictionary:
            return AppLocalization.string("uninstaller.err.plist_not_dict", locale: locale)
        case .missingBundleIdentifier:
            return AppLocalization.string("uninstaller.err.missing_bundle_id", locale: locale)
        }
    }
}

/// 解析后的 .app 元数据。
public struct AppMetadata: Hashable, Sendable {
    public let bundleID: String
    /// 反域名第一层 + 第二层（`com.foo.bar` -> `com.foo`），用于在 LaunchAgents/Daemons
    /// 这种“供应商共享目录”里做更宽匹配。**不会**用于 Application Support 等。
    public let bundleVendor: String?
    public let appName: String
    public let executableName: String?
    /// 代码签名中的 Apple Developer Team ID（如 10 位大写字母数字），用于核验
    /// `~/Library/Group Containers/<TeamID>.<bundleID>`。无签名或测试 fixture 时为 nil。
    public let teamID: String?

    public init(
        bundleID: String,
        bundleVendor: String?,
        appName: String,
        executableName: String?,
        teamID: String? = nil
    ) {
        self.bundleID = bundleID
        self.bundleVendor = bundleVendor
        self.appName = appName
        self.executableName = executableName
        self.teamID = teamID
    }

    /// 从 `<App>.app/Contents/Info.plist` 解析。
    ///
    /// v2026.07.18: application discovery shares ScanKit's bounded regular-file reader, which
    /// rejects a symlink at the final `Info.plist` component. A malformed bundle can no longer turn
    /// one small metadata read into unbounded memory use or publish bytes from a replaced file
    /// generation. Stable parent-component symlinks retain normal POSIX resolution here; the
    /// destructive boundary separately uses descriptor-relative all-component validation.
    public static func read(
        appURL: URL,
        shouldCancel: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> AppMetadata {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try BoundedLocalFileReader.read(
            at: plistURL,
            shouldCancel: shouldCancel
        )
        return try read(
            plistData: data,
            appFileName: appURL.lastPathComponent,
            teamID: readCodeSigningTeamID(at: appURL)
        )
    }

    /// Shared parser for the pathname compatibility API and production bounded fd reader.
    /// Keeping plist interpretation in one place prevents identity hardening from changing product
    /// naming or localization behavior.
    static func read(
        plistData data: Data,
        appFileName: String,
        teamID: String? = nil
    ) throws -> AppMetadata {
        guard
            let any = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            throw AppMetadataReadError.propertyListIsNotDictionary
        }
        guard let bundleID = any["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw AppMetadataReadError.missingBundleIdentifier
        }
        let nameFromPlist = (any["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // 退化：取 .app 的文件名去掉 .app 后缀
        let stem = URL(fileURLWithPath: appFileName).deletingPathExtension().lastPathComponent
        let appName = nameFromPlist ?? stem
        let exe = (any["CFBundleExecutable"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppMetadata(
            bundleID: bundleID,
            bundleVendor: vendorPrefix(of: bundleID),
            appName: appName,
            executableName: exe,
            teamID: teamID
        )
    }

    static func readCodeSigningTeamID(at appURL: URL) -> String? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return nil }
        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard infoStatus == errSecSuccess,
              let dict = signingInfo as? [String: Any],
              let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty else {
            return nil
        }
        return teamID
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
    /// Residual-root producer budget. Unlike candidate subtree snapshot budgets, this limits the
    /// twelve first-level `readdir` passes themselves and is shared across one discovery round.
    let primaryDiscoveryLimits: UninstallPrimaryDiscoveryLimits
    /// Production re-reads Info.plist through this boundary. The injectable reader keeps identity
    /// race tests deterministic without weakening the default filesystem validation.
    private let injectedAppMetadataReader: (@Sendable (URL) throws -> AppMetadata)?

    public init(
        homeDirectory: String = NSHomeDirectory(),
        systemLibrary: String = "/Library",
        fileManager: FileManagerSnapshotting = DefaultFileManagerSnapshot(
            maxDescendantFiles: 250_000,
            maxSnapshotDuration: 6
        ),
        vendorRules: [VendorRule] = [],
        spotlight: SpotlightProbing? = nil,
        spotlightTimeout: TimeInterval = 1.5,
        pkgutilScanner: PkgutilReceiptsScanner? = nil,
        appMetadataReader: (@Sendable (URL) throws -> AppMetadata)? = nil,
        primaryDiscoveryLimits: UninstallPrimaryDiscoveryLimits = .init()
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
        // Keep the protocol bounded even for injected probes: NaN/infinity/non-positive values
        // become an immediate typed timeout instead of disabling the deadline accidentally.
        self.spotlightTimeout = spotlightTimeout.isFinite && spotlightTimeout > 0
            ? min(spotlightTimeout, 30)
            : 0
        // 默认决策：homeDirectory 是真实 home 时启用 DefaultPkgutilRunner（生产路径）；
        // 否则禁用，避免子进程 /usr/sbin/pkgutil 拖慢 / 污染单测。
        if let s = pkgutilScanner {
            self.pkgutilScanner = s
        } else if homeDirectory == NSHomeDirectory() {
            self.pkgutilScanner = PkgutilReceiptsScanner()
        } else {
            self.pkgutilScanner = nil
        }
        self.injectedAppMetadataReader = appMetadataReader
        self.primaryDiscoveryLimits = primaryDiscoveryLimits
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

    private enum ProposalSource: Int, Sendable {
        case primary = 0
        case pkgReceipt = 1
        case spotlight = 2
        case vendorRule = 3

        var issueSource: UninstallDiscoveryIssue.Source {
            switch self {
            case .primary: return .primaryRoot
            case .pkgReceipt: return .pkgReceipt
            case .spotlight: return .spotlightBundleID
            case .vendorRule: return .vendorRule
            }
        }
    }

    private struct CandidateProposal: Sendable {
        let path: String
        let reason: MatchReason
        let source: ProposalSource
        /// Higher values carry stronger product ownership evidence. Overlapping candidates are
        /// resolved before snapshotting; strength wins, then the deeper path wins as fail-safe.
        let evidenceStrength: Int
        /// Present only for primary-root first-level entries. It binds later snapshot I/O to the
        /// root and child objects observed during no-follow enumeration.
        let firstLevelEntry: FSEntry?

        init(
            path: String,
            reason: MatchReason,
            source: ProposalSource,
            evidenceStrength: Int,
            firstLevelEntry: FSEntry? = nil
        ) {
            self.path = path
            self.reason = reason
            self.source = source
            self.evidenceStrength = evidenceStrength
            self.firstLevelEntry = firstLevelEntry
        }
    }

    private struct ProposalCollection: Sendable {
        var proposals: [CandidateProposal] = []
        var issues: [UninstallDiscoveryIssue] = []
        var pkgIssues: [PkgutilReceiptsScanner.IncompleteIssue] = []
    }

    private struct ValidatedIdentity: Sendable {
        let appURL: URL
        let bundlePath: String
        let metadata: AppMetadata
        let fileIdentity: InstalledAppFileIdentity
    }

    private struct SnapshottedProposal: Sendable {
        let proposal: CandidateProposal
        let snapshot: FSSnapshot
    }

    /// 主入口。
    public func candidates(forAppAt appURL: URL) throws -> UninstallCandidateDiscoveryResult {
        let meta = try AppMetadata.read(appURL: appURL)
        guard let identity = Self.captureSelectedIdentity(appURL: appURL, metadata: meta) else {
            return UninstallCandidateDiscoveryResult(
                candidates: [],
                incompleteIssues: [Self.selectedAppIdentityIssue(path: appURL.path)]
            )
        }
        return candidates(for: identity)
    }

    /// 已有元数据但没有 bundle 路径的入口。Receipt 归属需要用选中 `.app`
    /// 在清单中做产品锚定，因此这个兼容入口只执行主路径，不猜 receipt。
    public func candidates(for meta: AppMetadata) -> UninstallCandidateDiscoveryResult {
        buildSynchronousResult(meta: meta, validatedIdentity: nil, includePkgReceipts: false)
    }

    /// Compatibility surface for older callers. The two values are immediately frozen into one
    /// typed identity and validated as a unit before any candidate source is queried.
    public func candidates(
        for meta: AppMetadata,
        selectedAppURL: URL?
    ) -> UninstallCandidateDiscoveryResult {
        guard let selectedAppURL else { return candidates(for: meta) }
        guard let identity = Self.captureSelectedIdentity(
            appURL: selectedAppURL,
            metadata: meta
        ) else {
            return UninstallCandidateDiscoveryResult(
                candidates: [],
                incompleteIssues: [Self.selectedAppIdentityIssue(path: selectedAppURL.path)]
            )
        }
        return candidates(for: identity)
    }

    /// Production boundary: URL + claimed metadata are re-read and compared before scanning. A
    /// replaced/moved bundle cannot make metadata from App B authorize receipt anchors for App A.
    public func candidates(
        for identity: UninstallSelectedAppIdentity
    ) -> UninstallCandidateDiscoveryResult {
        switch validate(identity: identity) {
        case .success(let validated):
            return buildSynchronousResult(
                meta: validated.metadata,
                validatedIdentity: validated,
                includePkgReceipts: true
            )
        case .failure(let issue):
            return UninstallCandidateDiscoveryResult(candidates: [], incompleteIssues: [issue])
        }
    }

    /// Revalidate the exact selected bundle capability without running candidate discovery.
    /// The uninstall UI calls this before confirmation and immediately before recycle submission,
    /// so a same-path replacement cannot reuse an older scan revision.
    public func selectedAppValidationIssue(
        for identity: UninstallSelectedAppIdentity
    ) -> UninstallDiscoveryIssue? {
        switch validate(identity: identity) {
        case .success: return nil
        case .failure(let issue): return issue
        }
    }

    public enum SelectedAppDeletionValidationDisposition: Sendable, Equatable {
        case valid
        case appAlreadyRemoved
        case invalid(UninstallDiscoveryIssue)
    }

    /// Typed pre-deletion revalidator. When the `.app` itself was already trashed in an earlier
    /// pass (and is not among `deletingPaths`), `lstat` returning `ENOENT` yields `.appAlreadyRemoved`
    /// while any replacement file/directory/symlink at the bundle path still fails closed.
    public func revalidateSelectedAppForDeletion(
        identity: UninstallSelectedAppIdentity,
        deletingPaths: Set<String>
    ) -> SelectedAppDeletionValidationDisposition {
        switch validate(identity: identity) {
        case .success:
            return .valid
        case .failure(let issue):
            guard let bundlePath = Self.canonicalSelectedBundlePath(identity.appURL),
                  !deletingPaths.contains(bundlePath) else {
                return .invalid(issue)
            }
            var linkStat = stat()
            if lstat(bundlePath, &linkStat) != 0, errno == ENOENT {
                return .appAlreadyRemoved
            }
            return .invalid(issue)
        }
    }

    private func buildSynchronousResult(
        meta: AppMetadata,
        validatedIdentity: ValidatedIdentity?,
        includePkgReceipts: Bool
    ) -> UninstallCandidateDiscoveryResult {
        let cancellation = FSSnapshotCancellationToken()
        var discovery = primaryAndVendorProposals(for: meta, cancellationToken: cancellation)
        if includePkgReceipts, let validatedIdentity, pkgutilScanner != nil {
            let pkg = pkgReceiptProposals(
                for: meta,
                selectedBundlePath: validatedIdentity.bundlePath
            )
            discovery.proposals.append(contentsOf: pkg.proposals)
            discovery.issues.append(contentsOf: pkg.issues)
            discovery.pkgIssues.append(contentsOf: pkg.pkgIssues)
        }
        let resolved = Self.resolveOverlaps(
            discovery.proposals,
            excludingBundlePath: validatedIdentity?.bundlePath
        )
        let snapshotted = snapshotSynchronously(resolved, cancellationToken: cancellation)
        discovery.issues.append(contentsOf: snapshotted.issues)
        return UninstallCandidateDiscoveryResult(
            candidates: snapshotted.candidates,
            incompleteIssues: discovery.issues,
            pkgReceiptIncompleteIssues: discovery.pkgIssues
        )
    }

    /// v2026.07.18 product-owned receipt boundary.
    ///
    /// 1. Query only the selected App's exact-or-dot-descendant bundleID namespace.
    /// 2. Require the receipt to contain the selected `.app` (or one of its descendants).
    /// 3. Reject an umbrella receipt if it contains any other `.app` payload.
    /// 4. Project only the shallowest path component carrying product-specific evidence. Shared
    ///    ancestors and files inside the selected bundle are never related-cleanup candidates.
    func pkgReceiptCandidates(
        for meta: AppMetadata,
        selectedAppURL: URL,
        seenPaths: inout Set<String>
    ) -> UninstallCandidateDiscoveryResult {
        guard pkgutilScanner != nil else { return UninstallCandidateDiscoveryResult(candidates: []) }
        guard let claim = Self.captureSelectedIdentity(
            appURL: selectedAppURL,
            metadata: meta
        ) else {
            return UninstallCandidateDiscoveryResult(
                candidates: [],
                incompleteIssues: [Self.selectedAppIdentityIssue(path: selectedAppURL.path)]
            )
        }
        let validated: ValidatedIdentity
        switch validate(identity: claim) {
        case .success(let value): validated = value
        case .failure(let issue):
            return UninstallCandidateDiscoveryResult(candidates: [], incompleteIssues: [issue])
        }
        let discovery = pkgReceiptProposals(
            for: validated.metadata,
            selectedBundlePath: validated.bundlePath
        )
        // This focused helper cannot replace a previously accepted parent with a stronger pkg
        // descendant, so any component overlap is conservatively dropped. Full production scans
        // resolve all sources together in `resolveOverlaps` and can choose the stronger child.
        let nonOverlapping = discovery.proposals.filter { proposal in
            !seenPaths.contains(where: { Self.pathsOverlap($0, proposal.path) })
        }
        let resolved = Self.resolveOverlaps(
            nonOverlapping,
            excludingBundlePath: validated.bundlePath
        )
        let snapshotted = snapshotSynchronously(resolved)
        seenPaths.formUnion(snapshotted.candidates.map(\.path))
        return UninstallCandidateDiscoveryResult(
            candidates: snapshotted.candidates,
            incompleteIssues: discovery.issues + snapshotted.issues,
            pkgReceiptIncompleteIssues: discovery.pkgIssues
        )
    }

    private static func canonicalSelectedBundlePath(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), path.lowercased().hasSuffix(".app") else { return nil }
        return path
    }

    /// Compatibility APIs that receive only a URL freeze the current no-follow object before
    /// constructing a destructive identity. They never manufacture the old `nil` authority.
    private static func captureSelectedIdentity(
        appURL: URL,
        metadata: AppMetadata
    ) -> UninstallSelectedAppIdentity? {
        guard let path = canonicalSelectedBundlePath(appURL),
              let fileIdentity = currentDirectoryIdentityNoFollow(at: path) else { return nil }
        return UninstallSelectedAppIdentity(
            appURL: URL(fileURLWithPath: path, isDirectory: true),
            metadata: metadata,
            expectedFileIdentity: fileIdentity
        )
    }

    private static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Returns the first `.app` path component enclosing a receipt row. The scanner already
    /// guarantees canonical absolute paths, so this is a lexical bundle boundary, not mutable IO.
    private static func enclosingAppBundlePath(_ path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: {
            $0 != "/" && $0.lowercased().hasSuffix(".app")
        }) else { return nil }
        return Self.path(fromAbsoluteComponents: Array(components.prefix(through: index)))
    }

    private struct ProjectedReceiptRoot: Hashable, Sendable {
        enum Evidence: Int, Hashable, Sendable {
            case weakName = 300
            case strongBundleID = 700
        }

        let path: String
        let evidence: Evidence
    }

    private func pkgReceiptProposals(
        for meta: AppMetadata,
        selectedBundlePath: String
    ) -> ProposalCollection {
        guard let scanner = pkgutilScanner else { return ProposalCollection() }
        let discovery = scanner.receipts(matchingBundleIDPrefix: meta.bundleID)
        var collection = ProposalCollection(pkgIssues: discovery.incompleteIssues)
        for receipt in discovery.receipts {
            let paths = receipt.absolutePaths
            guard paths.contains(where: {
                Self.isSameOrDescendant($0, of: selectedBundlePath)
            }) else {
                continue
            }
            guard !paths.contains(where: { path in
                guard let appBundle = Self.enclosingAppBundlePath(path) else { return false }
                return appBundle != selectedBundlePath
            }) else {
                // An umbrella receipt owns another App; non-App payload may be suite-shared.
                collection.issues.append(UninstallDiscoveryIssue(
                    source: .pkgReceipt,
                    stage: .receiptValidation,
                    pkgID: receipt.pkgID,
                    reason: .receiptOwnershipAmbiguous
                ))
                continue
            }
            collection.proposals.append(contentsOf: Self.productSpecificPayloadRoots(
                receiptPaths: paths,
                selectedBundlePath: selectedBundlePath,
                meta: meta
            ).map {
                CandidateProposal(
                    path: $0.path,
                    reason: .pkgReceipt(receipt.pkgID),
                    source: .pkgReceipt,
                    evidenceStrength: $0.evidence.rawValue
                )
            })
        }
        return collection
    }

    private static func productSpecificPayloadRoots(
        receiptPaths: [String],
        selectedBundlePath: String,
        meta: AppMetadata
    ) -> [ProjectedReceiptRoot] {
        let projected = receiptPaths.compactMap { path -> ProjectedReceiptRoot? in
            // The selected bundle is already counted separately. Its contents are evidence for
            // receipt ownership, never one-candidate-per-file cleanup payloads.
            guard !isSameOrDescendant(path, of: selectedBundlePath),
                  !isSameOrDescendant(selectedBundlePath, of: path),
                  enclosingAppBundlePath(path) == nil else { return nil }
            let components = (path as NSString).pathComponents
            let strongMarker = components.indices.first(where: {
                isStrongBundleIDComponent(components[$0], bundleID: meta.bundleID)
            })
            let marker: Int
            let evidence: ProjectedReceiptRoot.Evidence
            if let strongMarker {
                marker = strongMarker
                evidence = .strongBundleID
            } else {
                // Weak names are useful only beneath a positively recognized shared payload root.
                // They can never turn `/Library/Application Support`, `Caches`, `Logs`, etc. into
                // candidates merely because the selected App happens to use that generic name.
                guard let sharedRootEnd = sharedPayloadRootEndIndex(components),
                      let weakMarker = components.indices.first(where: { index in
                          index > sharedRootEnd && isWeakProductNameComponent(
                              components[index],
                              meta: meta
                          )
                      }) else { return nil }
                marker = weakMarker
                evidence = .weakName
            }
            guard let root = Self.path(
                fromAbsoluteComponents: Array(components.prefix(through: marker))
            ) else { return nil }
            guard !isSameOrDescendant(root, of: selectedBundlePath),
                  !isSameOrDescendant(selectedBundlePath, of: root) else { return nil }
            return ProjectedReceiptRoot(path: root, evidence: evidence)
        }

        // Keep the strongest proof for an exact root. Ancestor/descendant conflicts are resolved
        // globally with primary/vendor/Spotlight proposals, not prematurely inside receipt logic.
        return Dictionary(grouping: projected, by: \.path).compactMap { _, roots in
            roots.max { $0.evidence.rawValue < $1.evidence.rawValue }
        }.sorted { $0.path < $1.path }
    }

    private static func isStrongBundleIDComponent(_ component: String, bundleID: String) -> Bool {
        let lowered = component.lowercased()
        let token = bundleID.lowercased()
        return lowered == token || lowered.hasPrefix(token + ".")
    }

    private static func isWeakProductNameComponent(_ component: String, meta: AppMetadata) -> Bool {
        let lowered = component.lowercased()
        let vendorLeaf = meta.bundleVendor?
            .split(separator: ".")
            .last
            .map { String($0).lowercased() }
        let names = [meta.appName, meta.executableName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                let lowered = $0.lowercased()
                let commonNoise: Set<String> = [
                    "app", "data", "test", "demo", "temp", "main", "user",
                ]
                return $0.count >= 4 && !commonNoise.contains(lowered)
            }
        return names.contains { name in
            let token = name.lowercased()
            // A product named exactly like the vendor is not evidence that the vendor directory
            // is exclusive. BundleID-shaped components remain accepted above.
            guard token != vendorLeaf else { return false }
            return lowered == token || lowered.hasPrefix(token + ".")
        }
    }

    /// Returns the end index of the deepest recognized shared payload structure. Matching a weak
    /// product name is permitted only strictly below this index. The patterns are structural—not
    /// derived from the selected App—so generic names cannot redefine the trust boundary.
    private static func sharedPayloadRootEndIndex(_ components: [String]) -> Int? {
        let lowered = components.map { $0.lowercased() }
        let patterns: [[String]] = [
            ["library", "application support"],
            ["library", "caches"],
            ["library", "logs"],
            ["library", "preferences"],
            ["library", "saved application state"],
            ["library", "containers"],
            ["library", "group containers"],
            ["library", "cookies"],
            ["library", "webkit"],
            ["library", "httpstorages"],
            ["library", "launchagents"],
            ["library", "launchdaemons"],
            ["library", "privilegedhelpertools"],
            ["library", "internet plug-ins"],
            ["library", "audio", "plug-ins"],
            ["usr", "local", "share"],
            ["usr", "local", "lib"],
            ["opt"],
        ]
        var deepest: Int?
        for pattern in patterns where pattern.count <= lowered.count {
            for start in 0...(lowered.count - pattern.count) where
                Array(lowered[start..<(start + pattern.count)]) == pattern {
                let end = start + pattern.count - 1
                if deepest == nil || end > deepest! { deepest = end }
            }
        }
        return deepest
    }

    private static func path(fromAbsoluteComponents components: [String]) -> String? {
        guard components.first == "/" else { return nil }
        if components.count == 1 { return "/" }
        return "/" + components.dropFirst().joined(separator: "/")
    }

    private func validate(
        identity: UninstallSelectedAppIdentity
    ) -> Result<ValidatedIdentity, UninstallDiscoveryIssue> {
        guard let bundlePath = Self.canonicalSelectedBundlePath(identity.appURL) else {
            return .failure(UninstallDiscoveryIssue(
                source: .selectedAppIdentity,
                stage: .identityValidation,
                path: identity.appURL.isFileURL ? identity.appURL.path : nil,
                reason: .identityUnavailable
            ))
        }
        let appURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let descriptor = open(bundlePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

        if descriptor < 0 {
            return .failure(Self.selectedAppIdentityIssue(path: bundlePath))
        }
        defer { close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(Self.selectedAppIdentityIssue(path: bundlePath))
        }
        let openedIdentity = InstalledAppFileIdentity(metadata: openedMetadata)
        guard identity.expectedFileIdentity == openedIdentity else {
            return .failure(Self.selectedAppIdentityIssue(path: bundlePath))
        }

        let parsedMetadata: AppMetadata
        do {
            if let injectedAppMetadataReader {
                parsedMetadata = try injectedAppMetadataReader(appURL)
            } else {
                parsedMetadata = try Self.readMetadata(
                    fromOpenBundleDescriptor: descriptor,
                    appFileName: appURL.lastPathComponent
                )
            }
        } catch {
            return .failure(Self.selectedAppIdentityIssue(path: bundlePath))
        }

        let observedTeamID = injectedAppMetadataReader == nil
            ? AppMetadata.readCodeSigningTeamID(at: appURL)
            : parsedMetadata.teamID
        if let claimedTeamID = identity.claimedMetadata.teamID,
           let observedTeamID,
           claimedTeamID != observedTeamID {
            return .failure(Self.selectedAppIdentityIssue(path: bundlePath))
        }
        let actual = AppMetadata(
            bundleID: parsedMetadata.bundleID,
            bundleVendor: parsedMetadata.bundleVendor,
            appName: parsedMetadata.appName,
            executableName: parsedMetadata.executableName,
            teamID: parsedMetadata.teamID ?? observedTeamID ?? identity.claimedMetadata.teamID
        )

        // The fd above freezes the object used for default metadata parsing. Re-opening the path at
        // the terminal boundary proves the UI path still names that object; a persistent rename or
        // symlink replacement cannot publish candidates for the displaced bundle.
        guard Self.currentDirectoryIdentityNoFollow(at: bundlePath) == openedIdentity else {
            return .failure(Self.selectedAppIdentityIssue(path: bundlePath))
        }
        guard actual.bundleID == identity.claimedMetadata.bundleID else {
            return .failure(Self.selectedAppIdentityMismatch(
                path: bundlePath,
                claimed: identity.claimedMetadata.bundleID,
                actual: actual.bundleID
            ))
        }
        return .success(ValidatedIdentity(
            appURL: appURL,
            bundlePath: bundlePath,
            metadata: actual,
            fileIdentity: openedIdentity
        ))
    }

    private static func selectedAppIdentityIssue(path: String) -> UninstallDiscoveryIssue {
        UninstallDiscoveryIssue(
            source: .selectedAppIdentity,
            stage: .identityValidation,
            path: path,
            reason: .identityUnavailable
        )
    }

    private static func selectedAppIdentityMismatch(
        path: String,
        claimed: String,
        actual: String
    ) -> UninstallDiscoveryIssue {
        UninstallDiscoveryIssue(
            source: .selectedAppIdentity,
            stage: .identityValidation,
            path: path,
            reason: .identityMismatch(claimedBundleID: claimed, actualBundleID: actual)
        )
    }

    private static func currentDirectoryIdentityNoFollow(
        at path: String
    ) -> InstalledAppFileIdentity? {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return InstalledAppFileIdentity(metadata: metadata)
    }

    /// Read `Contents/Info.plist` relative to an already identity-bound `.app` descriptor. Every
    /// component is opened with O_NOFOLLOW, so an attacker cannot swap `Contents` or the plist for
    /// a symlink while keeping the outer bundle inode unchanged.
    private static func readMetadata(
        fromOpenBundleDescriptor bundleDescriptor: Int32,
        appFileName: String
    ) throws -> AppMetadata {
        let contentsDescriptor = "Contents".withCString {
            openat(bundleDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard contentsDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(contentsDescriptor) }

        let plistDescriptor = "Info.plist".withCString {
            openat(contentsDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard plistDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(plistDescriptor) }

        var plistMetadata = stat()
        guard fstat(plistDescriptor, &plistMetadata) == 0,
              (plistMetadata.st_mode & S_IFMT) == S_IFREG,
              plistMetadata.st_size >= 0,
              plistMetadata.st_size <= 16 * 1_024 * 1_024 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG))
        }

        var data = Data()
        data.reserveCapacity(Int(plistMetadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(plistDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            data.append(buffer, count: count)
            guard data.count <= 16 * 1_024 * 1_024 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG))
            }
        }
        return try AppMetadata.read(plistData: data, appFileName: appFileName)
    }

    private func primaryAndVendorProposals(
        for meta: AppMetadata,
        cancellationToken: FSSnapshotCancellationToken
    ) -> ProposalCollection {
        var collection = ProposalCollection()
        let deadline = Self.uptimeDeadline(after: primaryDiscoveryLimits.maxDuration)
        let timeLimitMilliseconds = Self.primaryDurationMilliseconds(
            primaryDiscoveryLimits.maxDuration
        )
        var remainingEntries = primaryDiscoveryLimits.maxVisitedEntries
        for root in searchRoots() {
            if cancellationToken.isCancelled {
                collection.issues.append(Self.discoveryIssue(
                    source: .primaryRoot,
                    snapshotStage: .cancellation,
                    path: root.path,
                    reason: .cancelled
                ))
                return collection
            }
            switch fileManager.firstLevelDiscovery(
                at: root.path,
                maximumEntries: remainingEntries,
                deadlineUptimeNanoseconds: deadline,
                timeLimitMilliseconds: timeLimitMilliseconds,
                cancellationToken: cancellationToken
            ) {
            case .entries(let entries):
                remainingEntries -= entries.count
                for entry in entries {
                    guard let reason = matchReason(
                        name: entry.name,
                        scope: root.scope,
                        meta: meta
                    ) else { continue }
                    collection.proposals.append(CandidateProposal(
                        path: entry.path,
                        reason: reason,
                        source: .primary,
                        evidenceStrength: Self.evidenceStrength(for: reason),
                        firstLevelEntry: entry
                    ))
                }
            case .missing:
                continue
            case .incomplete(let stage, let reason):
                collection.issues.append(Self.discoveryIssue(
                    source: .primaryRoot,
                    snapshotStage: stage,
                    path: root.path,
                    reason: reason
                ))
                if stage == .budget || stage == .cancellation { return collection }
            }
        }

        guard !cancellationToken.isCancelled else { return collection }
        for vendor in matchedVendors(for: meta) {
            for path in vendor.absolutePathPrefixes(home: homeDirectory) {
                collection.proposals.append(CandidateProposal(
                    path: path,
                    reason: .vendorRule(vendor.name),
                    source: .vendorRule,
                    evidenceStrength: Self.evidenceStrength(for: .vendorRule(vendor.name))
                ))
            }
        }
        return collection
    }

    private static func uptimeDeadline(after duration: TimeInterval) -> UInt64 {
        guard duration.isFinite else { return .max }
        let seconds = max(0, duration)
        let nanosDouble = seconds * 1_000_000_000
        let nanos = nanosDouble >= Double(UInt64.max) ? UInt64.max : UInt64(nanosDouble)
        let now = DispatchTime.now().uptimeNanoseconds
        let sum = now.addingReportingOverflow(nanos)
        return sum.overflow ? .max : sum.partialValue
    }

    private static func primaryDurationMilliseconds(_ duration: TimeInterval) -> Int64 {
        guard duration.isFinite else { return .max }
        let milliseconds = max(0, duration) * 1_000
        return milliseconds >= Double(Int64.max) ? .max : Int64(milliseconds)
    }

    private static func evidenceStrength(for reason: MatchReason) -> Int {
        switch reason {
        case .bundleID: return 700
        case .appName: return 300
        case .bundleVendor: return 150
        case .vendorRule: return 100
        case .spotlight(let kind): return kind == "bundleID" ? 700 : 300
        case .pkgReceipt: return 300
        }
    }

    private static func canonicalCandidatePath(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains("\0") else { return nil }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let canonical = URL(fileURLWithPath: raw).standardizedFileURL.path
        guard canonical.hasPrefix("/") else { return nil }
        return canonical
    }

    static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = canonicalCandidatePath(lhs),
              let rhs = canonicalCandidatePath(rhs) else { return false }
        return isSameOrDescendant(lhs, of: rhs) || isSameOrDescendant(rhs, of: lhs)
    }

    /// Cross-source component-boundary resolver. It runs before any snapshot, so App Footprint
    /// never counts a vendor parent and a receipt/Spotlight child twice. Strong evidence wins;
    /// equal evidence selects the deeper (smaller) root, then a stable source/path tie-breaker.
    private static func resolveOverlaps(
        _ proposals: [CandidateProposal],
        excludingBundlePath: String?
    ) -> [CandidateProposal] {
        let normalized = proposals.compactMap { proposal -> CandidateProposal? in
            guard let path = canonicalCandidatePath(proposal.path) else { return nil }
            if let excludingBundlePath, pathsOverlap(path, excludingBundlePath) { return nil }
            return CandidateProposal(
                path: path,
                reason: proposal.reason,
                source: proposal.source,
                evidenceStrength: proposal.evidenceStrength,
                firstLevelEntry: proposal.firstLevelEntry
            )
        }.sorted { lhs, rhs in
            if lhs.evidenceStrength != rhs.evidenceStrength {
                return lhs.evidenceStrength > rhs.evidenceStrength
            }
            let lhsDepth = (lhs.path as NSString).pathComponents.count
            let rhsDepth = (rhs.path as NSString).pathComponents.count
            if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
            if lhs.source.rawValue != rhs.source.rawValue {
                return lhs.source.rawValue < rhs.source.rawValue
            }
            return lhs.path < rhs.path
        }

        var accepted: [CandidateProposal] = []
        for proposal in normalized where !accepted.contains(where: {
            pathsOverlap($0.path, proposal.path)
        }) {
            accepted.append(proposal)
        }
        return accepted.sorted { $0.path < $1.path }
    }

    private func snapshotSynchronously(
        _ proposals: [CandidateProposal],
        cancellationToken: FSSnapshotCancellationToken = FSSnapshotCancellationToken()
    ) -> (candidates: [UninstallCandidate], issues: [UninstallDiscoveryIssue]) {
        var candidates: [UninstallCandidate] = []
        var issues: [UninstallDiscoveryIssue] = []
        candidates.reserveCapacity(proposals.count)
        for proposal in proposals {
            guard !cancellationToken.isCancelled else { break }
            let snapshot: FSSnapshot
            if let entry = proposal.firstLevelEntry {
                snapshot = fileManager.snapshot(
                    entry: entry,
                    cancellationToken: cancellationToken
                )
            } else {
                snapshot = fileManager.snapshot(
                    at: proposal.path,
                    cancellationToken: cancellationToken
                )
            }
            issues.append(contentsOf: Self.discoveryIssues(
                for: snapshot,
                proposal: proposal
            ))
            guard snapshot.exists, snapshot.completion != .cancelled else { continue }
            candidates.append(UninstallCandidate(
                path: proposal.path,
                snapshot: snapshot,
                matchReason: proposal.reason
            ))
        }
        return (candidates, issues)
    }

    private static func discoveryIssues(
        for snapshot: FSSnapshot,
        proposal: CandidateProposal
    ) -> [UninstallDiscoveryIssue] {
        let source: UninstallDiscoveryIssue.Source
        if case .spotlight(let kind) = proposal.reason {
            source = kind == "bundleID" ? .spotlightBundleID : .spotlightAppName
        } else {
            source = proposal.source.issueSource
        }
        var issues = snapshot.issues.map {
            discoveryIssue(
                source: source,
                snapshotStage: $0.stage,
                path: $0.path,
                reason: $0.reason
            )
        }
        if snapshot.completion != .complete, issues.isEmpty {
            issues.append(UninstallDiscoveryIssue(
                source: source,
                stage: snapshot.completion == .cancelled ? .cancellation : .candidateSnapshot,
                path: proposal.path,
                reason: snapshot.completion == .cancelled ? .cancelled : .metadataUnavailable
            ))
        }
        return issues
    }

    private static func discoveryIssue(
        source: UninstallDiscoveryIssue.Source,
        snapshotStage: FSSnapshotIssueStage,
        path: String,
        reason: FSSnapshotIssueReason
    ) -> UninstallDiscoveryIssue {
        let stage: UninstallDiscoveryIssue.Stage
        switch snapshotStage {
        case .rootMetadata: stage = .rootMetadata
        case .enumeration: stage = .rootEnumeration
        case .entryMetadata, .budget: stage = .candidateSnapshot
        case .cancellation: stage = .cancellation
        }
        let mapped: UninstallDiscoveryIssue.Reason
        switch reason {
        case .fileBudgetExceeded(let limit): mapped = .fileBudgetExceeded(limit: limit)
        case .timeBudgetExceeded(let limit): mapped = .timeBudgetExceeded(limitMilliseconds: limit)
        case .permissionDenied: mapped = .permissionDenied
        case .enumerationFailed: mapped = .enumerationFailed
        case .metadataUnavailable: mapped = .metadataUnavailable
        case .cancelled: mapped = .cancelled
        case .issueCollectionLimitExceeded(let limit):
            mapped = .issueCollectionLimitExceeded(limit: limit)
        }
        return UninstallDiscoveryIssue(
            source: source,
            stage: stage,
            path: path,
            reason: mapped
        )
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
        // 1) 严格 bundleID 前缀（含 Group Containers 的 group.<bundleID> 与经签名验证的 <TeamID>.[group.]<bundleID>）
        if matchesStrictPrefix(name: name, prefix: meta.bundleID)
            || Self.matchesGroupContainerPrefix(
                name: name,
                bundleID: meta.bundleID,
                teamID: meta.teamID
            ) {
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

    static func matchesGroupContainerPrefix(
        name: String,
        bundleID: String,
        teamID: String? = nil
    ) -> Bool {
        if name.hasPrefix("group.") {
            let stripped = String(name.dropFirst("group.".count))
            return matchesStrictPrefix(name: stripped, prefix: bundleID)
        }
        guard let expectedTeamID = teamID,
              !expectedTeamID.isEmpty,
              let dot = name.firstIndex(of: ".") else {
            return false
        }
        let teamPrefix = String(name[..<dot])
        guard teamPrefix == expectedTeamID else {
            return false
        }
        var remainder = String(name[name.index(after: dot)...])
        while remainder.hasPrefix(".") {
            remainder.removeFirst()
        }
        if remainder.hasPrefix("group.") {
            remainder = String(remainder.dropFirst("group.".count))
        }
        return matchesStrictPrefix(name: remainder, prefix: bundleID)
    }

    func matchesStrictPrefix(name: String, prefix: String) -> Bool {
        Self.matchesStrictPrefix(name: name, prefix: prefix)
    }

    /// appName 用于匹配的最低长度，太短会带来海量误判。
    private func isAppNameMatchable(_ s: String) -> Bool {
        s.count >= 4
    }

    /// 比较 `name`（可能含已知扩展名，如 `Foo.savedState` / `Foo.plist`）是否等于 `stem`。
    /// 不再在任意第一个 `.` 处截断，从而支持本身带 `.` 的应用名并避免 `Acme.OtherApp` 误匹配 `Acme`。
    private func nameEqualsIgnoringCase(_ name: String, stem: String) -> Bool {
        if name.caseInsensitiveCompare(stem) == .orderedSame {
            return true
        }
        let knownSuffixes = [
            ".savedState",
            ".plist",
            ".binarycookies",
            ".cookies",
            ".log",
            ".cache",
            ".db",
            ".sqlite"
        ]
        for suffix in knownSuffixes where name.lowercased().hasSuffix(suffix.lowercased()) {
            let candidate = String(name.dropLast(suffix.count))
            if candidate.caseInsensitiveCompare(stem) == .orderedSame {
                return true
            }
        }
        return false
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
    /// 这里把 **匹配** 仍保持同步（CPU 廉价），只把 **`snapshot(at:)` 这种阻塞 IO**
    /// 交给 utility Dispatch queue，并用 8 个 in-flight 槽位的滑动窗口限流；这样既不会
    /// 对 50 个候选直接 spawn 50 个 traversal，也不会占满 Swift cooperative executor。
    public func candidatesAsync(
        for meta: AppMetadata,
        selectedAppURL: URL? = nil,
        includeFallbacks: Bool = true
    ) async -> UninstallCandidateDiscoveryResult {
        await candidatesAsync(
            for: meta,
            selectedAppURL: selectedAppURL,
            fallbacks: includeFallbacks ? .all : []
        )
    }

    public func candidatesAsync(
        for meta: AppMetadata,
        selectedAppURL: URL? = nil,
        fallbacks: UninstallDiscoveryFallbacks
    ) async -> UninstallCandidateDiscoveryResult {
        if let selectedAppURL {
            guard let identity = Self.captureSelectedIdentity(
                appURL: selectedAppURL,
                metadata: meta
            ) else {
                return UninstallCandidateDiscoveryResult(
                    candidates: [],
                    incompleteIssues: [Self.selectedAppIdentityIssue(path: selectedAppURL.path)]
                )
            }
            return await candidatesAsync(
                for: identity,
                fallbacks: fallbacks
            )
        }
        return await buildAsynchronousResult(
            meta: meta,
            validatedIdentity: nil,
            fallbacks: fallbacks
        )
    }

    public func candidatesAsync(
        for identity: UninstallSelectedAppIdentity,
        fallbacks: UninstallDiscoveryFallbacks = .all
    ) async -> UninstallCandidateDiscoveryResult {
        switch validate(identity: identity) {
        case .success(let validated):
            return await buildAsynchronousResult(
                meta: validated.metadata,
                validatedIdentity: validated,
                fallbacks: fallbacks
            )
        case .failure(let issue):
            return UninstallCandidateDiscoveryResult(candidates: [], incompleteIssues: [issue])
        }
    }

    private func buildAsynchronousResult(
        meta: AppMetadata,
        validatedIdentity: ValidatedIdentity?,
        fallbacks: UninstallDiscoveryFallbacks
    ) async -> UninstallCandidateDiscoveryResult {
        let cancellation = FSSnapshotCancellationToken()
        return await withTaskCancellationHandler {
            await buildAsynchronousResult(
                meta: meta,
                validatedIdentity: validatedIdentity,
                fallbacks: fallbacks,
                cancellationToken: cancellation
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func buildAsynchronousResult(
        meta: AppMetadata,
        validatedIdentity: ValidatedIdentity?,
        fallbacks: UninstallDiscoveryFallbacks,
        cancellationToken: FSSnapshotCancellationToken
    ) async -> UninstallCandidateDiscoveryResult {
        if Task.isCancelled {
            return cancellationResult(path: validatedIdentity?.bundlePath)
        }

        // Directory reads and pkgutil are synchronous I/O. Keep them off the cooperative executor;
        // candidate snapshots below use the same bounded Dispatch-backed ownership model.
        var discovery = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: primaryAndVendorProposals(
                    for: meta,
                    cancellationToken: cancellationToken
                ))
            }
        }
        if Task.isCancelled { return cancellationResult(path: validatedIdentity?.bundlePath) }

        if fallbacks.contains(.spotlight) {
            let spotlightDiscovery = await spotlightProposals(meta: meta)
            discovery.proposals.append(contentsOf: spotlightDiscovery.proposals)
            discovery.issues.append(contentsOf: spotlightDiscovery.issues)
        }
        if Task.isCancelled { return cancellationResult(path: validatedIdentity?.bundlePath) }

        if fallbacks.contains(.pkgReceipts), pkgutilScanner != nil {
            if let validatedIdentity {
                let pkgDiscovery = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(returning: pkgReceiptProposals(
                            for: meta,
                            selectedBundlePath: validatedIdentity.bundlePath
                        ))
                    }
                }
                discovery.proposals.append(contentsOf: pkgDiscovery.proposals)
                discovery.issues.append(contentsOf: pkgDiscovery.issues)
                discovery.pkgIssues.append(contentsOf: pkgDiscovery.pkgIssues)
            } else {
                discovery.issues.append(UninstallDiscoveryIssue(
                    source: .selectedAppIdentity,
                    stage: .identityValidation,
                    reason: .identityUnavailable
                ))
            }
        }
        if Task.isCancelled { return cancellationResult(path: validatedIdentity?.bundlePath) }

        let resolved = Self.resolveOverlaps(
            discovery.proposals,
            excludingBundlePath: validatedIdentity?.bundlePath
        )
        let snapshotted = await snapshotAsynchronously(
            resolved,
            cancellationToken: cancellationToken
        )
        if Task.isCancelled { return cancellationResult(path: validatedIdentity?.bundlePath) }
        discovery.issues.append(contentsOf: snapshotted.issues)
        return UninstallCandidateDiscoveryResult(
            candidates: snapshotted.candidates,
            incompleteIssues: discovery.issues,
            pkgReceiptIncompleteIssues: discovery.pkgIssues
        )
    }

    private func spotlightProposals(meta: AppMetadata) async -> ProposalCollection {
        var collection = ProposalCollection()
        let bundleEvidence = await spotlight.probeByBundleIDEvidence(
            meta.bundleID,
            timeout: spotlightTimeout
        )
        collection.proposals.append(contentsOf: spotlightCandidateProposals(
            paths: bundleEvidence.paths,
            reason: .spotlight("bundleID")
        ))
        if let failure = bundleEvidence.failure {
            collection.issues.append(Self.spotlightIssue(
                source: .spotlightBundleID,
                failure: failure
            ))
        }
        guard !Task.isCancelled else { return collection }

        let trimmed = meta.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonNoise: Set<String> = ["app", "data", "test", "demo", "temp", "main", "user"]
        guard trimmed.count >= 4, !commonNoise.contains(trimmed.lowercased()) else {
            return collection
        }
        let nameEvidence = await spotlight.probeByAppNameEvidence(
            trimmed,
            timeout: spotlightTimeout
        )
        collection.proposals.append(contentsOf: spotlightCandidateProposals(
            paths: nameEvidence.paths,
            reason: .spotlight("appName")
        ))
        if let failure = nameEvidence.failure {
            collection.issues.append(Self.spotlightIssue(
                source: .spotlightAppName,
                failure: failure
            ))
        }
        return collection
    }

    private func spotlightCandidateProposals(
        paths: [String],
        reason: MatchReason
    ) -> [CandidateProposal] {
        paths.compactMap { rawPath in
            guard let path = Self.canonicalCandidatePath(rawPath),
                  Self.isSameOrDescendant(path, of: homeDirectory) ||
                    Self.isSameOrDescendant(path, of: systemLibrary) else { return nil }
            return CandidateProposal(
                path: path,
                reason: reason,
                source: .spotlight,
                evidenceStrength: Self.evidenceStrength(for: reason)
            )
        }
    }

    private static func spotlightIssue(
        source: UninstallDiscoveryIssue.Source,
        failure: SpotlightProbeFailure
    ) -> UninstallDiscoveryIssue {
        switch failure {
        case .startFailed:
            return UninstallDiscoveryIssue(
                source: source,
                stage: .queryStart,
                reason: .queryStartFailed
            )
        case .timedOut:
            return UninstallDiscoveryIssue(
                source: source,
                stage: .queryGathering,
                reason: .timedOut
            )
        case .resultCountLimitExceeded(let limit):
            return UninstallDiscoveryIssue(
                source: source,
                stage: .queryGathering,
                reason: .resultCountLimitExceeded(limit: limit)
            )
        case .extractionTimeLimitExceeded(let limitMilliseconds):
            return UninstallDiscoveryIssue(
                source: source,
                stage: .queryGathering,
                reason: .extractionTimeLimitExceeded(
                    limitMilliseconds: limitMilliseconds
                )
            )
        case .cancelled:
            return UninstallDiscoveryIssue(
                source: source,
                stage: .cancellation,
                reason: .cancelled
            )
        }
    }

    private func snapshotAsynchronously(
        _ proposals: [CandidateProposal],
        cancellationToken cancellation: FSSnapshotCancellationToken
    ) async -> (candidates: [UninstallCandidate], issues: [UninstallDiscoveryIssue]) {
        let fileManager = self.fileManager
        let outcomes = await withTaskCancellationHandler {
            await withTaskGroup(of: SnapshottedProposal?.self) { group in
                var iterator = proposals.makeIterator()
                var inFlight = 0
                var collected: [SnapshottedProposal] = []

                func enqueue(_ proposal: CandidateProposal) {
                    inFlight += 1
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled, !cancellation.isCancelled else { return nil }
                        let snapshot = await withCheckedContinuation { continuation in
                            DispatchQueue.global(qos: .utility).async {
                                let snapshot: FSSnapshot
                                if let entry = proposal.firstLevelEntry {
                                    snapshot = fileManager.snapshot(
                                        entry: entry,
                                        cancellationToken: cancellation
                                    )
                                } else {
                                    snapshot = fileManager.snapshot(
                                        at: proposal.path,
                                        cancellationToken: cancellation
                                    )
                                }
                                continuation.resume(returning: snapshot)
                            }
                        }
                        return SnapshottedProposal(proposal: proposal, snapshot: snapshot)
                    }
                }

                while inFlight < 8, let proposal = iterator.next() { enqueue(proposal) }
                while let outcome = await group.next() {
                    inFlight -= 1
                    if let outcome { collected.append(outcome) }
                    if Task.isCancelled || cancellation.isCancelled {
                        group.cancelAll()
                    } else if let proposal = iterator.next() {
                        enqueue(proposal)
                    }
                }
                return collected
            }
        } onCancel: {
            cancellation.cancel()
        }

        var candidates: [UninstallCandidate] = []
        var issues: [UninstallDiscoveryIssue] = []
        for outcome in outcomes {
            issues.append(contentsOf: Self.discoveryIssues(
                for: outcome.snapshot,
                proposal: outcome.proposal
            ))
            guard outcome.snapshot.exists, outcome.snapshot.completion != .cancelled else { continue }
            candidates.append(UninstallCandidate(
                path: outcome.proposal.path,
                snapshot: outcome.snapshot,
                matchReason: outcome.proposal.reason
            ))
        }
        candidates.sort { $0.path < $1.path }
        return (candidates, issues)
    }

    private func cancellationResult(path: String?) -> UninstallCandidateDiscoveryResult {
        UninstallCandidateDiscoveryResult(
            candidates: [],
            incompleteIssues: [UninstallDiscoveryIssue(
                source: .primaryRoot,
                stage: .cancellation,
                path: path,
                reason: .cancelled
            )]
        )
    }
}

// MARK: - 文件系统抽象

/// 第一层目录读取的终态。`missing` 是正常的零结果；它必须与权限/枚举失败分开，
/// 否则 12 个根中任一受 TCC/POSIX 拒绝都会被错误宣布为 complete。
public enum FSFirstLevelDiscoveryResult: Sendable, Equatable {
    case entries([FSEntry])
    case missing
    case incomplete(stage: FSSnapshotIssueStage, reason: FSSnapshotIssueReason)
}

/// 抽象层 —— 让测试不依赖真实磁盘的 size 结果。
public protocol FileManagerSnapshotting: Sendable {
    func firstLevelEntries(at path: String) -> [FSEntry]?
    func firstLevelDiscovery(at path: String) -> FSFirstLevelDiscoveryResult
    func firstLevelDiscovery(
        at path: String,
        maximumEntries: Int,
        deadlineUptimeNanoseconds: UInt64,
        timeLimitMilliseconds: Int64,
        cancellationToken: FSSnapshotCancellationToken
    ) -> FSFirstLevelDiscoveryResult
    func snapshot(at path: String) -> FSSnapshot
    func snapshot(at path: String, cancellationToken: FSSnapshotCancellationToken) -> FSSnapshot
    /// Snapshot a first-level entry through the root/child identities frozen by discovery. The
    /// production implementation reopens the root no-follow and traverses the child descriptor;
    /// compatibility fakes may use the pathname fallback below.
    func snapshot(entry: FSEntry, cancellationToken: FSSnapshotCancellationToken) -> FSSnapshot
}

public extension FileManagerSnapshotting {
    /// Legacy/in-memory fixtures historically used nil for an absent root. Production overrides
    /// this method and preserves permission/enumeration errors; the compatibility default keeps
    /// existing deterministic fixtures from having to manufacture NSError values.
    func firstLevelDiscovery(at path: String) -> FSFirstLevelDiscoveryResult {
        if let entries = firstLevelEntries(at: path) { return .entries(entries) }
        return .missing
    }

    func firstLevelDiscovery(
        at path: String,
        maximumEntries: Int,
        deadlineUptimeNanoseconds: UInt64,
        timeLimitMilliseconds: Int64,
        cancellationToken: FSSnapshotCancellationToken
    ) -> FSFirstLevelDiscoveryResult {
        guard !cancellationToken.isCancelled else {
            return .incomplete(stage: .cancellation, reason: .cancelled)
        }
        guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
            return .incomplete(
                stage: .budget,
                reason: .timeBudgetExceeded(limitMilliseconds: timeLimitMilliseconds)
            )
        }
        let result = firstLevelDiscovery(at: path)
        guard case .entries(let entries) = result else { return result }
        guard entries.count <= maximumEntries else {
            return .incomplete(
                stage: .budget,
                reason: .fileBudgetExceeded(limit: maximumEntries)
            )
        }
        return cancellationToken.isCancelled
            ? .incomplete(stage: .cancellation, reason: .cancelled)
            : result
    }

    func snapshot(at path: String, cancellationToken: FSSnapshotCancellationToken) -> FSSnapshot {
        guard !cancellationToken.isCancelled else {
            return FSSnapshot(
                bytes: 0,
                fileCount: 0,
                exists: false,
                isDirectory: false,
                completion: .cancelled,
                issues: [.init(path: path, reason: .cancelled, stage: .cancellation)]
            )
        }
        return snapshot(at: path)
    }

    func snapshot(entry: FSEntry, cancellationToken: FSSnapshotCancellationToken) -> FSSnapshot {
        snapshot(at: entry.path, cancellationToken: cancellationToken)
    }
}

/// 同步 FileManager traversal 无法 `await` actor；一个扫描轮共享此锁保护 token，
/// 让 parent Task 的 onCancel 能在不等待 syscall/task-group 回收的情况下发出停止信号。
public final class FSSnapshotCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

public struct FSObjectIdentity: Hashable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64

    public init(deviceID: UInt64, inode: UInt64) {
        self.deviceID = deviceID
        self.inode = inode
    }

    init(metadata: stat) {
        self.init(
            deviceID: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino)
        )
    }
}

public struct FSFirstLevelEntryProof: Hashable, Sendable {
    public let rootPath: String
    public let rootIdentity: FSObjectIdentity
    public let entryName: String
    public let entryIdentity: FSObjectIdentity

    public init(
        rootPath: String,
        rootIdentity: FSObjectIdentity,
        entryName: String,
        entryIdentity: FSObjectIdentity
    ) {
        self.rootPath = rootPath
        self.rootIdentity = rootIdentity
        self.entryName = entryName
        self.entryIdentity = entryIdentity
    }
}

public struct FSEntry: Hashable, Sendable {
    public let name: String
    public let path: String
    public let identityProof: FSFirstLevelEntryProof?

    public init(
        name: String,
        path: String,
        identityProof: FSFirstLevelEntryProof? = nil
    ) {
        self.name = name
        self.path = path
        self.identityProof = identityProof
    }
}

/// v2026.07.17：容量值与“是否看全”是两条独立事实。partial/cancelled 的 bytes
/// 只能作为已观察下界，不能沿删除链路冒充完整快照。
public enum FSSnapshotCompletionStatus: String, Hashable, Sendable {
    case complete
    case partial
    case cancelled
}

public enum FSSnapshotIssueStage: String, Hashable, Sendable {
    case rootMetadata
    case enumeration
    case entryMetadata
    case budget
    case cancellation
}

/// FileManager snapshot 自身的完整性原因。预算与取消不是底层 ScanKit 的文件系统
/// 错误，因此在这里保持独立类型；进入删除边界时再映射为统一 access evidence。
public enum FSSnapshotIssueReason: Hashable, Sendable {
    case fileBudgetExceeded(limit: Int)
    case timeBudgetExceeded(limitMilliseconds: Int64)
    case permissionDenied
    case enumerationFailed
    case metadataUnavailable
    case cancelled
    /// 防止异常文件系统用海量逐项错误反过来耗尽内存；此项本身仍令快照保持 partial。
    case issueCollectionLimitExceeded(limit: Int)
}

public struct FSSnapshotIssue: Hashable, Sendable {
    public let path: String
    public let reason: FSSnapshotIssueReason
    public let stage: FSSnapshotIssueStage
    public let posixErrorCode: Int32?

    public init(
        path: String,
        reason: FSSnapshotIssueReason,
        stage: FSSnapshotIssueStage,
        posixErrorCode: Int32? = nil
    ) {
        self.path = path
        self.reason = reason
        self.stage = stage
        self.posixErrorCode = posixErrorCode
    }
}

public struct FSSnapshot: Hashable, Sendable {
    /// on-disk allocated bytes；所有清理/占用主值统一消费这一字段。
    public let bytes: Int64
    /// 文件逻辑长度之和；仅供 Finder 式详情或诊断展示。
    public let logicalBytes: Int64
    public let fileCount: Int
    public let exists: Bool
    public let isDirectory: Bool
    /// v2026.07.18: no-follow identity of the exact root object whose bytes were measured.
    /// A complete uninstall snapshot without this proof is display-only and cannot authorize trash.
    public let objectIdentity: TrashObjectIdentity?
    public let completion: FSSnapshotCompletionStatus
    public let issues: [FSSnapshotIssue]

    public init(
        bytes: Int64,
        logicalBytes: Int64? = nil,
        fileCount: Int,
        exists: Bool? = nil,
        isDirectory: Bool = false,
        objectIdentity: TrashObjectIdentity? = nil,
        completion: FSSnapshotCompletionStatus = .complete,
        issues: [FSSnapshotIssue] = []
    ) {
        self.bytes = max(0, bytes)
        self.logicalBytes = max(0, logicalBytes ?? bytes)
        self.fileCount = max(0, fileCount)
        // 旧 fake snapshots 没有 exists 字段；非零值表示它们原本表达“存在”。
        // 真实实现始终显式传值，所以空目录也不会被误判为不存在。
        self.exists = exists ?? (bytes > 0 || fileCount > 0)
        self.isDirectory = isDirectory
        self.objectIdentity = objectIdentity
        // 有 issue 的“complete”是自相矛盾状态，初始化边界直接收敛成 partial。
        self.completion = completion == .complete && !issues.isEmpty ? .partial : completion
        self.issues = issues
    }
}

/// v2026.07.17 live-hardlink accounting ledger shared by App Footprint and Uninstaller
/// snapshots. Ordinary single-link files are counted without being retained, while identities
/// first observed with multiple links remain remembered even if their `st_nlink` later drops
/// during the same live enumeration. This prevents a second pathname from being counted again
/// after another link is concurrently removed, without restoring O(all files) resident memory.
/// The opposite race (a new hardlink created only after a single-link file was already counted)
/// cannot be correlated without a real filesystem snapshot or retaining every inode.
struct FSSnapshotHardlinkLedger {
    private struct Identity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private var retainedIdentities: Set<Identity> = []

    mutating func shouldCount(
        device: UInt64,
        inode: UInt64,
        linkCount: UInt64
    ) -> Bool {
        // An unknown inode is not a stable identity; conservatively count each observation.
        guard inode != 0 else { return true }
        let identity = Identity(device: device, inode: inode)
        guard !retainedIdentities.contains(identity) else { return false }
        if linkCount > 1 {
            retainedIdentities.insert(identity)
        }
        return true
    }

    var retainedIdentityCount: Int { retainedIdentities.count }
}

/// 真实磁盘实现。第一层用 `contentsOfDirectory`，size 递归到子树，但受文件数/时长预算、
/// cooperative cancellation 与 typed completeness 约束。
///
/// **Step 14**：原 `try?` 全部改 do/catch + [IOErrorClassifier](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LogKit/Sources/LogKit/IOErrorClassifier.swift) 分类：
/// - `.permissionDenied` → 调用 `permissionDeniedHandler`（默认 nil）+ GSYLog.debug
/// - `.notFound` → GSYLog.debug 静默
/// - `.other` → GSYLog.warning 落盘
public struct DefaultFileManagerSnapshot: FileManagerSnapshotting {
    /// EACCES 时被调用一次的 handler（默认 nil = 不上报，保留旧静默语义）。
    public let permissionDeniedHandler: (@Sendable (String) -> Void)?
    /// 单个目录最多统计的文件数。nil 表示完整递归。
    public let maxDescendantFiles: Int?
    /// 单个目录最多统计时长。nil 表示不按时间截断。
    public let maxSnapshotDuration: TimeInterval?
    /// 生产默认读取当前 Task 的 cooperative cancellation；注入点让 fixture 能确定性
    /// 验证“逐项停止”，无需靠创建几十万个文件制造竞态。
    private let isCancellationRequested: @Sendable () -> Bool

    private static let maxReportedIssues = 256

    public init(
        permissionDeniedHandler: (@Sendable (String) -> Void)? = nil,
        maxDescendantFiles: Int? = nil,
        maxSnapshotDuration: TimeInterval? = nil,
        isCancellationRequested: @escaping @Sendable () -> Bool = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) {
        self.permissionDeniedHandler = permissionDeniedHandler
        self.maxDescendantFiles = maxDescendantFiles
        // v2026.07.17 bounded-scan input contract: `TimeInterval` also admits NaN and
        // infinities. A NaN comparison is always false, so the old code silently converted a
        // requested time budget into an unbounded traversal. Invalid/non-positive values now
        // expire at the first enumeration boundary; +infinity intentionally keeps the existing
        // "no practical deadline" behavior. This is policy normalization, not a fallback result.
        self.maxSnapshotDuration = Self.normalizedSnapshotDuration(maxSnapshotDuration)
        self.isCancellationRequested = isCancellationRequested
    }

    static func normalizedSnapshotDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration else { return nil }
        guard !duration.isNaN, duration > 0 else { return 0 }
        return duration
    }

    public func firstLevelEntries(at path: String) -> [FSEntry]? {
        guard case .entries(let entries) = firstLevelDiscovery(at: path) else { return nil }
        return entries
    }

    public func firstLevelDiscovery(at path: String) -> FSFirstLevelDiscoveryResult {
        firstLevelDiscovery(
            at: path,
            maximumEntries: .max,
            deadlineUptimeNanoseconds: .max,
            timeLimitMilliseconds: .max,
            cancellationToken: FSSnapshotCancellationToken()
        )
    }

    public func firstLevelDiscovery(
        at path: String,
        maximumEntries: Int,
        deadlineUptimeNanoseconds: UInt64,
        timeLimitMilliseconds: Int64,
        cancellationToken: FSSnapshotCancellationToken
    ) -> FSFirstLevelDiscoveryResult {
        guard !cancellationToken.isCancelled else {
            return .incomplete(stage: .cancellation, reason: .cancelled)
        }
        guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
            return .incomplete(
                stage: .budget,
                reason: .timeBudgetExceeded(limitMilliseconds: timeLimitMilliseconds)
            )
        }
        var pathMetadata = stat()
        guard lstat(path, &pathMetadata) == 0 else {
            let code = errno
            handle(
                error: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
                path: path,
                op: "firstLevelMetadata"
            )
            switch code {
            case ENOENT: return .missing
            case EACCES, EPERM:
                return .incomplete(stage: .rootMetadata, reason: .permissionDenied)
            default:
                return .incomplete(stage: .rootMetadata, reason: .metadataUnavailable)
            }
        }
        guard (pathMetadata.st_mode & S_IFMT) == S_IFDIR else {
            return .incomplete(stage: .enumeration, reason: .enumerationFailed)
        }

        // v2026.07.18 root-cause fix: lstat + contentsOfDirectory(path) was two unrelated
        // pathname operations. A rename-to-symlink between them enumerated a different tree while
        // still manufacturing candidate paths under the trusted root. Freeze one no-follow fd and
        // derive every child identity with fstatat on that descriptor.
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            handle(
                error: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
                path: path,
                op: "firstLevelOpen"
            )
            if code == ENOENT || code == ENOTDIR { return .missing }
            return .incomplete(
                stage: .rootMetadata,
                reason: code == EACCES || code == EPERM ? .permissionDenied : .metadataUnavailable
            )
        }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFDIR,
              FSObjectIdentity(metadata: openedMetadata) == FSObjectIdentity(metadata: pathMetadata)
        else {
            close(descriptor)
            return .incomplete(stage: .rootMetadata, reason: .metadataUnavailable)
        }
        let rootIdentity = FSObjectIdentity(metadata: openedMetadata)
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            handle(
                error: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
                path: path,
                op: "firstLevelFdopendir"
            )
            return .incomplete(
                stage: .enumeration,
                reason: code == EACCES || code == EPERM ? .permissionDenied : .enumerationFailed
            )
        }
        defer { closedir(directory) }
        let directoryDescriptor = dirfd(directory)
        guard directoryDescriptor >= 0 else {
            return .incomplete(stage: .enumeration, reason: .enumerationFailed)
        }

        var entries: [FSEntry] = []
        while true {
            if cancellationToken.isCancelled || isCancellationRequested() {
                return .incomplete(stage: .cancellation, reason: .cancelled)
            }
            if DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds {
                return .incomplete(
                    stage: .budget,
                    reason: .timeBudgetExceeded(limitMilliseconds: timeLimitMilliseconds)
                )
            }
            errno = 0
            guard let rawEntry = readdir(directory) else {
                if errno != 0 {
                    let code = errno
                    handle(
                        error: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
                        path: path,
                        op: "firstLevelReaddir"
                    )
                    return .incomplete(
                        stage: .enumeration,
                        reason: code == EACCES || code == EPERM
                            ? .permissionDenied
                            : .enumerationFailed
                    )
                }
                break
            }
            var nameStorage = rawEntry.pointee.d_name
            let nameLength = Int(rawEntry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &nameStorage) { bytes in
                String(decoding: bytes.prefix(nameLength), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            guard entries.count < maximumEntries else {
                return .incomplete(
                    stage: .budget,
                    reason: .fileBudgetExceeded(limit: maximumEntries)
                )
            }

            var childMetadata = stat()
            let metadataResult = name.withCString { namePointer in
                fstatat(directoryDescriptor, namePointer, &childMetadata, AT_SYMLINK_NOFOLLOW)
            }
            guard metadataResult == 0 else {
                let code = errno
                handle(
                    error: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
                    path: (path as NSString).appendingPathComponent(name),
                    op: "firstLevelEntryMetadata"
                )
                return .incomplete(
                    stage: .entryMetadata,
                    reason: code == EACCES || code == EPERM ? .permissionDenied : .metadataUnavailable
                )
            }
            let childPath = (path as NSString).appendingPathComponent(name)
            entries.append(FSEntry(
                name: name,
                path: childPath,
                identityProof: FSFirstLevelEntryProof(
                    rootPath: path,
                    rootIdentity: rootIdentity,
                    entryName: name,
                    entryIdentity: FSObjectIdentity(metadata: childMetadata)
                )
            ))
        }

        guard Self.directoryIdentityNoFollow(at: path) == rootIdentity else {
            return .incomplete(stage: .rootMetadata, reason: .metadataUnavailable)
        }
        return .entries(entries)
    }

    public func snapshot(at path: String) -> FSSnapshot {
        snapshot(at: path, cancellationToken: nil)
    }

    public func snapshot(
        entry: FSEntry,
        cancellationToken: FSSnapshotCancellationToken
    ) -> FSSnapshot {
        guard let proof = entry.identityProof else {
            return snapshot(at: entry.path, cancellationToken: cancellationToken)
        }
        guard !cancellationToken.isCancelled else {
            return cancelledSnapshot(path: entry.path, exists: false, isDirectory: false)
        }

        let rootDescriptor = open(
            proof.rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            return identityUnavailableSnapshot(path: entry.path, posixErrorCode: errno)
        }
        defer { close(rootDescriptor) }
        var rootMetadata = stat()
        guard fstat(rootDescriptor, &rootMetadata) == 0,
              (rootMetadata.st_mode & S_IFMT) == S_IFDIR,
              FSObjectIdentity(metadata: rootMetadata) == proof.rootIdentity else {
            return identityUnavailableSnapshot(path: entry.path)
        }

        var childMetadata = stat()
        let childMetadataResult = proof.entryName.withCString { namePointer in
            fstatat(rootDescriptor, namePointer, &childMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard childMetadataResult == 0,
              FSObjectIdentity(metadata: childMetadata) == proof.entryIdentity else {
            return identityUnavailableSnapshot(
                path: entry.path,
                posixErrorCode: childMetadataResult == 0 ? nil : errno
            )
        }

        let result: FSSnapshot
        if (childMetadata.st_mode & S_IFMT) == S_IFDIR {
            let childDescriptor = proof.entryName.withCString { namePointer in
                openat(
                    rootDescriptor,
                    namePointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard childDescriptor >= 0 else {
                return identityUnavailableSnapshot(path: entry.path, posixErrorCode: errno)
            }
            defer { close(childDescriptor) }
            var openedChildMetadata = stat()
            guard fstat(childDescriptor, &openedChildMetadata) == 0,
                  FSObjectIdentity(metadata: openedChildMetadata) == proof.entryIdentity else {
                return identityUnavailableSnapshot(path: entry.path)
            }
            result = snapshotOpenedDirectory(
                descriptor: childDescriptor,
                displayPath: entry.path,
                objectIdentity: TrashObjectIdentity(metadata: openedChildMetadata),
                cancellationToken: cancellationToken
            )
        } else {
            result = FSSnapshot(
                bytes: max(0, Int64(childMetadata.st_blocks) * 512),
                logicalBytes: max(0, Int64(childMetadata.st_size)),
                fileCount: 1,
                exists: true,
                isDirectory: false,
                objectIdentity: TrashObjectIdentity(metadata: childMetadata)
            )
        }

        // The descriptors freeze the measured objects. These terminal pathname checks additionally
        // prove the UI path still names those objects after traversal, closing persistent queued-root
        // and child replacement races without ever traversing the replacement tree.
        var finalChildMetadata = stat()
        let finalChildResult = proof.entryName.withCString { namePointer in
            fstatat(rootDescriptor, namePointer, &finalChildMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard Self.directoryIdentityNoFollow(at: proof.rootPath) == proof.rootIdentity,
              finalChildResult == 0,
              FSObjectIdentity(metadata: finalChildMetadata) == proof.entryIdentity,
              let measuredIdentity = result.objectIdentity,
              measuredIdentity.matches(TrashObjectIdentity(metadata: finalChildMetadata)) else {
            return addingIdentityIssue(to: result, path: entry.path)
        }
        return result
    }

    public func snapshot(
        at path: String,
        cancellationToken: FSSnapshotCancellationToken
    ) -> FSSnapshot {
        snapshot(at: path, cancellationToken: Optional(cancellationToken))
    }

    private static func directoryIdentityNoFollow(at path: String) -> FSObjectIdentity? {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FSObjectIdentity(metadata: metadata)
    }

    private func identityUnavailableSnapshot(
        path: String,
        posixErrorCode: Int32? = nil
    ) -> FSSnapshot {
        let reason: FSSnapshotIssueReason = switch posixErrorCode {
        case EACCES, EPERM: .permissionDenied
        default: .metadataUnavailable
        }
        return FSSnapshot(
            bytes: 0,
            fileCount: 0,
            exists: false,
            isDirectory: false,
            completion: .partial,
            issues: [.init(
                path: path,
                reason: reason,
                stage: .rootMetadata,
                posixErrorCode: posixErrorCode
            )]
        )
    }

    private func addingIdentityIssue(to snapshot: FSSnapshot, path: String) -> FSSnapshot {
        var issues = snapshot.issues
        let issue = FSSnapshotIssue(
            path: path,
            reason: .metadataUnavailable,
            stage: .rootMetadata
        )
        if !issues.contains(issue) { issues.append(issue) }
        return FSSnapshot(
            bytes: snapshot.bytes,
            logicalBytes: snapshot.logicalBytes,
            fileCount: snapshot.fileCount,
            exists: snapshot.exists,
            isDirectory: snapshot.isDirectory,
            objectIdentity: snapshot.objectIdentity,
            completion: snapshot.completion == .cancelled ? .cancelled : .partial,
            issues: issues
        )
    }

    /// Descriptor-relative recursive size traversal for a primary-root child. Nested symlinks are
    /// observed but never followed; every directory is opened with openat(O_NOFOLLOW), so a queued
    /// pathname replacement cannot redirect I/O beyond the frozen candidate object.
    private func snapshotOpenedDirectory(
        descriptor: Int32,
        displayPath: String,
        objectIdentity: TrashObjectIdentity,
        cancellationToken: FSSnapshotCancellationToken
    ) -> FSSnapshot {
        var totalBytes: Int64 = 0
        var totalLogicalBytes: Int64 = 0
        var totalFiles = 0
        var issues: [FSSnapshotIssue] = []
        var issueLimitWasRecorded = false
        var hardlinks = FSSnapshotHardlinkLedger()
        let startedAt = Date()
        var terminalCompletion: FSSnapshotCompletionStatus = .complete

        func record(_ issue: FSSnapshotIssue) {
            guard !issues.contains(issue) else { return }
            if issues.count < Self.maxReportedIssues {
                issues.append(issue)
            } else if !issueLimitWasRecorded {
                issueLimitWasRecorded = true
                issues.append(.init(
                    path: displayPath,
                    reason: .issueCollectionLimitExceeded(limit: Self.maxReportedIssues),
                    stage: .enumeration
                ))
            }
        }

        func shouldStop() -> Bool {
            if cancellationToken.isCancelled || isCancellationRequested() {
                terminalCompletion = .cancelled
                record(.init(path: displayPath, reason: .cancelled, stage: .cancellation))
                return true
            }
            if let maxDescendantFiles, totalFiles >= maxDescendantFiles {
                terminalCompletion = .partial
                record(.init(
                    path: displayPath,
                    reason: .fileBudgetExceeded(limit: maxDescendantFiles),
                    stage: .budget
                ))
                return true
            }
            if let maxSnapshotDuration,
               Date().timeIntervalSince(startedAt) >= maxSnapshotDuration {
                terminalCompletion = .partial
                record(.init(
                    path: displayPath,
                    reason: .timeBudgetExceeded(
                        limitMilliseconds: Self.millisecondsClamped(maxSnapshotDuration)
                    ),
                    stage: .budget
                ))
                return true
            }
            return false
        }

        func walk(directoryDescriptor: Int32, path: String) -> Bool {
            let ownedDescriptor = dup(directoryDescriptor)
            guard ownedDescriptor >= 0 else {
                terminalCompletion = .partial
                record(snapshotIssue(
                    posixErrorCode: errno,
                    path: path,
                    stage: .enumeration,
                    defaultReason: .enumerationFailed,
                    op: "anchoredDup"
                ))
                return true
            }
            guard let directory = fdopendir(ownedDescriptor) else {
                let code = errno
                close(ownedDescriptor)
                terminalCompletion = .partial
                record(snapshotIssue(
                    posixErrorCode: code,
                    path: path,
                    stage: .enumeration,
                    defaultReason: .enumerationFailed,
                    op: "anchoredFdopendir"
                ))
                return true
            }
            defer { closedir(directory) }
            let currentDescriptor = dirfd(directory)
            guard currentDescriptor >= 0 else {
                terminalCompletion = .partial
                record(.init(path: path, reason: .enumerationFailed, stage: .enumeration))
                return true
            }

            while true {
                if shouldStop() { return false }
                errno = 0
                guard let rawEntry = readdir(directory) else {
                    if errno != 0 {
                        terminalCompletion = .partial
                        record(snapshotIssue(
                            posixErrorCode: errno,
                            path: path,
                            stage: .enumeration,
                            defaultReason: .enumerationFailed,
                            op: "anchoredReaddir"
                        ))
                    }
                    return true
                }
                var nameStorage = rawEntry.pointee.d_name
                let nameLength = Int(rawEntry.pointee.d_namlen)
                let name = withUnsafeBytes(of: &nameStorage) { bytes in
                    String(decoding: bytes.prefix(nameLength), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                let childPath = (path as NSString).appendingPathComponent(name)
                var metadata = stat()
                let metadataResult = name.withCString { namePointer in
                    fstatat(currentDescriptor, namePointer, &metadata, AT_SYMLINK_NOFOLLOW)
                }
                guard metadataResult == 0 else {
                    terminalCompletion = .partial
                    record(snapshotIssue(
                        posixErrorCode: errno,
                        path: childPath,
                        stage: .entryMetadata,
                        defaultReason: .metadataUnavailable,
                        op: "anchoredEntryMetadata"
                    ))
                    continue
                }

                switch metadata.st_mode & S_IFMT {
                case S_IFREG:
                    totalFiles += 1
                    if hardlinks.shouldCount(
                        device: UInt64(truncatingIfNeeded: metadata.st_dev),
                        inode: UInt64(truncatingIfNeeded: metadata.st_ino),
                        linkCount: UInt64(truncatingIfNeeded: metadata.st_nlink)
                    ) {
                        totalBytes = Self.saturatedAdd(
                            totalBytes,
                            max(0, Int64(metadata.st_blocks) * 512)
                        )
                        totalLogicalBytes = Self.saturatedAdd(
                            totalLogicalBytes,
                            max(0, Int64(metadata.st_size))
                        )
                    }
                case S_IFDIR:
                    let childDescriptor = name.withCString { namePointer in
                        openat(
                            currentDescriptor,
                            namePointer,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard childDescriptor >= 0 else {
                        terminalCompletion = .partial
                        record(snapshotIssue(
                            posixErrorCode: errno,
                            path: childPath,
                            stage: .enumeration,
                            defaultReason: .enumerationFailed,
                            op: "anchoredOpenDirectory"
                        ))
                        continue
                    }
                    let completed = walk(directoryDescriptor: childDescriptor, path: childPath)
                    close(childDescriptor)
                    if !completed { return false }
                default:
                    // Symlinks and special files are never followed or counted as payload bytes.
                    continue
                }
            }
        }

        _ = walk(directoryDescriptor: descriptor, path: displayPath)
        if terminalCompletion == .complete, !issues.isEmpty { terminalCompletion = .partial }
        return FSSnapshot(
            bytes: totalBytes,
            logicalBytes: totalLogicalBytes,
            fileCount: totalFiles,
            exists: true,
            isDirectory: true,
            objectIdentity: objectIdentity,
            completion: terminalCompletion,
            issues: issues
        )
    }

    private func snapshot(
        at path: String,
        cancellationToken: FSSnapshotCancellationToken?
    ) -> FSSnapshot {
        func cancellationWasRequested() -> Bool {
            isCancellationRequested() || cancellationToken?.isCancelled == true
        }

        if cancellationWasRequested() {
            return cancelledSnapshot(path: path, exists: false, isDirectory: false)
        }

        var rootMetadata = stat()
        guard lstat(path, &rootMetadata) == 0 else {
            let code = errno
            // v2026.07.18: a speculative vendor/Spotlight proposal that is confirmed absent is a
            // complete zero-result, not an enumeration gap. Conflating ENOENT with metadata failure
            // caused one clean, nonexistent vendor path to disable every real uninstall candidate.
            if code == ENOENT {
                return .init(
                    bytes: 0,
                    fileCount: 0,
                    exists: false,
                    isDirectory: false,
                    completion: .complete,
                    issues: []
                )
            }
            let issue = snapshotIssue(
                posixErrorCode: code,
                path: path,
                stage: .rootMetadata,
                defaultReason: .metadataUnavailable,
                op: "rootMetadata"
            )
            return .init(
                bytes: 0,
                fileCount: 0,
                exists: false,
                isDirectory: false,
                completion: .partial,
                issues: [issue]
            )
        }

        let expectedIdentity = TrashObjectIdentity(metadata: rootMetadata)
        switch rootMetadata.st_mode & S_IFMT {
        case S_IFDIR:
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                return identityUnavailableSnapshot(path: path, posixErrorCode: errno)
            }
            defer { close(descriptor) }
            var openedMetadata = stat()
            guard fstat(descriptor, &openedMetadata) == 0,
                  expectedIdentity.matches(TrashObjectIdentity(metadata: openedMetadata)) else {
                return identityUnavailableSnapshot(path: path)
            }
            let measured = snapshotOpenedDirectory(
                descriptor: descriptor,
                displayPath: path,
                objectIdentity: expectedIdentity,
                cancellationToken: cancellationToken ?? FSSnapshotCancellationToken()
            )
            guard case .present(let terminalIdentity) = TrashObjectIdentity.probe(path: path),
                  expectedIdentity.matches(terminalIdentity) else {
                return addingIdentityIssue(to: measured, path: path)
            }
            return measured

        case S_IFREG:
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                return identityUnavailableSnapshot(path: path, posixErrorCode: errno)
            }
            defer { close(descriptor) }
            var openedMetadata = stat()
            guard fstat(descriptor, &openedMetadata) == 0,
                  expectedIdentity.matches(TrashObjectIdentity(metadata: openedMetadata)),
                  case .present(let terminalIdentity) = TrashObjectIdentity.probe(path: path),
                  expectedIdentity.matches(terminalIdentity) else {
                return identityUnavailableSnapshot(path: path)
            }
            return .init(
                bytes: max(0, Int64(openedMetadata.st_blocks) * 512),
                logicalBytes: max(0, Int64(openedMetadata.st_size)),
                fileCount: 1,
                exists: true,
                isDirectory: false,
                objectIdentity: expectedIdentity
            )

        default:
            // Special files and symlinks remain visible evidence but never become a stable
            // uninstall deletion capability (`hasStableDeletionIdentity` accepts REG/DIR only).
            guard case .present(let terminalIdentity) = TrashObjectIdentity.probe(path: path),
                  expectedIdentity.matches(terminalIdentity) else {
                return identityUnavailableSnapshot(path: path)
            }
            return .init(
                bytes: max(0, Int64(rootMetadata.st_blocks) * 512),
                logicalBytes: max(0, Int64(rootMetadata.st_size)),
                fileCount: 1,
                exists: true,
                isDirectory: false,
                objectIdentity: expectedIdentity
            )
        }
    }

    private func cancelledSnapshot(path: String, exists: Bool, isDirectory: Bool) -> FSSnapshot {
        .init(
            bytes: 0,
            fileCount: 0,
            exists: exists,
            isDirectory: isDirectory,
            completion: .cancelled,
            issues: [FSSnapshotIssue(path: path, reason: .cancelled, stage: .cancellation)]
        )
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private static func millisecondsClamped(_ seconds: TimeInterval) -> Int64 {
        guard seconds.isFinite else { return .max }
        let value = max(0, seconds) * 1_000
        guard value < Double(Int64.max) else { return .max }
        return Int64(value)
    }

    private func snapshotIssue(
        error: Error,
        path: String,
        stage: FSSnapshotIssueStage,
        defaultReason: FSSnapshotIssueReason,
        op: String
    ) -> FSSnapshotIssue {
        let ns = error as NSError
        let code: Int32? = ns.domain == NSPOSIXErrorDomain ? Int32(ns.code) : nil
        handle(error: error, path: path, op: op)
        let reason: FSSnapshotIssueReason = IOErrorClassifier.classify(error) == .permissionDenied
            ? .permissionDenied
            : defaultReason
        return .init(path: path, reason: reason, stage: stage, posixErrorCode: code)
    }

    private func snapshotIssue(
        posixErrorCode: Int32,
        path: String,
        stage: FSSnapshotIssueStage,
        defaultReason: FSSnapshotIssueReason,
        op: String
    ) -> FSSnapshotIssue {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(posixErrorCode))
        return snapshotIssue(
            error: error,
            path: path,
            stage: stage,
            defaultReason: defaultReason,
            op: op
        )
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
