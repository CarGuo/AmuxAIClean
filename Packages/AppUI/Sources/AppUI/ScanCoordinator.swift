import Darwin
import Foundation
import LogKit
import ScanKit
import SafetyKit

/// 扫描完整性证据到 Tree UI 的唯一投影。
///
/// Tree 有两个不能合并的维度：
/// - issue 与当前行相等，或 issue 是当前行的祖先：当前节点自身不可完整读取，画锁；
/// - 当前行是 issue 的严格祖先：当前节点仍可浏览，只标记“子树含未完整后代”。
///
/// 删除父目录时的安全预检仍需要祖先/后代双向重叠，但那是删除覆盖关系，不能反过来
/// 污染 Tree 的视觉访问状态。所有 TreeRow 合成入口都必须复用这个双轴投影。
private struct TreeScanEvidenceProjection: Sendable {
    struct ProjectedState: Sendable, Equatable {
        let accessState: TreeRow.AccessState
        let subtreeCompleteness: TreeRow.SubtreeCompleteness
    }

    private let permissionDeniedPaths: [String]
    private let tccProtectedPaths: [String]
    private let incompletePaths: [String]

    init(issues: [ScanIncompleteIssue] = []) {
        var permissionDenied = Set<String>()
        var tccProtected = Set<String>()
        var incomplete = Set<String>()
        for issue in issues {
            let path = Self.normalize(issue.path)
            guard !path.isEmpty else { continue }
            switch issue.reason {
            case .permissionDenied:
                permissionDenied.insert(path)
            case .tccProtectedSkipped:
                tccProtected.insert(path)
            case .enumerationFailed, .metadataUnavailable:
                incomplete.insert(path)
            }
        }
        permissionDeniedPaths = permissionDenied.sorted()
        tccProtectedPaths = tccProtected.sorted()
        incompletePaths = incomplete.sorted()
    }

    func projectedState(
        for path: String,
        fallbackAccessState: TreeRow.AccessState = .normal,
        fallbackSubtreeCompleteness: TreeRow.SubtreeCompleteness = .complete
    ) -> ProjectedState {
        let normalized = Self.normalize(path)
        let accessState: TreeRow.AccessState
        if tccProtectedPaths.contains(where: { Self.isSameOrAncestor($0, of: normalized) }) {
            accessState = .tccProtected
        } else if permissionDeniedPaths.contains(where: { Self.isSameOrAncestor($0, of: normalized) }) {
            accessState = .permissionDenied
        } else if incompletePaths.contains(where: { Self.isSameOrAncestor($0, of: normalized) }) {
            accessState = .incomplete
        } else {
            accessState = fallbackAccessState
        }

        let containsIncompleteDescendant = tccProtectedPaths.contains(where: {
            Self.isStrictAncestor(normalized, of: $0)
        }) || permissionDeniedPaths.contains(where: {
            Self.isStrictAncestor(normalized, of: $0)
        }) || incompletePaths.contains(where: {
            Self.isStrictAncestor(normalized, of: $0)
        })

        return ProjectedState(
            accessState: accessState,
            subtreeCompleteness: containsIncompleteDescendant
                ? .containsIncompleteDescendant
                : fallbackSubtreeCompleteness
        )
    }

    private static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func isSameOrAncestor(_ ancestor: String, of candidate: String) -> Bool {
        guard !ancestor.isEmpty, !candidate.isEmpty else { return false }
        if ancestor == candidate { return true }
        if ancestor == "/" { return candidate.hasPrefix("/") }
        return candidate.hasPrefix(ancestor + "/")
    }

    private static func isStrictAncestor(_ ancestor: String, of candidate: String) -> Bool {
        ancestor != candidate && isSameOrAncestor(ancestor, of: candidate)
    }
}

/// “旧版本残留”每个候选目录的一次完整扫描会话结果。
///
/// 大小、文件数和删除拒绝证据必须来自同一次 BulkScanner 遍历；否则 UI 可能展示
/// 一个不完整大小，却把整个父目录交给删除管线。`deletionDeniedPaths` 包含权限拒绝、
/// TCC 跳过和任何未完整结束的根，供 TrashPipeline 做祖先/后代一票否决。
private struct VersionedRootScanMeasurement: Sendable {
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let fileCount: Int
    let incompleteIssues: Set<ScanIncompleteIssue>

    var deletionDeniedPaths: Set<String> {
        Set(incompleteIssues.map(\.path))
    }
}

/// 扫描协调器 —— UI 与 BulkScanner 之间的"减压阀"。
///
/// 设计目标（每条都来自 PITFALLS §5）：
/// - **聚合到一级子目录**：4 万文件 yield 进 SwiftUI List 主线程必崩
/// - **节流 commit**：≥150ms 才发一次 snapshot；每条 .node 直接更新 state 是错的
/// - **按 size 实时排名**：每次 commit 重排，但发现期不动 row identity
/// - **SafetyEngine 内嵌**：每个一级子目录拿到 verdict，UI 直接渲染徽章
/// - **节流期总字节优先稳定**：UI 上的"已扫 X MB"不能跳变
@MainActor
public final class ScanCoordinator: ObservableObject {
    private actor TreeChildrenFetchGate {
        private let limit: Int
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) {
            self.limit = max(1, limit)
        }

        func acquire() async {
            if active < limit {
                active += 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            if waiters.isEmpty {
                active = max(0, active - 1)
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private nonisolated static let treeChildrenFetchGate = TreeChildrenFetchGate(limit: 2)

    public enum ScanPhase: Sendable, Equatable {
        case idle
        case scanning
    }

    /// 扫描器明确发出的致命终态。它与权限拒绝、TCC 跳过、deadline/max-entry
    /// 等“带精确拒绝路径的受限结果”分开保存，消费者不得通过比较本地化错误文案
    /// 来猜测终态类型。
    public struct TerminalFailure: Sendable, Equatable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    @Published public private(set) var snapshot: ScanSnapshot = .empty
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var scanPhase: ScanPhase = .idle
    @Published public private(set) var lastError: String?
    public private(set) var terminalFailure: TerminalFailure?
    /// 当前扫描会话的权威完整性证据。路径、原因、失败阶段和 errno 必须在这里保留；
    /// 下面三个 path 数组仅用于兼容现有 UI / 删除调用方，统一由本数组投影，禁止单独写入。
    @Published public private(set) var incompleteScanIssues: [ScanIncompleteIssue] = []
    @Published public private(set) var permissionDeniedPaths: [String] = []
    /// 扫描器明确报告“未完整遍历”的路径。它与权限拒绝/TCC 跳过分开保存，
    /// 避免把通用枚举错误误导成 FDA 问题；删除预检仍会把三类证据取并集，一票否决。
    @Published public private(set) var incompleteScanPaths: [String] = []
    /// v2026.07 修复：`pruneDeleted` 完成后的公共广播信号。
    ///
    /// **根因**：非 tree/list 走 `snapshot.rows` 的视图（如 [LargeFilesView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LargeFilesView.swift)）
    /// 用 `coordinator.largeFiles(...)` 读 `largeFileLeaves`；`pruneDeleted` 会正确剔掉叶子，
    /// 但它只 bump 了 non-@Published 的 `structuralRevision`——SwiftUI 视图订阅不到，
    /// 表现为"点了移到废纸篓成功，但列表还在"（用户反馈 Q2）。
    /// 现在 `pruneDeleted` 尾部再 `storeRevision &+= 1`，任何依赖 store 派生数据的视图
    /// `.onReceive(coordinator.$storeRevision)` 即可强同步。
    /// 只在 `pruneDeleted` 里 bump（非"每次 snapshot 都推"），避免扫描期 UI churn。
    @Published public private(set) var storeRevision: UInt64 = 0
    /// v1.1：因 TCC 雷区（Music / Photos / Mail 等）被主动 skip 的路径列表。
    /// 与 permissionDeniedPaths 合并展示在统一 banner，**不会触发系统弹窗**。
    @Published public private(set) var tccProtectedSkippedPaths: [String] = []
    private var treeScanEvidenceProjection = TreeScanEvidenceProjection()

    /// v1.3 P0-D：开发者构建产物勘察是否触发了截断（命中数达上限 或 walk 超时）。
    /// UI 在 dev 扫描结果区可读此标志展示 banner："命中过多，仅展示前 N 项"。
    /// 仅在 scanDeveloper 路径上有意义；其他扫描入口启动时会被清零。
    @Published public private(set) var devArtifactDidTruncate: Bool = false
    @Published public private(set) var devArtifactDidTimeout: Bool = false

    /// M4-T1：本轮扫描启动时从 [WhitelistStore.shared](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/WhitelistStore.swift)
    /// 拉一份的内存快照（normalized 后的 path Set）。publishSnapshot 是同步函数，
    /// 不能在 hot path 里 `await` 一个 actor —— 因此扫描入口拉一次快照，全程同步命中。
    /// 命中判定与 WhitelistStore.isWhitelisted 一致：完全相等 或 entry+"/" 作为 path prefix。
    private var whitelistSnapshot: Set<String> = []

    /// 白名单是用户显式表达的“永不展示/永不清理”边界，优先级高于 SafetyEngine。
    /// 这里保持与 `WhitelistStore.isWhitelisted` 完全相同的目录边界语义，供扫描热路径
    /// 使用一次性快照同步判断，避免逐 node 跨 actor。
    private nonisolated static func isWhitelisted(_ path: String,
                                                   in snapshot: Set<String>) -> Bool {
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if snapshot.contains(normalized) { return true }
        for entry in snapshot where normalized.hasPrefix(entry + "/") {
            return true
        }
        return false
    }

    private func isWhitelisted(_ path: String) -> Bool {
        Self.isWhitelisted(path, in: whitelistSnapshot)
    }

    private nonisolated static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.count > 1 && lhs.hasSuffix("/") ? String(lhs.dropLast()) : lhs
        let right = rhs.count > 1 && rhs.hasSuffix("/") ? String(rhs.dropLast()) : rhs
        if left == right { return true }
        if left == "/" || right == "/" { return true }
        return left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    /// 当前完成会话中与删除目标存在祖先/后代关系的 typed incomplete evidence。
    /// Professional target revalidator 只接受本结果；旧的聚合 path Set 不能反推 reason。
    public func incompleteIssues(overlappingAny paths: [String]) -> [ScanIncompleteIssue] {
        let normalizedTargets = paths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        guard !normalizedTargets.isEmpty else { return [] }
        return incompleteScanIssues.filter { issue in
            normalizedTargets.contains { Self.pathsOverlap($0, issue.path) }
        }
    }

    /// `incompleteScanIssues` 是唯一写源；旧 path 数组和 Tree 投影都在这里一次性同步。
    /// 每个字段只在值真的变化时写入，避免同一 ScanKit issue 的兼容事件
    /// (`permissionDenied` + `incomplete`) 造成多轮无意义 SwiftUI invalidation。
    private func synchronizeIncompleteEvidenceProjections() {
        let permissionPaths = Self.stableUniquePaths(
            incompleteScanIssues.lazy
                .filter { $0.reason == .permissionDenied }
                .map(\.path)
        )
        let tccPaths = Self.stableUniquePaths(
            incompleteScanIssues.lazy
                .filter { $0.reason == .tccProtectedSkipped }
                .map(\.path)
        )
        let allPaths = Self.stableUniquePaths(incompleteScanIssues.lazy.map(\.path))

        if permissionDeniedPaths != permissionPaths {
            permissionDeniedPaths = permissionPaths
        }
        if tccProtectedSkippedPaths != tccPaths {
            tccProtectedSkippedPaths = tccPaths
        }
        if incompleteScanPaths != allPaths {
            incompleteScanPaths = allPaths
        }
        treeScanEvidenceProjection = TreeScanEvidenceProjection(issues: incompleteScanIssues)
    }

    private nonisolated static func stableUniquePaths<S: Sequence>(_ paths: S) -> [String]
    where S.Element == String {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private func resetIncompleteEvidence() {
        if !incompleteScanIssues.isEmpty {
            incompleteScanIssues = []
        }
        synchronizeIncompleteEvidenceProjections()
    }

    private func replaceIncompleteEvidence(with issues: [ScanIncompleteIssue]) {
        var seen = Set<ScanIncompleteIssue>()
        let unique = issues.filter { seen.insert($0).inserted }
        if incompleteScanIssues != unique {
            incompleteScanIssues = unique
        }
        synchronizeIncompleteEvidenceProjections()
    }

    private func recordIncompleteIssue(_ issue: ScanIncompleteIssue) {
        let normalized = URL(fileURLWithPath: issue.path).standardizedFileURL.path
        let normalizedIssue = ScanIncompleteIssue(
            path: normalized,
            reason: issue.reason,
            stage: issue.stage,
            posixErrorCode: issue.posixErrorCode
        )

        // Legacy companion events do not carry stage/errno. If the richer `.incomplete`
        // arrives afterwards, replace the generic evidence rather than keeping two copies.
        if let genericIndex = incompleteScanIssues.firstIndex(where: {
            $0.path == normalized
                && $0.reason == normalizedIssue.reason
                && $0.stage == nil
        }), normalizedIssue.stage != nil {
            incompleteScanIssues[genericIndex] = normalizedIssue
            synchronizeIncompleteEvidenceProjections()
            return
        }
        if normalizedIssue.stage == nil,
           incompleteScanIssues.contains(where: {
               $0.path == normalized && $0.reason == normalizedIssue.reason
           }) {
            return
        }
        guard !incompleteScanIssues.contains(normalizedIssue) else { return }
        incompleteScanIssues.append(normalizedIssue)
        synchronizeIncompleteEvidenceProjections()
    }

    private func projectedTreeState(
        for path: String,
        fallbackAccessState: TreeRow.AccessState = .normal,
        fallbackSubtreeCompleteness: TreeRow.SubtreeCompleteness = .complete
    ) -> TreeScanEvidenceProjection.ProjectedState {
        treeScanEvidenceProjection.projectedState(
            for: path,
            fallbackAccessState: fallbackAccessState,
            fallbackSubtreeCompleteness: fallbackSubtreeCompleteness
        )
    }

    private enum ScanFailureScope {
        case root(ScanIncompleteIssue)
        case descendant(ScanIncompleteIssue)
    }

    /// 兼容旧 ScanKit 生产者可能把 descendant failure 发成 `.failed` 的情况；新合同下
    /// `.failed` 只应指向 root。消费者仍根据 error 自带 path 校验 scope，避免一次生产者
    /// 回归再次把精确 child 缺口扩大成整个扫描根失败。
    private nonisolated static func scanFailureScope(
        _ error: any Error,
        rootPath: String
    ) -> ScanFailureScope {
        let standardizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard let scanError = error as? ScanError else {
            return .root(ScanIncompleteIssue(
                path: standardizedRoot,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
        }

        let failedPath: String
        let stage: ScanIssueStage
        let posixErrorCode: Int32?
        switch scanError {
        case .cannotEnumerate(let path, let errorStage, let errorCode):
            failedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            stage = errorStage
            posixErrorCode = errorCode
        }
        let reason: ScanIncompleteReason
        if posixErrorCode == EACCES || posixErrorCode == EPERM {
            reason = .permissionDenied
        } else if stage == .metadata {
            reason = .metadataUnavailable
        } else {
            reason = .enumerationFailed
        }
        let issue = ScanIncompleteIssue(
            path: failedPath,
            reason: reason,
            stage: stage,
            posixErrorCode: posixErrorCode
        )
        if failedPath != standardizedRoot,
           failedPath.hasPrefix(standardizedRoot == "/" ? "/" : standardizedRoot + "/") {
            return .descendant(issue)
        }
        return .root(issue)
    }

    /// 记录 `.failed` 并返回它是否真的是 root 级致命失败。descendant 只进入结构化
    /// incomplete evidence，绝不写 terminalFailure / lastError。
    @discardableResult
    private func consumeScanFailure(
        _ error: any Error,
        rootPath: String,
        messagePrefix: String? = nil
    ) -> Bool {
        switch Self.scanFailureScope(error, rootPath: rootPath) {
        case .descendant(let issue):
            recordIncompleteIssue(issue)
            return false
        case .root(let issue):
            recordIncompleteIssue(issue)
            let rawMessage = String(describing: error)
            let message = messagePrefix.map { "[\($0)] \(rawMessage)" } ?? rawMessage
            terminalFailure = TerminalFailure(message: message)
            lastError = message
            return true
        }
    }

    /// v1.3：主列表（推荐清理 / 自定义路径）排序键。默认 `.sizeDesc`（按大小从大到小）。
    ///
    /// - 切换时立刻重发当前 snapshot，UI 列表实时按新排序刷新（不需要重扫）。
    /// - **仅作用于扫描完成态（finished=true）**；扫描进行中 publishSnapshot 强制按 path 字典序，
    ///   避免最大 bucket 永远霸占第一行造成"只一行在动"错觉（v1.3 publishSnapshot 注释有详细背景）。
    /// - 由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    ///   在启动时与 onChange 时从 [AppSettings.mainListSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    ///   同步过来。
    @Published public var mainListSortKey: MainListSortKey = .sizeDesc {
        didSet {
            guard oldValue != mainListSortKey else { return }
            // 排序只投影当前已发布 rows，不能重新从 buckets 物化。versioned/common
            // 等专用入口没有 buckets，旧做法会在切换排序时把真实结果清空；同时
            // partial 的可信度也必须原样保留，绝不能被 UI 重排提升成完整成功。
            guard snapshot.isFinished else { return }
            snapshot = ScanSnapshot(
                categoryID: snapshot.categoryID,
                rows: snapshot.rows.sorted { mainListSortKey.lessThan($0, $1) },
                totalBytes: snapshot.totalBytes,
                scannedFileCount: snapshot.scannedFileCount,
                isFinished: snapshot.isFinished,
                elapsed: snapshot.elapsed,
                isComplete: snapshot.isComplete,
                bytesPerSecond: snapshot.bytesPerSecond,
                estimatedRemaining: snapshot.estimatedRemaining
            )
        }
    }
    private var lastFinishedCategoryID: String?

    /// 当前/最近一次扫描的根路径；`nil` 表示尚未发起任何扫描（notStarted 态）。
    /// UI 用它在 `finishedEmpty(rootPath:)` 三态里显示具体目录，避免硬编码 `~/Library/Caches`。
    @Published public private(set) var currentRootPath: String?

    /// v1.3：FDA（完全磁盘访问）探测结果。
    /// - `granted`：用户已在系统设置勾选了本 App，扫描不再硬 skip TCC 雷区，banner 不显示
    /// - `denied` / `unknown`：保持保守 skip 行为，banner 仍可能显示
    /// 启动时探测一次；`refreshFDAStatus()` 让 UI（如从设置回到 App）能手动重探。
    @Published public private(set) var fdaStatus: FDAProbe.Status

    /// v1.3：磁盘卷容量信息（"482.95 GB of 494.38 GB used"）。
    /// 启动时探一次，每次扫描完成 / 删除完成后再探一次（容量是系统数据，需要重新读）。
    @Published public private(set) var volumeSnapshot: VolumeCapacity.Snapshot?

    /// v1.3.x：macOS 用了多少**硬盘空间**当虚拟内存（swap）+ 休眠镜像（sleepimage）。
    /// 与 [volumeSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L55-L55)
    /// 共用同一刷新时机：启动 / 扫描完成 / 删除完成。
    /// 仅供 UI 只读展示——swap 与 sleepimage 由内核管理，App 不应清理。
    @Published public private(set) var swapSnapshot: SwapProbe.Snapshot?

    /// v1.3：上一次扫描是否被用户主动 cancel 而中断。
    /// statusBar 借此把"已停止"与"还未扫描"区分开——
    /// 不区分会让用户以为按下停止后什么都没干。
    /// 任何新 scan 入口启动时清回 false。
    @Published public private(set) var wasCancelled: Bool = false

    /// v1.3：多根并行扫描时每根的进度信息。key=rootPath。
    /// - 单根扫描入口（scan/scanFullDisk）保持空 dict —— UI 据此回退到老的"扫描中… N 个文件 · X MB"单行；
    /// - 多根扫描入口（scanRecommended）会预填 5 条（每根一条）isFinished=false，
    ///   每收到一条 [MultiRootEvent](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)
    ///   按 rootPath 累加 bytes / fileCount；该根 .finished 事件到达时翻 isFinished=true。
    /// v1.3.zz 性能修复：每文件不再直接写 @Published（每写都触发 SwiftUI 全 view 重算），改成
    /// 写到 perRootStaging（普通字典），由 publishSnapshot（throttle 0.4s）批量同步到这里。
    ///
    /// v1.5 P1-B 性能修复：旧实现是整个 dict 替换 → SwiftUI 把 statusBar / 多根 ScrollView
    /// 大面积重 diff。dev scan 几十/几百根时极其卡。改为拆分为两份 @Published：
    /// - [perRootProgressActive](#)：仅 in-flight（isFinished==false）的根，体量小、变化频繁；
    /// - [perRootFinishedSlim](#)：已 finished 的根的轻量快照，体量随完成数增长但每个根只 push 一次；
    /// - [perRootFinishedCount](#)：finished 数量，方便 UI 只看个数变化触发刷新。
    /// 本字段保留为只读计算属性合并两者，让现有读取者（树形顶层合成 / status banner）无须改动。
    public var perRootProgress: [String: PerRootProgress] {
        if perRootFinishedSlim.isEmpty { return perRootProgressActive }
        if perRootProgressActive.isEmpty { return perRootFinishedSlim }
        return perRootProgressActive.merging(perRootFinishedSlim) { active, _ in active }
    }

    /// v1.5 P1-B：in-flight 根的进度。throttle 同步时只触达"还在扫"的根，整体重 diff 面收敛。
    @Published public private(set) var perRootProgressActive: [String: PerRootProgress] = [:]

    /// v1.5 P1-B：已 finished 根的轻量快照（保留 bytes/fileCount/title 用于树形顶层），
    /// 每根 finish 时一次性 push，之后不再变化 —— SwiftUI 对该字典的子树渲染会稳定下来。
    @Published public private(set) var perRootFinishedSlim: [String: PerRootProgress] = [:]

    /// v1.5 P1-B：已 finished 根的数量。便于 UI 只关心数量变化（例如显示 "3/5 已完成"）时，
    /// 避免依赖整 dict 触发重 diff。
    @Published public private(set) var perRootFinishedCount: Int = 0

    /// v2026.06.22 perf：UI 展示用的「已按 rootPath 字典序预排序」的数组形态。
    ///
    /// 背景（trace 6.67 s，主线程 NSHostingView.layout 778 ms）：
    /// 旧实现在 [statusBar L1549](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1549)
    /// 每帧 body 重 eval 都跑一次 `perRootProgress.values.sorted(by: { $0.rootPath < $1.rootPath })`：
    ///   - sort 几百根 String 字典序比较：~10 ms（_stringCompare 链）
    ///   - sort 闭包带 MainActor 上下文：每对比较都触发 `swift_task_isCurrentExecutor` ~6 ms
    ///   - 总计 statusBar.getter 单帧 44.3 ms，60fps 滚动直接吃光 frame budget。
    ///
    /// 现在：在 syncPerRootPublished 同步点一次性排序好，UI 直接读，零 sort。
    /// 由于 perRootProgressActive + perRootFinishedSlim 已经 @Published（throttle 0.4s
    /// 才更新），这个数组的更新频率天然就被 throttle 住——比每帧 sort 收益大几个量级。
    @Published public private(set) var perRootProgressSorted: [PerRootProgress] = []

    /// v1.3.zz 性能修复用：staging 累计区，每 .node 事件直接累计这里，避开 @Published 触发 SwiftUI invalidation。
    /// publishSnapshot 节流点会把它同步到 perRootProgress（0.4s 一次）。
    private var perRootStaging: [String: PerRootProgress] = [:]

    /// v1.5 P1-B：把 staging 字典拆分同步到 active / finishedSlim / finishedCount。
    /// - 仅当 active / finishedSlim 真的变化时才 assign，避免无谓 willChange。
    /// - 删除成功后的乐观 prune 可能让 finished root 的 bytes/fileCount 变小，甚至移除整根；
    ///   因此 finishedSlim 不能再假设 key set 单调增。
    private func syncPerRootPublished(from staging: [String: PerRootProgress]) {
        var nextActive: [String: PerRootProgress] = [:]
        nextActive.reserveCapacity(staging.count)
        var nextFinishedCount = 0
        var nextFinishedSlim: [String: PerRootProgress] = [:]
        for (k, v) in staging {
            if isDeletedTombstoned(k) { continue }
            if v.isFinished {
                nextFinishedCount += 1
                nextFinishedSlim[k] = v
            } else {
                nextActive[k] = v
            }
        }
        if perRootProgressActive != nextActive {
            perRootProgressActive = nextActive
        }
        if perRootFinishedSlim != nextFinishedSlim {
            perRootFinishedSlim = nextFinishedSlim
        }
        if perRootFinishedCount != nextFinishedCount {
            perRootFinishedCount = nextFinishedCount
        }

        // v2026.06.22 perf：同步维护 sorted 数组（UI 直接读，零 sort）。
        // staging 是合并后的最终态；这里就一次性按 rootPath 字典序排好。
        // 仅当真的变化才 assign，避免无谓 willChange / SwiftUI 重 diff。
        let nextSorted = staging.values.sorted(by: { $0.rootPath < $1.rootPath })
        if perRootProgressSorted != nextSorted {
            perRootProgressSorted = nextSorted
        }
        notePruneSourceMutation()
    }

    /// v1.5 P1-B：完整重置三份 @Published（用于 cancel / 重新预填）。
    private func resetPerRootPublished() {
        if !perRootProgressActive.isEmpty { perRootProgressActive = [:] }
        if !perRootFinishedSlim.isEmpty { perRootFinishedSlim = [:] }
        if perRootFinishedCount != 0 { perRootFinishedCount = 0 }
        if !perRootProgressSorted.isEmpty { perRootProgressSorted = [] }
        notePruneSourceMutation()
    }

    /// 单根的实时进度快照。
    /// - title：UI 直接展示的中文友好名（取自 ScanCategory.title），如"用户缓存"/"应用日志"；
    /// - bytes / fileCount：该根累计已扫到的字节与文件数；
    /// - isFinished：该根的 BulkScanner 是否已 yield 过 .finished。多根全部 isFinished=true 时
    ///   stream 关闭，runMultiRootScan 自身把 isScanning 翻 false。
    public struct PerRootProgress: Sendable, Equatable {
        public let rootPath: String
        public let title: String
        public var bytes: Int64
        public var logicalBytes: Int64
        public var fileCount: Int
        public var isFinished: Bool
        /// 根扫描已终止但未完整遍历（例如 per-root timeout / no-progress watchdog）。
        /// 这种终态可以展示已观察结果，但 UI 不能画成绿色完成勾。
        public var isPartial: Bool
        public init(rootPath: String, title: String,
                    bytes: Int64 = 0, logicalBytes: Int64? = nil, fileCount: Int = 0,
                    isFinished: Bool = false, isPartial: Bool = false) {
            self.rootPath = rootPath
            self.title = title
            self.bytes = bytes
            self.logicalBytes = logicalBytes ?? bytes
            self.fileCount = fileCount
            self.isFinished = isFinished
            self.isPartial = isPartial
        }
    }

    /// v1.3：多根并行扫描的特殊 categoryID 哨兵，与 ScanCategory.id 解耦。
    /// runScan 的 activeCategoryID 校验沿用此值；UI 不应依赖它做业务判断（用 perRootProgress 判更可靠）。
    public static let multiRootCategoryID: String = "recommended.multi"

    /// Smart Care “系统与日志”专用多根扫描。它刻意不包含应用缓存与开发缓存，
    /// 防止普通模式三个范围在真实文件系统根上互相重叠。
    public static let smartCareCoreCategoryID: String = "smart_care.core.multi"

    /// v1.4：开发者构建产物多根并行扫描的 categoryID 哨兵。与 multiRootCategoryID 区分，
    /// 让 UI 可以渲染不同标题（"开发者构建产物" vs "全部推荐扫描"），但底层 runMultiRootScan 共用。
    public static let developerCategoryID: String = "developer.multi"

    /// 常见应用缓存规则扫描的 categoryID。
    ///
    /// 该入口只消费 `vendors.yaml` 中 `category=common_app_cache` 的显式规则，结果是
    /// "命中路径列表"，不是普通文件系统目录树，因此不走 BulkScanner 流式 ingest。
    public static let commonAppCacheCategoryID: String = "common_app_cache"

    /// v1.5：多根扫描时 [currentRootPath](#) 设为这两个伪路径之一，给 UI 占位
    /// （树形/finishedEmpty 等场景需要一个非 nil 值）。这两个值不是真实目录，
    /// 也不会有"以它们为父"的真实文件系统子项；树形视图遇到它们时要走「合成多根顶层」分支
    /// （见 [directChildren(of:sortedBy:)](#)），把 perRootProgress 的真实根升级成顶层 TreeRow。
    ///
    /// v2026.06.21：原值为中文字面（"(多目录)" / "(开发者构建产物)" / "(开发者旧版本)"），
    /// 由于 [placeholder(for:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1572)
    /// 的 `.finishedEmpty(rootPath)` 分支会直接 `Text(rootPath)` 给英文用户看，
    /// 那相当于英文 UI 露出三个中文 token。统一改成纯英文 sentinel ID（带双下划线前后缀，
    /// 不会与任何真实文件路径冲突），UI 侧检测到 sentinel 后走 `path.sentinel.*`
    /// xcstrings key 走本地化显示。
    public static let multiRootSentinelPath: String = "__sentinel_multi_root__"
    public static let smartCareCoreSentinelPath: String = "__sentinel_smart_care_core__"
    public static let developerSentinelPath: String = "__sentinel_dev_artifact__"
    public static let versionedRootSentinelPath: String = "__sentinel_versioned_root__"
    public static let commonAppCacheSentinelPath: String = "__sentinel_common_app_cache__"
    public static let multiRootSentinelPaths: Set<String> = [
        multiRootSentinelPath,
        smartCareCoreSentinelPath,
        developerSentinelPath,
        versionedRootSentinelPath,
        commonAppCacheSentinelPath
    ]

    /// 便利属性 —— 转发自 `snapshot.isFinished`，表示事件流已进入终态；成功与否再看
    /// `snapshot.isComplete`。这样部分结果可以展示并按精确证据预检，不会伪装成成功。
    public var isFinished: Bool { snapshot.isFinished }

    private let engine = SafetyEngine()
    private let vendors: [VendorRule]
    private let home: String
    private let whitelistStore: WhitelistStore
    /// 预构建的 VendorTrie —— 性能关键：
    /// `publishSnapshot` 每帧（≥150ms）会对 N 个 bucket 调 `engine.evaluate`。
    /// 朴素 `evaluate(path:vendors:home:)` 内部**每次都重建 trie**（含 ~42 条 path-rule
    /// 的 `URL.standardizedFileURL` —— 系统调用级开销），整盘扫 buckets ~100+ 时
    /// 实测每秒重建上百次 trie，把主线程 publishSnapshot 拖到 50–200ms 一帧，
    /// 反向阻塞 BulkScanner 的 unbounded continuation.yield → 看起来"线扫描很慢"。
    /// 这里一次构建、扫描期间复用，evaluate 走 trie 版 O(路径深度) 路径。
    /// vendors 在 init 时就锁定，扫描期不会动；用 lazy + `let` 等价的 stored property 即可。
    private let trie: VendorTrieNode
    private var scanTask: Task<Void, Never>?

    /// 每次扫描会话的不可复用代际 token。
    ///
    /// categoryID 只能区分“扫什么”，不能区分“同一分类的前后两次扫描”。旧任务的
    /// cooperative cancellation 可能晚于新任务启动；若只比较 categoryID，旧任务仍能
    /// 发布收尾结果。所有异步回写必须同时持有 categoryID 与本 token。
    private var scanGeneration = UUID()

    /// 当前扫描会话的稳定身份。Professional 删除确认会冻结它，并在真正提交前复核，
    /// 避免同一 category 取消后重扫时把上一轮 rows 提交到下一轮状态。
    public var currentScanSessionID: UUID { scanGeneration }

    /// 同步 detector 的依赖边界。生产默认实现直接调用 ScanKit；internal 可替换性用于
    /// 构造“旧 detector 不协作取消且晚返回”的确定性并发测试，验证 generation 本身，
    /// 而不是依赖文件系统规模或时序碰运气。
    typealias CommonAppCacheDetector = @Sendable (
        _ vendors: [VendorRule],
        _ home: URL,
        _ options: CommonAppCacheScanner.Options
    ) -> CommonAppCacheScanner.ScanResult
    var commonAppCacheDetector: CommonAppCacheDetector = { vendors, home, options in
        CommonAppCacheScanner.detect(vendors: vendors, home: home, options: options)
    }

    /// 树形后台展开的代际 token。每次新扫描 / 取消都会刷新，防止旧展开任务写回新扫描缓存。
    private var treeFetchGeneration = UUID()

    /// v1.3：当前"活跃"的 categoryID。
    /// 防 [坑 1]：旧 scan 被 cancel 后，AsyncStream 缓冲里残留的 .node 事件仍可能被旧 for-await
    /// 循环消费一两轮（cancel 的传播是协作式，不是抢占式）。如果不带本次 token，
    /// 旧 ingest 会把数据写到刚被新 scan 重置过的 buckets/dirIndex 上，污染新 categoryID 的 snapshot。
    /// runScan 的每次事件处理之前先校验 `myCategoryID == activeCategoryID`，不一致直接 break。
    /// v1.3 P0-D：暴露 read-only 给 UI 用于判断 banner 上下文（仍是内部更新）。
    public private(set) var activeCategoryID: String?

    private func ownsScan(categoryID: String, generation: UUID) -> Bool {
        activeCategoryID == categoryID && scanGeneration == generation
    }

    /// 一级子目录 -> 累计统计；用 path 作 key 保证稳定。
    private struct Bucket: Sendable {
        var url: URL
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var isDirectory: Bool
        /// v1.5.4：bucket（一级聚合行 = 一级子目录或单个顶层文件）自身 inode 的 mtime。
        ///
        /// 仅在 isTopLevelBucket=true 时写入——即 BulkScanner 真的 yield 出该 bucket 自己的
        /// node entry（首次 ingest 一定会触发），所以扫完一定有值，无需额外探测。
        /// 为什么不维护"max(子孙 mtime)"：见 [RowItem.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L33) 文档——
        /// Finder 风格目录 mtime = 目录 inode 自身 mtime（在该目录里增删文件即由内核更新）。
        var modificationDate: Date? = nil

        /// Step 3 P0-3 / 2026-06：bucket 节点的 SafetyEngine.evaluate 结果缓存。
        ///
        /// 为什么这里能 cache：bucket 的 key 是 `path: String`，永久不变；`engine` 自身、
        /// vendor `trie` 与 `home` 在 ScanCoordinator 的生命周期里都是 `let` immutable —— 
        /// 所以同一 path 的 evaluate 结果**永远相同**。
        ///
        /// 旧 publishSnapshot 每帧（流式扫描 0.4s/帧）都对全部 N 个 bucket 调一次
        /// evaluate(trie:)。一次扫描扫到 K=数百~数千 bucket，× 数十帧，多出几千~几十万次
        /// 主线程纯函数调用 —— 对 Tree View 就是直接的卡顿源。
        ///
        /// 缓存策略：首次 publishSnapshot 看到该 bucket 时算一次写回；之后命中直接读。
        /// `nil` = 还没算过；非 nil = 已经算过且永远有效（因 cache 失效条件不存在 ——
        /// startScan/rescan/cancel 会整个 buckets.removeAll()，cache 字段自然消失）。
        var cachedVerdict: SafetyVerdict? = nil
        var cachedRejection: SafetyRejection? = nil
        var cachedVendor: VendorRule? = nil

        /// v1.3.z 性能优化：把 ingest hot path 的 read-modify-write 收敛进 Bucket 自身。
        /// 配合 `buckets[k, default: ...].applyIngest(...)` 让 hit 路径只走一次哈希查找，
        /// 且 hit 时不构造 default 值（autoclosure 不求值）。
        mutating func applyIngest(
            isFileNode: Bool,
            isTopLevelBucket: Bool,
            isDirEffective: Bool,
            bytes nodeBytes: Int64,
            logicalBytes nodeLogical: Int64,
            nodeMTime: Date? = nil
        ) {
            if isFileNode {
                bytes += nodeBytes
                logicalBytes += nodeLogical
                fileCount += 1
            }
            // 顶层 bucket 自身可能是文件（极少见），保留 isDirectory 信息
            if isTopLevelBucket {
                isDirectory = isDirEffective
                if !isDirEffective {
                    bytes += nodeBytes
                    logicalBytes += nodeLogical
                    fileCount = 1
                }
                // 仅在确实拿到 mtime 时覆盖；保留已有值避免被空帧清零
                if let m = nodeMTime {
                    modificationDate = m
                }
            }
        }
    }
    private var buckets: [String: Bucket] = [:]

    /// v1.3：每个 bucket 最近一次有 ingest 写入的时间戳（reference time interval）。
    ///
    /// 用法：publishSnapshot 时计算 `now - lastIngestAt[bucketPath] < activityWindow` 即视为 active，
    /// 写到 [RowItem.isActive](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L24)；
    /// UI（[ScanRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanRow.swift)）
    /// 据此给 bytes 数字上色 + 脉动。
    ///
    /// 为什么这样设计：BulkScanner 的 6 worker 在不同子树并发枚举时，每个 worker yield .node 进 ingest
    /// 都会落到对应 bucketPath（一级祖先），所以"哪些 bucket 最近有数据进来"= "哪些子树正在被扫"。
    /// 不需要额外的 worker → bucket 通知通道，零侵入到 ScanKit。
    private var lastIngestAt: [String: TimeInterval] = [:]

    /// v1.3：active 判定窗口。最近 N 秒内有 ingest 即视为正在扫描。
    /// 800ms 是经验值——大于 BulkScanner 默认 progress 节流（150ms）的若干倍，能容忍小的 ingest 间隙；
    /// 又显著小于"扫一个普通子目录的耗时"（通常 1~10s），不会让停掉的 bucket 持续假亮。
    private let activityWindow: TimeInterval = 0.8

    /// v1.0 T3：任意目录子树聚合索引，支撑 TreeBrowserView 多层下钻。
    /// key = 任意目录全路径，value = 该目录"整个子树"累计的 bytes / fileCount。
    /// 还额外维护 parent->Set<directChildPath> 边，让 OutlineGroup 能 O(1) 取子。
    ///
    /// v1.5.4：新增 `modificationDate` —— 仅在该目录"作为节点本身被 ingest"时写入，
    /// 即来自 [BulkScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift) 的目录条目自身的 inode mtime（Finder 风格）。
    /// 不做 max(子孙) 聚合，避免每个文件叶子都要回写所有祖先字段；nil 表示尚未拿到（极早期 publish 帧）。
    private struct DirAgg: Sendable {
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var modificationDate: Date? = nil
    }
    private var dirIndex: [String: DirAgg] = [:]
    /// 父目录 -> 直接子项集合（含目录与文件路径）。文件叶子也存进来方便单层展示。
    private var childEdges: [String: Set<String>] = [:]
    /// 叶子文件 path -> (allocated size, logical size, isDir, mtime?)；展示时区分文件与目录。
    /// v1.5.4 加 modificationDate：来源同 dirIndex —— 直接拿 [FSNode.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/FSNode.swift#L14)。
    private var fileLeaves: [String: (bytes: Int64, logicalBytes: Int64, isDir: Bool, modificationDate: Date?)] = [:]

    /// TreeBrowserView 的按需子树扫描缓存。
    ///
    /// 当 `enableTreeDeepIndex == false`（v1.3.z 起的默认）时，内存里没有
    /// `childEdges/dirIndex/fileLeaves`，TreeBrowserView 不能再同步拿到子项。
    /// 但 SwiftUI body 不能 await，所以这里做"同步表面 + 后台填充"双层缓存：
    ///   - body 每次调 `directChildren(of:sortedBy:)`，先看本 cache
    ///   - cache miss → 同步返 [], 同时启一个后台 Task 扫描当前目录子树并写回 cache
    ///   - 写回时 @Published 触发 view 重算, 第二帧拿到结果
    ///
    /// key = `"\(path)|\(sortKey.rawValue)"`，让不同排序各自缓存（用户切排序不丢上次结果）。
    /// 扫描结束 / 切类目 / 切根 时由 cancel/reset 主动清空，避免跨会话脏数据。
    ///
    /// **Step 9a / 2026-06**：从 `@Published` 解耦为普通字典。
    /// 历史问题：`@Published` 字典每次写入都会让整个 ScanCoordinator
    /// `objectWillChange` fire，所有 view（含 MainView 主列表 / SystemProbe banner）
    /// 都被波及一次重算；而真正需要被通知的只有 TreeBrowserView，
    /// 已经通过 [bumpStructuralRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L328-L332)
    /// 显式触发。新做法：cache 自己是普通字典，配套一条
    /// [childrenCacheVersion](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 计数器 @Published（仅给可能要按 cache 失效细粒度刷新的 view 订阅）。
    /// 主流程依赖 structuralRevision 即可。
    private var treeChildrenCache: [String: [TreeRow]] = [:]
    /// **Step 9a / 2026-06**：cache 写入计数器，monotonic UInt64。
    /// 任何 `treeChildrenCache` 写入（写新键 / 移除旧键 / 整轮 removeAll）后
    /// 都必须经过 [bumpChildrenCacheVersion()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 把它 &+= 1。view 端**通常不需要**直接订阅这条信号（structuralRevision 已经
    /// 覆盖），保留它是为：
    ///   - 单元测试断言"cache 写入 N 次 → version 自增 N 次"
    ///   - 未来 view 想做"按 cache 命中率细粒度刷新"留 hook
    ///
    /// v2026.06.21 perf：移除 @Published（同 treeRevision 的理由）。
    public private(set) var childrenCacheVersion: UInt64 = 0
    /// in-flight 路径集合：避免同 path 在 cache miss 时被 view body 多次重算疯狂启 Task。
    /// **不**参与 @Published（不需要触发 view 更新）。
    private var treeChildrenInFlight: Set<String> = []

    /// v2026.06.20 **目录 mtime 兜底缓存**。
    ///
    /// 背景：用户反馈"为什么有的地方修改时间就一直不显示"。
    /// 现状：BulkScanner 只对真正 yield 出的 `.node` 写入
    /// [DirAgg.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L189)；
    /// 但中间层目录（叶子上溯过程中累加的 ancestor）可能没有自己的 `.node` 事件，
    /// 这些 row 在 [materializeFromMemory](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 输出时 `modificationDate == nil`，UI 永远显示 `·`。
    ///
    /// 修复策略：directChildren 输出真实存在的"目录"行时，若 agg.modificationDate=nil
    /// 但路径在磁盘上存在，就 `lstat` 一次拿 inode mtime 兜底，并缓存避免每帧重算。
    /// **不命中磁盘的虚拟节点（如多根伪 root `(开发者构建产物)`）不会落到这里**——
    /// 它们走 [synthesizeMultiRootTopLevel](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1777)，
    /// path 不是真实文件系统路径，stat 失败时缓存 `.failure` 表示"问就是 nil"，
    /// 下次同样命中直接返回 nil 不再 stat（避免 4w 行 × 每帧重 stat）。
    ///
    /// 缓存 key 是绝对路径；生命周期与扫描会话绑定，[startScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 在切换 root 时一并 removeAll，避免跨扫描泄漏陈旧 mtime。
    private enum MtimeFallbackResult: Sendable {
        case found(Date)
        case failure
    }
    private var mtimeFallbackCache: [String: MtimeFallbackResult] = [:]

    /// 给目录路径 `path` 取一次磁盘 inode mtime；命中缓存直接返回。
    /// 该函数只读 file 系统，不写状态，故无需 @MainActor 隔离能保证（ScanCoordinator
    /// 本身就是 @MainActor），但 `lstat` 的耗时（亚毫秒级）和调用频率（每条可见行最多
    /// 一次，命中缓存后零成本）权衡下来落在主线程也可接受——避免引入 actor hop。
    private func resolveDirMtimeFallback(forPath path: String) -> Date? {
        if let cached = mtimeFallbackCache[path] {
            switch cached {
            case .found(let d): return d
            case .failure:      return nil
            }
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let d = attrs[.modificationDate] as? Date {
            mtimeFallbackCache[path] = .found(d)
            return d
        }
        mtimeFallbackCache[path] = .failure
        return nil
    }

    /// **Step 9a / 2026-06**：cache 写入版本号统一推进入口。
    /// 所有改 [treeChildrenCache](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 的位置（写新键 / 删旧键 / removeAll / patch-by-prune）必须串到这里。
    /// 用 `&+=` 让计数器溢出时回卷而非 trap；订阅者只关心"变没变"，绝对值无意义。
    @inline(__always)
    private func bumpChildrenCacheVersion() {
        childrenCacheVersion &+= 1
        treeBrowser.bumpChildrenCacheVersion()
        notePruneSourceMutation()
    }

    /// v1.5.4：树形视图扁平化重算的"统一脏标"。
    /// [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 把 visibleRows 从 computed 改为 `@State flatRows: [FlatTreeRow]`（性能修复，
    /// 避免一次操作里 4 次重复递归整棵展开树），重建时机靠 `onChange(of: treeRevision)` 串。
    ///
    /// 所有可能改变"directChildren(of:_) 输出"的入口必须 `treeRevision &+= 1`：
    /// 1. [publishSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1873)（流式 ingest tick / finished 收尾）
    /// 2. `treeChildrenCache` 主线程写回（按需子树扫描完成）
    /// 3. [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1174)（删除成功后的状态同步）
    /// 4. 启动新扫描 / cancel 后的 cache 清空
    /// 5. [invalidateTreeCacheAfterScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1147)（扫描结束清 cache）
    ///
    /// 用 `&+=` 让计数器溢出时自然回卷而非 trap；view 端只关心"变没变"，绝对值无意义。
    ///
    /// v2026.06.21 perf：**移除 @Published**。
    /// 旧设计让 4 个 revision 都是 @Published mirror，导致 ScanCoordinator 任一 bump
    /// 都让 MainView body / sidebar / footer 全失效（dev 扫每秒 ≥5 次 body 重算 = 卡顿核心）。
    /// 现在 view 端走 `coordinator.treeBrowser.*`（独立 ObservableObject）订阅；
    /// 本字段保留为普通 `public private(set) var` 仅供单测 / 外部代码直接读数。
    public private(set) var treeRevision: UInt64 = 0

    /// Step 2 P0-2 / 2026-06：treeRevision 拆分 —— 结构性脏标。
    /// 含义：节点新增 / 节点删除 / 排序键变化 / cache 整轮失效。订阅这条信号的 view
    /// **必须**重建 flatRows（一次 O(N) 拍平 + verdict 计算）。
    ///
    /// 与 `tickRevision` 的边界由 [bumpStructuralRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) /
    /// [bumpTickRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 两个 helper 单点收敛 —— 任何代码不再直接写
    /// `treeRevision &+= 1`，避免漏判类别。
    ///
    /// v2026.06.21 perf：移除 @Published（同 treeRevision 的理由）。
    public private(set) var structuralRevision: UInt64 = 0

    /// v1.5.7：结构变化的 hint —— "本次 structuralRevision 升的根因是这些 path 被删了"。
    /// 仅在 [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1422-L1542)
    /// 路径上写一次，订阅方需在 onChange(structuralRevision) 同步段内调
    /// [consumeLastPrunedPaths()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 一次性取走（取后立刻置 nil），避免下次 unrelated bump 误用。
    /// TreeBrowserView 在 hint 非 nil 时走"只剔被删 path 子树"的增量 patch，
    /// 避免对万级目录整树 rebuild。
    private var lastPrunedPaths: [String]? = nil

    /// 删除成功后的本轮扫描 tombstone。扫描事件和异步树缓存可能在删除完成后
    /// 继续回调；这些路径必须在当前扫描会话内持续屏蔽，直到下一次新扫描从文件系统
    /// 真实状态重新建立数据源。
    /// 不可变删除路径索引。父子最小化、排序与 Set rehash 全部由 prune worker 在
    /// generic executor 完成；MainActor 只替换这一条引用。查询沿候选祖先链命中 Set，
    /// 不再随 tombstone root 数量线性退化。
    private var deletedPathTombstones = DeletedPathIndex.empty

    /// 后台 prune transaction 的扫描会话代际。任何 cancel / 新扫描都会刷新，
    /// 因而旧会话基于 COW 快照算出的 plan 永远不能覆盖新扫描状态。
    private var pruneStateGeneration = UUID()

    /// prune 读取的数据源 revision。扫描 ingest、节流发布、树缓存写回以及另一个
    /// prune commit 都会推进它；后台 plan 回来时 revision 不一致就重新取快照计算。
    /// 这条计数器不参与 UI 发布，只是 transaction 的 compare-and-swap 版本号。
    private var pruneSourceRevision: UInt64 = 0

    /// 后台 prune plan 计算期间的短事务栅栏。扫描事件在写入索引前会协作式让出，
    /// 避免 planner 基于 COW 快照计算时又不断产生新写入而饥饿重试；UI 主线程本身
    /// 不被阻塞，仍可正常渲染与处理手势。
    private var activePruneTransactionCount = 0

    /// 仅供聚焦测试确认 production planner 的真实执行线程与耗时；不参与 UI。
    private var lastPrunePlanRanOnMainThread: Bool?
    private var lastPrunePlanDurationNanoseconds: UInt64?
    private var lastPruneTombstoneMergeRanOnMainThread: Bool?
    private var lastPruneRetirementRanOnMainThread: Bool?
    private var lastPruneRetirementDurationNanoseconds: UInt64?

    /// 一次性消费 v1.5.7 prune hint：取走当前值并立刻清 nil。
    /// 设计目的：避免 TreeBrowserView onChange 闭包跨 runloop tick 读到陈旧值。
    public func consumeLastPrunedPaths() -> [String]? {
        let v = lastPrunedPaths
        lastPrunedPaths = nil
        return v
    }

    private func isDeletedTombstoned(_ candidate: String) -> Bool {
        deletedPathTombstones.matcher.contains(candidate)
    }

    /// 每个扫描入口统一调用的删除会话重置。旧索引通过 detached task 保留到后台，
    /// 避免大型 roots/Set 的最后一次释放落在 MainActor。
    private func resetDeletionStateForNewScanSession() {
        guard !deletedPathTombstones.matcher.roots.isEmpty else { return }
        // retirementWorker 在 swap 前先取得强引用；即使 MainActor 当前栈随即结束，旧
        // matcher 也不会成为本地变量的最后引用。下一 MainActor turn 再让 worker actor
        // 于 generic executor 清空，形成可证明的 ownership handoff。
        let retirementWorker = DeletedPathRetirementWorker(index: deletedPathTombstones)
        deletedPathTombstones = .empty
        Task { @MainActor in
            await Task.yield()
            await retirementWorker.retire()
        }
    }

    @inline(__always)
    private func notePruneSourceMutation() {
        pruneSourceRevision &+= 1
    }

    /// 扫描消费者在每个事件写入前经过该协作式栅栏。prune 的 O(N) 工作在 detached
    /// executor 上执行，这里只 yield，不占用 MainActor 帧预算。
    private func waitForPruneTransactionBarrier() async -> Bool {
        while activePruneTransactionCount > 0 {
            if Task.isCancelled { return false }
            await Task.yield()
        }
        return !Task.isCancelled
    }

    /// Step 2 P0-2 / 2026-06：treeRevision 拆分 —— 数值脏标（非结构性）。
    /// 含义：已有节点的 bytes / fileCount / isActive 变了，**节点拓扑没变**。订阅这条
    /// 信号的 view **不需要**重建 flatRows，只需让 RowView 内部读最新 bucket（通过其它
    /// @Published 入口，这里仅作"我又跳了一次"的通知）。
    ///
    /// publishSnapshot 流式 tick（0.4s/帧）只推这条；当帧检测到 `(buckets.count,
    /// dirIndex.count, fileLeaves.count)` 三元组变化时，由 helper 兜底升格为 structural。
    ///
    /// v2026.06.21 perf：移除 @Published（同 treeRevision 的理由）。
    public private(set) var tickRevision: UInt64 = 0

    /// 上一帧 publishSnapshot 时三个核心索引的 (count, count, count) 快照，用于 O(1)
    /// 判定"本帧是否新增节点"——任一计数变化即视为结构变化。
    private var lastIndexSnapshot: (buckets: Int, dirIndex: Int, fileLeaves: Int) = (0, 0, 0)

    /// 单点收敛：推进结构脏标。
    /// 同时推 `treeRevision`（兼容外部已订阅 treeRevision 的代码）和 `structuralRevision`。
    /// `tickRevision` 也顺带 +1 —— 任何 structural 都隐含一次 tick（一致性保证）。
    private func bumpStructuralRevision() {
        structuralRevision &+= 1
        tickRevision &+= 1
        treeRevision &+= 1
        treeBrowser.bumpStructuralRevision()
        notePruneSourceMutation()
    }

    /// 单点收敛：推进数值脏标。
    /// 仅在确认"节点拓扑没变（仅 buckets[k].bytes 累加之类）"时调用。
    ///
    /// v1.5 P2 滑动卡顿修复：
    /// 此前为了"兼容订阅者不死寂"也把 `treeRevision` 一起推 —— 但 `treeRevision` 是
    /// TreeBrowserView 的"结构变化"信号，每帧 +1 等于强制 TreeBrowserView rebuildFlatRows()
    /// + 整个主列表所有 RowView body 重算，是滑动期主帧丢的第二大头（review-swarm 命中 #5）。
    /// 现在只 tick 数值通道（`tickRevision` + `treeBrowser.bumpTickRevision()`），
    /// 树形视图按"显式 structural"通道感知拓扑变化，纯 bytes 累加不再打扰它。
    private func bumpTickRevision() {
        tickRevision &+= 1
        // v2026.06.21 perf：保持与 [TreeBrowserStore.bumpTickRevision](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift#L67-L70)
        // 完全对齐（store 端 tick 也会推 treeRevision 作老订阅者兼容），
        // 否则 [TreeBrowserStoreTests.test_扫描期间coord的mirror与store同步](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/TreeBrowserStoreTests.swift#L96-L99)
        // 会判 coord.treeRevision 落后 store.treeRevision 一个 tick。
        treeRevision &+= 1
        treeBrowser.bumpTickRevision()
        notePruneSourceMutation()
    }

    /// Step 3 P0-3 / 2026-06：bucket cachedVerdict 命中率计数器。
    /// publishSnapshot 走 cache 路径时，`miss = 首次计算并写回`，`hit = 直接读现有值`。
    /// 仅作运行期遥测与测试观察用，**不参与 @Published**（不触发 view 更新）。
    private var verdictCacheHits: Int = 0
    private var verdictCacheMisses: Int = 0

    /// v1.5 P1-C：publishSnapshot 流式帧"排序结果"缓存。
    /// 不变量：扫描中 ingest 只 add 不 remove bucket（buckets.count 单调增），
    /// 同时白名单 whitelistSnapshot 在帧间一般不变 ——
    /// 所以当 `(buckets.count, whitelistSnapshot.count)` 与上一帧相同时，
    /// 流式帧（finished=false）的 sorted id 序（path 字典序）必然与上一帧完全一致，
    /// 可直接复用，跳过 O(N log N) 排序。
    /// finished=true 帧走用户 sort，不参与缓存。
    private var lastStreamSortedIds: [String] = []
    private var lastStreamSortCacheKey: (bucketCount: Int, whitelistCount: Int) = (-1, -1)

    /// 测试观察口：暴露 verdict cache 命中统计。
    /// 仅 internal —— 同 module 的测试代码可读；外部 framework 不可见。
    /// 用于 [BucketVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/BucketVerdictCacheTests.swift) 验证 P0-3 缓存生效。
    func verdictCacheStatsForTesting() -> (hits: Int, misses: Int) {
        (verdictCacheHits, verdictCacheMisses)
    }

    /// 测试触发口：在已扫完的状态下手动再触发一次 publishSnapshot。
    /// 用途：fake home fixture 太小时，扫描可能只跑一帧 publishSnapshot（150ms 节流没触发流式帧），
    /// 测试看不到 cache hit。该方法让 [BucketVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/BucketVerdictCacheTests.swift) 能在确定的 buckets 状态下
    /// 再调一次 publishSnapshot 验证"第二次访问 = cache hit"。生产路径不调它。
    func forcePublishSnapshotForTesting(categoryID: String = "_test_") {
        publishSnapshot(categoryID: categoryID, finished: false)
    }

    /// UI 专用的工作计时口径。
    ///
    /// `snapshot.elapsed` 只会在扫描数据发布时更新；勘察、聚合、一次性规则扫描等阶段可能
    /// 长时间没有新 snapshot，若 UI 直接读它就会出现“有些入口计时动、有些入口停在 0”的错觉。
    /// 这里把“工作计时”从“扫描结果发布”里解耦：扫描中按会话起点实时计算，结束后回到最终快照。
    public func elapsedForDisplay(referenceDate: Date = Date()) -> TimeInterval {
        guard isScanning, startedAt > .distantPast else {
            return max(0, snapshot.elapsed)
        }
        return max(0, max(snapshot.elapsed, referenceDate.timeIntervalSince(startedAt)))
    }

    /// v1.0 T4：大文件叶子集合。
    /// 仅当 `largeFileMinBytes > 0` 时才会被填充（避免普通扫描浪费内存）。
    /// 每条记录原样保留 path / bytes / mtime，让 `largeFiles(...)` 能按多种 sortKey
    /// 自由切换排序，**无需重扫**。
    public struct LargeFileLeaf: Sendable, Hashable {
        public let path: String
        public let bytes: Int64
        public let logicalBytes: Int64
        public let modificationDate: Date?

        public init(path: String,
                    bytes: Int64,
                    logicalBytes: Int64? = nil,
                    modificationDate: Date?) {
            self.path = path
            self.bytes = bytes
            self.logicalBytes = logicalBytes ?? bytes
            self.modificationDate = modificationDate
        }
    }
    private var largeFileLeaves: LargeFileLeafTopNHeap = LargeFileLeafTopNHeap(capacity: ScanCoordinator.largeFileTopNCapacity)
    /// **Step 9c / 2026-06**：Top-N 容量上限（绝对硬顶）。
    /// 选 1000：
    ///   - LargeFilesView 本就只渲染 limit=200，N=1000 留 5×缓冲量给排序切换。
    ///   - 内存：1000 × ~64B（path/bytes/mtime）= ~64KB，常驻可忽略。
    ///   - 插入复杂度：O(log 1000) ≈ 10 次比较，远小于原"无脑 append + 末尾 N log N 排序"。
    public static let largeFileTopNCapacity: Int = 1000
    /// compactAfterScanPreservingCache 之后的"二级缓存"。
    /// 把 Top N 大文件保留到这，UI 重进大文件页时仍可同步渲染——
    /// 既享受了主索引被释放的内存收益，又不让 UI 出现空白回退。
    /// `nil` 表示尚未 compact 或主路径仍可用；非 nil 表示 largeFileLeaves 已清空，UI 应读这里。
    private var compactedLargeFileTopN: [LargeFileLeaf]?
    /// 当前扫描会话中"采集大文件的下限"。0 表示不采集。
    private var largeFileMinBytes: Int64 = 0
    /// 大文件入口只需要文件级 Top-N，不需要主列表 bucket / 树形索引 / Safety verdict 行。
    /// 保持这个边界能避免百万级文件扫描把 MainActor 拖进通用结果树构建。
    private var largeFileTopNOnlyScan: Bool = false

    private var totalBytes: Int64 = 0
    private var scannedFiles: Int = 0
    private var startedAt: Date = .distantPast

    /// v1.3：扫描吞吐 EWMA 速率（bytes/s）。在 publishSnapshot 时基于
    /// (totalBytes - lastSampleBytes) / (now - lastSampleAt) 增量采样并 EWMA 平滑：
    ///   rate' = α × instant + (1-α) × rate，α = 0.3 让短期跳变不至于把数字拉飞，
    ///   也让长期趋势能跟得上。
    private var bytesPerSecondEMA: Double = 0
    private var lastSampleAt: Date?
    private var lastSampleBytes: Int64 = 0

    /// v1.3：本次扫描是否能给 ETA。仅当 category.kind == .fullDisk 且 volumeSnapshot 已知时为 true，
    /// 此时"剩余字节" = volumeSnapshot.usedBytes - totalBytes 是个有意义的上限。
    /// 推荐扫描 / 自定义路径不报 ETA（不知道总量），UI 显示"估算中…"。
    private var etaEligible: Bool = false

    /// v1.3.x：用户反馈"扫描感觉很久也没 ETA"——给推荐扫描 / 自定义根扫描提供 ETA 分母。
    ///
    /// 与 [etaEligible](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L195-L195)
    /// 互补：整盘扫用 `volumeSnapshot.usedBytes` 作为分母（无需采样），推荐/自定义扫
    /// 在 [scanRecommended](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L331-L331)
    /// 启动时**异步**用 [TreeSizeEstimator.estimate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/TreeSizeEstimator.swift)
    /// 快速 walk 5 个根的元数据（不分类、不去重 hardlink），写到这个字段。
    /// nil = 还在估算 / 无法估算（沙盒挡住），UI 显示"估算中…"。
    @Published public private(set) var expectedTotalBytes: Int64? = nil

    /// 清理页主值固定使用 macOS 的 on-disk allocated size。
    ///
    /// 这是 System Settings「储存空间」以及 `du` 的清理语义；不能让用户把整页切到
    /// sparse 文件的虚拟长度，否则 Docker.raw 会再次显示出超过磁盘容量的“可清理”总量。
    /// `logicalSize` 仍随 RowItem 保留，只在详情中像 Finder「显示简介」一样作为副值展示。
    @inline(__always)
    private func displayBytes(of node: FSNode) -> Int64 {
        node.allocatedSize
    }

    /// v1.3.z 性能开关：是否在 ingest 时构建多层下钻索引（dirIndex / childEdges / fileLeaves）。
    /// - true：扫描期就维护好整棵树索引，TreeBrowserView 进入即可同步渲染。
    ///   **代价**：大目录（70 GB / 72 万文件）下，主线程会被 576 万次祖先上溯字典写入压住 ~5 分钟。
    /// - false（v1.3.zz 起的默认）：跳过深索引维护；TreeBrowserView 通过后台按需扫描异步下钻
    ///   （首次 cache miss → 后台 Task 扫当前目录 → 回填 cache → SwiftUI 重新渲染）。
    /// 切换不影响：buckets（主列表）、totalBytes、scannedFiles、largeFileLeaves。
    public var enableTreeDeepIndex: Bool = false

    /// Step 10a / 2026-06：系统探针 SSOT。
    /// fdaStatus / volumeSnapshot / swapSnapshot 三个字段的写入路径全部经此 store；
    /// ScanCoordinator 自身保留 @Published mirror（向后兼容）。
    public let systemProbe: SystemProbeStore

    /// Step 10b / 2026-06：树形浏览状态 SSOT 接口外壳。
    /// 让新代码 / 单测可以单独订阅 `coordinator.treeBrowser.structuralRevision` 等，
    /// 不再依赖整个 ScanCoordinator.objectWillChange。
    /// ScanCoordinator 自身保留对应字段作 @Published mirror（向后兼容）；
    /// bumpStructuralRevision / bumpTickRevision / bumpChildrenCacheVersion
    /// 三个 helper 内部双写到 store 与 mirror 保证一致。
    public let treeBrowser: TreeBrowserStore
    private static let fullDiskDataRootPath = Firmlinks.recommendedDataVolumeRoot.path
    private let fullDiskFirmlinkRules: [(dataPrefix: String, publicPrefix: String)]

    public init(vendors: [VendorRule] = [], home: String = NSHomeDirectory(),
                enableTreeDeepIndex: Bool = false,
                whitelistStore: WhitelistStore = .shared) {
        self.vendors = vendors
        self.home = home
        self.enableTreeDeepIndex = enableTreeDeepIndex
        self.whitelistStore = whitelistStore
        self.fullDiskFirmlinkRules = Self.makeFullDiskFirmlinkRules()
        // 性能关键：vendors 在 init 时已确定，扫描期不会变。
        // 一次构建 trie 复用整个生命周期，避免 publishSnapshot 每帧 N 次重建。
        self.trie = VendorTrie.build(vendors: vendors, home: home)
        // Step 10a / 2026-06：抽 SystemProbeStore 持有 fdaStatus/volumeSnapshot/swapSnapshot。
        // store 的 init 内部就会探一次三个值。
        let probe = SystemProbeStore(home: home)
        self.systemProbe = probe
        // Step 10b / 2026-06：抽 TreeBrowserStore 提供 cache / revision 的 SSOT 接口外壳。
        // ScanCoordinator 上同名字段保留作 @Published mirror（向后兼容）；
        // bump* helper 双写保证 store 与 mirror 一致。
        self.treeBrowser = TreeBrowserStore()
        // 向后兼容 mirror：保留 ScanCoordinator 上 @Published 字段供老 view / 老测试读取，
        // 写入唯一来源是 systemProbe。
        self.fdaStatus = probe.fdaStatus
        self.volumeSnapshot = probe.volumeSnapshot
        self.swapSnapshot = probe.swapSnapshot
    }

    /// v1.3：用户从系统设置回到 App 后调用，重探 FDA 状态与卷容量。
    /// 推荐绑定到 `.onAppear` 与"打开系统设置"按钮的 `NSApplication.didBecomeActive` 回调。
    /// Step 10a / 2026-06：写入唯一来源 [systemProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L474-L474)，
    /// 之后同步回 mirror 字段。
    public func refreshFDAStatus() {
        systemProbe.refreshFDAStatus()
        fdaStatus = systemProbe.fdaStatus
        volumeSnapshot = systemProbe.volumeSnapshot
        swapSnapshot = systemProbe.swapSnapshot
    }

    /// v1.3：每次扫描完成 / 删除完成后调用，重探卷容量（FDA 不变就不动）。
    /// Step 10a / 2026-06：写入唯一来源 [systemProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L474-L474)，
    /// 之后同步回 mirror 字段。
    public func refreshVolumeCapacity() {
        systemProbe.refreshVolumeCapacity()
        volumeSnapshot = systemProbe.volumeSnapshot
        swapSnapshot = systemProbe.swapSnapshot
    }

    public func cancel() {
        if isScanning || scanTask != nil {
            GSYLog.notice(.operation, "scan.cancel activeCategory=\(activeCategoryID ?? "nil") root=\(currentRootPath ?? "nil")")
        }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration = UUID()
        isScanning = false
        scanPhase = .idle
        // v1.3：cancel 同时清 activeCategoryID，让旧 stream 残留事件能被自检识别为"过期"并丢弃。
        activeCategoryID = nil
        // v1.3 review-fix：cancel 必须 reset snapshot 与 currentRootPath，
        // 否则 isPristine 判定（rows.isEmpty + scannedFileCount==0）失真，
        // statusBar 会把"扫到一半被打断"误显示成"还未扫描"。
        // 同时把 permissionDeniedPaths / tccProtectedSkippedPaths / lastError 一起清掉，
        // 避免上一轮 banner 漂到下一类目。
        snapshot = .empty
        currentRootPath = nil
        resetIncompleteEvidence()
        lastError = nil
        terminalFailure = nil
        largeFileTopNOnlyScan = false
        // v1.3：cancel 时同时清掉多根扫描进度，避免 statusBar 上残留旧根的"扫描中"行。
        resetPerRootPublished()
        perRootStaging = [:]
        // v1.3：标记本次状态为"用户主动停止"，让 statusBar 显示"已停止"而非"还未扫描"。
        wasCancelled = true
        treeFetchGeneration = UUID()
        pruneStateGeneration = UUID()
        notePruneSourceMutation()
    }

    public func scan(category: ScanCategory, includeHidden: Bool = true,
                     largeFileMinBytes: Int64 = 0) {
        cancel()
        // v1.3：cancel() 在上面把 wasCancelled 置 true，但本次是新扫描入口而非"停止"，立刻清回 false
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        buckets.removeAll(keepingCapacity: true)
        // Step 3 P0-3：buckets 整轮清空 → bucket 上的 cachedVerdict 也跟着消失。
        // 但独立维护的命中率计数器需要显式归零，否则跨会话累计无意义。
        verdictCacheHits = 0
        verdictCacheMisses = 0
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        // 清掉上一轮的 TreeBrowserView 按需子树缓存，避免新扫描看到旧展开结果。
        treeChildrenCache.removeAll(keepingCapacity: true)
        bumpChildrenCacheVersion()
        treeChildrenInFlight.removeAll(keepingCapacity: true)
        // v2026.06.20：mtime 兜底缓存也跟随会话清零——
        // 用户两次扫描之间完全可能在 Finder/CLI 改文件，旧 mtime 必须作废。
        mtimeFallbackCache.removeAll(keepingCapacity: true)
        bumpStructuralRevision()
        largeFileLeaves.removeAll(keepingCapacity: true)
        // M3：新 scan 启动必须清掉上一轮 compact 缓存的 Top N，避免新会话期间
        // largeFiles(...) 错误命中旧 cache（largeFileLeaves 当前空 + cache 非空）。
        compactedLargeFileTopN = nil
        // v1.3：清掉上一轮的 ingest 时间戳，避免新扫描启动瞬间旧 bucket 仍被判 active
        lastIngestAt.removeAll(keepingCapacity: true)
        let topNOnlyLargeFileScan = category.kind == .largeFiles
        self.largeFileTopNOnlyScan = topNOnlyLargeFileScan
        self.largeFileMinBytes = max(0, largeFileMinBytes)
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        // v1.3：ETA 采样状态归零；仅整盘扫给 ETA（其它扫描不知道总量）。
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        // v1.3.x：所有非整盘扫描也开 ETA 闸门——是否真的能出 ETA 取决于 expectedTotalBytes 是否估出来。
        etaEligible = true
        expectedTotalBytes = nil
        currentRootPath = category.rootPath
        snapshot = ScanSnapshot(categoryID: category.id, rows: [], totalBytes: 0,
                                scannedFileCount: 0, isFinished: false, elapsed: 0)
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        // v1.3：cancel() 把 activeCategoryID 清空了，本次 scan 入口重新打上当前 token；
        // runScan 内每个事件先校验 `categoryID == activeCategoryID`，过期 stream 残留事件会被自动丢弃。
        activeCategoryID = category.id

        // 白名单是最高优先级边界：必须先拿到完整快照，再让 scanner 产生第一个 node。
        // 旧实现把快照加载与扫描并发启动，首帧可能短暂暴露甚至选中已加白路径。
        whitelistSnapshot = []

        let rootURL = category.rootURL
        let categoryID = category.id
        let generation = scanGeneration
        GSYLog.notice(.flow, "scan.start category=\(category.id) root=\(rootURL.path) includeHidden=\(includeHidden) largeFileMinBytes=\(largeFileMinBytes)")

        treeFetchGeneration = UUID()

        // v1.3.x：非整盘扫描启动 TreeSizeEstimator 给 ETA 分母；整盘扫直接用 volumeSnapshot.usedBytes
        // （在 publishSnapshot 内部判断），无需再 walk 一遍。
        if category.kind != .fullDisk {
            Task { [weak self] in
                let estimated = await TreeSizeEstimator.estimate(roots: [rootURL], timeout: 4.0)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.ownsScan(categoryID: categoryID, generation: generation) else { return }
                    self.expectedTotalBytes = estimated
                }
            }
        } else if let used = volumeSnapshot?.usedBytes {
            // 整盘扫直接把 used 当 expectedTotalBytes 暴露给 UI，统一口径
            self.expectedTotalBytes = used
        }
        // v1.0 T5：整盘扫描时强制开启 staySingleVolume，避免误吃外接卷 / 网络挂载点把扫描时间打爆
        let isFullDisk = category.kind == .fullDisk
        // v1.3 P0-C：整盘扫描节点量 100k+，deep index 在 MainActor ingest 内做
        // 祖先回溯 + childEdges/dirIndex/fileLeaves 写入会瞬间打爆主线程帧预算。
        // 整盘永远走按需子树扫描路径（同步表面 + 后台填充）。
        if isFullDisk && enableTreeDeepIndex {
            GSYLog.info(.scan, "ScanCoordinator 整盘扫描强制关闭 enableTreeDeepIndex（防止 MainActor ingest burst）")
            enableTreeDeepIndex = false
        }
        let whitelistStore = self.whitelistStore
        scanTask = Task { [weak self] in
            let whitelist = await whitelistStore.snapshotPaths()
            guard let self,
                  self.ownsScan(categoryID: categoryID, generation: generation) else { return }
            self.whitelistSnapshot = whitelist
            await self.runScan(rootURL: rootURL, categoryID: categoryID, generation: generation,
                               includeHidden: includeHidden, staySingleVolume: isFullDisk,
                               largeFileTopNOnly: topNOnlyLargeFileScan)
        }
    }

    /// v1.0 T5：整盘扫描便捷入口 —— 等价于 `scan(category: .fullDisk)`。
    /// MainView 路径栏输入 `/` 回车 / 整盘扫描按钮 都走这个 API，避免在多处硬编码 `ScanCategory.fullDisk`。
    public func scanFullDisk(includeHidden: Bool = true) {
        scan(category: .fullDisk, includeHidden: includeHidden)
    }

    /// M4-T2：版本化收集根扫描入口。
    ///
    /// 调用 [KnownVersionedRoots.scanAllWithEvidence(home:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift)
    /// 拿到所有可回收的旧版本子目录（Xcode DeviceSupport / JetBrains Toolbox 等），
    /// 直接构造 [RowItem](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift)
    /// 发布一个 finished snapshot 给 UI。每个候选仍使用独立 BulkScanner 会话计量，
    /// 但不把海量 node materialize 到主列表；主线程只接收最终 rows 和完整性证据。
    ///
    /// categoryID 固定 `"developer.versioned"`，方便上层按 id 区分。
    /// 每条 Hit 的物理/逻辑大小、文件数、permissionDenied/TCC/partial 都来自同一
    /// BulkScanner 扫描会话。任何不完整候选仍可展示，但会以 `.accessDenied` 锁定，
    /// 且其证据同步进入最终 TrashPipeline 预检，绝不能移动未完整扫描的父目录。
    ///
    /// 与 [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
    /// 的关系：每条命中仍然走 `engine.evaluate(path:trie:home:)`，让 forbid 路径
    /// 在 UI 上以 lock 形式显示而非被静默删除（与主扫描行为对齐）。
    public func scanKnownVersionedRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        cancel()
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        buckets.removeAll(keepingCapacity: true)
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        largeFileLeaves.removeAll(keepingCapacity: true)
        compactedLargeFileTopN = nil
        lastIngestAt.removeAll(keepingCapacity: true)
        largeFileTopNOnlyScan = false
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        etaEligible = false
        expectedTotalBytes = nil
        // v2026.06.21：用专用 sentinel 而非 home.path，让 TreeBrowserView 走
        // [synthesizeVersionedTopLevel] 把 snapshot.rows 合成树形顶层；
        // 否则 directChildren(of: home.path) 在 childEdges/store 都找不到子项，
        // 树形视图永远空（用户反馈"清单 28 文件，树形为空"）。
        let categoryID = "developer.versioned"
        currentRootPath = ScanCoordinator.versionedRootSentinelPath
        snapshot = ScanSnapshot(categoryID: categoryID, rows: [], totalBytes: 0,
                                scannedFileCount: 0, isFinished: false, elapsed: 0)
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        whitelistSnapshot = []
        activeCategoryID = categoryID
        let generation = scanGeneration
        GSYLog.notice(.flow, "scan.versioned.start home=\(home.path)")

        // v2026.06.21 P0：原本 KnownVersionedRoots.scanAll + 逐 hit directorySize 的全
        // 同步遍历直接挂在 @MainActor 上跑，Xcode DeviceSupport / JetBrains Toolbox
        // 这类 GB 级目录会让主线程冻结到秒级（命中 30 条 × 每条 GB 全递归读 fileSize）。
        // 改用 Task.detached 派到默认 executor 做 IO，结尾 await MainActor.run 一次性
        // 回主线程发布 snapshot，参考 [scanDeveloper L1142-L1149] 同款模式，并保留
        // activeCategoryID 防过期检查避免用户中途切走时覆盖新分类的 snapshot。
        let engineCopy = engine
        let trieRef = trie
        let homeStr = self.home
        let startedAtCopy = startedAt
        let whitelistStore = self.whitelistStore
        let scanOptions = ScanOptions(
            includeHidden: true,
            includePackageContents: true,
            followSymlinks: false,
            followFirmlinks: false,
            dedupByInode: true,
            staySingleVolume: true,
            mediaAware: true,
            respectTCCSkipList: fdaStatus == .denied
        )
        scanTask = Task.detached { [weak self] in
            let whitelist = await whitelistStore.snapshotPaths()
            if Task.isCancelled { return }
            let discovery = KnownVersionedRoots.scanAllWithEvidence(home: home)
            let hits = discovery.hits.filter {
                !Self.isWhitelisted($0.url.path, in: whitelist)
            }
            var rows: [RowItem] = []
            rows.reserveCapacity(hits.count)
            var totalAccum: Int64 = 0
            var fileCountAccum = 0
            // 发现阶段也是删除正确性证据的一部分：若某个版本集无法枚举或读取
            // metadata，不能把兼容 API 的空 hits 解释为“已完整扫描且没有旧版本”。
            // 这里保留精确 issue.path：分组发现只会锁住失败产品组，不会把其它
            // 已完整计量的兄弟组扩大成不可删。
            var incompleteIssues = Set(discovery.incompleteIssues)
            for hit in hits {
                if Task.isCancelled { return }
                let (verdict, rejection, vendor) = engineCopy.evaluate(path: hit.url.path,
                                                                       trie: trieRef, home: homeStr)
                guard let measurement = await Self.measureVersionedRoot(
                    at: hit.url,
                    options: scanOptions
                ) else {
                    return
                }
                incompleteIssues.formUnion(measurement.incompleteIssues)
                totalAccum &+= measurement.allocatedBytes
                fileCountAccum &+= measurement.fileCount
                let localizedDisplay = String(localized: String.LocalizationValue(hit.displayName), bundle: .module)
                let composedTitle: String
                if let groupKey = hit.groupKey, !groupKey.isEmpty {
                    composedTitle = "\(localizedDisplay) · \(groupKey) · \(hit.versionName)"
                } else {
                    composedTitle = "\(localizedDisplay) · \(hit.versionName)"
                }
                let scanWasIncomplete = !measurement.deletionDeniedPaths.isEmpty
                let effectiveVerdict: SafetyVerdict = scanWasIncomplete && verdict != .forbid
                    ? .forbid
                    : verdict
                let effectiveRejection: SafetyRejection = scanWasIncomplete && verdict != .forbid
                    ? .accessDenied
                    : rejection
                rows.append(RowItem(
                    id: hit.url.path,
                    url: hit.url,
                    title: composedTitle,
                    isDirectory: true,
                    bytes: measurement.allocatedBytes,
                    logicalBytes: measurement.logicalBytes,
                    fileCount: measurement.fileCount,
                    verdict: effectiveVerdict,
                    rejection: effectiveRejection,
                    vendorName: vendor?.name,
                    vendorNote: "retain: \(hit.retainedLatest)",
                    isActive: false,
                    modificationDate: nil
                ))
            }
            let sortedRows = rows.sorted { $0.bytes > $1.bytes }
            let rowsCount = rows.count
            let totalCaptured = totalAccum
            let fileCountCaptured = fileCountAccum
            let incompleteIssuesCaptured = incompleteIssues.sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                if $0.reason != $1.reason { return $0.reason.rawValue < $1.reason.rawValue }
                return ($0.stage?.rawValue ?? "") < ($1.stage?.rawValue ?? "")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 防过期：用户在后台扫描期间切到别的分类入口时，activeCategoryID 已被
                // 后续 scan() 改写；本次结果直接丢弃，不污染新分类的 snapshot。
                guard self.ownsScan(categoryID: categoryID, generation: generation) else { return }
                self.whitelistSnapshot = whitelist
                self.replaceIncompleteEvidence(with: incompleteIssuesCaptured)
                self.totalBytes = totalCaptured
                self.scannedFiles = fileCountCaptured
                self.snapshot = ScanSnapshot(
                    categoryID: categoryID,
                    rows: sortedRows,
                    totalBytes: totalCaptured,
                    scannedFileCount: fileCountCaptured,
                    isFinished: true,
                    elapsed: Date().timeIntervalSince(startedAtCopy),
                    isComplete: incompleteIssuesCaptured.isEmpty
                )
                self.lastFinishedCategoryID = categoryID
                self.isScanning = false
                self.scanPhase = .idle
                self.scanTask = nil
                self.activeCategoryID = nil
                // **Review fix-soon #3，2026-06-15**：scanKnownVersionedRoots 会改变 snapshot
                // 里 "developer.versioned" 的行集合（特别是 PR 新增的 Android SDK / JetBrains
                // 分组规则上线后，老 cache 里同路径的子项可能与新分组结果不一致）。
                // 与 [scan(category:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1495-L1497)
                // 走完后调 [invalidateTreeCacheAfterScan()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1495-L1497)
                // 的行为对齐：本入口同样清掉 treeChildrenCache 并 bump childrenCacheVersion，
                // 让 TreeBrowserView 不会用旧扫描的展开缓存误展示已被
                // 新规则重新分组的版本子目录。
                self.invalidateTreeCacheAfterScan()
                self.refreshVolumeCapacity()
                GSYLog.notice(.flow,
                              "scan.versioned.finish rows=\(rowsCount) files=\(fileCountCaptured) totalBytes=\(totalCaptured) complete=\(self.snapshot.isComplete) discoveryIssues=\(discovery.incompleteIssues.count) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAtCopy)))")
            }
        }
    }

    /// 常见应用缓存扫描入口。
    ///
    /// 这里不是从某个大根目录递归构建树，而是消费 `vendors.yaml` 里审计过的
    /// `category=common_app_cache` 路径规则，做"规则命中列表"。因此：
    /// - IO 和目录计量全部在后台 executor 完成；
    /// - 主线程只在开始/结束各发布一次状态，不产生扫描中列表抖动；
    /// - 发布前仍走 SafetyEngine，保证硬禁区不会被规则误写绕过。
    public func scanCommonAppCaches(
        includeConfirm: Bool = true,
        scannerOptions: CommonAppCacheScanner.Options? = nil
    ) {
        cancel()
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        buckets.removeAll(keepingCapacity: true)
        verdictCacheHits = 0
        verdictCacheMisses = 0
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        treeChildrenCache.removeAll(keepingCapacity: true)
        bumpChildrenCacheVersion()
        treeChildrenInFlight.removeAll(keepingCapacity: true)
        mtimeFallbackCache.removeAll(keepingCapacity: true)
        bumpStructuralRevision()
        largeFileLeaves.removeAll(keepingCapacity: true)
        compactedLargeFileTopN = nil
        lastIngestAt.removeAll(keepingCapacity: true)
        largeFileTopNOnlyScan = false
        self.largeFileMinBytes = 0
        resetPerRootPublished()
        perRootStaging = [:]
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        etaEligible = false
        expectedTotalBytes = nil
        currentRootPath = ScanCoordinator.commonAppCacheSentinelPath
        snapshot = ScanSnapshot(categoryID: ScanCoordinator.commonAppCacheCategoryID,
                                rows: [],
                                totalBytes: 0,
                                scannedFileCount: 0,
                                isFinished: false,
                                elapsed: 0)
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        devArtifactDidTruncate = false
        devArtifactDidTimeout = false
        activeCategoryID = ScanCoordinator.commonAppCacheCategoryID
        whitelistSnapshot = []
        treeFetchGeneration = UUID()
        let generation = scanGeneration

        let categoryID = ScanCoordinator.commonAppCacheCategoryID
        let activeStartedAt = startedAt
        let vendorsCopy = vendors
        let engineCopy = engine
        let trieRef = trie
        let homeStr = home
        let homeURL = URL(fileURLWithPath: homeStr, isDirectory: true)
        let included: Set<SafetyVerdict> = includeConfirm ? [.safe, .confirm] : [.safe]
        var options = scannerOptions ?? CommonAppCacheScanner.Options()
        options.includedVerdicts = included
        let whitelistStore = self.whitelistStore
        let detector = commonAppCacheDetector
        GSYLog.notice(.flow,
                      "scan.common_app_cache.start rules=\(vendorsCopy.filter { $0.category == "common_app_cache" }.count) includeConfirm=\(includeConfirm)")

        scanTask = Task.detached { [weak self] in
            let whitelist = await whitelistStore.snapshotPaths()
            if Task.isCancelled { return }
            let standardRules = Self.standardInstalledAppCacheRules()
            let scanResult = detector(vendorsCopy + standardRules, homeURL, options)
            if scanResult.wasCancelled { return }
            let hits = scanResult.hits
            let incompletePaths = scanResult.deletionProtectedPaths
            var rows: [RowItem] = []
            rows.reserveCapacity(hits.count)
            var totalAccum: Int64 = 0
            var countAccum = 0
            var seenPaths = Set<String>()

            for hit in hits {
                if Task.isCancelled { return }
                let normalizedPath = hit.url.standardizedFileURL.path
                guard !Self.isWhitelisted(normalizedPath, in: whitelist) else { continue }
                guard seenPaths.insert(normalizedPath).inserted else { continue }
                let (evaluatedVerdict, rejection, vendor) = engineCopy.evaluate(path: hit.url.path,
                                                                                trie: trieRef,
                                                                                home: homeStr)
                let isIncomplete = incompletePaths.contains {
                    Self.pathsOverlap(normalizedPath, $0)
                }
                let rowBytes = hit.sizeBytes
                totalAccum &+= rowBytes
                countAccum &+= hit.entryCount
                rows.append(RowItem(
                    id: hit.url.path,
                    url: hit.url,
                    title: hit.ruleName,
                    isDirectory: hit.isDirectory,
                    bytes: rowBytes,
                    logicalBytes: hit.logicalSizeBytes,
                    fileCount: hit.entryCount,
                    verdict: isIncomplete ? .forbid : evaluatedVerdict,
                    rejection: isIncomplete ? .accessDenied : rejection,
                    vendorName: vendor?.name ?? hit.ruleName,
                    vendorNote: hit.reason ?? hit.source,
                    runningBundleIDPrefix: hit.bundleIDPrefix,
                    isActive: false,
                    modificationDate: Self.modificationDate(at: hit.url)
                ))
            }

            let sortedRows = rows.sorted { lhs, rhs in
                if lhs.bytes == rhs.bytes { return lhs.id < rhs.id }
                return lhs.bytes > rhs.bytes
            }
            let rowsCount = sortedRows.count
            let totalCaptured = totalAccum
            let fileCountCaptured = countAccum
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.ownsScan(categoryID: categoryID, generation: generation) else { return }
                self.whitelistSnapshot = whitelist
                // CommonAppCacheScanner 的 partial bytes 只用于展示，不能作为“可删”证明。
                // 将 open/deadline/maxEntries 等所有不完整路径并入现有 request-scoped
                // 删除硬拒绝集合；TrashPipeline 的祖先/后代重叠检查会同时拦住父根。
                let structuredIssues = scanResult.incompletePaths.map(
                    Self.commonAppCacheIncompleteIssue
                )
                self.replaceIncompleteEvidence(with: structuredIssues)
                for issue in scanResult.incompletePaths {
                    GSYLog.warning(.scan,
                                   "scan.common_app_cache.incomplete path=\(issue.path) reason=\(issue.reason.rawValue)")
                }
                self.totalBytes = totalCaptured
                self.scannedFiles = fileCountCaptured
                self.snapshot = ScanSnapshot(
                    categoryID: categoryID,
                    rows: sortedRows,
                    totalBytes: totalCaptured,
                    scannedFileCount: fileCountCaptured,
                    isFinished: true,
                    elapsed: Date().timeIntervalSince(activeStartedAt),
                    isComplete: scanResult.isComplete
                )
                // partial 也是可展示、可排序的终态；可信度由 snapshot.isComplete 单独表达。
                // 这样排序重发布会命中同一终态，同时必须原样保留 partial 语义。
                self.lastFinishedCategoryID = categoryID
                self.isScanning = false
                self.scanPhase = .idle
                self.scanTask = nil
                self.activeCategoryID = nil
                self.invalidateTreeCacheAfterScan()
                self.refreshVolumeCapacity()
                GSYLog.notice(.flow,
                              "scan.common_app_cache.finish rows=\(rowsCount) totalBytes=\(totalCaptured) entries=\(fileCountCaptured) complete=\(scanResult.isComplete) incompletePaths=\(scanResult.incompletePaths.count) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(activeStartedAt)))")
            }
        }
    }

    nonisolated private static func standardInstalledAppCacheRules() -> [VendorRule] {
        let appsPath = "/Applications"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: appsPath) else { return [] }

        var rules: [VendorRule] = []
        rules.reserveCapacity(names.count)
        for name in names where name.hasSuffix(".app") {
            if Task.isCancelled { return [] }
            let appURL = URL(fileURLWithPath: appsPath).appendingPathComponent(name)
            guard let meta = try? AppMetadata.read(appURL: appURL) else { continue }
            let bundleID = meta.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else { continue }
            let paths = [
                "~/Library/Caches/\(bundleID)",
                "~/Library/Containers/\(bundleID)/Data/Library/Caches",
                "~/Library/HTTPStorages/\(bundleID)"
            ].map {
                PathRule(path: $0,
                         verdict: .safe,
                         reason: "standard macOS app cache")
            }

            rules.append(VendorRule(
                name: String(format: String(localized: "common_app_cache.standard.title %@", bundle: .module),
                             meta.appName),
                bundleIDPrefix: bundleID,
                category: "common_app_cache",
                source: "standard-macos-cache",
                paths: paths
            ))
        }
        return rules
    }

    nonisolated private static func commonAppCacheIncompleteIssue(
        _ issue: CommonAppCacheScanner.IncompletePath
    ) -> ScanIncompleteIssue {
        switch issue.reason {
        case .metadataUnavailable:
            return ScanIncompleteIssue(
                path: issue.path,
                reason: .metadataUnavailable,
                stage: .metadata
            )
        case .directoryOpenFailed:
            return ScanIncompleteIssue(
                path: issue.path,
                reason: .enumerationFailed,
                stage: .open
            )
        case .enumerationFailed,
             .deadlineExceeded,
             .entryLimitReached,
             .globExpansionLimitReached:
            return ScanIncompleteIssue(
                path: issue.path,
                reason: .enumerationFailed,
                stage: .enumerate
            )
        }
    }

    /// 旧版本候选的唯一计量入口。完整性证据和大小来自同一 BulkScanner 会话，
    /// 不再用 `FileManager.enumerator(errorHandler:nil)` 静默跳过失败子树。
    nonisolated private static func measureVersionedRoot(
        at url: URL,
        options: ScanOptions
    ) async -> VersionedRootScanMeasurement? {
        let scanner = BulkScanner(options: options)
        var summary: ScanSummary?
        var incompleteIssues = Set<ScanIncompleteIssue>()

        for await event in scanner.scan(root: url) {
            if Task.isCancelled { return nil }
            switch event {
            case .permissionDenied(let path):
                incompleteIssues.insert(ScanIncompleteIssue(path: path, reason: .permissionDenied))
            case .tccProtectedSkipped(let path):
                incompleteIssues.insert(ScanIncompleteIssue(path: path, reason: .tccProtectedSkipped))
            case .failed(let error):
                let issue: ScanIncompleteIssue
                switch scanFailureScope(error, rootPath: url.path) {
                case .root(let value), .descendant(let value):
                    issue = value
                }
                incompleteIssues.insert(issue)
                GSYLog.warning(.scan,
                               "KnownVersionedRoots BulkScanner failed root=\(url.path) error=\(error)")
            case .incomplete(let issue):
                incompleteIssues.insert(issue)
            case .finished(let value):
                summary = value
                incompleteIssues.formUnion(value.incompleteIssues)
                if value.completionStatus == .partial,
                   value.incompleteIssues.isEmpty {
                    incompleteIssues.insert(ScanIncompleteIssue(
                        path: url.path,
                        reason: .enumerationFailed,
                        stage: .enumerate
                    ))
                }
                if value.permissionDeniedCount > 0,
                   !incompleteIssues.contains(where: { $0.reason == .permissionDenied }) {
                    incompleteIssues.insert(ScanIncompleteIssue(
                        path: url.path,
                        reason: .permissionDenied
                    ))
                }
                if value.tccProtectedSkippedCount > 0,
                   !incompleteIssues.contains(where: { $0.reason == .tccProtectedSkipped }) {
                    incompleteIssues.insert(ScanIncompleteIssue(
                        path: url.path,
                        reason: .tccProtectedSkipped
                    ))
                }
            case .node, .nodes, .progress, .cacheDirTagged:
                break
            }
        }

        guard !Task.isCancelled else { return nil }
        guard let summary else {
            incompleteIssues.insert(ScanIncompleteIssue(
                path: url.path,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
            return VersionedRootScanMeasurement(
                allocatedBytes: 0,
                logicalBytes: 0,
                fileCount: 0,
                incompleteIssues: incompleteIssues
            )
        }
        return VersionedRootScanMeasurement(
            allocatedBytes: summary.totalAllocatedBytes,
            logicalBytes: summary.totalLogicalBytes,
            fileCount: summary.fileCount,
            incompleteIssues: incompleteIssues
        )
    }

    nonisolated private static func modificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// v1.3：多根并行扫描入口（"全部推荐扫描"）。
    ///
    /// 解决用户反馈："扫描看起来还是只有一个目录在动" —— 走 [MultiRootScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)
    /// 把 ScanCategories.recommended() 的 5 个根 **同时** 启动，每根独立 BulkScanner + InodeSet + 6 worker，
    /// 真正打满 M*6 个并行工作单元。
    ///
    /// 实现要点：
    /// - currentRootPath 设 "(多目录)"：UI 在 finishedEmpty / 树视图等场景需要一个非 nil 占位；
    ///   这里不能用具体的某根路径（否则 5 根中只能选 1 个展示，逻辑混乱）。
    /// - activeCategoryID = multiRootCategoryID 哨兵：与单根 scan 共用 `runScan` 防过期事件机制；
    ///   现有 `cancel()` 把 activeCategoryID 清空 → 旧 stream 残留事件自动丢弃。
    /// - perRootProgress 预填 5 条：UI 立刻能渲染 5 行"扫描中…"，不等第一个事件到达。
    /// - bucket key 形如 "{rootPath}/{firstSegment}"：现有 ingest 走的是 rootPath 前缀切割，
    ///   多根时不同根不会撞 key（路径前缀不同），现有逻辑无需改。
    public func scanRecommended(includeHidden: Bool = true) {
        scanMultiRootCategories(
            ScanCategories.recommended(home: home),
            includeHidden: includeHidden,
            categoryID: ScanCoordinator.multiRootCategoryID,
            sentinelPath: ScanCoordinator.multiRootSentinelPath,
            logName: "recommended"
        )
    }

    /// Smart Care 的“系统与日志”真实扫描入口。
    ///
    /// 普通模式的应用缓存与开发缓存各自有独立 scanner；这里仅扫描
    /// [ScanCategories.smartCareCore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift)
    /// 声明的非重叠根，不能复用包含 `~/Library/Caches` 与 DerivedData 的完整推荐计划。
    public func scanSmartCareCore(includeHidden: Bool = true) {
        scanMultiRootCategories(
            ScanCategories.smartCareCore(home: home),
            includeHidden: includeHidden,
            categoryID: ScanCoordinator.smartCareCoreCategoryID,
            sentinelPath: ScanCoordinator.smartCareCoreSentinelPath,
            logName: "smart_care.core"
        )
    }

    /// 推荐扫描与 Smart Care core 的共享多根启动器。
    ///
    /// 白名单必须在真正创建 `MultiRootScanner` 之前完成加载；这样从第一个 node 开始，
    /// 本轮 `publishSnapshot` 使用的就是同一份不可变快照，不存在首帧暴露已加白路径的窗口。
    private func scanMultiRootCategories(_ categories: [ScanCategory],
                                         includeHidden: Bool,
                                         categoryID: String,
                                         sentinelPath: String,
                                         logName: String) {
        cancel()
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        buckets.removeAll(keepingCapacity: true)
        // Step 3 P0-3：buckets 整轮清空 → bucket 上的 cachedVerdict 也跟着消失。
        // 但独立维护的命中率计数器需要显式归零，否则跨会话累计无意义。
        verdictCacheHits = 0
        verdictCacheMisses = 0
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        // 清掉上一轮的 TreeBrowserView 按需子树缓存，
        // 避免新扫描期间 view 看到旧扫描的展开结果。
        treeChildrenCache.removeAll(keepingCapacity: true)
        bumpChildrenCacheVersion()
        treeChildrenInFlight.removeAll(keepingCapacity: true)
        // v2026.06.20：mtime 兜底缓存也跟随会话清零——
        // 用户两次扫描之间完全可能在 Finder/CLI 改文件，旧 mtime 必须作废。
        mtimeFallbackCache.removeAll(keepingCapacity: true)
        bumpStructuralRevision()
        largeFileLeaves.removeAll(keepingCapacity: true)
        // M3：新 scan 启动必须清掉上一轮 compact 缓存的 Top N，避免新会话期间
        // largeFiles(...) 错误命中旧 cache（largeFileLeaves 当前空 + cache 非空）。
        compactedLargeFileTopN = nil
        // v1.3：清掉上一轮的 ingest 时间戳，避免新扫描启动瞬间旧 bucket 仍被判 active
        lastIngestAt.removeAll(keepingCapacity: true)
        largeFileTopNOnlyScan = false
        self.largeFileMinBytes = 0
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        // v1.3.x：用户反馈"扫描很久也没 ETA" —— 推荐扫描虽然没整盘 volumeSnapshot 可用，
        // 但 5 个根的总字节数可以异步快速估算（几百毫秒到几秒），估出来后开 ETA。
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        // 启动时先标记 eligible=true（等估算完成后由 expectedTotalBytes 决定能否真出数）；
        // 真正用 expectedTotalBytes 判断会在 publishSnapshot 里做，这里只是开闸。
        etaEligible = true
        expectedTotalBytes = nil  // 还没估算出来
        currentRootPath = sentinelPath
        snapshot = ScanSnapshot(categoryID: categoryID, rows: [],
                                totalBytes: 0, scannedFileCount: 0, isFinished: false, elapsed: 0)
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        activeCategoryID = categoryID
        let generation = scanGeneration
        whitelistSnapshot = []

        treeFetchGeneration = UUID()

        // 预填 perRootProgress，UI 立刻能看到 5 行"扫描中…"行；
        // 后续 .node / .finished 事件再原地累加 / 翻 isFinished。
        var initial: [String: PerRootProgress] = [:]
        for c in categories {
            initial[c.rootPath] = PerRootProgress(rootPath: c.rootPath, title: c.displayTitle)
        }
        syncPerRootPublished(from: initial)
        // v1.3.zz 性能修复：staging 同步初始化，让 .node 事件累计的目标存在
        perRootStaging = initial

        let roots = categories.map(\.rootURL)
        GSYLog.notice(.flow, "scan.\(logName).start roots=\(roots.map(\.path).joined(separator: ",")) includeHidden=\(includeHidden)")
        // v1.3.x：异步估算总字节数，用作 ETA 分母。
        // 4s 软超时 + 后台 detached → 完全不阻塞正式扫描的启动。
        let activeID = categoryID
        Task { [weak self] in
            let estimated = await TreeSizeEstimator.estimate(roots: roots, timeout: 4.0)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 防止过期估算覆盖新一轮扫描
                guard self.ownsScan(categoryID: activeID, generation: generation) else { return }
                self.expectedTotalBytes = estimated
            }
        }
        // v1.3 review-fix Must4：原写法 `(fdaStatus != .granted)` 把 `.unknown` 也当成"未授权"处理，
        // 导致 FDAProbe 三探针目录全不存在时（沙盒 / 容器异常）会**误报**一个 TCC banner，
        // 而真实状态可能是已授权。改成只在 `.denied` 时才 respectTCCSkipList，`.unknown` 走默认（信任系统层 errno=EPERM 自然 skip），
        // 既保守又不会出现"什么都还没扫就闪 banner"。
        let respectTCC = (fdaStatus == .denied)
        let options = ScanOptions(includeHidden: includeHidden,
                                  staySingleVolume: false,
                                  respectTCCSkipList: respectTCC)
        let whitelistStore = self.whitelistStore
        scanTask = Task { [weak self] in
            let whitelist = await whitelistStore.snapshotPaths()
            guard let self,
                  self.ownsScan(categoryID: activeID, generation: generation) else { return }
            self.whitelistSnapshot = whitelist
            // v1.5 性能修复：推荐扫描 5 根固定，但常见命中 ~/Library/Caches、
            // ~/Library/Logs、~/Library/Application Support 等大根；并发上限 3 足够
            // 让吞吐拉满又不会让整机 IO 子系统拥塞（详见 MultiRootScanner.scan 注释）。
            await self.runMultiRootScan(roots: roots, options: options,
                                        generation: generation,
                                        categoryID: activeID,
                                        maxConcurrentRoots: 3)
        }
    }

    /// v1.4：开发者构建产物多根并行扫描入口。
    ///
    /// 流程：
    /// 1. [DevArtifactScanner] 在 `~` 下勘察命中规则的目录（不计字节，只列 URL + 规则元数据）；
    /// 2. 用 [DevArtifactRule.Verdict] 过滤——本入口只接收 `.safe` + `.confirm` 两类，
    ///    勾选默认值由 verdict 决定（safe 默认勾选、confirm 默认不勾，与 ScanCategory 体系一致）；
    /// 3. 把命中目录转成多根，复用 [runMultiRootScan]——这样 UI 全套（perRootProgress / footerBar /
    ///    treeBrowser / safety / TrashPipeline）零改动；
    /// 4. 命中数为 0 时直接 publish 一个 finished=true 的空 snapshot，避免 UI 无限"扫描中…"。
    ///
    /// - Parameters:
    ///   - includeHidden: 透传 ScanOptions.includeHidden（开发者产物里很多隐藏目录如 `.next`，应保持 true）
    ///   - enabledRuleIDs: 启用的规则 ID 集合，缺省 = 全部启用；调用方传入用户设置中关掉的差集
    public func scanDeveloper(includeHidden: Bool = true,
                              enabledRuleIDs: Set<String> = DevArtifactRules.allIDs) {
        cancel()
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        // v1.3 P0-C：开发者构建产物扫描典型命中 30+ 根 × 每根上万 node，
        // 若 enableTreeDeepIndex 开着，MainActor ingest 会被祖先回溯 + index 写入打挂。
        // 强制关闭，让 TreeBrowser 走按需子树扫描路径（与全盘扫一致策略）。
        if enableTreeDeepIndex {
            GSYLog.info(.scan, "ScanCoordinator dev 扫描强制关闭 enableTreeDeepIndex（防止 MainActor ingest burst）")
            enableTreeDeepIndex = false
        }
        buckets.removeAll(keepingCapacity: true)
        // Step 3 P0-3：buckets 整轮清空 → bucket 上的 cachedVerdict 也跟着消失。
        // 但独立维护的命中率计数器需要显式归零，否则跨会话累计无意义。
        verdictCacheHits = 0
        verdictCacheMisses = 0
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        treeChildrenCache.removeAll(keepingCapacity: true)
        bumpChildrenCacheVersion()
        treeChildrenInFlight.removeAll(keepingCapacity: true)
        // v2026.06.20：mtime 兜底缓存与扫描会话同寿，cancel/reset 一并清空。
        mtimeFallbackCache.removeAll(keepingCapacity: true)
        largeFileLeaves.removeAll(keepingCapacity: true)
        bumpStructuralRevision()
        compactedLargeFileTopN = nil
        lastIngestAt.removeAll(keepingCapacity: true)
        largeFileTopNOnlyScan = false
        self.largeFileMinBytes = 0
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        etaEligible = true
        expectedTotalBytes = nil
        currentRootPath = ScanCoordinator.developerSentinelPath
        snapshot = ScanSnapshot(categoryID: ScanCoordinator.developerCategoryID, rows: [],
                                totalBytes: 0, scannedFileCount: 0, isFinished: false, elapsed: 0)
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        // v1.3 P0-D：dev 扫描入口归零截断标志，避免上次的状态污染本次 banner。
        devArtifactDidTruncate = false
        devArtifactDidTimeout = false
        activeCategoryID = ScanCoordinator.developerCategoryID
        let generation = scanGeneration
        whitelistSnapshot = []

        treeFetchGeneration = UUID()

        let respectTCC = (fdaStatus == .denied)
        let options = ScanOptions(includeHidden: includeHidden,
                                  staySingleVolume: false,
                                  respectTCCSkipList: respectTCC)
        let activeID = ScanCoordinator.developerCategoryID
        let activeStartedAt = startedAt
        let whitelistStore = self.whitelistStore
        let knownDeveloperRoots = ScanCategories.developerCacheRoots(home: home).filter { category in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: category.rootPath, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        // 异步勘察 + 启动扫描。勘察默认不做任意秒数截断，用户取消会显式
        // 传播到 detached 文件遍历；避免大型开发机把 partial 结果伪装成完成。
        scanTask = Task { [weak self] in
            let whitelist = await whitelistStore.snapshotPaths()
            guard !Task.isCancelled,
                  let owner = self,
                  owner.ownsScan(categoryID: activeID, generation: generation) else { return }
            owner.whitelistSnapshot = whitelist
            // v2026.06.21 总体方针修订：用户明确要求"不能进入截断/超时状态"——
            // 因此 maxHits 走 DevArtifactScanner 默认值 (.max)，命中再多也不截断；
            // timeoutSeconds 保留 60s 作为最后安全网（实际正常家目录几秒~十几秒走完）。
            // 同时换用 streamed 接口：每命中 [flushEvery] 条 hit 就把这批 partial
            // 通过 onPartial 回调推回主 actor 预填 perRootStaging，让 UI 在 walk
            // 还没完成时就能看到 sidebar 不断长出新的"待扫根"行——视觉上不再"卡死"。
            let opts = DevArtifactScanner.Options(enabledRuleIDs: enabledRuleIDs)
            let scanner = DevArtifactScanner(options: opts)
            let homeStr = owner.home
            // partial 回调在 detached 线程，必须跳回主 actor 写 @MainActor 隔离的字段
            // v2026.06.21 性能：原本每个 batch（每 20 hit）都立刻调一次 syncPerRootPublished，
            // discover 命中几百条时 partial 阶段触发 10+ 次同步——每次都让 MainView 整 body
            // 重算，dev 扫主列表滑动卡顿的最大单点。改为：staging 写入是 hot path 保留；
            // syncPerRootPublished 节流到 0.4s 一次（与 runMultiRootScan throttle 对齐），
            // 用 nonisolated(unsafe) 包装一个时间戳 box 做窗口判定。最终 flush 由 walk 结束
            // 后的 MainActor.run（L1232 之后）兜底，不会漏掉尾巴。
            let partialSyncBox = PartialSyncWindow()
            let onPartial: @Sendable ([DevArtifactScanner.Hit]) -> Void = { [weak self] batch in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard await self.waitForPruneTransactionBarrier() else { return }
                    guard self.ownsScan(categoryID: activeID, generation: generation) else { return }
                    // 把这一批 hit 预填进 perRootStaging（不动 @Published，等下次 throttle 同步）
                    for hit in batch {
                        let path = hit.url.path
                        if Self.isWhitelisted(path, in: whitelist) { continue }
                        if self.isDeletedTombstoned(path) { continue }
                        if self.perRootStaging[path] != nil { continue }
                        let shortPath = self.shortenPath(path, home: homeStr)
                        let localizedDisplay = String(localized: String.LocalizationValue(hit.displayName), bundle: .module)
                        let title = "\(localizedDisplay) · \(shortPath)"
                        self.perRootStaging[path] = PerRootProgress(rootPath: path, title: title)
                    }
                    // 节流：距离上次 sync ≥ 0.4s 才推；否则只动 staging，等下个 partial 或最终
                    // result 之后的兜底 sync。这样 sidebar 新行最坏延迟 0.4s 出现，UX 无感。
                    let now = Date().timeIntervalSinceReferenceDate
                    if now - partialSyncBox.lastSync >= 0.4 {
                        partialSyncBox.lastSync = now
                        self.syncPerRootPublished(from: self.perRootStaging)
                    }
                }
            }
            let result = await scanner.discoverWithMetadataStreamed(
                home: URL(fileURLWithPath: homeStr),
                flushEvery: 20,
                onPartial: onPartial
            )
            guard !Task.isCancelled else { return }
            let hits = result.hits.filter {
                !Self.isWhitelisted($0.url.path, in: whitelist)
            }
            let supplementalRoots = knownDeveloperRoots.filter {
                !Self.isWhitelisted($0.rootPath, in: whitelist)
            }
            // 防过期：勘察期间用户可能切走或重新点击其他扫描入口
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.ownsScan(categoryID: activeID, generation: generation) else { return }
                self.devArtifactDidTruncate = result.didTruncate
                self.devArtifactDidTimeout = result.didTimeout
                // DevArtifactScanner 的发现 walk 与后续每根 BulkScanner 都是删除证据链。
                // 发现阶段的 I/O 缺口必须保留精确路径，不能只用一个全局 partial bool；
                // 这样 TrashPipeline 会锁住与缺口重叠的候选，同时不误伤其它完整根。
                self.replaceIncompleteEvidence(with: result.incompleteIssues)
                let discoveryWasIncomplete = !Self.developerDiscoveryIsComplete(
                    didTimeout: result.didTimeout,
                    didTruncate: result.didTruncate,
                    hasIncompleteEvidence: !result.incompleteIssues.isEmpty
                )
                // v2026.06.21：partial 阶段已经把 hits 增量预填进 perRootStaging 了；
                // 这里只补齐 partial 没收到的尾巴（理论上 onPartial 在末尾会 flush 残余，
                // 但仍按"以最终结果为准"做一次最终对账）。
                var finalStaging = self.perRootStaging
                var finalRoots: [URL] = []
                finalRoots.reserveCapacity(hits.count + supplementalRoots.count)
                var seenPaths = Set<String>()
                for hit in hits {
                    let path = hit.url.path
                    if self.isDeletedTombstoned(path) { continue }
                    guard seenPaths.insert(path).inserted else { continue }
                    finalRoots.append(hit.url)
                    if finalStaging[path] == nil {
                        let shortPath = self.shortenPath(path, home: self.home)
                        let localizedDisplay = String(localized: String.LocalizationValue(hit.displayName), bundle: .module)
                        let title = "\(localizedDisplay) · \(shortPath)"
                        finalStaging[path] = PerRootProgress(rootPath: path, title: title)
                    }
                }
                for category in supplementalRoots {
                    let path = category.rootPath
                    if self.isDeletedTombstoned(path) { continue }
                    guard seenPaths.insert(path).inserted else { continue }
                    finalRoots.append(category.rootURL)
                    if finalStaging[path] == nil {
                        let shortPath = self.shortenPath(path, home: self.home)
                        let title = "\(category.displayTitle) · \(shortPath)"
                        finalStaging[path] = PerRootProgress(rootPath: path, title: title)
                    }
                }
                if finalRoots.isEmpty {
                    // 0 命中：直接 publish 一个 finished snapshot，让 UI 不再卡在"扫描中…"
                    self.resetPerRootPublished()
                    self.perRootStaging = [:]
                    self.snapshot = ScanSnapshot(categoryID: activeID, rows: [],
                                                 totalBytes: 0, scannedFileCount: 0,
                                                 isFinished: true,
                                                 elapsed: Date().timeIntervalSince(activeStartedAt),
                                                 isComplete: !discoveryWasIncomplete)
                    self.isScanning = false
                    self.scanPhase = .idle
                    self.lastFinishedCategoryID = activeID
                    self.scanTask = nil
                    self.activeCategoryID = nil
                    self.refreshVolumeCapacity()
                    GSYLog.info(.scan, "DevArtifact 勘察 0 命中 直接结束扫描")
                    return
                }
                self.perRootStaging = finalStaging
                self.syncPerRootPublished(from: finalStaging)
                let rootsToScan = finalRoots

                // 估算总字节，给 ETA 用
                Task { [weak self] in
                    let estimated = await TreeSizeEstimator.estimate(roots: rootsToScan, timeout: 4.0)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard self.ownsScan(categoryID: activeID, generation: generation) else { return }
                        self.expectedTotalBytes = estimated
                    }
                }

                // 起真正的多根扫描——复用 runMultiRootScan 全套
                // v2026.06.21：用户反馈"卡顿比之前更糟糕"。maxHits=.max 后 dev 扫
                // 命中数可能上千；fan-out 时 3 并发仍然每秒产生大量 .nodes 事件
                // 打主 actor。再降一档到 2，让 UI 有更多空档期 layout / 响应手势。
                self.scanTask = Task { [weak self] in
                    await self?.runMultiRootScan(roots: rootsToScan, options: options,
                                                 generation: generation,
                                                 categoryID: activeID,
                                                 maxConcurrentRoots: 2,
                                                 upstreamWasIncomplete: discoveryWasIncomplete)
                }
            }
        }
    }

    /// v1.4：把 `~/Foo/Bar/node_modules` 缩成 `~/Foo/Bar` 形式以便 UI 展示。
    private nonisolated func shortenPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func runScan(rootURL: URL,
                         categoryID: String,
                         generation: UUID,
                         includeHidden: Bool,
                         staySingleVolume: Bool = false,
                         largeFileTopNOnly: Bool = false) async {
        let rootPath = rootURL.path
        // v1.0 T2：把 AppSettings.showHidden 透传到 ScanOptions
        // v1.0 T5：整盘扫描时叠加 staySingleVolume=true（详见 ScanOptions 文档）
        // v1.3：FDA 已授予时关掉 TCC 硬 skip，让用户原本就有权限读的目录被正常下钻；
        //       同时不再 yield .tccProtectedSkipped，banner 不再误报。
        // v1.3 review-fix Must4：见上方多根入口同名注释。`.unknown` 不应触发 TCC banner，仅 `.denied` 触发。
        let respectTCC = (fdaStatus == .denied)
        let options = ScanOptions(
            includeHidden: includeHidden,
            staySingleVolume: staySingleVolume,
            respectTCCSkipList: respectTCC
        )
        let scanner = BulkScanner(options: options)
        var lastEmit = Date(timeIntervalSince1970: 0)
        // v1.3.z 性能修复（App 实测 90s 定位结论）：
        // 主线程 sample 显示 95% 时间在 SwiftUI ViewGraph flushTransactions / MainView.body 重算，
        // 节流 150ms = 每秒 6.7 帧 body，扫 90s = 600 次全 body 重计算（results / statusBar /
        // footerBar / selectedRows.filter）；扫描期 UI 没人盯帧率，250-400ms 完全够看到字节跳动。
        // 抬到 0.40 后预期 ViewGraph 重算次数降到 ~2.5 fps，主线程让出给 ingest。
        let throttle: TimeInterval = 0.40
        // v1.3.y / v2026.06.25 性能修复：
        // BulkScanner 会把一个目录下的多个 node 合并成 `.nodes(arr)`。旧实现按"事件数"
        // 计数让出，百万级文件扫描时一个事件可能代表几百个 node，MainActor 仍会被连续
        // 占住太久。这里改为按实际 node 数计数，让 SwiftUI / RunLoop 有稳定空档。
        let yieldEvery = 256
        var consumedSinceYield = 0
        var finishedSummary: ScanSummary?
        var sawRootFailure = false

        for await event in scanner.scan(root: rootURL) {
            if Task.isCancelled { break }
            guard await waitForPruneTransactionBarrier() else { break }
            // v1.3 防 [坑 1]：旧 stream 残留事件污染新 snapshot。
            // activeCategoryID 在 cancel() 里被清空、在新 scan 入口被重新打上；只要本次 stream 已被
            // 新一轮 scan 取代，下面这一行就会让旧 for-await 立刻跳出循环，不再写 buckets/dirIndex。
            guard ownsScan(categoryID: categoryID, generation: generation) else { break }
            var consumedThisEvent = 1
            switch event {
            case .node(let node):
                if largeFileTopNOnly {
                    ingestLargeFileNode(node, rootPath: rootPath)
                } else {
                    ingest(node: node, rootPath: rootPath)
                }
            case .nodes(let arr):
                // Step 13B micro-batch：批量 ingest，减少跨 actor hop 开销。
                // 大文件入口只保留 Top-N，不构建通用树形/主列表索引。
                for node in arr {
                    if largeFileTopNOnly {
                        ingestLargeFileNode(node, rootPath: rootPath)
                    } else {
                        ingest(node: node, rootPath: rootPath)
                    }
                }
                consumedThisEvent = max(1, arr.count)
            case .progress(let bytes, let count):
                // BulkScanner 自带的 progress 我们也用上，但首选 node 累计
                _ = bytes
                _ = count
            case .finished(let summary):
                finishedSummary = summary
                for issue in summary.incompleteIssues {
                    recordIncompleteIssue(issue)
                }
                if summary.completionStatus == .partial,
                   summary.incompleteIssues.isEmpty {
                    recordIncompleteIssue(ScanIncompleteIssue(
                        path: rootPath,
                        reason: .enumerationFailed,
                        stage: .enumerate
                    ))
                }
            case .failed(let error):
                if consumeScanFailure(error, rootPath: rootPath) {
                    sawRootFailure = true
                }
            case .incomplete(let issue):
                recordIncompleteIssue(issue)
            case .permissionDenied(let path):
                recordIncompleteIssue(ScanIncompleteIssue(
                    path: path,
                    reason: .permissionDenied
                ))
            case .tccProtectedSkipped(let path):
                recordIncompleteIssue(ScanIncompleteIssue(
                    path: path,
                    reason: .tccProtectedSkipped
                ))
            case .cacheDirTagged:
                // v1.5 Step 8：CACHEDIR.TAG 命中——单根扫描忽略；
                // safe 候选由后续 SafetyEngine 路径级 verdict 兜底，这里不重复 banner。
                break
            }

            // 节流：≥150ms 推一次（PITFALLS §5.4）
            let now = Date()
            if now.timeIntervalSince(lastEmit) >= throttle {
                lastEmit = now
                publishSnapshot(categoryID: categoryID, finished: false)
            }

            // 性能修复：每 N 个事件让出一次主 actor（详见上方注释）
            consumedSinceYield += consumedThisEvent
            if consumedSinceYield >= yieldEvery {
                consumedSinceYield = 0
                await Task.yield()
            }
        }
        // v1.3 防 [坑 1] 收尾：只有当本次 runScan 仍是当前活跃 scan 时才标记 finished。
        // 若已被新 scan 取代，本次"完成"事件不应该覆盖新的 in-progress snapshot；
        // isScanning / scanTask 由新 scan 自己管理，这里也不要重置。
        guard ownsScan(categoryID: categoryID, generation: generation) else { return }
        let completedSuccessfully = !Task.isCancelled
            && !sawRootFailure
            && finishedSummary?.completionStatus == .complete
        if Self.singleRootNeedsTerminalFallback(
            sawFailure: sawRootFailure,
            summary: finishedSummary
        ) {
            // 流关闭/失败却没有完整 summary 时，不能只把 UI 画成 partial；删除预检
            // 还必须得到根级证据，否则父根仍可能被当成完整结果移入废纸篓。
            recordIncompleteIssue(ScanIncompleteIssue(
                path: rootPath,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
        }
        // 精确 child issue 由结构化 banner/Tree lock 表达，绝不能再塞进 lastError
        // 变成一条看似整轮崩溃的红字。只有根事件流没有可信 summary，或 summary
        // 自己只给出 opaque partial，才需要根级通用错误。
        let hasOpaqueRootFailure = finishedSummary == nil
            || (finishedSummary?.completionStatus == .partial
                && finishedSummary?.incompleteIssues.isEmpty == true)
        if !completedSuccessfully, hasOpaqueRootFailure, lastError == nil {
            let message = String(localized: "main.scan.incomplete", bundle: .module)
            lastError = message
            if finishedSummary == nil {
                terminalFailure = TerminalFailure(message: message)
            }
        }
        publishSnapshot(categoryID: categoryID, finished: true, complete: completedSuccessfully)
        isScanning = false
        scanPhase = .idle
        scanTask = nil
        activeCategoryID = nil
        // v1.3.zz 流式修复 ③：扫描结束后清掉 treeChildrenCache 里"扫描期间被钉空"
        // 的所有项目，让 TreeBrowserView 下一帧重新拉一次"finalize 之后的全量结果"。
        // 之所以放在 isScanning=false 之后：directChildren 写回逻辑判 isScanning 决定是否
        // 钉 cache；这里清完后下一次 fetch 即便 rows 仍然空也会被正常缓存（终态空 = 真没数据）。
        invalidateTreeCacheAfterScan()
        // v1.3：扫描完成后刷新一次容量，与 Finder/系统设置口径一致。
        // 删除发生时另行调 refreshVolumeCapacity（见 MainView.performDelete）。
        refreshVolumeCapacity()
    }

    /// v1.3：多根并行扫描的主消费循环。
    ///
    /// 与 [runScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 的差别：
    /// - 事件流是 [MultiRootEvent](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)，
    ///   带 `rootPath` 信封，`ingest(node:rootPath:)` 直接拿到正确根；
    /// - 每个 .node 同时累加全局 totalBytes / scannedFiles **和** 该根的 perRootProgress；
    /// - 每个 .finished 翻该根的 isFinished=true；所有根 finish 后 stream 自然关闭。
    private func runMultiRootScan(roots: [URL], options: ScanOptions,
                                  generation: UUID,
                                  categoryID: String,
                                  maxConcurrentRoots: Int = 4,
                                  upstreamWasIncomplete: Bool = false) async {
        let scanner = MultiRootScanner(options: options)
        let expectedRootPaths = Set(roots.map(\.path))
        var finishedRootPaths = Set<String>()
        var failedRootPaths = Set<String>()
        // Developer discovery may time out/truncate before the per-root scanners start.
        // Discovered roots can still be measured precisely, but the overall session must remain partial.
        var sawPartialRoot = upstreamWasIncomplete
        var sawRootFailure = false
        var lastEmit = Date(timeIntervalSince1970: 0)
        // v1.3.z 性能修复：见 runScan 同名注释。多根模式 throttle 同步抬到 0.40。
        let throttle: TimeInterval = 0.40
        // v1.3.y 性能修复：见 runScan 同名注释。多根模式同样需要让出主 actor。
        // v2026.06.21 修复 #4（卡顿+超长）：
        //   - 旧实现 `yieldEvery=256` 是按**事件数**计，而 `.nodes(arr)` 一个事件可能含
        //     几百个 node，主线程实际处理时间远超字面值。dev scan discover 命中几十根 +
        //     每根几万 node 时，主线程被 ingest 连续占住 200~500ms，列表滑动直接卡死。
        //   - 改为按**实际处理的 node 个数**累加：`.node` 计 1、`.nodes(arr)` 计 `arr.count`。
        //   - 阈值降到 96：node 路径上典型 ingest ~5–15µs，96 节点 ≈ 0.5–1.5ms 让出一次，
        //     既能保证 ProMotion 120Hz 滑动 (8.3ms/帧) 有足够主线程空隙，又不让 ingest
        //     吞吐被 yield 反噬（一次 await 调度本身有几十微秒成本）。
        let yieldEvery = 96
        var consumedSinceYield = 0

        for await wrapped in await scanner.scan(roots: roots, maxConcurrentRoots: maxConcurrentRoots) {
            if Task.isCancelled { break }
            guard await waitForPruneTransactionBarrier() else { break }
            // 与 runScan 同款过期事件保护：activeCategoryID 被覆盖即旧 stream 残留事件，丢弃。
            guard ownsScan(categoryID: categoryID, generation: generation) else { break }
            let rootPath = wrapped.rootPath
            if isDeletedTombstoned(rootPath) {
                if case .finished(let summary) = wrapped.event {
                    finishedRootPaths.insert(rootPath)
                    for issue in summary.incompleteIssues {
                        recordIncompleteIssue(issue)
                    }
                    if summary.completionStatus == .partial,
                       summary.incompleteIssues.isEmpty {
                        recordIncompleteIssue(ScanIncompleteIssue(
                            path: rootPath,
                            reason: .enumerationFailed,
                            stage: .enumerate
                        ))
                    }
                    if summary.completionStatus == .partial {
                        sawPartialRoot = true
                    }
                }
                if !expectedRootPaths.isEmpty,
                   expectedRootPaths.isSubset(of: finishedRootPaths) {
                    break
                }
                continue
            }
            // v2026.06.21 修复 #4：本事件实际"处理了几个 node"，作为 yield 计数权重。
            // .node 计 1；.nodes(arr) 计 arr.count；非数据事件计 1（让控制类事件也参与 yield）。
            var consumedThisEvent = 1
            switch wrapped.event {
            case .node(let node):
                ingestMultiRootNode(node, rootPath: rootPath)
            case .nodes(let arr):
                ingestMultiRootNodes(arr, rootPath: rootPath)
                consumedThisEvent = max(1, arr.count)
            case .progress:
                break
            case .finished(let summary):
                finishedRootPaths.insert(rootPath)
                for issue in summary.incompleteIssues {
                    recordIncompleteIssue(issue)
                }
                let isPartial = summary.completionStatus == .partial
                if isPartial {
                    sawPartialRoot = true
                    if summary.incompleteIssues.isEmpty {
                        recordIncompleteIssue(ScanIncompleteIssue(
                            path: rootPath,
                            reason: .enumerationFailed,
                            stage: .enumerate
                        ))
                    }
                }
                if var p = perRootStaging[rootPath] {
                    p.isFinished = true
                    p.isPartial = isPartial
                    perRootStaging[rootPath] = p
                }
                // v1.3：原本 .finished 是低频事件，立刻同步到 @Published 让 UI 看到"该根已完成"。
                // v1.5 性能修复：dev scan discover 命中几十/几百根时，.finished 风暴密集
                // 触发，每个 finished 都立即整体替换 perRootProgress dict → SwiftUI 把整个
                // sidebar / statusBar / list 重 diff 一次，列表滑动直接卡死。
                // 现在 .finished 也并入下面的 throttle 统一节流（每 0.4s 同步一次），
                // 单根/少量根的扫描场景下 throttle 间隔本来就足够小，肉眼无感差异；
                // 而 dev scan 几百根场景下重画次数从 N 降到 ~elapsed/0.4，主线程立刻回归。
                //
                // v1.5 review-fix #8：小批量根（≤10）场景把 .finished 立刻 publish 出去——
                // 推荐扫描固定 5 根、整盘扫描 1 根，throttle 0.4s 滞后看得见；
                // 仅 dev scan / fullDisk discover 命中很多根时才走纯 throttle 路径。
                if perRootStaging.count <= 10 {
                    syncPerRootPublished(from: perRootStaging)
                    lastEmit = Date()
                }
            case .failed(let error):
                let title = perRootStaging[rootPath]?.title ?? rootPath
                let isRootFailure = consumeScanFailure(
                    error,
                    rootPath: rootPath,
                    messagePrefix: title
                )
                if isRootFailure {
                    sawRootFailure = true
                    failedRootPaths.insert(rootPath)
                } else {
                    sawPartialRoot = true
                }
                if var progress = perRootStaging[rootPath] {
                    progress.isPartial = true
                    perRootStaging[rootPath] = progress
                }
            case .incomplete(let issue):
                sawPartialRoot = true
                recordIncompleteIssue(issue)
            case .permissionDenied(let path):
                recordIncompleteIssue(ScanIncompleteIssue(
                    path: path,
                    reason: .permissionDenied
                ))
            case .tccProtectedSkipped(let path):
                recordIncompleteIssue(ScanIncompleteIssue(
                    path: path,
                    reason: .tccProtectedSkipped
                ))
            case .cacheDirTagged:
                // v1.5 Step 8：多根模式下命中 CACHEDIR.TAG 同样静默——SafetyEngine 兜底。
                break
            }

            let now = Date()
            if now.timeIntervalSince(lastEmit) >= throttle {
                lastEmit = now
                // v1.3.zz 性能修复：节流同步 staging → @Published，让 UI 0.4s 看一次进度
                syncPerRootPublished(from: perRootStaging)
                publishSnapshot(categoryID: categoryID, finished: false)
                // v1.3 P0-C：publishSnapshot 触发 SwiftUI 大面积 invalidate，主动让 1ms
                // 给主线程跑 layout/render + 接受用户手势；不让的话下一批 .nodes 立即上来
                // 又把 MainActor 抢走，形成"扫得越快越卡"反馈环。
                try? await Task.sleep(nanoseconds: 1_000_000)
            }

            // v2026.06.21 修复 #4：按"实际 node 个数"累加，不再按 event 个数。
            // .nodes(arr) 一个 event 累 arr.count，从而真正让 yield 跟主线程占用对齐。
            consumedSinceYield += consumedThisEvent
            if consumedSinceYield >= yieldEvery {
                consumedSinceYield = 0
                await Task.yield()
            }
            if !expectedRootPaths.isEmpty,
               expectedRootPaths.isSubset(of: finishedRootPaths) {
                break
            }
        }
        guard ownsScan(categoryID: categoryID, generation: generation) else { return }
        let completedSuccessfully = Self.multiRootCompletionIsSuccessful(
            expectedRootPaths: expectedRootPaths,
            finishedRootPaths: finishedRootPaths,
            sawPartialRoot: sawPartialRoot,
            sawFailure: sawRootFailure,
            consumerCancelled: Task.isCancelled
        )
        let fallbackRoots = Self.multiRootTerminalFallbackPaths(
            expectedRootPaths: expectedRootPaths,
            finishedRootPaths: finishedRootPaths,
            failedRootPaths: failedRootPaths
        )
        for rootPath in fallbackRoots.sorted() {
            recordIncompleteIssue(ScanIncompleteIssue(
                path: rootPath,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
            if var progress = perRootStaging[rootPath] {
                // 终态未收到完整 summary 的根不能继续显示旋转中的状态，也不能保持 normal。
                progress.isFinished = true
                progress.isPartial = true
                perRootStaging[rootPath] = progress
            }
        }
        if !fallbackRoots.isEmpty, lastError == nil {
            let message = String(localized: "main.scan.incomplete", bundle: .module)
            lastError = message
            terminalFailure = TerminalFailure(message: message)
        }
        // v1.3.zz 性能修复：收尾把 staging 最后状态同步到 @Published，让 UI 看到完整最终值
        syncPerRootPublished(from: perRootStaging)
        publishSnapshot(categoryID: categoryID, finished: true, complete: completedSuccessfully)
        isScanning = false
        scanPhase = .idle
        scanTask = nil
        activeCategoryID = nil
        // v1.3.zz 流式修复 ③：见 runScan 同名注释。
        invalidateTreeCacheAfterScan()
        refreshVolumeCapacity()
    }

    /// 事件流关闭只代表生产者停止，不代表所有根完整成功。
    ///
    /// 终态必须同时满足：任务未取消、没有 `.failed`、没有 synthetic partial summary，
    /// 且每个预期根都明确发出 `.finished`。这样 total deadline、未来 watchdog 或意外闭流
    /// 都不会再被包装成成功。
    nonisolated static func multiRootCompletionIsSuccessful(
        expectedRootPaths: Set<String>,
        finishedRootPaths: Set<String>,
        sawPartialRoot: Bool,
        sawFailure: Bool,
        consumerCancelled: Bool
    ) -> Bool {
        !consumerCancelled
            && !sawPartialRoot
            && !sawFailure
            && expectedRootPaths.isSubset(of: finishedRootPaths)
    }

    nonisolated static func developerDiscoveryIsComplete(
        didTimeout: Bool,
        didTruncate: Bool,
        hasIncompleteEvidence: Bool
    ) -> Bool {
        !didTimeout && !didTruncate && !hasIncompleteEvidence
    }

    /// 单根事件流在没有完整、可信 summary 时必须补一条根级 incomplete 证据。
    /// 精确 issues 非空的 partial summary 已能锁住受影响祖先，无需扩大到整根。
    nonisolated static func singleRootNeedsTerminalFallback(
        sawFailure: Bool,
        summary: ScanSummary?
    ) -> Bool {
        if sawFailure || summary == nil { return true }
        return summary?.completionStatus == .partial
            && summary?.incompleteIssues.isEmpty == true
    }

    /// 多根流的事件通道关闭不等于每根成功。未发出 finished 的根和明确 failed 的根
    /// 都必须进入最终删除拒绝集合；调用方再把它们同步成 partial 终态行。
    nonisolated static func multiRootTerminalFallbackPaths(
        expectedRootPaths: Set<String>,
        finishedRootPaths: Set<String>,
        failedRootPaths: Set<String>
    ) -> Set<String> {
        expectedRootPaths.subtracting(finishedRootPaths).union(failedRootPaths)
    }

    private func ingestMultiRootNode(_ node: FSNode, rootPath: String) {
        guard ingest(node: node, rootPath: rootPath), !node.isDirectory,
              var progress = perRootStaging[rootPath] else { return }
        progress.bytes += displayBytes(of: node)
        progress.logicalBytes += node.logicalSize
        progress.fileCount += 1
        perRootStaging[rootPath] = progress
    }

    private func ingestMultiRootNodes(_ nodes: [FSNode], rootPath: String) {
        // Step 13B micro-batch：只累计真正被全局 ingest 接受的 node。
        // tombstone / 越界 node 返回 false，不能再进入 per-root staging。
        var stagingDelta: (bytes: Int64, logicalBytes: Int64, files: Int) = (0, 0, 0)
        for node in nodes where ingest(node: node, rootPath: rootPath) && !node.isDirectory {
            stagingDelta.bytes += displayBytes(of: node)
            stagingDelta.logicalBytes += node.logicalSize
            stagingDelta.files += 1
        }
        guard stagingDelta.files > 0, var progress = perRootStaging[rootPath] else { return }
        progress.bytes += stagingDelta.bytes
        progress.logicalBytes += stagingDelta.logicalBytes
        progress.fileCount += stagingDelta.files
        perRootStaging[rootPath] = progress
    }

    /// 测试专用注入：模拟 BulkScanner yield 的 .permissionDenied 路径，
    /// 走的是和 runScan 同一条去重逻辑。仅 `@testable` 可见。
    ///
    /// SwiftPM 的 Release 测试 target 也会编译同一组测试源；若用 `#if DEBUG`
    /// 删除这些 internal symbol，`swift test -c release` 会在编译阶段失败。
    internal func _testInjectPermissionDenied(path: String) {
        recordIncompleteIssue(ScanIncompleteIssue(path: path, reason: .permissionDenied))
    }

    /// 测试专用注入：模拟 BulkScanner yield 的 .tccProtectedSkipped 路径。
    internal func _testInjectTCCSkipped(path: String) {
        recordIncompleteIssue(ScanIncompleteIssue(path: path, reason: .tccProtectedSkipped))
    }

    internal func _testReplaceIncompleteEvidence(_ issues: [ScanIncompleteIssue]) {
        replaceIncompleteEvidence(with: issues)
    }

    internal func _testConsumeScanFailure(_ error: any Error, rootPath: String) -> Bool {
        consumeScanFailure(error, rootPath: rootPath)
    }

    internal func _testAccessState(for path: String) -> TreeRow.AccessState {
        projectedTreeState(for: path).accessState
    }

    internal func _testSubtreeCompleteness(for path: String) -> TreeRow.SubtreeCompleteness {
        projectedTreeState(for: path).subtreeCompleteness
    }

    internal func _testIngestMultiRootNodes(rootPath: String, nodes: [FSNode]) {
        ingestMultiRootNodes(nodes, rootPath: rootPath)
        syncPerRootPublished(from: perRootStaging)
    }

    /// 将 node 写入全局聚合，并返回它是否通过本轮 tombstone/投影边界。
    /// 多根扫描必须只对返回 `true` 的 node 累加 per-root 进度，否则已删除子树的
    /// 晚到事件虽然不会复活 bucket，却仍会把父根 bytes/fileCount 加回来。
    @discardableResult
    private func ingest(node: FSNode, rootPath: String) -> Bool {
        // 把 node 归到"根的第一级子目录"——这是聚合行，不展平
        let nodePath = displayPathForScanNode(node.path, rootPath: rootPath)
        guard !isDeletedTombstoned(nodePath) else { return false }
        guard let projection = Self.bucketProjection(nodePath: nodePath, rootPath: rootPath) else { return false }
        let tail = projection.tail
        let firstSegment = tail.split(separator: "/", maxSplits: 1).first.map(String.init) ?? tail
        guard !firstSegment.isEmpty else { return false }
        let bucketPath = projection.bucketPath

        // v1.3：刷新该 bucket 的"最近 ingest 时间"，作为 active 判定的活跃度信号。
        // 用 timeIntervalSinceReferenceDate 比 Date() 更轻量，单调递增足够。
        // v1.3.y 性能修复：72 万 .node 每次都写一次 lastIngestAt 主线程字典 → 主线程压力大。
        // 该值仅用于 publishSnapshot 时（≥150ms 一次）判 active，精度做到 ~50ms 完全够；
        // 同 bucket 在 50ms 窗口内重复的写入直接跳过，把字典写入次数从 N 降到 N / (50ms 内同 bucket node 数)。
        // v1.5 P1-D：去抖窗口从 0.05s 抬到 0.2s。配合 publishSnapshot 0.4s 节流与
        // activityWindow=0.8s 仍完全安全（active 判定不会误失活），但字典写入再降一档，
        // dev scan 几十/几百根高密度 ingest 时主线程字典写入压力进一步下降。
        let nowTI = Date.timeIntervalSinceReferenceDate
        if let prev = lastIngestAt[bucketPath], nowTI - prev < 0.20 {
            // 窗口内已写过，跳过
        } else {
            lastIngestAt[bucketPath] = nowTI
        }

        // 主值固定累计 allocated bytes；logicalBytes 只作为 Finder 式详情副值保留。
        let bytes = displayBytes(of: node)

        // 文件累计
        if !node.isDirectory {
            scannedFiles += 1
            totalBytes += bytes
        }

        let isDir = nodePath == bucketPath ? true : node.isDirectory
        // v1.3.z 性能优化：把"两次哈希查找"合并为"一次默认值构造 + modify accessor 写回"。
        // sample(80125, 5s) 显示 ingest 在主线程占 372 ticks，buckets 字典访问是其中热点之一。
        // 旧写法：`var b = buckets[k] ?? Bucket(...); ...; buckets[k] = b` —— 即便 hit
        // 也要每次构造 URL 默认值，且要做两次 hash 定位。
        // 新写法：用 `[k, default:]` 的 modify accessor —— hit 时不构造 URL，只走一次 hash。
        buckets[bucketPath, default: Bucket(
            url: URL(fileURLWithPath: bucketPath, isDirectory: true),
            isDirectory: true
        )].applyIngest(
            isFileNode: !node.isDirectory,
            isTopLevelBucket: nodePath == bucketPath,
            isDirEffective: isDir,
            bytes: bytes,
            logicalBytes: node.logicalSize,
            nodeMTime: node.modificationDate
        )

        // v1.0 T3：构建多层下钻索引。
        // - 叶子文件：累计到所有祖先目录的 dirIndex
        // - 任意 node：把它登记为父目录的直接子项（childEdges）
        // v1.3.z 性能开关：CLI bench / 性能基线场景关掉，跳过 576 万次主线程字典写入。
        if !node.isDirectory {
            // v1.0 T4：达到大文件阈值的叶子单独留底，供 LargeFilesView 用。
            // 注：与深索引开关解耦，largeFileLeaves 即便 deepIndex=off 也照常采集。
            if largeFileMinBytes > 0 && bytes >= largeFileMinBytes {
                largeFileLeaves.consider(LargeFileLeaf(
                    path: nodePath,
                    bytes: bytes,
                    logicalBytes: node.logicalSize,
                    modificationDate: node.modificationDate
                ))
            }
            if enableTreeDeepIndex {
                fileLeaves[nodePath] = (
                    bytes: bytes,
                    logicalBytes: node.logicalSize,
                    isDir: false,
                    modificationDate: node.modificationDate
                )
                // v1.5.7 perf：沿路径回溯到 rootPath，把 size 加到所有祖先。
                // 旧实现：每步 `(cursor as NSString).deletingLastPathComponent` 触发一次
                // NSString 桥接 + 路径拷贝；大目录（>5w 文件）下 instrument 显示
                // NSPathStore2 / NSString.bridgeFromObjC 占主线程 ~12% 时间。
                // 新实现：在原生 String 上用 lastIndex(of: "/") 切片，零桥接零额外 alloc。
                var cursor = String._gsyParentPath(of: nodePath)
                while !cursor.isEmpty, cursor.hasPrefix(rootPath) {
                    var agg = dirIndex[cursor] ?? DirAgg()
                    agg.bytes += bytes
                    agg.logicalBytes += node.logicalSize
                    agg.fileCount += 1
                    dirIndex[cursor] = agg
                    if cursor == rootPath { break }
                    let parent = String._gsyParentPath(of: cursor)
                    childEdges[parent, default: []].insert(cursor)
                    cursor = parent
                }
                // 文件本身也作为父目录的直接子项
                let parent = String._gsyParentPath(of: nodePath)
                childEdges[parent, default: []].insert(nodePath)
            }
        } else if enableTreeDeepIndex {
            // 目录节点（即使没有累计字节，也把它登记到边集，避免空目录在树里漏掉）
            // v1.5.4：把目录自身的 inode mtime 写入 DirAgg（保留已有 bytes/fileCount/logicalBytes）
            var agg = dirIndex[nodePath] ?? DirAgg()
            // 仅在目录节点 ingest 时覆盖 modificationDate；后续叶子累加路径不再回写它，
            // 保持"目录 mtime = 目录自身 inode mtime"的 Finder 语义。
            if let m = node.modificationDate {
                agg.modificationDate = m
            }
            dirIndex[nodePath] = agg
            if nodePath != rootPath {
                let parent = (nodePath as NSString).deletingLastPathComponent
                if parent.hasPrefix(rootPath) || parent == rootPath {
                    childEdges[parent, default: []].insert(nodePath)
                }
            }
        }
        notePruneSourceMutation()
        return true
    }

    private func ingestLargeFileNode(_ node: FSNode, rootPath: String) {
        guard !node.isDirectory else { return }
        let nodePath = displayPathForScanNode(node.path, rootPath: rootPath)
        guard !isDeletedTombstoned(nodePath) else { return }
        let bytes = displayBytes(of: node)
        scannedFiles += 1
        totalBytes += bytes
        if largeFileMinBytes > 0 && bytes >= largeFileMinBytes {
            largeFileLeaves.consider(LargeFileLeaf(
                path: nodePath,
                bytes: bytes,
                logicalBytes: node.logicalSize,
                modificationDate: node.modificationDate
            ))
        }
        notePruneSourceMutation()
    }

    private static func makeFullDiskFirmlinkRules() -> [(dataPrefix: String, publicPrefix: String)] {
        return Firmlinks.load()
            .map { source, target in
                let publicPrefix = source.hasPrefix("/") ? source : "/" + source
                let relativeTarget = target.hasPrefix("/") ? String(target.dropFirst()) : target
                return (dataPrefix: fullDiskDataRootPath + "/" + relativeTarget, publicPrefix: publicPrefix)
            }
            .sorted { lhs, rhs in
                lhs.dataPrefix.count > rhs.dataPrefix.count
            }
    }

    private func displayPathForScanNode(_ path: String, rootPath: String) -> String {
        guard rootPath == "/" else { return path }
        guard path.hasPrefix(Self.fullDiskDataRootPath + "/") else { return path }
        for rule in fullDiskFirmlinkRules {
            if path == rule.dataPrefix {
                return rule.publicPrefix
            }
            if path.hasPrefix(rule.dataPrefix + "/") {
                return rule.publicPrefix + String(path.dropFirst(rule.dataPrefix.count))
            }
        }
        return path
    }

    static func bucketProjection(nodePath: String, rootPath: String) -> (tail: String, bucketPath: String)? {
        if rootPath == "/" {
            guard nodePath.hasPrefix("/"), nodePath != "/" else { return nil }
            let tail = String(nodePath.dropFirst())
            guard let firstSegment = tail.split(separator: "/", maxSplits: 1).first.map(String.init),
                  !firstSegment.isEmpty else { return nil }
            return (tail, "/" + firstSegment)
        }
        guard nodePath.hasPrefix(rootPath + "/") else { return nil }
        let tail = String(nodePath.dropFirst(rootPath.count + 1))
        guard let firstSegment = tail.split(separator: "/", maxSplits: 1).first.map(String.init),
              !firstSegment.isEmpty else { return nil }
        return (tail, "\(rootPath)/\(firstSegment)")
    }

    // MARK: - T3 多层下钻 API

    /// 给 TreeBrowserView 用：取某目录路径下"直接子项"按 size 降序排好的列表。
    /// `path` 必须是当前扫描根的子路径或根本身。返回数组顺序稳定（size 大在前，size 相同按 path 升序）。
    public func directChildren(of path: String) -> [TreeRow] {
        directChildren(of: path, sortedBy: .sizeDesc)
    }

    /// v1.0 T5：支持自定义排序键的列出。供 TreeBrowserView 表头点击切排序。
    /// 排序稳定性：主键相等时一律按 path 升序兜底，保证 ForEach 不抖。
    ///
    /// v1.3.z 起：当 `enableTreeDeepIndex == false`（默认）且本路径不在内存索引中时，
    /// 走按需子树扫描缓存：本次同步返 cache（首次为空），同时启动后台 Task 通过
    /// `directChildrenAsync` 扫描当前目录写回 cache，下一帧 SwiftUI 自动重算。
    public func directChildren(of path: String, sortedBy key: TreeSortKey) -> [TreeRow] {
        // 扫描中禁用树表从 staging / snapshot 拉半成品数据。扫描期间树表只显示
        // loading，等最终快照发布后再一次性展示稳定节点，避免滚动卡顿
        // 和 8KB / 0KB 这种目录 inode 半成品误导用户。
        if isScanning, !enableTreeDeepIndex {
            return []
        }
        // v1.5：多根扫描伪路径分支——把 perRootProgress 里的真实根升级成顶层 TreeRow。
        // 没有这一支时 path == "(多目录)" / "(开发者构建产物)" 在 childEdges / 按需扫描里
        // 都查不到真实文件系统子项 → directChildren 返 [] → TreeBrowserView 渲染
        // "No expandable children yet"（用户截图反馈）。
        // 真实根（如 ~/Library/Caches）展开后走的还是原 directChildren 逻辑。
        if path == ScanCoordinator.versionedRootSentinelPath {
            // v2026.06.21：开发者旧版本扫描不进 BulkScanner，所以 perRootProgress 是空的。
            // 直接把 snapshot.rows 升级为顶层 TreeRow——title/bytes 都现成，
            // 复用 [synthesizeVersionedTopLevel] 集中维护排序与 hasChildren=false 语义。
            return synthesizeVersionedTopLevel(sortedBy: key)
        }
        if path == ScanCoordinator.commonAppCacheSentinelPath {
            return snapshotTopLevelRows(sortedBy: key)
        }
        if ScanCoordinator.multiRootSentinelPaths.contains(path) {
            return synthesizeMultiRootTopLevel(sortedBy: key)
        }
        if let kids = childEdges[path] {
            return materializeFromMemory(kids: kids, sortedBy: key)
        }
        // Root-level safety net: the flat list already owns the first-level bucket
        // projection. When deepIndex is off, never let a missing/late async fetch
        // turn a non-empty scan into an empty tree root.
        if path == currentRootPath, !isScanning, !snapshot.rows.isEmpty {
            return snapshotTopLevelRows(sortedBy: key)
        }
        // 内存索引不命中。enableTreeDeepIndex=on 时这就是"真没有"，直接返空（保持旧语义）。
        guard !enableTreeDeepIndex else { return [] }
        // deepIndex=off 路径：进按需子树扫描缓存。
        let cacheKey = "\(path)|\(key.rawValue)"
        if let cached = treeChildrenCache[cacheKey] {
            // v1.3.zz 流式修复 ②：扫描进行中时，cache 里的"空快照"会被周期性清掉
            // （见 invalidateEmptyCachesDuringScan），这里只在真正命中**非空** cache 时才返回。
            // 这样可以解决"第一次树形出来就空，再切回来还空"的死锁——
            // 扫描中从来不让一个空结果被钉死。
            if !cached.isEmpty || !isScanning {
                return cached
            }
        }
        // cache miss：启动 staged fetch（同 path 复用，不重复发）。
        if !isScanning, !treeChildrenInFlight.contains(cacheKey) {
            startTreeChildrenFetch(path: path, sortedBy: key, cacheKey: cacheKey)
        }
        return []
    }

    @MainActor
    private func startTreeChildrenFetch(path: String, sortedBy key: TreeSortKey, cacheKey: String) {
        treeChildrenInFlight.insert(cacheKey)
        GSYLog.info(.flow, "tree.children.fetch.start path=\(path) sort=\(key.rawValue)")
        let dispatchedGeneration = treeFetchGeneration
        let accessProjection = treeScanEvidenceProjection

        Task { [weak self] in
            guard let self else { return }
            let shallowStarted = DispatchTime.now().uptimeNanoseconds
            let shallowRows = await Task.detached(priority: .userInitiated) {
                Self.scanDirectChildrenShallow(
                    rootPath: path,
                    sortedBy: key,
                    accessProjection: accessProjection
                )
            }.value
            let shallowElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - shallowStarted) / 1_000_000

            await MainActor.run {
                guard dispatchedGeneration == self.treeFetchGeneration else {
                    self.treeChildrenInFlight.remove(cacheKey)
                    GSYLog.info(.flow, "tree.children.fetch.drop_stale_stage=shallow path=\(path) sort=\(key.rawValue) rows=\(shallowRows.count) elapsed_ms=\(String(format: "%.2f", shallowElapsedMs))")
                    return
                }
                if !shallowRows.isEmpty, !self.isScanning {
                    self.storeFetchedChildren(path: path, sortedBy: key, rows: shallowRows)
                    GSYLog.info(.flow, "tree.children.fetch.shallow path=\(path) sort=\(key.rawValue) rows=\(shallowRows.count) elapsed_ms=\(String(format: "%.2f", shallowElapsedMs))")
                }
            }

            let shouldContinue = await MainActor.run {
                dispatchedGeneration == self.treeFetchGeneration && !self.isScanning
            }
            guard shouldContinue else {
                _ = await MainActor.run { self.treeChildrenInFlight.remove(cacheKey) }
                return
            }

            await Self.treeChildrenFetchGate.acquire()
            if Task.isCancelled {
                await Self.treeChildrenFetchGate.release()
                _ = await MainActor.run { self.treeChildrenInFlight.remove(cacheKey) }
                return
            }

            let deepStarted = DispatchTime.now().uptimeNanoseconds
            let rows = await self.directChildrenAsync(of: path, sortedBy: key)
            await Self.treeChildrenFetchGate.release()
            let deepElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - deepStarted) / 1_000_000

            await MainActor.run {
                guard dispatchedGeneration == self.treeFetchGeneration else {
                    self.treeChildrenInFlight.remove(cacheKey)
                    GSYLog.info(.flow, "tree.children.fetch.drop_stale_stage=deep path=\(path) sort=\(key.rawValue) rows=\(rows.count) elapsed_ms=\(String(format: "%.2f", deepElapsedMs))")
                    return
                }
                if rows.isEmpty && self.isScanning {
                    self.treeChildrenInFlight.remove(cacheKey)
                    GSYLog.info(.flow, "tree.children.fetch.drop_scanning path=\(path) sort=\(key.rawValue) elapsed_ms=\(String(format: "%.2f", deepElapsedMs))")
                    return
                }
                self.storeFetchedChildren(path: path, sortedBy: key, rows: rows)
                self.treeChildrenInFlight.remove(cacheKey)
                GSYLog.info(.flow, "tree.children.fetch.finish path=\(path) sort=\(key.rawValue) rows=\(rows.count) elapsed_ms=\(String(format: "%.2f", deepElapsedMs))")
                // v2026.06.21 性能：这里仍只 bump childrenCacheVersion，避免每次后台
                // 回写都触发整树 structural rebuild。
            }
        }
    }

    /// 后台按需子节点扫描结果的唯一写入口。
    ///
    /// 除了写 `path|sortKey` 自身 cache，还会把 `path` 这条父行同步回已存在的祖先 cache。
    /// 这样可以避免竞态下出现"父目录仍是 0KB，但展开后子项已经有几十 GB"的视觉矛盾：
    /// 子层 cache 回来后，父层 cache 里的同 path 行至少要与子层聚合保持一致。
    @MainActor
    private func storeFetchedChildren(path: String, sortedBy key: TreeSortKey, rows: [TreeRow]) {
        let cacheKey = "\(path)|\(key.rawValue)"
        guard !isDeletedTombstoned(path) else {
            treeChildrenCache.removeValue(forKey: cacheKey)
            bumpChildrenCacheVersion()
            return
        }
        let visibleRows = rows.filter { !isDeletedTombstoned($0.path) }
        treeChildrenCache[cacheKey] = visibleRows
        reconcileCachedParentRows(parentPath: path, children: visibleRows)
        bumpChildrenCacheVersion()
    }

    @MainActor
    private func reconcileCachedParentRows(parentPath: String, children: [TreeRow]) {
        guard !children.isEmpty else { return }
        let childBytes = children.reduce(Int64(0)) { $0 + $1.bytes }
        let childLogicalBytes = children.reduce(Int64(0)) { $0 + $1.logicalBytes }
        let childFileCount = children.reduce(0) { $0 + $1.fileCount }
        var updates: [(String, [TreeRow])] = []
        updates.reserveCapacity(2)

        for (cacheKey, rows) in treeChildrenCache {
            guard let idx = rows.firstIndex(where: { $0.path == parentPath }) else { continue }
            var updated = rows
            let old = rows[idx]
            let projectedState = projectedTreeState(
                for: old.path,
                fallbackAccessState: old.accessState,
                fallbackSubtreeCompleteness: old.subtreeCompleteness
            )
            updated[idx] = TreeRow(
                path: old.path,
                title: old.title,
                bytes: max(old.bytes, childBytes),
                logicalBytes: max(old.logicalBytes, childLogicalBytes),
                fileCount: max(old.fileCount, childFileCount),
                isDirectory: old.isDirectory,
                hasChildren: old.hasChildren || !children.isEmpty,
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: old.modificationDate,
                isSizePending: children.contains(where: \.isSizePending)
            )
            let sortKey = Self.sortKeyFromCacheKey(cacheKey) ?? .sizeDesc
            updates.append((cacheKey, updated.sorted { Self.sortTreeRow($0, before: $1, by: sortKey) }))
        }

        for (cacheKey, rows) in updates {
            treeChildrenCache[cacheKey] = rows
        }
    }

    nonisolated private static func sortKeyFromCacheKey(_ cacheKey: String) -> TreeSortKey? {
        guard let pipe = cacheKey.lastIndex(of: "|") else { return nil }
        return TreeSortKey(rawValue: String(cacheKey[cacheKey.index(after: pipe)...]))
    }

    /// 扫描完成后的轻量预热：只预取当前树表最可能被点击的顶层目录，降低首次展开等待。
    ///
    /// 约束：
    /// - 扫描中不跑，避免和主扫描争 IO；
    /// - deepIndex 已有内存索引时不跑；
    /// - 路径已 cache / in-flight 时不重复；
    /// - 顺序执行，避免全盘根下同时扫多个大目录造成新的卡顿。
    @MainActor
    public func prefetchTreeChildren(paths: [String], sortedBy key: TreeSortKey, limit: Int = 4) {
        guard !isScanning, !enableTreeDeepIndex else { return }
        if shouldSuppressAutomaticTreePrefetch {
            GSYLog.info(.flow, "tree.children.prefetch.skip reason=full_disk_root")
            return
        }
        var targets: [(path: String, cacheKey: String)] = []
        targets.reserveCapacity(min(paths.count, limit))
        for path in paths {
            guard targets.count < limit else { break }
            guard childEdges[path] == nil else { continue }
            let cacheKey = "\(path)|\(key.rawValue)"
            guard treeChildrenCache[cacheKey] == nil,
                  !treeChildrenInFlight.contains(cacheKey)
            else { continue }
            targets.append((path, cacheKey))
        }
        guard !targets.isEmpty else { return }
        GSYLog.info(.flow, "tree.children.prefetch.start count=\(targets.count) sort=\(key.rawValue)")
        for target in targets {
            startTreeChildrenFetch(path: target.path, sortedBy: key, cacheKey: target.cacheKey)
        }
    }

    /// 全盘扫描根 `/` 的最终快照已经持有一级目录聚合值。这里如果自动预取 `/Users`、
    /// `/System` 等顶层目录，会在扫描结束后立刻二次深扫整盘主分支；用户按 Space 预览或
    /// 继续操作时会和这轮重 IO 抢资源。保留用户主动展开时的按需 fetch，只禁止无人触发的
    /// top-level prefetch。
    private var shouldSuppressAutomaticTreePrefetch: Bool {
        currentRootPath == "/" && snapshot.categoryID == ScanCategory.fullDisk.id
    }

    /// 扫描结束时作废展开缓存，下一次 view body 会按当前最终快照重新拉取。
    /// in-flight 集合不清，让正在飞的 task 自然写回；写回时 generation 会拦掉过期结果。
    @MainActor
    fileprivate func invalidateTreeCacheAfterScan() {
        treeChildrenCache.removeAll(keepingCapacity: true)
        bumpChildrenCacheVersion()
        bumpStructuralRevision()
    }

    /// v2026.06 用户反馈 #1：Tree 右键"刷新此目录"入口。
    ///
    /// **范围**：仅清掉按需子树扫描缓存（[treeChildrenCache](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L299)）
    /// 中以 `path` 为根的所有 cacheKey（含子目录、所有 sortKey 组合），并触发
    /// [bumpStructuralRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L379)
    /// 让 [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 重新走 [directChildren(of:sortedBy:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1422)
    /// → 后台重新扫描该目录。
    ///
    /// **不做的事**：
    /// 1. 不重启 BulkScanner（那是 runScan 入口的事），全量扫描成本无法承担在右键菜单里；
    /// 2. 不改 `childEdges`（扫描期内存索引）——若该 path 命中 childEdges，下一帧 SwiftUI 仍走
    ///    [materializeFromMemory](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1432)
    ///    返回 internal 索引（这是按设计：扫描态下树形已经是最新的，缓存只是冷启动的兜底）。
    /// 3. 不动 in-flight 集合，让正在飞的 task 自然写回（跨会话守卫已经保护好脏数据）。
    ///
    /// 用户在 deepIndex=off 路径下右键刷新一个目录，相当于丢掉该目录的展开缓存并重扫。
    /// 典型场景：浏览器 cache / Xcode DerivedData 在 app 后台跑过一轮，
    /// 用户回来发现 size 对不上，右键 refresh 即可。
    @MainActor
    public func rescanSubtree(at path: String) {
        GSYLog.notice(.operation, "tree.subtree.refresh path=\(path)")
        let prefixSelf = "\(path)|"
        let prefixChildren = "\(path)/"
        let removedKeys = treeChildrenCache.keys.filter { key in
            key.hasPrefix(prefixSelf) || key.hasPrefix(prefixChildren)
        }
        guard !removedKeys.isEmpty || childEdges[path] == nil else {
            // 内存索引命中（扫描期最新数据）且无按需缓存：无需任何动作。
            return
        }
        for key in removedKeys {
            treeChildrenCache.removeValue(forKey: key)
        }
        bumpChildrenCacheVersion()
        bumpStructuralRevision()
    }

    private struct PruneContribution: Sendable {
        let path: String
        var bytes: Int64
        var logicalBytes: Int64
        var fileCount: Int

        mutating func add(_ other: PruneContribution) {
            bytes &+= other.bytes
            logicalBytes &+= other.logicalBytes
            fileCount &+= other.fileCount
        }
    }

    /// 目录边界匹配器。把父子重复的删除路径压成最小根集合，再用 ancestor Set
    /// 查询代替“每个候选 × 每个删除路径”的嵌套扫描。
    private struct PrunedPathMatcher: Sendable {
        let roots: [String]
        private let rootSet: Set<String>

        init<S: Sequence>(paths: S) where S.Element == String {
            let unique = Set(paths.lazy.map(Self.normalize).filter { !$0.isEmpty })
            let sorted = unique.sorted()
            var minimal: [String] = []
            var minimalSet: Set<String> = []
            minimal.reserveCapacity(sorted.count)
            minimalSet.reserveCapacity(sorted.count)
            for path in sorted {
                if Self.hasAncestor(of: path, in: minimalSet) {
                    continue
                }
                minimal.append(path)
                minimalSet.insert(path)
            }
            roots = minimal
            rootSet = minimalSet
        }

        func contains(_ candidate: String) -> Bool {
            matchingRoot(for: candidate) != nil
        }

        func matchingRoot(for candidate: String) -> String? {
            guard !candidate.isEmpty else { return nil }
            if rootSet.contains("/"), candidate.hasPrefix("/") { return "/" }
            var cursor = Self.normalize(candidate)
            while !cursor.isEmpty {
                if rootSet.contains(cursor) { return cursor }
                if cursor == "/" { break }
                let parent = String._gsyParentPath(of: cursor)
                if parent == cursor { break }
                cursor = parent
            }
            return nil
        }

        private static func normalize(_ path: String) -> String {
            var value = path
            while value.count > 1, value.hasSuffix("/") {
                value.removeLast()
            }
            return value
        }

        private static func hasAncestor(of candidate: String, in roots: Set<String>) -> Bool {
            if roots.contains("/"), candidate.hasPrefix("/") { return true }
            var cursor = candidate
            while !cursor.isEmpty {
                if roots.contains(cursor) { return true }
                if cursor == "/" { break }
                let parent = String._gsyParentPath(of: cursor)
                if parent == cursor { break }
                cursor = parent
            }
            return false
        }
    }

    /// tombstone matcher 的不可变引用壳。引用替换是 O(1)，并让旧 Set/Array storage
    /// 能被 prune worker 持有到 MainActor commit 之后再于后台显式释放。
    private final class DeletedPathIndex: Sendable {
        static let empty = DeletedPathIndex(matcher: PrunedPathMatcher(paths: EmptyCollection<String>()))

        let matcher: PrunedPathMatcher

        init(matcher: PrunedPathMatcher) {
            self.matcher = matcher
        }
    }

    private actor DeletedPathRetirementWorker {
        private var retainedIndex: DeletedPathIndex?

        init(index: DeletedPathIndex) {
            retainedIndex = index
        }

        func retire() {
            retainedIndex = nil
        }
    }

    private actor PruneRequestPathRetirementWorker {
        private var retainedPaths: [String]?

        init(paths: [String]) {
            retainedPaths = paths
        }

        func retire() {
            retainedPaths = nil
        }
    }

    /// deep-index 关闭时，按需树缓存是删除前仍可用的权威子树统计来源。
    /// 同一路径会因不同排序键出现在多个 cache entry；这里先按 path 取最大完整值去重，
    /// 再为“完整 direct-children cache”聚合父目录贡献，避免父行 + 子行重复累计。
    private struct TreeCacheContributionIndex: Sendable {
        private let exactByPath: [String: PruneContribution]
        private let aggregateByParent: [String: PruneContribution]

        init(cache: [String: [TreeRow]]) {
            var exact: [String: PruneContribution] = [:]
            var completeChildrenByParent: [String: [String: PruneContribution]] = [:]

            for (cacheKey, rows) in cache {
                let parentPath: String
                if let pipe = cacheKey.lastIndex(of: "|") {
                    parentPath = String(cacheKey[..<pipe])
                } else {
                    parentPath = cacheKey
                }

                let isCompleteEntry = rows.allSatisfy {
                    !$0.isSizePending && $0.hasCompleteAccessEvidence
                }
                if isCompleteEntry, completeChildrenByParent[parentPath] == nil {
                    // 空数组同样是“已完整枚举且贡献为 0”，不能与 cache miss 混淆。
                    completeChildrenByParent[parentPath] = [:]
                }

                for row in rows where !row.isSizePending && row.hasCompleteAccessEvidence {
                    let item = PruneContribution(
                        path: row.path,
                        bytes: row.bytes,
                        logicalBytes: row.logicalBytes,
                        fileCount: row.fileCount
                    )
                    exact[row.path] = Self.preferred(exact[row.path], item)
                    if isCompleteEntry {
                        let current = completeChildrenByParent[parentPath]?[row.path]
                        completeChildrenByParent[parentPath]?[row.path] = Self.preferred(current, item)
                    }
                }
            }

            var aggregate: [String: PruneContribution] = [:]
            aggregate.reserveCapacity(completeChildrenByParent.count)
            for (parent, children) in completeChildrenByParent {
                var value = PruneContribution(path: parent, bytes: 0, logicalBytes: 0, fileCount: 0)
                for child in children.values {
                    value.add(child)
                }
                aggregate[parent] = value
            }
            exactByPath = exact
            aggregateByParent = aggregate
        }

        func contribution(for path: String) -> PruneContribution? {
            exactByPath[path] ?? aggregateByParent[path]
        }

        private static func preferred(_ current: PruneContribution?,
                                      _ candidate: PruneContribution) -> PruneContribution {
            guard let current else { return candidate }
            return PruneContribution(
                path: candidate.path,
                bytes: max(current.bytes, candidate.bytes),
                logicalBytes: max(current.logicalBytes, candidate.logicalBytes),
                fileCount: max(current.fileCount, candidate.fileCount)
            )
        }
    }

    /// MainActor 上只取得这些 COW storage 的不可变快照；真正触发 copy/mutate 的第一笔
    /// 写发生在 `PruneStateWorker` actor 中，不在 UI executor 上做全表遍历。
    private struct PruneStateSnapshot: Sendable {
        let snapshot: ScanSnapshot
        let totalBytes: Int64
        let scannedFiles: Int
        let buckets: [String: Bucket]
        let dirIndex: [String: DirAgg]
        let childEdges: [String: Set<String>]
        let fileLeaves: [String: (bytes: Int64, logicalBytes: Int64, isDir: Bool, modificationDate: Date?)]
        let treeChildrenCache: [String: [TreeRow]]
        let largeFileLeaves: LargeFileLeafTopNHeap
        let compactedLargeFileTopN: [LargeFileLeaf]?
        let perRootStaging: [String: PerRootProgress]
        let perRootActive: [String: PerRootProgress]
        let perRootFinished: [String: PerRootProgress]
        /// commit 会替换的其余 COW storage 也必须由 worker 跨过 MainActor swap 强持有。
        let perRootSorted: [PerRootProgress]
        let previousPrunedPaths: [String]?
    }

    private struct PrunePlan: Sendable {
        let prunedRoots: [String]
        let snapshot: ScanSnapshot
        let totalBytes: Int64
        let scannedFiles: Int
        let buckets: [String: Bucket]
        let dirIndex: [String: DirAgg]
        let childEdges: [String: Set<String>]
        let fileLeaves: [String: (bytes: Int64, logicalBytes: Int64, isDir: Bool, modificationDate: Date?)]
        let treeChildrenCache: [String: [TreeRow]]
        let largeFileLeaves: LargeFileLeafTopNHeap
        let compactedLargeFileTopN: [LargeFileLeaf]?
        let perRootStaging: [String: PerRootProgress]
        let perRootActive: [String: PerRootProgress]
        let perRootFinished: [String: PerRootProgress]
        let perRootFinishedCount: Int
        let perRootSorted: [PerRootProgress]
        let largeRemoved: Int
        let compactedLargeRemoved: Int
        let ranOnMainThread: Bool
        var durationNanoseconds: UInt64 = 0
    }

    private struct PreparedPrune: Sendable {
        let tombstones: DeletedPathIndex
        let plan: PrunePlan
        let mergeRanOnMainThread: Bool
    }

    private struct PruneRetirementDiagnostics: Sendable {
        let ranOnMainThread: Bool
        let durationNanoseconds: UInt64
    }

    /// 持有删除前全部 COW storage 与旧 tombstone index，直到 MainActor 完成 O(1) commit。
    /// `retire` 在本 actor 的 generic executor 上把最后引用置 nil，避免 Dictionary/Array
    /// 大量元素析构占用 UI 帧。actor 本身是 Sendable，不需要 unchecked 逃逸并发检查。
    private actor PruneStateWorker {
        private var retainedState: PruneStateSnapshot?
        private var retainedTombstones: DeletedPathIndex?
        private var requestedPaths: [String]?

        init(state: PruneStateSnapshot,
             tombstones: DeletedPathIndex,
             requestedPaths: [String]) {
            retainedState = state
            retainedTombstones = tombstones
            self.requestedPaths = requestedPaths
        }

        func prepare() -> PreparedPrune? {
            guard let state = retainedState,
                  let previous = retainedTombstones,
                  let requestedPaths else { return nil }

            var mergedPaths = previous.matcher.roots
            mergedPaths.reserveCapacity(mergedPaths.count + requestedPaths.count)
            mergedPaths.append(contentsOf: requestedPaths)
            let matcher = PrunedPathMatcher(paths: mergedPaths)
            let mergeRanOnMainThread = Thread.isMainThread

            let started = DispatchTime.now().uptimeNanoseconds
            var plan = ScanCoordinator.makePrunePlan(from: state, matcher: matcher)
            plan.durationNanoseconds = DispatchTime.now().uptimeNanoseconds - started
            return PreparedPrune(
                tombstones: DeletedPathIndex(matcher: matcher),
                plan: plan,
                mergeRanOnMainThread: mergeRanOnMainThread
            )
        }

        func retire(beforeRelease: (@Sendable () async -> Void)? = nil) async
            -> PruneRetirementDiagnostics {
            if let beforeRelease {
                await beforeRelease()
            }
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            retainedState = nil
            retainedTombstones = nil
            requestedPaths = nil
            return PruneRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    /// Foundation 把 `Thread.isMainThread` 标成 async-unavailable；诊断只读线程标签，
    /// 经同步 nonisolated helper 读取，不把任何业务隔离建立在线程身份之上。
    private nonisolated static func currentThreadIsMainForDiagnostics() -> Bool {
        Thread.isMainThread
    }

    /// 把已成功移入废纸篓的路径从 ScanCoordinator 的全部派生数据源中原子剔除。
    ///
    /// O(N) 路径过滤、祖先聚合扣减、边集和树缓存重建全部由 worker actor 完成；
    /// MainActor 只做 COW 快照、generation/revision compare-and-swap 与最终 storage 提交。
    /// 若新扫描已开始，旧 plan 直接丢弃；同一会话若后台树缓存等状态有变化，则重取
    /// 最新快照重算，绝不让旧 plan 覆盖新状态。
    public func pruneDeleted(paths: [String]) async {
        await performPruneTransaction(paths: paths, beforeCommitForTesting: nil)
    }

    /// 测试专用确定性竞态注入：plan 已算完但 CAS 尚未执行时切换扫描代际，验证旧 plan
    /// 会被拒绝。生产调用永远传 nil，不引入延迟或分支依赖。
    func _pruneDeletedForTesting(
        paths: [String],
        beforeCommit: @escaping @MainActor @Sendable () -> Void,
        beforeRetire: (@Sendable () async -> Void)? = nil
    ) async {
        await performPruneTransaction(
            paths: paths,
            beforeCommitForTesting: beforeCommit,
            beforeRetireForTesting: beforeRetire
        )
    }

    /// `paths` 可能是上万条临时数组。必须在 perform 返回前先交给 actor 强持有，
    /// 下一 MainActor turn 才允许 generic executor 清空；否则函数参数会在 UI executor
    /// 成为最后一份 Array storage 引用并逐项析构。
    private func handOffPruneRequestPathsForRetirement(_ paths: [String]) {
        let retirementWorker = PruneRequestPathRetirementWorker(paths: paths)
        Task { @MainActor in
            await Task.yield()
            await retirementWorker.retire()
        }
    }

    private func performPruneTransaction(
        paths: [String],
        beforeCommitForTesting: (@MainActor @Sendable () -> Void)?,
        beforeRetireForTesting: (@Sendable () async -> Void)? = nil
    ) async {
        guard !paths.isEmpty else { return }

        let requestGeneration = pruneStateGeneration
        activePruneTransactionCount += 1
        defer { activePruneTransactionCount = max(0, activePruneTransactionCount - 1) }

        var pendingTestHook = beforeCommitForTesting

        while requestGeneration == pruneStateGeneration {
            let sourceRevision = pruneSourceRevision
            let worker = PruneStateWorker(
                state: capturePruneStateSnapshot(),
                tombstones: deletedPathTombstones,
                requestedPaths: paths
            )
            guard let prepared = await worker.prepare(),
                  !prepared.tombstones.matcher.roots.isEmpty else {
                _ = await worker.retire()
                handOffPruneRequestPathsForRetirement(paths)
                return
            }

            if let hook = pendingTestHook {
                pendingTestHook = nil
                hook()
            }
            guard requestGeneration == pruneStateGeneration else {
                _ = await worker.retire()
                handOffPruneRequestPathsForRetirement(paths)
                return
            }
            guard sourceRevision == pruneSourceRevision else {
                _ = await worker.retire()
                await Task.yield()
                continue
            }

            // 两个大状态都只做引用/storage swap；旧索引与旧 COW storage 仍由 worker
            // 强持有，因此下面的 MainActor 赋值不会触发其最后一次析构。
            deletedPathTombstones = prepared.tombstones
            lastPruneTombstoneMergeRanOnMainThread = prepared.mergeRanOnMainThread
            commitPrunePlan(prepared.plan)
            let retirement = await worker.retire(beforeRelease: beforeRetireForTesting)
            lastPruneRetirementRanOnMainThread = retirement.ranOnMainThread
            lastPruneRetirementDurationNanoseconds = retirement.durationNanoseconds
            handOffPruneRequestPathsForRetirement(paths)
            return
        }
        handOffPruneRequestPathsForRetirement(paths)
    }

    private func capturePruneStateSnapshot() -> PruneStateSnapshot {
        PruneStateSnapshot(
            snapshot: snapshot,
            totalBytes: totalBytes,
            scannedFiles: scannedFiles,
            buckets: buckets,
            dirIndex: dirIndex,
            childEdges: childEdges,
            fileLeaves: fileLeaves,
            treeChildrenCache: treeChildrenCache,
            largeFileLeaves: largeFileLeaves,
            compactedLargeFileTopN: compactedLargeFileTopN,
            perRootStaging: perRootStaging,
            perRootActive: perRootProgressActive,
            perRootFinished: perRootFinishedSlim,
            perRootSorted: perRootProgressSorted,
            previousPrunedPaths: lastPrunedPaths
        )
    }

    private nonisolated static func makePrunePlan(
        from state: PruneStateSnapshot,
        matcher: PrunedPathMatcher
    ) -> PrunePlan {
        var sourcePerRoot = state.perRootStaging
        if sourcePerRoot.isEmpty {
            sourcePerRoot = state.perRootFinished
            for (path, progress) in state.perRootActive {
                sourcePerRoot[path] = progress
            }
        }

        let rowsByID = Dictionary(uniqueKeysWithValues: state.snapshot.rows.map { ($0.id, $0) })
        let treeCacheContributions = TreeCacheContributionIndex(cache: state.treeChildrenCache)
        // large-file-only 会话不构建 rows/fileLeaves/dirIndex；Top-N heap 是用户可删
        // 文件唯一的精确贡献来源。主 heap 与 compact cache 可能在过渡态同时存在，
        // 按 path 去重并取较大字节，绝不能把同一叶子累计两次。
        var largeFileContributions: [String: PruneContribution] = [:]
        let largeFileCandidates = state.largeFileLeaves.snapshot()
            + (state.compactedLargeFileTopN ?? [])
        largeFileContributions.reserveCapacity(largeFileCandidates.count)
        for leaf in largeFileCandidates {
            let candidate = PruneContribution(
                path: leaf.path,
                bytes: leaf.bytes,
                logicalBytes: leaf.logicalBytes,
                fileCount: 1
            )
            if let current = largeFileContributions[leaf.path], current.bytes >= candidate.bytes {
                continue
            }
            largeFileContributions[leaf.path] = candidate
        }
        func contribution(for path: String) -> PruneContribution? {
            if let leaf = state.fileLeaves[path] {
                return PruneContribution(path: path, bytes: leaf.bytes,
                                         logicalBytes: leaf.logicalBytes, fileCount: 1)
            }
            if let agg = state.dirIndex[path] {
                return PruneContribution(path: path, bytes: agg.bytes,
                                         logicalBytes: agg.logicalBytes, fileCount: agg.fileCount)
            }
            if let bucket = state.buckets[path] {
                return PruneContribution(path: path, bytes: bucket.bytes,
                                         logicalBytes: bucket.logicalBytes, fileCount: bucket.fileCount)
            }
            if let row = rowsByID[path] {
                return PruneContribution(path: path, bytes: row.bytes,
                                         logicalBytes: row.logicalBytes, fileCount: row.fileCount)
            }
            if let progress = sourcePerRoot[path] {
                return PruneContribution(path: path, bytes: progress.bytes,
                                         logicalBytes: progress.logicalBytes, fileCount: progress.fileCount)
            }
            if let largeFile = largeFileContributions[path] {
                return largeFile
            }
            // deep-index=off 时深层目录不会进入 dirIndex/fileLeaves/buckets；用户展开树后，
            // 完整按需 cache 是文件移入废纸篓前最后一份精确子树贡献。
            return treeCacheContributions.contribution(for: path)
        }

        let indexedContributions = matcher.roots.compactMap(contribution(for:))
        let indexedMatcher = PrunedPathMatcher(paths: indexedContributions.map(\.path))
        let perRootContributions = sourcePerRoot.values.compactMap { progress -> PruneContribution? in
            guard matcher.contains(progress.rootPath),
                  !indexedMatcher.contains(progress.rootPath) else { return nil }
            return PruneContribution(path: progress.rootPath, bytes: progress.bytes,
                                     logicalBytes: progress.logicalBytes, fileCount: progress.fileCount)
        }
        let deletedContributions = indexedContributions + perRootContributions
        let totalDeletedBytes = deletedContributions.reduce(Int64(0)) { $0 &+ $1.bytes }
        let totalDeletedFiles = deletedContributions.reduce(0) { $0 &+ $1.fileCount }

        // 一次构建“祖先 -> 总扣减量”，snapshot rows / dirIndex / perRoot 后续均 O(1) 查表。
        var ancestorDecrements: [String: PruneContribution] = [:]
        ancestorDecrements.reserveCapacity(deletedContributions.count * 4)
        for item in deletedContributions {
            var cursor = String._gsyParentPath(of: item.path)
            while !cursor.isEmpty, cursor != "/" {
                if matcher.contains(cursor) { break }
                let delta = PruneContribution(path: cursor, bytes: item.bytes,
                                              logicalBytes: item.logicalBytes,
                                              fileCount: item.fileCount)
                if var current = ancestorDecrements[cursor] {
                    current.add(delta)
                    ancestorDecrements[cursor] = current
                } else {
                    ancestorDecrements[cursor] = delta
                }
                let parent = String._gsyParentPath(of: cursor)
                if parent == cursor { break }
                cursor = parent
            }
        }

        var newRows: [RowItem] = []
        newRows.reserveCapacity(state.snapshot.rows.count)
        var removedRowBytes: Int64 = 0
        for row in state.snapshot.rows {
            if matcher.contains(row.id) {
                removedRowBytes &+= row.bytes
                continue
            }
            guard let dec = ancestorDecrements[row.id],
                  dec.bytes > 0 || dec.logicalBytes > 0 || dec.fileCount > 0 else {
                newRows.append(row)
                continue
            }
            newRows.append(RowItem(
                id: row.id,
                url: row.url,
                title: row.title,
                isDirectory: row.isDirectory,
                bytes: max(0, row.bytes - dec.bytes),
                logicalBytes: max(0, row.logicalBytes - dec.logicalBytes),
                fileCount: max(0, row.fileCount - dec.fileCount),
                verdict: row.verdict,
                rejection: row.rejection,
                vendorName: row.vendorName,
                vendorNote: row.vendorNote,
                runningBundleIDPrefix: row.runningBundleIDPrefix,
                isActive: row.isActive,
                modificationDate: row.modificationDate
            ))
        }
        let snapshotBytesToSubtract = totalDeletedBytes > 0 ? totalDeletedBytes : removedRowBytes
        let nextSnapshot = ScanSnapshot(
            categoryID: state.snapshot.categoryID,
            rows: newRows,
            totalBytes: max(0, state.snapshot.totalBytes - snapshotBytesToSubtract),
            scannedFileCount: max(0, state.snapshot.scannedFileCount - totalDeletedFiles),
            isFinished: state.snapshot.isFinished,
            elapsed: state.snapshot.elapsed,
            isComplete: state.snapshot.isComplete,
            bytesPerSecond: state.snapshot.bytesPerSecond,
            estimatedRemaining: state.snapshot.estimatedRemaining
        )

        var nextDirIndex = state.dirIndex
        for (ancestor, dec) in ancestorDecrements {
            guard var agg = nextDirIndex[ancestor] else { continue }
            agg.bytes = max(0, agg.bytes - dec.bytes)
            agg.logicalBytes = max(0, agg.logicalBytes - dec.logicalBytes)
            agg.fileCount = max(0, agg.fileCount - dec.fileCount)
            nextDirIndex[ancestor] = agg
        }
        nextDirIndex = nextDirIndex.filter { !matcher.contains($0.key) }

        var nextPerRoot: [String: PerRootProgress] = [:]
        nextPerRoot.reserveCapacity(sourcePerRoot.count)
        for (rootPath, progress) in sourcePerRoot where !matcher.contains(rootPath) {
            if let dec = ancestorDecrements[rootPath],
               dec.bytes > 0 || dec.logicalBytes > 0 || dec.fileCount > 0 {
                var updated = progress
                updated.bytes = max(0, updated.bytes - dec.bytes)
                updated.logicalBytes = max(0, updated.logicalBytes - dec.logicalBytes)
                updated.fileCount = max(0, updated.fileCount - dec.fileCount)
                nextPerRoot[rootPath] = updated
            } else {
                nextPerRoot[rootPath] = progress
            }
        }
        var nextActive: [String: PerRootProgress] = [:]
        var nextFinished: [String: PerRootProgress] = [:]
        nextActive.reserveCapacity(nextPerRoot.count)
        nextFinished.reserveCapacity(nextPerRoot.count)
        for (path, progress) in nextPerRoot {
            if progress.isFinished {
                nextFinished[path] = progress
            } else {
                nextActive[path] = progress
            }
        }
        let nextSorted = nextPerRoot.values.sorted { $0.rootPath < $1.rootPath }

        var nextLargeFileLeaves = state.largeFileLeaves
        let largeRemoved = nextLargeFileLeaves.removeAll { matcher.contains($0.path) }
        var nextCompacted = state.compactedLargeFileTopN
        let compactedLargeRemoved: Int
        if var cache = nextCompacted {
            let before = cache.count
            cache.removeAll { matcher.contains($0.path) }
            compactedLargeRemoved = before - cache.count
            nextCompacted = cache
        } else {
            compactedLargeRemoved = 0
        }

        var nextChildEdges: [String: Set<String>] = [:]
        nextChildEdges.reserveCapacity(state.childEdges.count)
        for (parent, children) in state.childEdges where !matcher.contains(parent) {
            nextChildEdges[parent] = Set(children.lazy.filter { !matcher.contains($0) })
        }

        var nextTreeCache: [String: [TreeRow]] = [:]
        nextTreeCache.reserveCapacity(state.treeChildrenCache.count)

        // A cached parent row owns its disclosure state, while the actual direct children live in
        // a separate `parent|sort` entry. Resolve the post-delete child state once across all sort
        // variants so deleting the last child removes the stale empty chevron immediately. When no
        // cache exists for a path we preserve the row's prior value instead of guessing.
        var cachedParentHasSurvivingChildren: [String: Bool] = [:]
        cachedParentHasSurvivingChildren.reserveCapacity(state.treeChildrenCache.count)
        for (cacheKey, rows) in state.treeChildrenCache {
            let parentPath: String
            if let pipe = cacheKey.lastIndex(of: "|") {
                parentPath = String(cacheKey[..<pipe])
            } else {
                parentPath = cacheKey
            }
            guard !matcher.contains(parentPath) else { continue }
            let hasSurvivingChild = rows.contains { !matcher.contains($0.path) }
            cachedParentHasSurvivingChildren[parentPath] =
                (cachedParentHasSurvivingChildren[parentPath] ?? false) || hasSurvivingChild
        }

        for (cacheKey, rows) in state.treeChildrenCache {
            let parentPath: String
            if let pipe = cacheKey.lastIndex(of: "|") {
                parentPath = String(cacheKey[..<pipe])
            } else {
                parentPath = cacheKey
            }
            if matcher.contains(parentPath) { continue }

            var nextRows: [TreeRow] = []
            nextRows.reserveCapacity(rows.count)
            for row in rows where !matcher.contains(row.path) {
                let decrement = ancestorDecrements[row.path]
                let hasAggregateChange = decrement.map {
                    $0.bytes > 0 || $0.logicalBytes > 0 || $0.fileCount > 0
                } ?? false
                let updatedHasChildren = cachedParentHasSurvivingChildren[row.path]
                    ?? row.hasChildren
                guard hasAggregateChange || updatedHasChildren != row.hasChildren else {
                    nextRows.append(row)
                    continue
                }

                // deep-index 关闭时，已展开目录只存在于按需 cache。删除其后代后，
                // 必须与 snapshot/dirIndex/perRoot 在同一个 prune plan 内扣减祖先行；
                // 否则磁盘已删除但 Tree 会一直显示旧大小，直到用户重扫或重新展开。
                // 这里只更新聚合字段，其余访问证据、展开能力和元数据必须原样保留。
                nextRows.append(TreeRow(
                    path: row.path,
                    title: row.title,
                    bytes: max(0, row.bytes - (decrement?.bytes ?? 0)),
                    logicalBytes: max(0, row.logicalBytes - (decrement?.logicalBytes ?? 0)),
                    fileCount: max(0, row.fileCount - (decrement?.fileCount ?? 0)),
                    isDirectory: row.isDirectory,
                    hasChildren: updatedHasChildren,
                    accessState: row.accessState,
                    subtreeCompleteness: row.subtreeCompleteness,
                    modificationDate: row.modificationDate,
                    isSizePending: row.isSizePending
                ))
            }
            nextTreeCache[cacheKey] = nextRows
        }

        return PrunePlan(
            prunedRoots: matcher.roots,
            snapshot: nextSnapshot,
            totalBytes: snapshotBytesToSubtract > 0
                ? max(0, state.totalBytes - snapshotBytesToSubtract)
                : state.totalBytes,
            scannedFiles: totalDeletedFiles > 0
                ? max(0, state.scannedFiles - totalDeletedFiles)
                : state.scannedFiles,
            buckets: state.buckets.filter { !matcher.contains($0.key) },
            dirIndex: nextDirIndex,
            childEdges: nextChildEdges,
            fileLeaves: state.fileLeaves.filter { !matcher.contains($0.key) },
            treeChildrenCache: nextTreeCache,
            largeFileLeaves: nextLargeFileLeaves,
            compactedLargeFileTopN: nextCompacted,
            perRootStaging: nextPerRoot,
            perRootActive: nextActive,
            perRootFinished: nextFinished,
            perRootFinishedCount: nextFinished.count,
            perRootSorted: nextSorted,
            largeRemoved: largeRemoved,
            compactedLargeRemoved: compactedLargeRemoved,
            ranOnMainThread: Thread.isMainThread
        )
    }

    /// Compare-and-swap 已在调用方完成。这里不再做任何 keys.filter / sort / reduce；
    /// Dictionary/Array storage 赋值是 O(1) COW 提交，随后只发布必要 revision。
    private func commitPrunePlan(_ plan: PrunePlan) {
        snapshot = plan.snapshot
        totalBytes = plan.totalBytes
        scannedFiles = plan.scannedFiles
        buckets = plan.buckets
        dirIndex = plan.dirIndex
        childEdges = plan.childEdges
        fileLeaves = plan.fileLeaves
        treeChildrenCache = plan.treeChildrenCache
        largeFileLeaves = plan.largeFileLeaves
        compactedLargeFileTopN = plan.compactedLargeFileTopN
        perRootStaging = plan.perRootStaging
        perRootProgressActive = plan.perRootActive
        perRootFinishedSlim = plan.perRootFinished
        perRootFinishedCount = plan.perRootFinishedCount
        perRootProgressSorted = plan.perRootSorted

        lastPrunedPaths = plan.prunedRoots
        lastPrunePlanRanOnMainThread = plan.ranOnMainThread
        lastPrunePlanDurationNanoseconds = plan.durationNanoseconds
        bumpChildrenCacheVersion()
        bumpStructuralRevision()
        storeRevision &+= 1

        if plan.largeRemoved > 0 {
            GSYLog.info(.scan, "pruneDeleted largeFileLeaves 剔除 \(plan.largeRemoved)")
        }
        if plan.compactedLargeRemoved > 0 {
            GSYLog.info(.scan, "pruneDeleted compactedLargeFileTopN 剔除 \(plan.compactedLargeRemoved)")
        }
    }

    /// v1.3.zz：暴露给 [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 区分"后台 fetch 还在飞" vs "真的查到 0 条子项"——
    /// 前者应显 ProgressView 占位避免误导用户以为没数据；后者才显"还没有可展开的子节点"。
    ///
    /// 实现：cacheKey 在 `treeChildrenInFlight` 集合里，表示后台按需扫描已经派发但 cache 还没写回。
    public func isFetchingChildren(of path: String, sortedBy key: TreeSortKey) -> Bool {
        // 扫描中树表不做子节点加载，避免"扫描还没结束却显示正在加载子节点"。
        if isScanning { return false }
        // v1.5：多根伪路径下 directChildren 是同步合成（perRootProgress），不存在 fetching。
        if ScanCoordinator.multiRootSentinelPaths.contains(path) { return false }
        // 内存命中或 deepIndex=on 时，directChildren 已是同步路径，不存在 fetching。
        if childEdges[path] != nil { return false }
        guard !enableTreeDeepIndex else { return false }
        let cacheKey = "\(path)|\(key.rawValue)"
        if treeChildrenInFlight.contains(cacheKey) { return true }
        if treeChildrenCache[cacheKey] != nil { return false }
        return false
    }

    /// v1.5：多根扫描伪路径下合成"顶层" TreeRow——把 perRootProgress 里的真实根
    /// 升级成树形顶层节点。每行 path 是真实目录（如 ~/Library/Caches），
    /// 用户展开时 TreeBrowserView 会再次调 [directChildren(of:sortedBy:)](#) 拿真实的下一层
    /// （走原 childEdges / 按需子树扫描路径，无需改动）。
    /// - bytes / fileCount 直接复用 已统计好的值
    /// - title 沿用 .title（已带 displayName + 短路径）
    ///
    /// 扫描中不再由树表读取 staging；这里在完成态优先读已经发布给 UI 的
    /// perRootProgress，避免最终列表继续拿到 staging 里的半成品 inode 行。
    /// review-fix #6：hasChildren 不再硬编码 true—— fileCount==0 的 root（discover
    /// 命中但还未 ingest，或扫完确实空）就不显示披露三角，避免"展开后空树"的误导。
    private func synthesizeMultiRootTopLevel(sortedBy key: TreeSortKey) -> [TreeRow] {
        let source: [String: PerRootProgress]
        if isScanning {
            source = perRootStaging.isEmpty ? perRootProgress : perRootStaging
        } else {
            source = perRootProgress.isEmpty ? perRootStaging : perRootProgress
        }
        let rows: [TreeRow] = source.values.compactMap { p in
            guard !isDeletedTombstoned(p.rootPath) else { return nil }
            let fallbackSubtreeCompleteness: TreeRow.SubtreeCompleteness =
                p.isPartial || (!isScanning && !p.isFinished)
                ? .containsIncompleteDescendant
                : .complete
            let projectedState = projectedTreeState(
                for: p.rootPath,
                fallbackSubtreeCompleteness: fallbackSubtreeCompleteness
            )
            return TreeRow(
                path: p.rootPath,
                title: p.title,
                bytes: p.bytes,
                logicalBytes: p.logicalBytes,
                fileCount: p.fileCount,
                isDirectory: true,
                hasChildren: p.fileCount > 0,
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness
            )
        }
        return sortTreeRows(rows, by: key)
    }

    /// v2026.06.21：开发者旧版本扫描结束后的 TreeBrowserView 顶层合成。
    ///
    /// 与 [synthesizeMultiRootTopLevel] 的区别：旧版本扫描不进 BulkScanner 管线，
    /// `perRootProgress` 永远空；hits 都已经放在 `snapshot.rows` 里（title 是带
    /// i18n 与版本号的 "iOS DeviceSupport · 18.0" 这种），所以直接把 snapshot.rows
    /// 上升成 TreeRow。`hasChildren=false`——TreeBrowserView 拿这个判定不画披露
    /// 三角；用户要看具体子文件可在 Finder 里展开（与多根 1-tier 风格一致）。
    private func synthesizeVersionedTopLevel(sortedBy key: TreeSortKey) -> [TreeRow] {
        let rows: [TreeRow] = snapshot.rows.map { row in
            let projectedState = projectedTreeState(for: row.url.path)
            return TreeRow(
                path: row.url.path,
                title: row.title,
                bytes: row.bytes,
                logicalBytes: row.logicalBytes,
                fileCount: row.fileCount,
                isDirectory: row.isDirectory,
                hasChildren: false,
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: row.modificationDate
            )
        }
        return sortTreeRows(rows, by: key)
    }

    /// v1.5：抽出 TreeRow 排序，给 synthesizeMultiRootTopLevel / 其他场景复用。
    /// 主键相等时统一按 path 升序兜底，保证 ForEach 不抖。
    private func sortTreeRows(_ rows: [TreeRow], by key: TreeSortKey) -> [TreeRow] {
        switch key {
        case .sizeDesc:
            return rows.sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.path < rhs.path
            }
        case .sizeAsc:
            return rows.sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes < rhs.bytes }
                return lhs.path < rhs.path
            }
        case .nameAsc:
            return rows.sorted { lhs, rhs in
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.path < rhs.path
            }
        case .nameDesc:
            return rows.sorted { lhs, rhs in
                if lhs.title != rhs.title { return lhs.title > rhs.title }
                return lhs.path < rhs.path
            }
        case .countDesc:
            return rows.sorted { lhs, rhs in
                if lhs.fileCount != rhs.fileCount { return lhs.fileCount > rhs.fileCount }
                return lhs.path < rhs.path
            }
        case .countAsc:
            return rows.sorted { lhs, rhs in
                if lhs.fileCount != rhs.fileCount { return lhs.fileCount < rhs.fileCount }
                return lhs.path < rhs.path
            }
        case .mtimeDesc:
            return rows.sorted { lhs, rhs in
                // nil 一律压最后，避免占位"最近"头部；与 LargeFile 排序一致
                let l = lhs.modificationDate, r = rhs.modificationDate
                if l == nil && r != nil { return false }
                if l != nil && r == nil { return true }
                if let l = l, let r = r, l != r { return l > r }
                return lhs.path < rhs.path
            }
        case .mtimeAsc:
            return rows.sorted { lhs, rhs in
                let l = lhs.modificationDate, r = rhs.modificationDate
                if l == nil && r != nil { return false }
                if l != nil && r == nil { return true }
                if let l = l, let r = r, l != r { return l < r }
                return lhs.path < rhs.path
            }
        }
    }

    /// 内存索引命中时的"老路径"渲染——抽出来给同步 directChildren 与 directChildrenAsync 复用。
    private func materializeFromMemory(kids: Set<String>, sortedBy key: TreeSortKey) -> [TreeRow] {
        let rows: [TreeRow] = kids.map { childPath in
            let projectedState = projectedTreeState(for: childPath)
            if let agg = dirIndex[childPath] {
                // 目录
                // v2026.06.20：agg.modificationDate 在"中间层 ancestor 目录"上经常为 nil
                // （BulkScanner 没单独 yield 该目录的 .node 事件，只把它当祖先累加 bytes）。
                // 用 [resolveDirMtimeFallback](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
                // lstat 一次拿磁盘 inode mtime，O(1) 缓存避免每帧 stat，让"修改时间"
                // 列对真实存在的目录都能显示出来。
                let mtime = agg.modificationDate ?? resolveDirMtimeFallback(forPath: childPath)
                return TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: agg.bytes,
                    logicalBytes: agg.logicalBytes,
                    fileCount: agg.fileCount,
                    isDirectory: true,
                    hasChildren: !(childEdges[childPath]?.isEmpty ?? true),
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness,
                    modificationDate: mtime
                )
            } else if let leaf = fileLeaves[childPath] {
                // 文件
                return TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: leaf.bytes,
                    logicalBytes: leaf.logicalBytes,
                    fileCount: 1,
                    isDirectory: leaf.isDir,
                    hasChildren: false,
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness,
                    modificationDate: leaf.modificationDate
                )
            } else {
                return TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: 0,
                    fileCount: 0,
                    isDirectory: false,
                    hasChildren: false,
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness
                )
            }
        }
        return rows.sorted { (a, b) in
            Self.sortTreeRow(a, before: b, by: key)
        }
    }

    private func snapshotTopLevelRows(sortedBy key: TreeSortKey) -> [TreeRow] {
        let rows = snapshot.rows.map { row in
            var isDirValue = ObjCBool(row.isDirectory)
            let exists = FileManager.default.fileExists(atPath: row.url.path, isDirectory: &isDirValue)
            let isDirectory = exists ? isDirValue.boolValue : row.isDirectory
            let hasChildren = isDirectory && row.fileCount > 0
            let projectedState = projectedTreeState(for: row.url.path)
            return TreeRow(
                path: row.url.path,
                title: row.title,
                bytes: row.bytes,
                logicalBytes: row.logicalBytes,
                fileCount: row.fileCount,
                isDirectory: isDirectory,
                hasChildren: hasChildren,
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: row.modificationDate
            )
        }
        return rows.sorted { Self.sortTreeRow($0, before: $1, by: key) }
    }

    nonisolated private static func sortTreeRow(_ a: TreeRow, before b: TreeRow, by key: TreeSortKey) -> Bool {
        switch key {
        case .sizeDesc:
            if a.bytes != b.bytes { return a.bytes > b.bytes }
        case .sizeAsc:
            if a.bytes != b.bytes { return a.bytes < b.bytes }
        case .nameAsc:
            let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
            if cmp != .orderedSame { return cmp == .orderedAscending }
        case .nameDesc:
            let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
            if cmp != .orderedSame { return cmp == .orderedDescending }
        case .countDesc:
            if a.fileCount != b.fileCount { return a.fileCount > b.fileCount }
        case .countAsc:
            if a.fileCount != b.fileCount { return a.fileCount < b.fileCount }
        case .mtimeDesc:
            let av = a.modificationDate, bv = b.modificationDate
            if av == nil && bv != nil { return false }
            if av != nil && bv == nil { return true }
            if let l = av, let r = bv, l != r { return l > r }
        case .mtimeAsc:
            let av = a.modificationDate, bv = b.modificationDate
            if av == nil && bv != nil { return false }
            if av != nil && bv == nil { return true }
            if let l = av, let r = bv, l != r { return l < r }
        }
        return a.path < b.path
    }

    private struct OnDemandChildAggregate: Sendable {
        var path: String
        var title: String
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var directChildSeen: Bool = false
        var isDirectory: Bool = true
        var hasChildren: Bool = false
        var modificationDate: Date?
        var accessState: TreeRow.AccessState = .normal
        var subtreeCompleteness: TreeRow.SubtreeCompleteness = .complete
    }

    nonisolated private static func scanDirectChildrenShallow(rootPath: String,
                                                              sortedBy key: TreeSortKey,
                                                              accessProjection: TreeScanEvidenceProjection) -> [TreeRow] {
        var isRootDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isRootDirectory),
              isRootDirectory.boolValue
        else { return [] }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }

        let rows = urls.compactMap { url -> TreeRow? in
            let path = url.path
            let values = try? url.resourceValues(forKeys: keys)
            let isSymlink = values?.isSymbolicLink ?? false
            let isDirectory = (values?.isDirectory ?? false) && !isSymlink
            let projectedState = accessProjection.projectedState(for: path)
            let accessState = projectedState.accessState

            let bytes: Int64
            let logicalBytes: Int64
            let fileCount: Int
            if isDirectory {
                bytes = 0
                logicalBytes = 0
                fileCount = 0
            } else {
                let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize
                let logical = values?.totalFileSize ?? values?.fileSize
                // 不得回退到 logical size：那会把 sparse 虚拟容量混入磁盘占用主值。
                // 本地文件系统未提供 allocated 值时先展示 0；完整后台阶段仍由
                // BulkScanner 的 `st_blocks` 结果覆盖，而不是用另一种语义伪造一个数。
                bytes = Int64(max(0, allocated ?? 0))
                logicalBytes = Int64(max(0, logical ?? 0))
                fileCount = 1
            }

            return TreeRow(
                path: path,
                title: url.lastPathComponent,
                bytes: bytes,
                logicalBytes: logicalBytes,
                fileCount: fileCount,
                isDirectory: isDirectory,
                hasChildren: isDirectory && accessState == .normal,
                accessState: accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: values?.contentModificationDate,
                isSizePending: isDirectory && accessState == .normal
            )
        }

        return rows.sorted { Self.sortTreeRow($0, before: $1, by: key) }
    }

    nonisolated private static func scanDirectChildrenOnDemand(rootPath: String,
                                                               sortedBy key: TreeSortKey,
                                                               respectTCCSkipList: Bool,
                                                               accessProjection: TreeScanEvidenceProjection) async -> [TreeRow] {
        guard FileManager.default.fileExists(atPath: rootPath) else { return [] }

        var aggregates: [String: OnDemandChildAggregate] = [:]
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let scanner = BulkScanner(options: ScanOptions(
            includeHidden: true,
            includePackageContents: true,
            followSymlinks: false,
            followFirmlinks: false,
            dedupByInode: true,
            staySingleVolume: true,
            respectTCCSkipList: respectTCCSkipList
        ))

        for await event in scanner.scan(root: root) {
            switch event {
            case .node(let node):
                mergeOnDemandNode(node,
                                  rootPath: rootPath,
                                  into: &aggregates)
            case .nodes(let nodes):
                for node in nodes {
                    mergeOnDemandNode(node,
                                      rootPath: rootPath,
                                      into: &aggregates)
                }
            case .permissionDenied(let path):
                markOnDemandAccess(path,
                                   rootPath: rootPath,
                                   accessState: .permissionDenied,
                                   into: &aggregates)
            case .tccProtectedSkipped(let path):
                markOnDemandAccess(path,
                                   rootPath: rootPath,
                                   accessState: .tccProtected,
                                   into: &aggregates)
            case .incomplete(let issue):
                let accessState: TreeRow.AccessState
                switch issue.reason {
                case .permissionDenied:
                    accessState = .permissionDenied
                case .tccProtectedSkipped:
                    accessState = .tccProtected
                case .enumerationFailed, .metadataUnavailable:
                    accessState = .incomplete
                }
                markOnDemandAccess(issue.path,
                                   rootPath: rootPath,
                                   accessState: accessState,
                                   into: &aggregates)
            case .progress, .finished, .failed, .cacheDirTagged:
                continue
            }
        }

        let rows = aggregates.values.map { agg in
            let projectedState = accessProjection.projectedState(
                for: agg.path,
                fallbackAccessState: agg.accessState,
                fallbackSubtreeCompleteness: agg.subtreeCompleteness
            )
            return TreeRow(
                path: agg.path,
                title: agg.title,
                bytes: agg.bytes,
                logicalBytes: agg.logicalBytes,
                fileCount: max(agg.fileCount, agg.isDirectory ? 1 : agg.fileCount),
                isDirectory: agg.isDirectory,
                hasChildren: agg.isDirectory && agg.hasChildren,
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: agg.modificationDate
            )
        }
        return rows.sorted { Self.sortTreeRow($0, before: $1, by: key) }
    }

    nonisolated private static func mergeOnDemandNode(_ node: FSNode,
                                                      rootPath: String,
                                                      into aggregates: inout [String: OnDemandChildAggregate]) {
        guard let projection = directChildProjection(rootPath: rootPath, nodePath: node.path) else { return }
        let displayBytes = node.allocatedSize
        var aggregate = aggregates[projection.childPath] ?? OnDemandChildAggregate(
            path: projection.childPath,
            title: projection.segment
        )
        aggregate.bytes += displayBytes
        aggregate.logicalBytes += node.logicalSize
        if !node.isDirectory {
            aggregate.fileCount += 1
        }
        if projection.isDirectChild {
            aggregate.directChildSeen = true
            aggregate.isDirectory = node.isDirectory
            aggregate.modificationDate = node.modificationDate
            if !node.isDirectory {
                aggregate.fileCount = max(aggregate.fileCount, 1)
            }
        } else {
            aggregate.hasChildren = true
        }
        aggregates[projection.childPath] = aggregate
    }

    nonisolated private static func markOnDemandAccess(_ path: String,
                                                       rootPath: String,
                                                       accessState: TreeRow.AccessState,
                                                       into aggregates: inout [String: OnDemandChildAggregate]) {
        guard let projection = directChildProjection(rootPath: rootPath, nodePath: path) else { return }
        var aggregate = aggregates[projection.childPath] ?? OnDemandChildAggregate(
            path: projection.childPath,
            title: projection.segment
        )
        if projection.isDirectChild {
            // 只有真实直接子项本身不可访问时才画锁；不能把深层问题升级到父行。
            aggregate.isDirectory = true
            aggregate.hasChildren = false
            aggregate.accessState = accessState
        } else {
            // 深层问题只降低子树完整性，父行仍保持可展开，供用户继续定位真实目录。
            aggregate.hasChildren = true
            aggregate.subtreeCompleteness = .containsIncompleteDescendant
        }
        aggregates[projection.childPath] = aggregate
    }

    nonisolated private static func directChildProjection(rootPath: String,
                                                         nodePath: String) -> (childPath: String, segment: String, isDirectChild: Bool)? {
        guard nodePath != rootPath else { return nil }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard nodePath.hasPrefix(prefix) else { return nil }
        let tail = String(nodePath.dropFirst(prefix.count))
        guard let segment = tail.split(separator: "/", maxSplits: 1).first.map(String.init),
              !segment.isEmpty else { return nil }
        let childPath = rootPath == "/" ? "/" + segment : prefix + segment
        return (childPath, segment, !tail.contains("/"))
    }

    /// 异步 directChildren —— deepIndex 关闭时，后台扫描当前目录并聚合直接子项。
    ///
    /// 这条路径替代旧扫描数据库 fallback：
    /// - 不写全量节点数据库，不产生扫描收尾落盘等待；
    /// - 不在主线程遍历文件系统；
    /// - 只在用户真正展开某个目录时扫描该目录子树，结果写入 `treeChildrenCache`。
    public func directChildrenAsync(of path: String, sortedBy key: TreeSortKey) async -> [TreeRow] {
        if childEdges[path] != nil {
            return directChildren(of: path, sortedBy: key)
        }
        let accessProjection = treeScanEvidenceProjection
        let respectTCC = fdaStatus != .granted

        let rows = await Task.detached(priority: .utility) {
            await Self.scanDirectChildrenOnDemand(
                rootPath: path,
                sortedBy: key,
                respectTCCSkipList: respectTCC,
                accessProjection: accessProjection
            )
        }.value

        return rows
    }

    /// v1.3 bug1：根据 path O(1) 反查 TreeRow。
    /// 用于 TreeBrowserView 选中变化的 onSelect 回调——之前每点一次都要把整棵展开树
    /// 拍平递归一遍 (`visibleRows`)，4w 级展开节点下卡顿明显。这里用 dirIndex / fileLeaves
    /// 字典直接定位，避免遍历。
    public func row(for path: String) -> TreeRow? {
        if let agg = dirIndex[path] {
            // v2026.06.20：与 [materializeFromMemory](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
            // 同款 mtime 兜底，保证 onSelect → detail 面板与 tree 列里"修改时间"显示一致。
            let mtime = agg.modificationDate ?? resolveDirMtimeFallback(forPath: path)
            let projectedState = projectedTreeState(for: path)
            return TreeRow(
                path: path,
                title: (path as NSString).lastPathComponent,
                bytes: agg.bytes,
                logicalBytes: agg.logicalBytes,
                fileCount: agg.fileCount,
                isDirectory: true,
                hasChildren: !(childEdges[path]?.isEmpty ?? true),
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: mtime
            )
        }
        if let leaf = fileLeaves[path] {
            let projectedState = projectedTreeState(for: path)
            return TreeRow(
                path: path,
                title: (path as NSString).lastPathComponent,
                bytes: leaf.bytes,
                logicalBytes: leaf.logicalBytes,
                fileCount: 1,
                isDirectory: leaf.isDir,
                hasChildren: false,
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: leaf.modificationDate
            )
        }
        return nil
    }

    /// Post-prune refresh for MainView's value-type Tree selection. Indexed rows stay O(1); lazy
    /// deep-index-off rows use direct-parent cache keys, and top-level snapshot rows are rebuilt
    /// from the just-committed aggregate. This path runs once per successful delete, not per frame.
    public func refreshedTreeRow(for path: String) -> TreeRow? {
        if let indexed = row(for: path) { return indexed }

        let parentPath = String._gsyParentPath(of: path)
        for sortKey in TreeSortKey.allCases {
            let cacheKey = "\(parentPath)|\(sortKey.rawValue)"
            if let cached = treeChildrenCache[cacheKey]?.first(where: { $0.path == path }) {
                return cached
            }
        }

        guard let item = snapshot.rows.first(where: { $0.id == path }) else { return nil }
        let projectedState = projectedTreeState(for: path)
        return TreeRow(
            path: path,
            title: item.title,
            bytes: item.bytes,
            logicalBytes: item.logicalBytes,
            fileCount: item.fileCount,
            isDirectory: item.isDirectory,
            hasChildren: item.isDirectory && item.fileCount > 0,
            accessState: projectedState.accessState,
            subtreeCompleteness: projectedState.subtreeCompleteness,
            modificationDate: item.modificationDate
        )
    }

    /// 删除 UI 的唯一预检入口。Tree / Large Files 等页面必须通过当前扫描会话持有的
    /// engine + vendor trie + home 评估，不能再各自 new 一个裸 SafetyEngine；否则 UI
    /// 可能显示可删，而 TrashPipeline 最终按完整 vendor 规则拒绝。
    public func deletionSafetyEvaluation(
        for path: String
    ) -> (verdict: SafetyVerdict, rejection: SafetyRejection, vendor: VendorRule?) {
        let result = engine.evaluate(path: path, trie: trie, home: home)
        return (result.0, result.1, result.2)
    }

    // MARK: - T4 大文件 API

    /// v1.0 T4：取扫描期收集到的大文件，按视图阈值二次过滤、按 sortKey 排序、截到 limit 项。
    ///
    /// - Parameters:
    ///   - minSizeMB: 视图层阈值（MB）。**必须 ≥ 扫描期阈值**，否则视图能给出的就只是
    ///     当前已采集到的子集——这种情况下 UI 应当提示用户重新扫描（见 LargeFilesView）。
    ///   - sortKey: 排序键。
    ///   - limit: Top N 截断；ROADMAP T4 默认 200，避免一次性渲染数千行卡 UI。
    ///   - mtimeFilter: v1.2 P1-4 修改日期过滤。`.all` 时不做时间过滤。
    public func largeFiles(minSizeMB: Int,
                           sortKey: LargeFileSortKey,
                           limit: Int = 200,
                           mtimeFilter: AppSettings.MtimeFilter = .all)
        -> [LargeFileItem]
    {
        guard limit > 0 else { return [] }
        let minBytes = Int64(max(0, minSizeMB)) * 1024 * 1024
        let now = Date()
        // 主索引已被 compact 释放时回退到二级缓存（内存保留的 Top N）。
        // 既保证 UI 同步路径不变，又不让 compact 后页面空白。
        let source: [LargeFileLeaf]
        if largeFileLeaves.isEmpty, let cache = compactedLargeFileTopN {
            // compactedLargeFileTopN 是一个有限子集。自动 compact 已在 LargeFilesView 侧禁用，
            // 但测试/手动调用 compact 后仍应保持 list/count 一致。
            source = cache
        } else {
            source = largeFileLeaves.snapshot()
        }
        let filtered = source
            .filter { $0.bytes >= minBytes }
            .filter { mtimeFilter.passes($0.modificationDate, now: now) }
            .map {
                LargeFileItem(
                    path: $0.path,
                    bytes: $0.bytes,
                    logicalBytes: $0.logicalBytes,
                    modificationDate: $0.modificationDate
                )
            }
        let sorted = filtered.sorted { (a, b) in
            switch sortKey {
            case .sizeDesc:
                if a.bytes != b.bytes { return a.bytes > b.bytes }
            case .sizeAsc:
                if a.bytes != b.bytes { return a.bytes < b.bytes }
            case .mtimeDesc:
                let ad = a.modificationDate ?? .distantPast
                let bd = b.modificationDate ?? .distantPast
                if ad != bd { return ad > bd }
            case .mtimeAsc:
                let ad = a.modificationDate ?? .distantFuture
                let bd = b.modificationDate ?? .distantFuture
                if ad != bd { return ad < bd }
            }
            // 主键相等 → path 升序兜底，保 ForEach 不抖
            return a.path < b.path
        }
        return Array(sorted.prefix(limit))
    }

    /// v1.0 T4：当前扫描会话采集到的"原始大文件叶子总数"——视图想提示
    /// "还有 X 项被截断"或者"未达到任何阈值"时用。
    /// M3：compact 之后回退到二级缓存的 count，UI 拿到的"集合大小"语义不变。
    public var largeFileCollectedCount: Int {
        if largeFileLeaves.isEmpty, let cache = compactedLargeFileTopN {
            return cache.count
        }
        return largeFileLeaves.count
    }

    /// v1.0 T4：当前会话扫描期阈值（bytes）。视图据此判断是否需要"调阈值后重扫"。
    public var largeFileScanThresholdBytes: Int64 { largeFileMinBytes }

    private func sampleScanRate(nowDate: Date = Date()) -> TimeInterval {
        let sampleStart = lastSampleAt ?? startedAt
        let dt = nowDate.timeIntervalSince(sampleStart)
        let dBytes = totalBytes - lastSampleBytes
        if dt >= 0.05, dBytes >= 0 {
            let instant = Double(dBytes) / max(dt, 0.001)
            if bytesPerSecondEMA == 0 {
                bytesPerSecondEMA = instant
            } else {
                let alpha = 0.3
                bytesPerSecondEMA = alpha * instant + (1 - alpha) * bytesPerSecondEMA
            }
            lastSampleAt = nowDate
            lastSampleBytes = totalBytes
        }
        return nowDate.timeIntervalSince(startedAt)
    }

    private func publishSnapshot(categoryID: String, finished: Bool, complete: Bool? = nil) {
        let isComplete = complete ?? finished
        if largeFileTopNOnlyScan {
            let elapsedTotal = sampleScanRate()
            let nextSnapshot = ScanSnapshot(
                categoryID: categoryID,
                rows: [],
                totalBytes: totalBytes,
                scannedFileCount: scannedFiles,
                isFinished: finished,
                elapsed: elapsedTotal,
                isComplete: isComplete,
                bytesPerSecond: bytesPerSecondEMA,
                estimatedRemaining: nil
            )
            if !finished && snapshot == nextSnapshot { return }
            snapshot = nextSnapshot
            if finished {
                lastFinishedCategoryID = categoryID
                lastIngestAt.removeAll(keepingCapacity: true)
                lastStreamSortedIds.removeAll(keepingCapacity: true)
                lastStreamSortCacheKey = (-1, -1)
            }
            return
        }

        // v1.3 修「只有一行在动」错觉：
        //   扫描期间按 path 字典序排（位置稳定），让用户看到所有一级子目录的字节
        //   各自独立、同时跳动；只有 finished=true 那一帧切到用户选定的 mainListSortKey
        //   （默认 sizeDesc），呈现最终结果。
        //
        // 背景：之前一直按 bytes 降序排，结果"最大的 bucket"永远固定在第一行，且
        //   它的字节增长得最快——视觉上就是"列表只有第一行数字在变"，给用户造成
        //   "多线程没生效，只在扫一个目录"的错觉。实际上 6 worker 真的在扫 6 个
        //   不同子目录，所有 bucket 都在涨。
        //
        // v1.3：每个 row 携带 isActive 标志（最近 activityWindow 内有 ingest 写入即 active），
        //   UI 给 active 行的 bytes 数字上色 + 脉动，让"哪些 worker 正在扫"视觉化。
        //   finished=true 那帧强制 isActive=false（扫完就不该再亮）。
        //
        // 副作用：扫描期间行序按 path 字典序而非 size 降序——这是必要的代价，
        //   且与许多竞品（CleanMyMac 实时扫描态）一致。完成后立刻切回用户排序。
        let now = Date.timeIntervalSinceReferenceDate
        let activeCutoff = now - activityWindow

        // 先 map 出无序 rows，再统一排序——避免在 sort 闭包里反复算 evaluate
        // 性能：走 trie 版 evaluate（init 期一次性 build，扫描期复用），
        // 比 evaluate(path:vendors:home:) 每次重建 trie 快一个量级。
        //
        // Step 3 P0-3 / 2026-06：bucket cachedVerdict 缓存。
        // path/engine/trie/home 在扫描期间均不变 —— 同 path 的 evaluate 结果永远相同。
        // 第一帧把每个 bucket 的 verdict/rejection/vendor 算一次写回 bucket struct，
        // 后续帧（流式 0.4s 一次）直接读字段。一次扫描 N=数百~数千 bucket × 数十帧
        // 的重复 evaluate 收敛到"每 bucket 只算一次"。
        var unsorted: [RowItem] = []
        unsorted.reserveCapacity(buckets.count)
        for path in buckets.keys {
            // 通过 buckets[path] 路径 read-modify-write —— Bucket 是 value type，
            // 必须从 dict 重新写回才能保留 cache 字段。
            guard var bucket = buckets[path] else { continue }
            let verdict: SafetyVerdict
            let rejection: SafetyRejection
            let vendor: VendorRule?
            if let v = bucket.cachedVerdict, let r = bucket.cachedRejection {
                // hit：path/engine/trie/home 都没变，verdict 永远相同 —— 直接读
                verdict = v
                rejection = r
                vendor = bucket.cachedVendor
                verdictCacheHits &+= 1
            } else {
                // miss：算一次并写回 bucket
                let result = engine.evaluate(path: path, trie: trie, home: home)
                verdict = result.0
                rejection = result.1
                vendor = result.2
                bucket.cachedVerdict = verdict
                bucket.cachedRejection = rejection
                bucket.cachedVendor = vendor
                buckets[path] = bucket
                verdictCacheMisses &+= 1
            }

            let active: Bool
            if finished {
                active = false
            } else if let ts = lastIngestAt[path] {
                active = ts >= activeCutoff
            } else {
                active = false
            }
            unsorted.append(RowItem(
                id: path,
                url: bucket.url,
                title: bucket.url.lastPathComponent,
                isDirectory: bucket.isDirectory,
                bytes: bucket.bytes,
                logicalBytes: bucket.logicalBytes,
                fileCount: bucket.fileCount,
                verdict: verdict,
                rejection: rejection,
                vendorName: vendor?.name,
                vendorNote: vendor?.note,
                isActive: active,
                modificationDate: bucket.modificationDate
            ))
        }
        let rows: [RowItem]
        // M4-T1：白名单过滤——命中规则与 WhitelistStore.isWhitelisted 等价（同步快照版）。
        let filtered: [RowItem]
        if whitelistSnapshot.isEmpty {
            filtered = unsorted
        } else {
            filtered = unsorted.filter {
                !Self.isWhitelisted($0.url.path, in: whitelistSnapshot)
            }
        }
        if finished {
            rows = filtered.sorted(by: { mainListSortKey.lessThan($0, $1) })
            // 流式 cache 不用于 finished，但避免下次扫描首帧误命中——失效掉
            lastStreamSortedIds.removeAll(keepingCapacity: true)
            lastStreamSortCacheKey = (-1, -1)
        } else {
            // v1.5 P1-C：流式帧排序缓存。
            // 命中条件：bucketCount 与上次相同（ingest 单调增 → 相同即 key set 完全相同）
            // 且 whitelistCount 与上次相同（避免白名单变化产生不同的 filtered 序列影响）。
            // 命中时直接按上次的 id 序重排 filtered，跳过 O(N log N) 排序。
            let currentKey = (bucketCount: buckets.count, whitelistCount: whitelistSnapshot.count)
            let cacheHit = currentKey.bucketCount > 0
                && currentKey.bucketCount == lastStreamSortCacheKey.bucketCount
                && currentKey.whitelistCount == lastStreamSortCacheKey.whitelistCount
                && lastStreamSortedIds.count == filtered.count
            if cacheHit {
                // 按缓存 id 序重组 filtered（一次哈希构表 + 一次顺序拼装，O(N) 替代 O(N log N)）。
                var byID: [String: RowItem] = [:]
                byID.reserveCapacity(filtered.count)
                for r in filtered { byID[r.id] = r }
                var reordered: [RowItem] = []
                reordered.reserveCapacity(filtered.count)
                for id in lastStreamSortedIds {
                    if let r = byID[id] { reordered.append(r) }
                }
                // 兜底：若映射出现不一致（理论上不应该发生），fallback 走真排序
                if reordered.count == filtered.count {
                    rows = reordered
                } else {
                    rows = filtered.sorted { $0.id < $1.id }
                    lastStreamSortedIds = rows.map { $0.id }
                    lastStreamSortCacheKey = currentKey
                }
            } else {
                rows = filtered.sorted { $0.id < $1.id }
                lastStreamSortedIds = rows.map { $0.id }
                lastStreamSortCacheKey = currentKey
            }
        }

        // v1.3：ETA 采样 —— 在每帧 publishSnapshot 时基于自上次采样的字节增量算瞬时速率，
        // 再 EWMA 平滑（α=0.3）。注意 elapsed 起点是 startedAt，速率窗口起点是 lastSampleAt
        // （第一帧没有"上次"，初始化成 startedAt 让首个采样长度 = elapsed）。
        let nowDate = Date()
        let elapsedTotal = sampleScanRate(nowDate: nowDate)

        // v2026.06.23 产品决策：不再向 UI 下发 ETA（剩余时间）。
        // 长扫场景下速率窗口噪声 + estimator 偏小都会让 ETA 严重失真，呈现给用户反而误导。
        // 上游 UI / HUD 已停止读取 estimatedRemaining；这里把字段恒置 nil，作为单一数据源闸门，
        // 杜绝未来某条入口"偷偷"把 ETA 再加回来。`expectedTotalBytes` 仍然继续算并下发，
        // 给"有分母时显示进度条 + 百分比"用——这是用户唯一信得过的进度表达。
        let eta: TimeInterval? = nil

        let nextSnapshot = ScanSnapshot(
            categoryID: categoryID,
            rows: rows,
            totalBytes: totalBytes,
            scannedFileCount: scannedFiles,
            isFinished: finished,
            elapsed: elapsedTotal,
            isComplete: isComplete,
            bytesPerSecond: bytesPerSecondEMA,
            estimatedRemaining: finished ? nil : eta
        )
        // v2026.06.21 perf：Equatable 短路。
        // 用户对比反馈"开发者构建产物比 Library 卡得夸张"——根因之一是 @Published
        // 不会自动比较，每帧重复赋同样内容仍会 send objectWillChange，把 MainView.body
        // 整体失效，连带 sidebar / statusBar / listResults 全跑 O(N)。
        // ScanSnapshot 现在 Equatable（rows / 三桶字节 / max / bytesPerSecond / eta 全字段
        // 参与对比），等价帧直接 return 不写 @Published；典型 dev 扫场景"两根并行 throttle
        // 错峰共振导致空帧 publish"会被这里挡下，body 失效频率从 ≥5次/秒 降到内容真有变化
        // 才触发。等价比较的代价是 N 行 RowItem.== 浅比，远低于 SwiftUI body 重新跑一次。
        //
        // 注意：finished 帧不能短路——下游 lastFinishedCategoryID / lastIngestAt 清理
        // 与 (buckets/dirIndex/fileLeaves) 索引快照对齐都依赖这里跑完。
        if !finished && snapshot == nextSnapshot { return }
        snapshot = nextSnapshot
        if finished {
            lastFinishedCategoryID = categoryID
            // 扫完清空 lastIngestAt，避免下一次切排序键 / 重扫前的 stale 数据让旧 row 误亮
            lastIngestAt.removeAll(keepingCapacity: true)
        }
        // Step 2 P0-2 / 2026-06：treeRevision 拆分。
        // 流式扫描 publishSnapshot 帧（0.4s/帧）以前一律 `treeRevision &+= 1` —— 这会让
        // TreeBrowserView 把上万节点的 flatRows 整树重建一遍。但 95% 的帧只是已有节点
        // 的 bytes/fileCount 累加（节点拓扑没变），整树重建纯属浪费。
        //
        // 这里用三元组 `(buckets.count, dirIndex.count, fileLeaves.count)` 做 O(1) 判定：
        //   - 任一计数变化 → 必然有新节点首次出现 → 升格为 structural
        //   - 三元组全等 → 仅数值变化 → 只推 tickRevision，flatRows 不重建
        //
        // 漏判风险：dirIndex 内 children 集合微调（同一 parent 下子项排序变）不会让 count 变。
        // 但这种排序级变化在我们的 ingest 路径里**不会发生**（每次 insert 只 add/不 remove），
        // 所以三元组对索引集合的"严格单调增"语义足够安全。
        let snapshot = (
            buckets: buckets.count,
            dirIndex: dirIndex.count,
            fileLeaves: fileLeaves.count
        )
        if snapshot != lastIndexSnapshot {
            lastIndexSnapshot = snapshot
            bumpStructuralRevision()
        } else {
            bumpTickRevision()
        }
    }

    // MARK: - Testing helpers (Step 15)

    /// 仅供 [PruneDeletedTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/PruneDeletedTests.swift)
    /// / [PerformDeleteIntegrationTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/PerformDeleteIntegrationTests.swift)
    /// 注入内部状态。
    ///
    /// 同 [forcePublishSnapshotForTesting](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L389)
    /// 风格：`internal` 可见性，配合 `@testable import AppUI` 在测试 target 内可用，
    /// 生产路径不会调到。
    ///
    /// 全部参数都 optional，默认 nil = 不动该字段。Bucket/DirAgg 是 private struct，
    /// 这里以"简化字典"接收（path -> bytes 即可）由方法内部包装成真实结构。
    func _seedForTesting(
        snapshot: ScanSnapshot? = nil,
        currentRootPath: String? = nil,
        isScanning: Bool? = nil,
        buckets: [String: Int64]? = nil,
        dirIndex: [String]? = nil,
        dirIndexFull: [String: (bytes: Int64, fileCount: Int)]? = nil,
        fileLeaves: [String]? = nil,
        fileLeavesFull: [String: Int64]? = nil,
        childEdges: [String: Set<String>]? = nil,
        treeChildrenCache: [String: [TreeRow]]? = nil,
        perRootStaging: [String: PerRootProgress]? = nil,
        totalBytes: Int64? = nil,
        scannedFiles: Int? = nil
    ) {
        if let snap = snapshot {
            self.snapshot = snap
        }
        if let currentRootPath {
            self.currentRootPath = currentRootPath
        }
        if let isScanning {
            self.isScanning = isScanning
        }
        if let buckets {
            self.buckets.removeAll()
            for (path, bytes) in buckets {
                self.buckets[path] = Bucket(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    bytes: bytes,
                    logicalBytes: bytes,
                    fileCount: 1,
                    isDirectory: true
                )
            }
        }
        if let dirIndex {
            self.dirIndex.removeAll()
            for path in dirIndex {
                self.dirIndex[path] = DirAgg(bytes: 1, logicalBytes: 1, fileCount: 1)
            }
        }
        // v1.5.7：带 (bytes, fileCount) 的 seed，让 prune 减法契约能拿到可验证的祖先聚合。
        if let dirIndexFull {
            self.dirIndex.removeAll()
            for (path, val) in dirIndexFull {
                self.dirIndex[path] = DirAgg(bytes: val.bytes, logicalBytes: val.bytes, fileCount: val.fileCount)
            }
        }
        if let fileLeaves {
            self.fileLeaves.removeAll()
            for path in fileLeaves {
                self.fileLeaves[path] = (bytes: 1, logicalBytes: 1, isDir: false, modificationDate: nil)
            }
        }
        if let fileLeavesFull {
            self.fileLeaves.removeAll()
            for (path, b) in fileLeavesFull {
                self.fileLeaves[path] = (bytes: b, logicalBytes: b, isDir: false, modificationDate: nil)
            }
        }
        if let childEdges {
            self.childEdges = childEdges
        }
        if let treeChildrenCache {
            self.treeChildrenCache = treeChildrenCache
        }
        if let perRootStaging {
            self.perRootStaging = perRootStaging
            syncPerRootPublished(from: perRootStaging)
        }
        if let totalBytes {
            self.totalBytes = totalBytes
        }
        if let scannedFiles {
            self.scannedFiles = scannedFiles
        }
        notePruneSourceMutation()
    }

    func _bucketsKeysForTesting() -> [String] { Array(buckets.keys) }
    func _dirIndexKeysForTesting() -> [String] { Array(dirIndex.keys) }
    /// v1.5.7：暴露 dirIndex 聚合值，让 pruneDeleted 祖先减法契约可验证。
    func _dirIndexAggForTesting(_ path: String) -> (bytes: Int64, fileCount: Int)? {
        guard let agg = dirIndex[path] else { return nil }
        return (agg.bytes, agg.fileCount)
    }
    func _fileLeavesKeysForTesting() -> [String] { Array(fileLeaves.keys) }
    func _childEdgesForTesting() -> [String: Set<String>] { childEdges }
    func _treeChildrenCacheForTesting() -> [String: [TreeRow]] { treeChildrenCache }
    func _prunePlanDiagnosticsForTesting() -> (ranOnMainThread: Bool?, durationNanoseconds: UInt64?) {
        (lastPrunePlanRanOnMainThread, lastPrunePlanDurationNanoseconds)
    }
    func _pruneLifecycleDiagnosticsForTesting() -> (
        mergeRanOnMainThread: Bool?,
        retirementRanOnMainThread: Bool?,
        retirementDurationNanoseconds: UInt64?
    ) {
        (
            lastPruneTombstoneMergeRanOnMainThread,
            lastPruneRetirementRanOnMainThread,
            lastPruneRetirementDurationNanoseconds
        )
    }
    func _deletedTombstoneRootsForTesting() -> [String] {
        deletedPathTombstones.matcher.roots
    }
    func _isDeletedTombstonedForTesting(_ path: String) -> Bool {
        isDeletedTombstoned(path)
    }
    func _aggregateTotalsForTesting() -> (bytes: Int64, files: Int) {
        (totalBytes, scannedFiles)
    }
    func _treeChildrenInFlightForTesting() -> Set<String> { treeChildrenInFlight }
    func _storeFetchedChildrenForTesting(path: String, sortedBy key: TreeSortKey, rows: [TreeRow]) {
        storeFetchedChildren(path: path, sortedBy: key, rows: rows)
    }
    func _displayPathForScanNodeForTesting(_ path: String, rootPath: String) -> String {
        displayPathForScanNode(path, rootPath: rootPath)
    }

    // MARK: - Step 17-A: 内存占用护栏 readers（仅供 [DirIndexMemoryFootprintTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/DirIndexMemoryFootprintTests.swift)）

    /// 暴露 DirAgg / Bucket 的 MemoryLayout.size，让护栏测能钉死结构体大小不变量。
    /// DirAgg / Bucket 是 private struct，测试 target 看不到 type 本身——
    /// 这里以静态值返回 size，外面只断言"不超过上限"，无字段 schema 暴露。
    static var _dirAggSizeForTesting: Int { MemoryLayout<DirAgg>.size }
    static var _bucketSizeForTesting: Int { MemoryLayout<Bucket>.size }

}

// MARK: - v1.5.7 perf：原生 String 路径切分（避免 NSString 桥接 + 拷贝）

extension String {
    /// 返回 path 的父目录路径（与 `(p as NSString).deletingLastPathComponent` 等价的
    /// **常见 case** 子集，针对 POSIX 绝对路径优化）。
    ///
    /// 关键差异：仅在原生 `String` 上用 `lastIndex(of: "/")` 切片，**不**触发 NSString
    /// bridging / NSPathStore2 分配。ingest 热路径每个叶子文件回溯 O(depth) 次，
    /// 在 5w+ 文件场景下原方案 NSString 桥接占主线程 ~12% 时间（Instruments 采样口径）。
    ///
    /// 行为契约：
    /// - `/` → `/`
    /// - `/A` → `/`
    /// - `/A/B` → `/A`
    /// - `/A/B/C` → `/A/B`
    /// - 空串 → 空串
    /// 与 NSString.deletingLastPathComponent 在"POSIX 绝对路径、单 / 分隔、无尾 /"
    /// 输入下完全一致；ingest 调用方保证传入路径都是 FileManager.enumerator 给出
    /// 的规范绝对路径，无尾斜杠、无 `.`/`..`，所以这个简化版安全。
    @inline(__always)
    static func _gsyParentPath(of p: String) -> String {
        if p.isEmpty { return "" }
        guard let slash = p.lastIndex(of: "/") else { return "" }
        // 根目录 "/X" → "/"
        if slash == p.startIndex { return "/" }
        return String(p[p.startIndex..<slash])
    }
}

// MARK: - v2026.06.21 perf：onPartial 节流窗口

/// `scanDeveloperArtifacts` 的 `onPartial` 闭包需要在多次回调之间共享"上次 sync 时间戳"。
/// 闭包要 `@Sendable`，又要可变状态——直接用 var capture 会被 Swift 6 拒绝；
/// 包一层 reference type 即可。所有读写都被 `Task { @MainActor ... }` 串行化在主 actor
/// 上，没有 data race，因此不需要 lock。
@MainActor
final class PartialSyncWindow {
    /// 上次调用 `syncPerRootPublished` 的时间戳（`Date.timeIntervalSinceReferenceDate`）。
    /// 0 = 首次，肯定通过 0.4s 阈值——保证 sidebar 第一行立刻出现。
    var lastSync: TimeInterval = 0
}
