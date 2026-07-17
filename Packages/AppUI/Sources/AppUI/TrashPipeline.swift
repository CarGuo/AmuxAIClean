import AppKit
import Darwin
import Foundation
import LogKit
import ScanKit
import SafetyKit

/// v0 主链路：把文件移到废纸篓，不需要 root，不需要 Helper，不需要 Apple Developer Program。
///
/// **设计原则**（PITFALLS §5.9）：
/// - 走 [NSWorkspace.recycle](https://developer.apple.com/documentation/appkit/nsworkspace/1524800-recycle)：
///   - 用户可在 Finder 撤销
///   - 不调 unlink，可 100% 恢复
/// - dryRun=true 时只打印，不真动文件
/// - 任意一项失败都会被记入 skipped（不抛异常中断整批）
///
/// **M4 增强（清理更安全）**：
/// 即使 UI 层已经过 SafetyEngine 过滤，pipeline 自身仍然在最后一刻
/// 再走一次 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L203-L215)。
/// 任何被判 `.forbid` 的路径都**不会**进入 NSWorkspace.recycle，会被计入 skipped
/// 并通过 error 文案附带机器可读原因。这是最后一道闸门——防御:
/// 1. 调用方传入未经过滤的路径（比如未来直接接命令行 / scripting）
/// 2. UI 卡住老的 SafetyVerdict 缓存导致 forbid 漏检
/// 3. 用户硬塞 `..` 或绝对路径以外的形式
///
/// **并发与可变性契约（v1.5.7 显式化）**：
/// - `safety` / `trie` / `whitelistStore` 一旦 init 完成即 immutable；白名单 actor 自身
///   Sendable；`@unchecked Sendable` 是基于这些前提
///   外加 `_accessDeniedPaths` 用 `accessDeniedLock` 保护的可变状态。
/// - 调用 `setAccessDeniedPaths(_:)` 是更新可变状态的**唯一**入口，其它任何字段都不
///   可在 init 后改写；如新增字段必须重审 Sendable 假设。
/// - `moveToTrash` / `partitionByForbid` 可被多 actor / 多并发 await chain 调用，
///   `trie` / `safety` 的并发读由 SafetyKit 保证（参见 [VendorTrieNode](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift#L29) 的生命周期契约）。
public final class TrashPipeline: DeletionPipeline, @unchecked Sendable {

    /// 一次系统回收调用的不可变结果。抽成值类型后，批处理算法可以用无破坏的
    /// scripted operation 验证，不必在测试里真的触碰废纸篓。
    struct RecycleAttempt: Sendable {
        enum State: Sendable, Equatable {
            case callbackCompleted
            /// 调用已交给 `NSWorkspace`，但在应用等待窗口内没有给出完成回调。
            case callbackPending(operationID: UUID)
            /// The submission queue entered the synchronous AppKit API, but the API itself
            /// did not return before the request budget expired. Acceptance is unknown.
            case submissionUnknown(operationID: UUID)
            /// 整个请求的产品等待预算已耗尽，本次调用没有交给系统。
            case notSubmittedBudgetExpired
            /// The frozen inode changed/disappeared or the persistent gate became unavailable
            /// before the synchronous AppKit boundary. No call was made for these paths.
            case preSubmitRejected(TrashPendingOperationRejection)
        }

        let moved: [(String, String)]
        let errorDescription: String?
        let state: State

        init(
            moved: [(String, String)],
            errorDescription: String?,
            state: State = .callbackCompleted
        ) {
            self.moved = moved
            self.errorDescription = errorDescription
            self.state = state
        }
    }

    struct RecycleBatchResult: Sendable {
        let moved: [(String, String)]
        let failureReasons: [String: String]
        /// 真正交给 `NSWorkspace.recycle` 的去重输入（含尚待系统回调的批次）。
        let attemptedPaths: [String]
        let pendingPaths: [String]
        let submissionUnknownPaths: [String]
        let notSubmittedPaths: [String]
        let preSubmitRejection: TrashPendingOperationRejection?
    }

    private typealias MovePayload = (
        legacy: (Int, Int, String?, [(String, String)]),
        outcome: TrashOutcome?
    )

    /// Compatibility callers still consume `payload`; Professional execution consumes the
    /// independently typed boundary. A nil disposition is reserved for diagnostic dry-run.
    private struct PerformedMove: Sendable {
        let payload: MovePayload
        let submissionDisposition: TrashSubmissionDisposition?
    }

    private let safety: SafetyEngine
    /// 预建的 vendor 路径树（M4-P0 修复）。
    /// **生命周期**：init 注入，全程只读；read 阶段并发安全详见 [VendorTrieNode](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift#L29) 契约。
    /// 非 nil 时 partitionByForbid 走 [SafetyEngine.evaluate(path:trie:home:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L342)，
    /// 让 vendors.yaml 中通过 `paths: [{verdict: forbid}]` 声明的硬禁区
    /// （`~/.cargo/bin`、`~/.android/sdk`、`~/Library/Developer/Xcode/UserData/KeyBindings/...` 等）
    /// 在 pipeline 这道最后闸门也能被拦住——而不是仅靠 SafetyEngine 的硬编码列表。
    /// nil 时退回 base evaluate，与历史行为一致（仅供未注入 vendors 的测试 / 旧入口使用）。
    private let trie: VendorTrieNode?
    /// 生产删除入口显式注入共享白名单；测试默认 nil，避免读取真实用户数据。
    /// actor 自身 Sendable，perform 时取一次不可变快照并参与最终原子预检。
    private let whitelistStore: WhitelistStore?
    private let home: String
    /// SECURITY.md 的能力边界：默认只允许 `$HOME` 的严格子路径。Darwin 把当前用户
    /// 的 T/C 目录放在 `/var/folders`，因此只额外接受 `confstr(3)` 返回的当前用户
    /// 精确根，绝不接受 `/var/folders` 总根或其它用户/外置卷。
    private let externalDeletionRoots: [String]
    private let pendingOperationLedger: any TrashPendingOperationLedger

    /// v1.3.zzzz：上层一票否决集合（`permissionDenied` / `tccProtected` 路径），
    /// `moveToTrash` 内部用 NSLock 保护读写，调用方通过 [setAccessDeniedPaths](#) 注入最新快照。
    /// 协议 [DeletionPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift#L37)
    /// 自 v2026.06.17 (AUDIT A2) 起取消 protocol extension 默认 no-op：每个实现都必须
    /// 显式提供本方法，杜绝"上层忘了调"被静默放行的脆弱契约。
    ///
    /// **锁的作用范围（必读）**：`accessDeniedLock` 只盖 Set 的"写入"和"快照交接"
    /// （[setAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L52) /
    /// [snapshotAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L62)）
    /// 这两个 O(1) 临界区。`partitionByForbid` 内部的 `for p in paths` 循环里走的是
    /// **值拷贝（CoW）后的本地 Set.contains O(1)**，**不持锁**——这是设计而非疏漏，避免锁
    /// 在大批量删除时成为热点。改动该锁范围前请确保理解此约束。
    private let accessDeniedLock = NSLock()
    private var _accessDeniedPaths: Set<String> = []

    public convenience init(safety: SafetyEngine = SafetyEngine(),
                            vendors: [VendorRule] = [],
                            home: String = NSHomeDirectory(),
                            whitelistStore: WhitelistStore? = nil,
                            externalDeletionRoots: [String]? = nil) {
        self.init(
            safety: safety,
            vendors: vendors,
            home: home,
            whitelistStore: whitelistStore,
            externalDeletionRoots: externalDeletionRoots,
            pendingOperationLedger: PersistentTrashPendingOperationLedger.shared
        )
    }

    /// Internal injection keeps deterministic tests away from the real Application Support
    /// ledger while every production construction path receives the shared persistent gate.
    init(safety: SafetyEngine = SafetyEngine(),
         vendors: [VendorRule] = [],
         home: String = NSHomeDirectory(),
         whitelistStore: WhitelistStore? = nil,
         externalDeletionRoots: [String]? = nil,
         pendingOperationLedger: any TrashPendingOperationLedger) {
        self.safety = safety
        self.trie = vendors.isEmpty ? nil : VendorTrie.build(vendors: vendors, home: home)
        self.whitelistStore = whitelistStore
        self.home = home
        let usesCurrentUserHome = Self.scopeNormalize(home) == Self.scopeNormalize(NSHomeDirectory())
        self.externalDeletionRoots = externalDeletionRoots
            ?? (usesCurrentUserHome ? Self.currentUserDarwinDeletionRoots() : [])
        self.pendingOperationLedger = pendingOperationLedger

        // v2026.07.16: startup/new-surface reconciliation is read/identity work and must never
        // block SwiftUI construction. Only claimed-but-unresolved same-inode records remain
        // pending. Absent/replaced or pre-claim interrupted records become durable fresh-review
        // tombstones; an ephemeral notification can invalidate views but can never clear them.
        let ledger = pendingOperationLedger
        Task.detached(priority: .utility) {
            let reconciliation = ledger.reconcilePersistedRecords()
            Self.publishLedgerInvalidation(
                paths: reconciliation.invalidatedPaths,
                operationID: UUID()
            )
        }
    }

    public func preflight(
        paths: [String],
        accessDeniedPaths: Set<String>
    ) async -> DeletionPreflight {
        let uniquePaths = Self.stableUniquePaths(paths)
        guard !uniquePaths.isEmpty else {
            return DeletionPreflight(allowedPaths: [], rejections: [])
        }
        let whitelist = if let whitelistStore {
            await whitelistStore.snapshotPaths()
        } else {
            Set<String>()
        }
        let safety = self.safety
        let trie = self.trie
        let home = self.home
        let externalDeletionRoots = self.externalDeletionRoots
        let worker = Task.detached(priority: .userInitiated) {
            Self.partitionByForbid(
                paths: uniquePaths,
                safety: safety,
                trie: trie,
                accessDeniedPaths: accessDeniedPaths,
                whitelistPaths: whitelist,
                home: home,
                externalDeletionRoots: externalDeletionRoots
            )
        }
        let partition = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard partition.rejected.isEmpty else {
            let direct = partition.rejected.map {
                DeletionPreflight.Rejection(path: $0.path, reason: $0.reason.rawValue)
            }
            let atomic = partition.allowed.map {
                DeletionPreflight.Rejection(
                    path: $0,
                    reason: SafetyRejection.batchContainsForbidden.rawValue
                )
            }
            let overrideEligiblePaths = Self.vendorOverrideEligiblePaths(
                paths: uniquePaths,
                partition: partition,
                safety: safety,
                trie: trie,
                home: home,
                externalDeletionRoots: externalDeletionRoots
            )
            return DeletionPreflight(
                allowedPaths: [],
                rejections: direct + atomic,
                vendorOverrideEligiblePaths: overrideEligiblePaths
            )
        }
        return DeletionPreflight(allowedPaths: partition.allowed, rejections: [])
    }

    public func prepareScanIncompleteOverride(
        rows: [RowItem],
        scanIssues: [ScanIncompleteIssue],
        scanSessionID: UUID
    ) async -> ScanIncompleteOverridePreparation {
        let whitelist = if let whitelistStore {
            await whitelistStore.snapshotPaths()
        } else {
            Set<String>()
        }
        let safety = self.safety
        let trie = self.trie
        let home = self.home
        let externalDeletionRoots = self.externalDeletionRoots
        let worker = Task.detached(priority: .userInitiated) {
            DeletionTargetRevalidator.prepare(
                rows: rows,
                scanIssues: scanIssues,
                scanSessionID: scanSessionID,
                safety: safety,
                trie: trie,
                whitelistPaths: whitelist,
                home: home,
                externalDeletionRoots: externalDeletionRoots
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func finalScanIncompleteRejections(
        request: ScanIncompleteOverrideRequest,
        paths: [String],
        accessDeniedPaths: Set<String>
    ) async -> [DeletionPreflight.Rejection] {
        let whitelist = if let whitelistStore {
            await whitelistStore.snapshotPaths()
        } else {
            Set<String>()
        }
        let safety = self.safety
        let trie = self.trie
        let home = self.home
        let externalDeletionRoots = self.externalDeletionRoots
        let worker = Task.detached(priority: .userInitiated) {
            DeletionTargetRevalidator.validateFinal(
                request: request,
                paths: paths,
                accessDeniedPaths: accessDeniedPaths,
                safety: safety,
                trie: trie,
                whitelistPaths: whitelist,
                home: home,
                externalDeletionRoots: externalDeletionRoots
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func scanIncompletePreSubmitFailure(
        paths: [String],
        rejections: [DeletionPreflight.Rejection],
        dryRun: Bool
    ) -> PerformedMove {
        let firstReason = rejections.first?.reason
            ?? ScanIncompleteTargetRejectionReason.invalidStrictRequest.rawValue
        let failureSummary = TrashFailureSummary.safetyBlocked(
            count: paths.count,
            firstReason: firstReason,
            preview: dryRun
        )
        let outcome = TrashOutcome(
            movedPairs: [],
            failedPaths: [],
            safetyRejected: rejections.map { ($0.path, $0.reason) },
            missingPaths: [],
            failureSummary: failureSummary
        )
        recordOutcome(outcome)
        let err = failureSummary.legacyDiagnostic
        return PerformedMove(
            payload: ((0, paths.count, err, []), outcome),
            submissionDisposition: dryRun ? nil : .preSubmitRejected(
                .invalidScanIncompleteOverride(rejections)
            )
        )
    }

    private func duplicateVerificationPreSubmitFailure(
        paths: [String],
        rejections: [DeletionPreflight.Rejection]
    ) -> PerformedMove {
        let effectiveRejections = rejections.isEmpty
            ? paths.map {
                .init(
                    path: $0,
                    reason: DuplicateDeletionVerificationRejectionReason.invalidEvidence.rawValue
                )
            }
            : rejections
        let firstReason = effectiveRejections[0].reason
        let failureSummary = TrashFailureSummary.safetyBlocked(
            count: paths.count,
            firstReason: firstReason,
            preview: false
        )
        let outcome = TrashOutcome(
            movedPairs: [],
            failedPaths: [],
            safetyRejected: effectiveRejections.map { ($0.path, $0.reason) },
            missingPaths: [],
            failureSummary: failureSummary
        )
        recordOutcome(outcome)
        return PerformedMove(
            payload: ((0, paths.count, failureSummary.legacyDiagnostic, []), outcome),
            submissionDisposition: .preSubmitRejected(
                .invalidDuplicateVerification(effectiveRejections)
            )
        )
    }

    /// Claim-fence failures use the pending-operation carrier while the serial submission queue
    /// is deciding whether it may claim. If no earlier AppKit call occurred, recover the original
    /// Duplicate-specific presentation type instead of mislabelling cancellation/survivor drift
    /// as a recycle result.
    private func duplicateClaimFenceRejections(
        from rejection: TrashPendingOperationRejection
    ) -> [DeletionPreflight.Rejection]? {
        var mapped: [DeletionPreflight.Rejection] = []
        mapped.reserveCapacity(rejection.reasonsByPath.count)
        for path in rejection.reasonsByPath.keys.sorted() {
            guard let reason = rejection.reasonsByPath[path] else { continue }
            let duplicateReason: DuplicateDeletionVerificationRejectionReason
            switch reason {
            case .duplicateVerificationCancelled:
                duplicateReason = .verificationCancelled
            case .duplicateTargetIdentityChanged:
                duplicateReason = .targetIdentityChanged
            case .duplicateRetainedReferenceChanged:
                duplicateReason = .retainedReferenceChanged
            case .priorOperationPending, .identityChanged, .targetMissing, .ledgerUnavailable,
                 .submissionQueueExpired, .freshReviewRequired:
                return nil
            }
            mapped.append(.init(path: path, reason: duplicateReason.rawValue))
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// 删除批次统一按首次出现顺序去重。重复 URL 既不应让确认页计数膨胀，也不能被
    /// NSWorkspace.recycle 提交两次；vendor override 最终的路径顺序身份也以此为准。
    private static func stableUniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(paths.count)
        for path in paths where seen.insert(path).inserted {
            unique.append(path)
        }
        return unique
    }

    /// 只为“至少一项直接命中 vendorPathRule，其余项原本安全”
    /// 的原子批铸造 override 能力。
    ///
    /// 不能直接把 `partition.rejected.allSatisfy(.vendorPathRule)` 当作充分条件：
    /// vendor trie 的最终 verdict 可能覆盖 base bundle protection，而且 vendor forbid
    /// 发生在 deletion-scope 检查之前。这里显式重验 base Safety、全部 bundle protection、
    /// vendor 命中与能力范围；whitelist/accessDenied/非 vendor 安全拒绝
    /// 已经由 partition reason 排除。原本可放行项只会产生合成的
    /// `batchContainsForbidden`，它们会与 vendor 项一起进入严格二次验证。
    static func vendorOverrideEligiblePaths(
        paths: [String],
        partition: (allowed: [String], rejected: [(path: String, reason: SafetyRejection)]),
        safety: SafetyEngine,
        trie: VendorTrieNode?,
        home: String,
        externalDeletionRoots: [String]
    ) -> [String] {
        guard !paths.isEmpty,
              !partition.rejected.isEmpty,
              partition.rejected.allSatisfy({ $0.reason == .vendorPathRule }),
              partition.allowed.count + partition.rejected.count == paths.count,
              Set(partition.allowed).union(partition.rejected.map(\.path)) == Set(paths),
              // protected_bundles 资源不可用时不能把“没有匹配结果”解释为“确定未受保护”。
              // 普通扫描仍可按原语义继续，但破坏性的 vendor override 必须 fail closed。
              safety.hasCompleteBundleProtectionEvidence,
              let trie else {
            return []
        }
        let deletionScope = DeletionScope(home: home, externalRoots: externalDeletionRoots)
        let directlyVendorRejected = Set(partition.rejected.map(\.path))
        for path in paths {
            if Task.isCancelled { return [] }
            let (baseVerdict, baseReason) = safety.evaluate(path: path, home: home)
            guard baseVerdict != .forbid,
                  baseReason != .bundleSystemCritical,
                  baseReason != .bundleDataProtected,
                  !safety.isPathBundleProtected(path: path, home: home),
                  deletionScope.contains(rawPath: path) else {
                return []
            }
            let (vendorVerdict, vendorReason, _) = safety.evaluate(
                path: path,
                trie: trie,
                home: home
            )
            if directlyVendorRejected.contains(path) {
                guard vendorVerdict == .forbid, vendorReason == .vendorPathRule else {
                    return []
                }
            } else if vendorVerdict == .forbid {
                return []
            }
        }
        return paths
    }

    /// 替换上层注入的 accessDenied 集合。每次扫描完成后由 UI 层调一次。
    /// 线程安全：所有读写都在 [accessDeniedLock](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L43) 下进行。
    ///
    /// **路径标准化（v1.3.zzzz Phase 2-F-A）**：入集前对每条路径做
    /// `URL(fileURLWithPath:).standardizedFileURL.path`，把 `/private/var/folders/...`
    /// 这类 firmlink 折叠成 `/var/folders/...`，与 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L215)
    /// 的口径一致；`partitionByForbid` 比较时对入参 `p` 也做同样处理（见 [normalize](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)）。
    /// 防御场景：BulkScanner 给的 deniedPaths 与 selectedRows 里的 url.path 来源不同，
    /// firmlink 形态可能不一致——任一侧未标准化都会造成"明明在 deniedSet 却 contains 落空"
    /// 漏拦。
    public func setAccessDeniedPaths(_ paths: Set<String>) {
        let normalized = Set(paths.map(Self.normalizePath))
        accessDeniedLock.lock()
        _accessDeniedPaths = normalized
        accessDeniedLock.unlock()
    }

    /// 当前 accessDenied 快照（仅供单测断言使用）。已经是标准化后的形式。
    func snapshotAccessDeniedPaths() -> Set<String> {
        accessDeniedLock.lock()
        defer { accessDeniedLock.unlock() }
        return _accessDeniedPaths
    }

    /// 路径标准化（v1.3.zzzz Phase 2-F-A）：折叠 firmlink，与 SafetyEngine 口径对齐。
    ///
    /// **为什么不用 `URL(fileURLWithPath:).standardizedFileURL.path`**：
    /// macOS 的 `standardizedFileURL` 对**不存在**的路径不会折叠 firmlink（实测：
    /// `/private/var/folders/zz/abc/T/x` 不存在时会原样返回 `/private/var/folders/...`，
    /// 不会变成 `/var/folders/...`）。这导致 BulkScanner 给的 `/private/var/...` 形态
    /// 和 selectedRows 拿到的 `/var/...` 形态在 `Set.contains` 上对不上。
    /// SafetyEngine 之所以能正常工作，是因为它的 hardForbid 列表里同时膨胀了
    /// `/private/var` 和 `/var` 两套前缀（见 [hardForbidPrefixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L185)），
    /// 不依赖路径标准化吃 firmlink。
    ///
    /// **本函数实现**：用纯字符串规则折叠已知 firmlink 前缀，与磁盘是否存在解耦：
    /// - `/private/var/...` → `/var/...`
    /// - `/private/tmp/...` → `/tmp/...`
    /// - `/private/etc/...` → `/etc/...`
    ///
    /// 这三条覆盖 macOS 当前所有标准 firmlink，且与 `getattrlist(ATTR_CMNEXT_NOFIRMLINKPATH)`
    /// 折叠出的形态等价。再叠一层 `URL.standardizedFileURL` 处理 `..` / 重复 `/`。
    /// 复杂度：单次 O(path 长度)。调用规模是 paths.count（几十~几千）级别，
    /// 不是 BulkScanner 节点数（30w）级别，可放心走。
    static func normalizePath(_ raw: String) -> String {
        let trimmed = URL(fileURLWithPath: raw).standardizedFileURL.path
        // 已知 firmlink 前缀：长前缀优先，避免 `/private/var/...` 被 `/private/...` 截短。
        let firmlinks: [(String, String)] = [
            ("/private/var/", "/var/"),
            ("/private/tmp/", "/tmp/"),
            ("/private/etc/", "/etc/"),
        ]
        for (priv, pub) in firmlinks {
            if trimmed.hasPrefix(priv) {
                return pub + String(trimmed.dropFirst(priv.count))
            }
            // 整体等于 `/private/var` 这种边界（无尾斜杠）也归一化
            let privNoSlash = String(priv.dropLast())
            if trimmed == privNoSlash {
                return String(pub.dropLast())
            }
        }
        return trimmed
    }

    /// 把传入的路径按 SafetyEngine 判定切成两堆：可继续 trash 的 + 被禁的（连同 rejection）。
    ///
    /// 暴露成 `static`（@testable 可见）的目的：
    /// - 单测可以独立验证拦截策略，无需触发真的 NSWorkspace.recycle
    /// - UI 层可以在弹窗前调一次拿到拒绝清单，提示用户"以下 N 项不会被删"
    ///
    /// `trie` 非 nil 时启用 vendor 路径覆盖判定（vendors.yaml `paths: [{verdict: forbid}]`），
    /// 命中即拒、reason=`.vendorPathRule`。这是修复"vendor-only forbid 路径在最后闸门漏拦"的硬伤。
    ///
    /// `accessDeniedPaths`（v1.3.zzzz）是上层一票否决集合：BulkScanner 期间被标记
    /// `permissionDenied` / `tccProtected` 的路径里实质没有数据，"对它 trash"是个伪操作。
    /// 请求路径与 denied 路径只要存在祖先 / 后代重叠就直接拒绝，reason=`.accessDenied`，
    /// **不再走 SafetyEngine**——优先级最高。这样既不会删除一个包含未扫描子树的父目录，
    /// 也不会从一个未获权限的目录内部挑路径删除。
    ///
    /// **路径口径（v1.3.zzzz Phase 2-F-A）**：循环内对每个待判路径 p 做
    /// [normalizePath](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L80)
    /// 后再 `Set.contains`，确保两侧 firmlink 形态一致；`accessDeniedPaths` 入参允许
    /// 调用方传入未标准化的 Set（外部测试 / 旧 callsite），Set 元素也被假定将经过
    /// [setAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L63)
    /// 注入路径标准化——若直接以 static 方式调用，调用方需自行确保两侧口径一致。
    /// `rejected` 仍返回原始 p（不替换为标准化后的字符串），便于 UI / 日志展示用户能识别的路径。
    static func partitionByForbid(
        paths: [String],
        safety: SafetyEngine,
        trie: VendorTrieNode? = nil,
        accessDeniedPaths: Set<String> = [],
        whitelistPaths: Set<String> = [],
        home: String = NSHomeDirectory(),
        externalDeletionRoots: [String] = [],
        deviceIdentityProvider: @escaping @Sendable (String) -> PathDeviceIdentity = TrashPipeline.pathDeviceIdentity
    ) -> (allowed: [String], rejected: [(path: String, reason: SafetyRejection)]) {
        var allowed: [String] = []
        var rejected: [(String, SafetyRejection)] = []
        allowed.reserveCapacity(paths.count)
        // accessDeniedPaths 容量小（几十~几千），对它做一次性 normalize。
        // 这里不能只做 Set.contains：若 denied=/A/locked、request=/A，删除父目录仍会把
        // 未扫描子树一起移入废纸篓。反向的 request=/A/locked/child 也必须拒绝。
        let deniedIndex = ProtectedPathIndex(paths: accessDeniedPaths)
        let whitelistIndex = ProtectedPathIndex(paths: whitelistPaths)
        let deletionScope = DeletionScope(
            home: home,
            externalRoots: externalDeletionRoots,
            deviceIdentityProvider: deviceIdentityProvider
        )
        for (index, p) in paths.enumerated() {
            // 解析 symlink 属于潜在慢 IO；每个候选之间都允许协作取消，大批量时
            // 另按固定步长检查，取消后整批显式拒绝，绝不返回部分 allowed。
            if index.isMultiple(of: 32), Task.isCancelled {
                return cancelledPartition(paths: paths)
            }
            let normalizedPath = normalizePath(p)
            // 优先级 1：用户白名单是跨扫描、跨功能入口的“永不清理”合同。
            // 子项被加白时，删除其父目录同样必须拒绝。raw 与
            // resolved-symlink 身份都要命中：否则 `/cache/alias/child`
            // 通过中间 symlink 指向已加白真实目录时，内核会移动真实
            // child，但纯字符串索引看不出这层身份关系。
            if whitelistIndex.overlapsAnyIdentity(of: normalizedPath) {
                rejected.append((p, .userWhitelisted))
                continue
            }
            // 优先级 2：accessDenied 一票否决（不走 SafetyEngine）
            // 用组件边界安全的祖先 / 后代重叠判断，避免 /A 与 /AB 发生字符串前缀误判。
            if deniedIndex.overlapsAnyIdentity(of: normalizedPath) {
                rejected.append((p, .accessDenied))
                continue
            }
            // 优先级 3：原有 SafetyEngine.evaluate（内部已自带 standardizedFileURL）。
            // 先保留 relative/dot-dot/SIP/凭证等更具体的拒绝原因；只有通过语义
            // 安全判定的路径才继续检查“当前进程究竟有没有删除该范围的能力”。
            let verdict: SafetyVerdict
            let reason: SafetyRejection
            if let trie {
                let (v, r, _) = safety.evaluate(path: p, trie: trie, home: home)
                verdict = v
                reason = r
            } else {
                (verdict, reason) = safety.evaluate(path: p, home: home)
            }
            if verdict == .forbid {
                rejected.append((p, reason))
                continue
            }
            // 优先级 4：删除能力只覆盖当前用户数据。扫描可以浏览外置卷/其它路径，
            // 但它们永远不能因此自动获得删除能力。raw 与 resolved 任一身份逃出范围
            // 都拒绝，封住“HOME 内 symlink 指向外部卷”的路径穿越。
            guard deletionScope.contains(rawPath: p) else {
                rejected.append((p, .outsideUserDeletionScope))
                continue
            }
            allowed.append(p)
        }
        if Task.isCancelled {
            return cancelledPartition(paths: paths)
        }
        return (allowed, rejected)
    }

    private static func cancelledPartition(
        paths: [String]
    ) -> (allowed: [String], rejected: [(path: String, reason: SafetyRejection)]) {
        ([], paths.map { ($0, .preflightCancelled) })
    }

    /// `lstat(2)` 的设备身份结果。missing 继续交给 dry-run / recycle 的缺失路径逻辑；
    /// unavailable 表示路径存在性或 metadata 无法可信判断，必须拒绝。
    enum PathDeviceIdentity: Sendable, Equatable {
        case device(UInt64)
        case missing
        case unavailable
    }

    nonisolated static func pathDeviceIdentity(at path: String) -> PathDeviceIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unavailable
        }
        return .device(UInt64(info.st_dev))
    }

    /// 最终删除能力范围。所有根都使用“严格子路径 + 同设备”语义：不能回收 HOME 本身，
    /// 也不能回收整个 Darwin T/C 根；直接挂载在 HOME 子目录的外置卷 / DMG 即使字符串
    /// 前缀仍在 HOME 下，也会因 `st_dev` 不同被拒绝。SafetyEngine 仍会做更细语义判定。
    private struct DeletionScope {
        struct AllowedRoot {
            let path: String
            let deviceID: UInt64?
        }

        let allowedRoots: [AllowedRoot]
        let deviceIdentityProvider: @Sendable (String) -> PathDeviceIdentity

        init(
            home: String,
            externalRoots: [String],
            deviceIdentityProvider: @escaping @Sendable (String) -> PathDeviceIdentity = TrashPipeline.pathDeviceIdentity
        ) {
            var rootPaths = Set(Self.rootIdentities(home))
            for root in externalRoots {
                rootPaths.formUnion(Self.rootIdentities(root))
            }
            self.deviceIdentityProvider = deviceIdentityProvider
            self.allowedRoots = rootPaths.sorted().compactMap { rootPath in
                switch deviceIdentityProvider(rootPath) {
                case .device(let deviceID):
                    return AllowedRoot(path: rootPath, deviceID: deviceID)
                case .missing:
                    // 自定义测试 HOME 可以是纯字符串；候选同样 missing 时仍保留历史
                    // path-only 语义。生产 HOME / Darwin T-C 根必然存在并会绑定设备。
                    return AllowedRoot(path: rootPath, deviceID: nil)
                case .unavailable:
                    return nil
                }
            }
        }

        func contains(rawPath: String) -> Bool {
            guard rawPath.hasPrefix("/") else { return false }
            let identities = Self.pathIdentities(rawPath)
            guard !identities.isEmpty else { return false }
            let matchingRoots: (String) -> [AllowedRoot] = { candidate in
                allowedRoots.filter { root in
                    candidate.hasPrefix(root.path == "/" ? "/" : root.path + "/")
                }
            }
            guard identities.allSatisfy({ !matchingRoots($0).isEmpty }) else { return false }

            switch deviceIdentityProvider(rawPath) {
            case .missing:
                // 保留 dry-run 对不存在路径的独立 missing 结果；真实存在的挂载点一定
                // 会走 .device，因此不能借此绕过跨卷检查。
                return true
            case .unavailable:
                return false
            case .device(let candidateDeviceID):
                return identities.allSatisfy { candidate in
                    matchingRoots(candidate).contains { root in
                        root.deviceID == candidateDeviceID
                    }
                }
            }
        }

        private static func rootIdentities(_ path: String) -> Set<String> {
            pathIdentities(path)
        }

        private static func pathIdentities(_ path: String) -> Set<String> {
            let raw = TrashPipeline.scopeNormalize(path)
            let resolved = TrashPipeline.scopeNormalize(
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            )
            return raw == resolved ? [raw] : [raw, resolved]
        }
    }

    /// 删除范围比较专用的 canonical form。除标准 firmlink 外，把 Data 卷镜像
    /// `/System/Volumes/Data/Users/...` 折回 `/Users/...`，与 Finder/用户看到的 HOME
    /// 身份对齐；这只用于“是否在能力范围”判断，不改变最终提交给 recycle 的路径。
    private static func scopeNormalize(_ raw: String) -> String {
        let normalized = normalizePath(raw)
        let dataPrefix = "/System/Volumes/Data"
        if normalized == dataPrefix { return "/" }
        if normalized.hasPrefix(dataPrefix + "/") {
            return String(normalized.dropFirst(dataPrefix.count))
        }
        return normalized
    }

    /// `confstr(3)` 是 Darwin 对当前登录用户 T/C 根的权威来源。只在生产 HOME 与
    /// `NSHomeDirectory()` 一致时作为默认例外；自定义 test home 不会意外继承真实根。
    private static func currentUserDarwinDeletionRoots() -> [String] {
        let names: [Int32] = [_CS_DARWIN_USER_TEMP_DIR, _CS_DARWIN_USER_CACHE_DIR]
        var roots: Set<String> = []
        for name in names {
            guard let path = confstrPath(name) else { continue }
            roots.insert(scopeNormalize(path))
        }
        return roots.sorted()
    }

    private static func confstrPath(_ name: Int32) -> String? {
        let length = confstr(name, nil, 0)
        guard length > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let bytes = buffer[..<terminator].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 删除保护路径的祖先 / 后代索引。祖先用 Set 按组件逐级查询，后代用排序数组
    /// lower-bound 查询第一个可能命中的前缀，避免大批量删除时笛卡尔扫描。
    ///
    /// 每条保护路径同时保留两种身份：
    /// - raw standardized：保护用户实际加白 / scanner 实际上报的命名空间；
    /// - resolved symlink：保护内核最终会触及的真实子树。
    ///
    /// resolved 只会**扩大拒绝集**，不会替换 raw 或产生放行决策；即使 symlink
    /// 在扫描后被重定向，原 alias 与当前 target 也都会保守拒绝。
    private struct ProtectedPathIndex {
        let pathSet: Set<String>
        let sortedPaths: [String]

        init<S: Sequence>(paths: S) where S.Element == String {
            var identities: Set<String> = []
            for path in paths {
                identities.formUnion(Self.identities(of: path))
            }
            self.pathSet = identities
            self.sortedPaths = identities.sorted()
        }

        func overlapsAnyIdentity(of path: String) -> Bool {
            // 正常删除批次通常没有 denied，用户也可能没配白名单。
            // 空索引先短路，避免为每个待删路径做无意义的 symlink IO。
            guard !pathSet.isEmpty else { return false }
            return Self.identities(of: path).contains(where: overlaps)
        }

        private func overlaps(_ path: String) -> Bool {
            guard !pathSet.isEmpty else { return false }

            // denied == request，或 denied 是 request 的祖先。
            var cursor = path
            while true {
                if pathSet.contains(cursor) { return true }
                guard cursor != "/", let slash = cursor.lastIndex(of: "/") else { break }
                cursor = slash == cursor.startIndex ? "/" : String(cursor[..<slash])
            }

            // request 是 denied 的祖先。`/` 组件边界保证 /A 不会匹配 /AB。
            let descendantPrefix = path == "/" ? "/" : path + "/"
            var lower = 0
            var upper = sortedPaths.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if sortedPaths[middle] < descendantPrefix {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower < sortedPaths.count && sortedPaths[lower].hasPrefix(descendantPrefix)
        }

        private static func identities(of path: String) -> Set<String> {
            let raw = TrashPipeline.normalizePath(path)
            let resolved = TrashPipeline.normalizePath(
                URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
            )
            if resolved == raw { return [raw] }
            return [raw, resolved]
        }
    }

    public func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
        let result = await performMoveToTrash(paths: paths, dryRun: dryRun)
        return result.payload.legacy
    }

    /// **v2026.06.17 (P0-3)**：原子返回结构化 outcome，避免 side-channel 单槽位被并发覆盖。
    /// 同时也会同步写入 `_lastOutcome`，保持老 callsite 通过 `snapshotLastOutcome()` 读取的兼容。
    public func moveToTrashReturningOutcome(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        return await performMoveToTrash(paths: paths, dryRun: dryRun).payload
    }

    /// request-scoped 的 accessDenied 入口。denied 快照与本次 paths 在同一个调用参数里
    /// 原子交接，避免两个并发删除请求通过 `setAccessDeniedPaths` 互相覆盖共享状态。
    public func moveToTrashReturningOutcome(
        paths: [String],
        dryRun: Bool,
        accessDeniedPaths: Set<String>
    ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        await performMoveToTrash(
            paths: paths,
            dryRun: dryRun,
            requestAccessDeniedPaths: accessDeniedPaths
        ).payload
    }

    public func moveToTrashVendorPathOverride(
        request: VendorPathOverrideRequest,
        dryRun: Bool,
        accessDeniedPaths: Set<String>
    ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        await performMoveToTrash(
            paths: request.paths,
            dryRun: dryRun,
            requestAccessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: request
        ).payload
    }

    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?
    ) async -> TrashSubmissionDisposition {
        await submitToTrashReturningDisposition(
            paths: paths,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: nil
        )
    }

    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?
    ) async -> TrashSubmissionDisposition {
        await submitToTrashReturningDisposition(
            paths: paths,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
            reviewIdentity: nil
        )
    }

    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?
    ) async -> TrashSubmissionDisposition {
        let performed = await performMoveToTrash(
            paths: paths,
            dryRun: false,
            requestAccessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
            reviewIdentity: reviewIdentity
        )
        // `dryRun=false` makes every return path explicit: either final revalidation rejected
        // before recycle, or recycle completed. Keep this fail-closed assertion so a future
        // branch cannot silently create an untyped Professional result.
        guard let disposition = performed.submissionDisposition else {
            assertionFailure("Real trash submission finished without a typed boundary")
            return .preSubmitRejected(.unsupportedPipeline)
        }
        return disposition
    }

    /// v2026.07.17 observable execution overload. Progress never participates in Safety, ledger,
    /// claim-fence or completion decisions; it only mirrors already-reached source-proof or
    /// ordinary recycle phases to the revision-owned UI consumer.
    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?,
        executionVerification: DeletionExecutionVerification?,
        executionProgressObserver: DeletionExecutionProgressObserver?
    ) async -> TrashSubmissionDisposition {
        let performed = await performMoveToTrash(
            paths: paths,
            dryRun: false,
            requestAccessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
            reviewIdentity: reviewIdentity,
            executionVerification: executionVerification,
            executionProgressObserver: executionProgressObserver
        )
        guard let disposition = performed.submissionDisposition else {
            assertionFailure("Real trash submission finished without a typed boundary")
            return .preSubmitRejected(.unsupportedPipeline)
        }
        return disposition
    }

    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?,
        executionVerification: DeletionExecutionVerification?
    ) async -> TrashSubmissionDisposition {
        let performed = await performMoveToTrash(
            paths: paths,
            dryRun: false,
            requestAccessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
            reviewIdentity: reviewIdentity,
            executionVerification: executionVerification
        )
        guard let disposition = performed.submissionDisposition else {
            assertionFailure("Real trash submission finished without a typed boundary")
            return .preSubmitRejected(.unsupportedPipeline)
        }
        return disposition
    }

    /// 历史兼容入口。本方法不能泛化绕过 `.forbid`，与普通删除走完全相同的 vendor trie；
    /// vendorPathRule 的专业模式能力只能走类型化 override 请求与最终重验。保留符号只为
    /// 旧调用方源码兼容，不能作为“强制越过任意安全规则”的产品入口。
    public func moveToTrashForce(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        return await performMoveToTrash(paths: paths, dryRun: dryRun).payload
    }

    /// 共享实现：一次计算 legacy 4 元组 + 结构化 outcome，**返回值**即权威结果，
    /// 同时 `recordOutcome` 写入 lastOutcome 槽位仅为兼容旧 `snapshotLastOutcome()` 读取方。
    /// `requestAccessDeniedPaths` 非 nil 时是本次请求自己的不可变快照；nil 仅为旧入口读取
    /// 兼容共享集合。生产统一协调器使用前者，避免并发请求串值。
    private func performMoveToTrash(
        paths: [String],
        dryRun: Bool,
        requestAccessDeniedPaths: Set<String>? = nil,
        vendorOverrideRequest: VendorPathOverrideRequest? = nil,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest? = nil,
        reviewIdentity: DeletionSnapshotIdentity? = nil,
        executionVerification: DeletionExecutionVerification? = nil,
        executionProgressObserver: DeletionExecutionProgressObserver? = nil
    ) async -> PerformedMove {
        guard !paths.isEmpty else {
            let outcome = TrashOutcome(movedPairs: [], failedPaths: [], safetyRejected: [], missingPaths: [])
            recordOutcome(outcome)
            let payload: MovePayload = ((0, 0, nil, []), outcome)
            return PerformedMove(
                payload: payload,
                submissionDisposition: dryRun ? nil : .preSubmitRejected(.emptyRequest)
            )
        }
        GSYLog.info(.trash, "moveToTrash 开始 dryRun=\(dryRun) paths=\(paths.count)")

        let trashExecutionProgress: (@Sendable (TrashExecutionProgress) -> Void)?
        if executionVerification == nil, let executionProgressObserver {
            trashExecutionProgress = { progress in
                executionProgressObserver(.trash(progress))
            }
        } else {
            trashExecutionProgress = nil
        }
        trashExecutionProgress?(.init(
            phase: .finalValidation,
            completedItems: 0,
            totalItems: paths.count,
            currentPath: nil
        ))

        // M4 闸门：先按 SafetyEngine 切批。被 forbid 的不进入后续逻辑（既不 dryRun present
        // 计数、也不真 recycle），统一计入 skipped。
        // v1.3.zzzz：把上层注入的 accessDeniedPaths 一并带上，让 partitionByForbid 一次切净
        // accessDenied + forbid 两类。
        let accessDenied = requestAccessDeniedPaths ?? snapshotAccessDeniedPaths()
        if let scanIncompleteOverrideRequest {
            let finalRejections = await finalScanIncompleteRejections(
                request: scanIncompleteOverrideRequest,
                paths: paths,
                accessDeniedPaths: accessDenied
            )
            guard finalRejections.isEmpty else {
                return scanIncompletePreSubmitFailure(
                    paths: paths,
                    rejections: finalRejections,
                    dryRun: dryRun
                )
            }
        }
        let preflight = await preflight(
            paths: paths,
            // A typed scan-incomplete request does not erase the denied set. The exact
            // overlapping paths were proven above against the frozen typed issues; this second
            // pass therefore evaluates the independent Safety/vendor/whitelist/scope layers.
            accessDeniedPaths: scanIncompleteOverrideRequest == nil ? accessDenied : []
        )
        let allowed: [String]
        let rejected: [DeletionPreflight.Rejection]
        if let vendorOverrideRequest {
            let finalAuthorization = VendorPathOverrideRequest(preflight: preflight)
            if vendorOverrideRequest.paths == paths,
               finalAuthorization == vendorOverrideRequest {
                // 只越过本次重新预检确认的纯 vendorPathRule。其它所有安全层已经在
                // `vendorOverrideEligiblePaths` 铸造阶段重验，且这里没有复用 UI 旧快照。
                allowed = paths
                rejected = []
                GSYLog.warning(.trash, "vendorPathRule override 最终预检通过 paths=\(paths.count)")
            } else {
                allowed = []
                rejected = preflight.rejections.isEmpty
                    ? paths.map {
                        DeletionPreflight.Rejection(
                            path: $0,
                            reason: "vendorOverrideNotEligible"
                        )
                    }
                    : preflight.rejections
                GSYLog.warning(.trash, "vendorPathRule override 最终预检拒绝 paths=\(paths.count)")
            }
        } else {
            allowed = preflight.allowedPaths
            rejected = preflight.rejections
        }
        if !rejected.isEmpty {
            GSYLog.warning(.trash, "moveToTrash 被安全预检拦截 \(rejected.count)/\(paths.count) firstReason=\(rejected[0].reason) firstPath=\(rejected[0].path)")
        }

        // SECURITY.md 的批级原子合同：任一 path 命中 forbid，整批在触碰文件系统前拒绝。
        // preflight 已把其余原本 allowed 的路径标成 batchContainsForbidden，UI 与执行
        // 共用同一批结果，不再各自拼装。
        if !rejected.isEmpty {
            let atomicSafetyRejectedTuples = rejected.map { ($0.path, $0.reason) }
            let firstReason = rejected[0].reason
            let failureSummary = TrashFailureSummary.safetyBlocked(
                count: paths.count,
                firstReason: firstReason,
                preview: dryRun
            )
            let outcome = TrashOutcome(
                movedPairs: [],
                failedPaths: [],
                safetyRejected: atomicSafetyRejectedTuples,
                missingPaths: [],
                vendorOverrideEligiblePaths: preflight.vendorOverrideEligiblePaths,
                failureSummary: failureSummary
            )
            recordOutcome(outcome)
            let err = failureSummary.legacyDiagnostic
            GSYLog.warning(
                .trash,
                "moveToTrash 批级原子拒绝 submitted=\(paths.count) directRejected=\(rejected.count) firstReason=\(firstReason)"
            )
            let payload: MovePayload = ((0, paths.count, err, []), outcome)
            let rejectedPreflight = DeletionPreflight(
                allowedPaths: [],
                rejections: rejected,
                vendorOverrideEligiblePaths: vendorOverrideRequest == nil
                    ? preflight.vendorOverrideEligiblePaths
                    : []
            )
            let preSubmitRejection: TrashPreSubmitRejection = if vendorOverrideRequest == nil {
                .safety(rejectedPreflight)
            } else {
                .invalidVendorOverride(rejectedPreflight)
            }
            return PerformedMove(
                payload: payload,
                submissionDisposition: dryRun ? nil : .preSubmitRejected(preSubmitRejection)
            )
        }

        // The safety/vendor pass above may perform filesystem resolution. Recheck the stable
        // target identity once more after that work and immediately before constructing the
        // recycle input, so a replacement during preflight cannot inherit the old confirmation.
        if let scanIncompleteOverrideRequest {
            let immediateRejections = await finalScanIncompleteRejections(
                request: scanIncompleteOverrideRequest,
                paths: paths,
                accessDeniedPaths: accessDenied
            )
            guard immediateRejections.isEmpty else {
                return scanIncompletePreSubmitFailure(
                    paths: paths,
                    rejections: immediateRejections,
                    dryRun: dryRun
                )
            }
        }

        let duplicateVerificationRequest: DuplicateDeletionVerificationRequest?
        switch executionVerification {
        case .some(.duplicate(let request)):
            guard request.matchesExactTargets(allowed) else {
                return duplicateVerificationPreSubmitFailure(
                    paths: allowed,
                    rejections: allowed.map {
                        .init(
                            path: $0,
                            reason: DuplicateDeletionVerificationRejectionReason
                                .invalidEvidence.rawValue
                        )
                    }
                )
            }
            duplicateVerificationRequest = request
        case .none:
            duplicateVerificationRequest = nil
        }

        if dryRun {
            var present = 0
            var missingPaths: [String] = []
            let fm = FileManager.default
            for p in allowed {
                if fm.fileExists(atPath: p) {
                    present += 1
                } else {
                    missingPaths.append(p)
                }
            }
            let missing = missingPaths.count
            let skipped = missing
            let failureSummary = missing > 0
                ? TrashFailureSummary.previewMissing(count: missing)
                : nil
            let err = failureSummary?.legacyDiagnostic
            GSYLog.info(.trash, "moveToTrash dryRun 完成 present=\(present) skipped=\(skipped) missing=\(missing)")
            let outcome = TrashOutcome(movedPairs: [],
                                       failedPaths: [],
                                       safetyRejected: [],
                                       missingPaths: missingPaths,
                                       failureSummary: failureSummary)
            recordOutcome(outcome)
            return PerformedMove(
                payload: ((present, skipped, err, []), outcome),
                submissionDisposition: nil
            )
        }

        // **v2026.07.16 pending duplicate root-cause fix**：reserve the complete normalized
        // request in one flock-protected RMW before any AppKit call can be queued. Every
        // TrashPipeline instance/process shares this boundary; a prior unknown operation or
        // changed inode remains a typed pre-submit rejection rather than a duplicate retry.
        let operationID = UUID()
        let ledger = pendingOperationLedger
        let reservation = await Task.detached(priority: .userInitiated) {
            ledger.reserve(
                paths: allowed,
                operationID: operationID,
                reviewIdentity: reviewIdentity
            )
        }.value
        let reservedPaths: [String]
        switch reservation {
        case .reserved(let normalizedPaths, let invalidatedPaths):
            reservedPaths = normalizedPaths
            Self.publishLedgerInvalidation(paths: invalidatedPaths, operationID: operationID)
        case .rejected(let rejection, let invalidatedPaths):
            Self.publishLedgerInvalidation(paths: invalidatedPaths, operationID: operationID)
            return pendingLedgerPreSubmitFailure(
                paths: allowed,
                rejection: rejection
            )
        }


        // v2026.07.17 Duplicate TOCTOU closure: reserve first so every target has a frozen inode
        // in the cross-process ledger, then re-open and fully hash selected targets plus one
        // retained copy on a background dispatch queue. A failed/cancelled proof releases the
        // unclaimed reservation and returns a typed pre-submit block; no AppKit recycle call has
        // occurred. The resulting cheap claim fence is carried into every batch and single retry.
        let duplicateClaimFence: DuplicateDeletionClaimFence?
        let duplicateSubmissionObserver: (@Sendable () -> Void)?
        if let duplicateVerificationRequest {
            let cancellationToken = DuplicateDeletionVerificationCancellationToken()
            let verificationProgress: (@Sendable (DuplicateDeletionVerificationProgress) -> Void)?
            if let executionProgressObserver {
                verificationProgress = { progress in
                    executionProgressObserver(.duplicate(progress))
                }
            } else {
                verificationProgress = nil
            }
            GSYLog.info(
                .trash,
                "Duplicate verification phase=start targets=\(reservedPaths.count) items=\(duplicateVerificationRequest.verificationItemCount)"
            )
            var rejections = await DuplicateDeletionFinalVerifier.verify(
                request: duplicateVerificationRequest,
                authorizedPaths: reservedPaths,
                cancellationToken: cancellationToken,
                progress: verificationProgress
            )
            if cancellationToken.isCancelled, rejections.isEmpty {
                rejections = reservedPaths.map {
                    .init(
                        path: $0,
                        reason: DuplicateDeletionVerificationRejectionReason
                            .verificationCancelled.rawValue
                    )
                }
            }
            guard rejections.isEmpty else {
                GSYLog.notice(
                    .trash,
                    "Duplicate verification phase=blocked targets=\(reservedPaths.count) rejections=\(rejections.count) cancelled=\(cancellationToken.isCancelled)"
                )
                let released = await Task.detached(priority: .utility) {
                    ledger.finish(operationID: operationID, retainingPendingPaths: [])
                }.value
                if !released {
                    GSYLog.error(
                        .trash,
                        "Duplicate verification reservation release failed operationID=\(operationID.uuidString)"
                    )
                }
                return duplicateVerificationPreSubmitFailure(
                    paths: reservedPaths,
                    rejections: rejections
                )
            }
            GSYLog.info(
                .trash,
                "Duplicate verification phase=complete targets=\(reservedPaths.count)"
            )
            duplicateClaimFence = DuplicateDeletionClaimFence(
                request: duplicateVerificationRequest,
                cancellationToken: cancellationToken
            )
            if let executionProgressObserver {
                let progressGate = RecycleSubmissionProgressGate {
                    executionProgressObserver(.duplicate(.init(
                        phase: .submittingToTrash,
                        completedItems: duplicateVerificationRequest.verificationItemCount,
                        totalItems: duplicateVerificationRequest.verificationItemCount,
                        currentPath: nil
                    )))
                }
                duplicateSubmissionObserver = { progressGate.notifyOnce() }
            } else {
                duplicateSubmissionObserver = nil
            }
        } else {
            duplicateClaimFence = nil
            duplicateSubmissionObserver = nil
        }

        // **v2026.06.16 修复 #2（system-images 删除拒绝）**：
        // 旧实现把 allowed 整批（可能 100+ 条、单条 1-3GB）一次性塞给 NSWorkspace.recycle。
        // NSWorkspace.recycle 在如下场景容易整批返回 "Some files could not be moved" 而不告知是哪条：
        // 1. 批内单条文件被进程占用（emulator / qemu 持有 system.img 句柄）
        // 2. 批内含 0444 只读文件 + xattr 复杂的 system image
        // 3. 单次回收站操作有路径/数量上限
        //
        // 新实现：分批 → 批失败回退到单 URL 隔离重试，能精确捕获哪条 path 失败、不让一条坏路径拖垮整批。
        let allowedURLs = reservedPaths.map { URL(fileURLWithPath: $0) }
        let recycleResult: RecycleBatchResult
        if let duplicateClaimFence {
            recycleResult = await withTaskCancellationHandler {
                await recycleInBatches(
                    urls: allowedURLs,
                    operationID: operationID,
                    duplicateClaimFence: duplicateClaimFence,
                    duplicateSubmissionObserver: duplicateSubmissionObserver,
                    progress: trashExecutionProgress
                )
            } onCancel: {
                duplicateClaimFence.cancel()
            }
        } else {
            recycleResult = await recycleInBatches(
                urls: allowedURLs,
                operationID: operationID,
                progress: trashExecutionProgress
            )
        }
        let retainedUnknown = Set(
            recycleResult.pendingPaths + recycleResult.submissionUnknownPaths
        )
        let ledgerFinalized = await Task.detached(priority: .utility) {
            ledger.finish(operationID: operationID, retainingPendingPaths: retainedUnknown)
        }.value
        if !ledgerFinalized {
            // Fail-safe behavior is a stale tombstone, never an unguarded duplicate submission.
            GSYLog.error(.trash, "Trash pending ledger finalization failed operationID=\(operationID.uuidString)")
        }

        if recycleResult.attemptedPaths.isEmpty,
           let rejection = recycleResult.preSubmitRejection {
            if let rejections = duplicateClaimFenceRejections(from: rejection) {
                return duplicateVerificationPreSubmitFailure(
                    paths: reservedPaths,
                    rejections: rejections
                )
            }
            return pendingLedgerPreSubmitFailure(paths: reservedPaths, rejection: rejection)
        }
        if recycleResult.attemptedPaths.isEmpty {
            let rejection = TrashPendingOperationRejection(
                reasonsByPath: Dictionary(uniqueKeysWithValues: reservedPaths.map {
                    ($0, .submissionQueueExpired)
                })
            )
            return pendingLedgerPreSubmitFailure(paths: reservedPaths, rejection: rejection)
        }
        let movedPairs = recycleResult.moved
        let movedSet = Set(movedPairs.map { $0.0 })
        let unresolvedSet = Set(
            recycleResult.pendingPaths + recycleResult.submissionUnknownPaths
        )
        let confirmedAttempted = recycleResult.attemptedPaths.filter { !unresolvedSet.contains($0) }
        let failedPaths = confirmedAttempted.filter { !movedSet.contains($0) }
        var failureReasons = recycleResult.failureReasons
        let unknownFailure = TrashFailureSummary.unknownRecycleReasonKey
        for path in failedPaths where failureReasons[path] == nil {
            failureReasons[path] = unknownFailure
        }

        let movedCount = movedPairs.count
        let totalSkipped = failedPaths.count
            + recycleResult.pendingPaths.count
            + recycleResult.submissionUnknownPaths.count
            + recycleResult.notSubmittedPaths.count
        let failureSummary: TrashFailureSummary? = if !recycleResult.submissionUnknownPaths.isEmpty {
            .recycleSubmissionUnknown(
                unknownCount: recycleResult.submissionUnknownPaths.count,
                notSubmittedCount: recycleResult.notSubmittedPaths.count,
                movedCount: movedCount
            )
        } else if !recycleResult.pendingPaths.isEmpty {
            .recyclePending(
                pendingCount: recycleResult.pendingPaths.count,
                notSubmittedCount: recycleResult.notSubmittedPaths.count,
                movedCount: movedCount
            )
        } else if !recycleResult.notSubmittedPaths.isEmpty {
            .recycleBudgetExpired(
                notSubmittedCount: recycleResult.notSubmittedPaths.count,
                movedCount: movedCount,
                failedCount: failedPaths.count
            )
        } else if !failedPaths.isEmpty {
            .recycleFailed(
                failedCount: failedPaths.count,
                movedCount: movedCount,
                firstPath: failedPaths.first
            )
        } else {
            nil
        }
        let outcome = TrashOutcome(movedPairs: movedPairs,
                                   failedPaths: failedPaths,
                                   pendingPaths: recycleResult.pendingPaths,
                                   submissionUnknownPaths: recycleResult.submissionUnknownPaths,
                                   notSubmittedPaths: recycleResult.notSubmittedPaths,
                                   notSubmittedReasons: recycleResult.preSubmitRejection?.reasonsByPath ?? [:],
                                   safetyRejected: [],
                                   missingPaths: [],
                                   failureReasons: failureReasons,
                                   failureSummary: failureSummary)
        recordOutcome(outcome)
        let err = failureSummary?.legacyDiagnostic
        GSYLog.info(.trash, "moveToTrash 返回 moved=\(movedCount) failed=\(failedPaths.count) pending=\(recycleResult.pendingPaths.count) submissionUnknown=\(recycleResult.submissionUnknownPaths.count) notSubmitted=\(recycleResult.notSubmittedPaths.count) safetyRejected=\(rejected.count) totalSkipped=\(totalSkipped) pairs=\(movedPairs.count)")
        let payload: MovePayload = ((movedCount, totalSkipped, err, movedPairs), outcome)
        return PerformedMove(
            payload: payload,
            submissionDisposition: .recycleCompleted(TrashRecycleCompletion(
                attemptedPaths: recycleResult.attemptedPaths,
                legacy: payload.legacy,
                outcome: payload.outcome
            ))
        )
    }

    private func pendingLedgerPreSubmitFailure(
        paths: [String],
        rejection: TrashPendingOperationRejection
    ) -> PerformedMove {
        let rejections = rejection.preflightRejections
        let firstReason = rejections.first?.reason
            ?? TrashPendingOperationRejection.Reason.ledgerUnavailable.rawValue
        let summary = TrashFailureSummary.safetyBlocked(
            count: paths.count,
            firstReason: firstReason,
            preview: false
        )
        let outcome = TrashOutcome(
            movedPairs: [],
            failedPaths: [],
            safetyRejected: rejections.map { ($0.path, $0.reason) },
            missingPaths: [],
            failureSummary: summary
        )
        recordOutcome(outcome)
        return PerformedMove(
            payload: ((0, paths.count, summary.legacyDiagnostic, []), outcome),
            submissionDisposition: .preSubmitRejected(.pendingOperation(rejection))
        )
    }

    /// Absence / inode replacement proves the old pending row is no longer an accurate model
    /// of the filesystem. This notification only invalidates projections; the durable ledger
    /// tombstone remains fail-closed until a future typed fresh-review capability clears it.
    private static func publishLedgerInvalidation(paths: [String], operationID: UUID) {
        guard !paths.isEmpty else { return }
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .gsyTrashPendingLedgerDidInvalidate,
                object: nil,
                userInfo: [
                    "paths": paths,
                    "source": "TrashPendingLedger",
                    "operationID": operationID.uuidString
                ]
            )
        }
    }

    /// **v2026.06.16 修复 #2**：分批 recycle + 单 URL 隔离重试。
    /// - 第一轮：把 urls 按 `batchSize` 切片，每批一次 `NSWorkspace.recycle`；
    /// - 任一批失败（含部分失败）→ 只对该批未成功的 URL **逐条** 再 recycle 一次，
    ///   把"哪一条具体卡住"暴露出来，不让坏路径拖垮整批。
    ///
    /// **批大小 32**：经验值——既能利用 recycle 批处理优势降低系统开销，又能让单批失败时
    /// 隔离重试的代价（最多 32 次单 URL recycle）可控。可改 `batchSize` 调优。
    ///
    /// **v2026.07.16（异步终态合同）**：一旦系统回调超时，本批标记为 pending，后续
    /// 批次标记为 not-submitted 并立即停止。未知状态绝不能回退为单项重试，否则同一路径
    /// 可能被重复提交；确认成功的 pair 仍可独立写入 Undo。
    private func recycleInBatches(
        urls: [URL],
        operationID: UUID,
        duplicateClaimFence: DuplicateDeletionClaimFence? = nil,
        duplicateSubmissionObserver: (@Sendable () -> Void)? = nil,
        progress: (@Sendable (TrashExecutionProgress) -> Void)? = nil,
        batchSize: Int = 32
    ) async -> RecycleBatchResult {
        // v2026.07.16：45 秒是整个请求的 UI 等待预算，不是每个子调用各 45 秒。
        // 这样即使批失败后需要逐项诊断，整轮也不会退化为 N × timeout 的分钟级 loading。
        let budgetNanoseconds: UInt64 = 45 * 1_000_000_000
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started > UInt64.max - budgetNanoseconds
            ? UInt64.max
            : started + budgetNanoseconds
        return await Self.executeRecycleBatches(
            urls: urls,
            batchSize: batchSize,
            progress: progress,
            recycle: { urls in
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else {
                    return RecycleAttempt(
                        moved: [],
                        errorDescription: nil,
                        state: .notSubmittedBudgetExpired
                    )
                }
                let remainingSeconds = Double(deadline - now) / 1_000_000_000
                return await Self.recycleOnce(
                    urls: urls,
                    operationID: operationID,
                    timeoutSeconds: remainingSeconds,
                    ledger: self.pendingOperationLedger,
                    duplicateClaimFence: duplicateClaimFence,
                    submissionObserver: duplicateSubmissionObserver
                )
            }
        )
    }

    /// 批处理核心只依赖一个 Sendable 异步操作：生产环境传 `NSWorkspace.recycle` 适配器，
    /// 单测传 actor-backed script。这样能精确验证部分成功与单项隔离重试，同时保证
    /// 测试不会移动任何真实文件。
    static func executeRecycleBatches(
        urls: [URL],
        batchSize: Int = 32,
        progress: (@Sendable (TrashExecutionProgress) -> Void)? = nil,
        recycle: @Sendable ([URL]) async -> RecycleAttempt
    ) async -> RecycleBatchResult {
        precondition(batchSize > 0, "batchSize must be positive")
        var allMoved: [(String, String)] = []
        allMoved.reserveCapacity(urls.count)
        var failureReasons: [String: String] = [:]
        var attemptedPaths: [String] = []
        var pendingPaths: [String] = []
        var submissionUnknownPaths: [String] = []
        var notSubmittedPaths: [String] = []
        var preSubmitRejection: TrashPendingOperationRejection?
        var progressCompletedPaths = Set<String>()

        func emitProgress(_ phase: TrashExecutionProgress.Phase, currentPath: String? = nil) {
            progress?(.init(
                phase: phase,
                completedItems: progressCompletedPaths.count,
                totalItems: urls.count,
                currentPath: currentPath
            ))
        }

        func markProgressCompleted<S: Sequence>(_ paths: S) where S.Element == String {
            progressCompletedPaths.formUnion(paths)
        }

        // v2026.07.17: every return path converges the observable side channel. This defer does
        // not participate in recycle accounting and cannot manufacture a success result.
        defer { emitProgress(.finalizing) }

        var idx = 0
        while idx < urls.count {
            let end = min(idx + batchSize, urls.count)
            let batch = Array(urls[idx..<end])
            idx = end

            emitProgress(.submitting, currentPath: batch.first?.path)
            let batchAttempt = await recycle(batch)
            if case .notSubmittedBudgetExpired = batchAttempt.state {
                notSubmittedPaths.append(contentsOf: batch.map(\.path))
                if idx < urls.count {
                    notSubmittedPaths.append(contentsOf: urls[idx...].map(\.path))
                }
                GSYLog.warning(.trash, "moveToTrash 整体等待预算已耗尽；当前及后续批次未提交 count=\(notSubmittedPaths.count)")
                break
            }
            if case .preSubmitRejected(let rejection) = batchAttempt.state {
                preSubmitRejection = rejection
                notSubmittedPaths.append(contentsOf: batch.map(\.path))
                if idx < urls.count {
                    notSubmittedPaths.append(contentsOf: urls[idx...].map(\.path))
                }
                GSYLog.warning(.trash, "moveToTrash 持久提交闸门拒绝当前及后续批次 count=\(notSubmittedPaths.count)")
                break
            }

            attemptedPaths.append(contentsOf: batch.map(\.path))
            allMoved.append(contentsOf: batchAttempt.moved)
            markProgressCompleted(batchAttempt.moved.map { $0.0 })

            if case .submissionUnknown(let operationID) = batchAttempt.state {
                markProgressCompleted(batch.map(\.path))
                submissionUnknownPaths.append(contentsOf: batch.map(\.path))
                if idx < urls.count {
                    notSubmittedPaths.append(contentsOf: urls[idx...].map(\.path))
                }
                GSYLog.warning(.trash, "NSWorkspace.recycle 同步调用终态未知 operationID=\(operationID.uuidString) unknown=\(submissionUnknownPaths.count) notSubmitted=\(notSubmittedPaths.count)；停止后续提交")
                break
            }

            if case .callbackPending(let operationID) = batchAttempt.state {
                markProgressCompleted(batch.map(\.path))
                let movedSet = Set(batchAttempt.moved.map { $0.0 })
                pendingPaths.append(contentsOf: batch.lazy.map(\.path).filter { !movedSet.contains($0) })
                if idx < urls.count {
                    notSubmittedPaths.append(contentsOf: urls[idx...].map(\.path))
                }
                GSYLog.warning(.trash, "NSWorkspace.recycle 回调待定 operationID=\(operationID.uuidString) pending=\(pendingPaths.count) notSubmitted=\(notSubmittedPaths.count)；停止后续提交且不自动重试")
                break
            }

            // 不只依赖 error：系统偶尔会返回部分 trashed、但不给 NSError。只要存在未移动项，
            // 都逐条隔离重试，最终把每条失败原因带回 UI。
            let movedSet = Set(batchAttempt.moved.map { $0.0 })
            let unmoved = batch.filter { !movedSet.contains($0.path) }
            if !unmoved.isEmpty {
                GSYLog.warning(.trash, "moveToTrash 批次存在未移动项，回退到单 URL 隔离重试 batch=\(batch.count) unmoved=\(unmoved.count)")
            }
            for url in unmoved {
                emitProgress(.diagnosingItems, currentPath: url.path)
                let singleAttempt = await recycle([url])
                markProgressCompleted([url.path])
                if case .notSubmittedBudgetExpired = singleAttempt.state {
                    // 当前批已经收到确定的批量回调，只是没有剩余预算继续逐项诊断；
                    // 因此当前批仍按已提交失败核算，只有尚未开始的后续批次是 not-submitted。
                    for remaining in unmoved {
                        failureReasons[remaining.path] = batchAttempt.errorDescription
                            ?? TrashFailureSummary.unknownRecycleReasonKey
                    }
                    if idx < urls.count {
                        notSubmittedPaths.append(contentsOf: urls[idx...].map(\.path))
                    }
                    GSYLog.warning(.trash, "moveToTrash 整体等待预算在单项诊断前耗尽；停止后续批次")
                    return RecycleBatchResult(
                        moved: Self.stableUniqueMovedPairs(allMoved),
                        failureReasons: failureReasons,
                        attemptedPaths: Self.stableUniquePaths(attemptedPaths),
                        pendingPaths: Self.stableUniquePaths(pendingPaths),
                        submissionUnknownPaths: Self.stableUniquePaths(submissionUnknownPaths),
                        notSubmittedPaths: Self.stableUniquePaths(notSubmittedPaths),
                        preSubmitRejection: preSubmitRejection
                    )
                }
                if case .preSubmitRejected(let rejection) = singleAttempt.state {
                    preSubmitRejection = rejection
                    // The path already crossed the earlier batch call and received a terminal
                    // non-moved callback. Only the diagnostic retry was rejected, so the path
                    // remains a failed attempted item rather than becoming disjoint notSubmitted.
                    for remaining in unmoved {
                        failureReasons[remaining.path] = batchAttempt.errorDescription
                            ?? TrashFailureSummary.unknownRecycleReasonKey
                    }
                    if idx < urls.count {
                        notSubmittedPaths.append(contentsOf: urls[idx...].map(\.path))
                    }
                    return RecycleBatchResult(
                        moved: Self.stableUniqueMovedPairs(allMoved),
                        failureReasons: failureReasons,
                        attemptedPaths: Self.stableUniquePaths(attemptedPaths),
                        pendingPaths: Self.stableUniquePaths(pendingPaths),
                        submissionUnknownPaths: Self.stableUniquePaths(submissionUnknownPaths),
                        notSubmittedPaths: Self.stableUniquePaths(notSubmittedPaths),
                        preSubmitRejection: preSubmitRejection
                    )
                }
                attemptedPaths.append(url.path)
                allMoved.append(contentsOf: singleAttempt.moved)
                if case .submissionUnknown(let operationID) = singleAttempt.state {
                    submissionUnknownPaths.append(url.path)
                    for remaining in unmoved where remaining.path != url.path {
                        failureReasons[remaining.path] = batchAttempt.errorDescription
                            ?? TrashFailureSummary.unknownRecycleReasonKey
                    }
                    if idx < urls.count {
                        notSubmittedPaths.append(contentsOf: urls[idx...].map(\.path))
                    }
                    GSYLog.warning(.trash, "NSWorkspace.recycle 单项同步调用终态未知 operationID=\(operationID.uuidString) path=\(url.path)")
                    return RecycleBatchResult(
                        moved: Self.stableUniqueMovedPairs(allMoved),
                        failureReasons: failureReasons,
                        attemptedPaths: Self.stableUniquePaths(attemptedPaths),
                        pendingPaths: Self.stableUniquePaths(pendingPaths),
                        submissionUnknownPaths: Self.stableUniquePaths(submissionUnknownPaths),
                        notSubmittedPaths: Self.stableUniquePaths(notSubmittedPaths),
                        preSubmitRejection: preSubmitRejection
                    )
                }
                if case .callbackPending(let operationID) = singleAttempt.state {
                    pendingPaths.append(url.path)
                    // 当前批的其它未移动项已经随批量调用跨过系统边界，并收到确定回调；
                    // 只是没有再做单项诊断，所以它们仍按失败计，而不是“未提交”。
                    for remaining in unmoved where remaining.path != url.path {
                        failureReasons[remaining.path] = batchAttempt.errorDescription
                            ?? TrashFailureSummary.unknownRecycleReasonKey
                    }
                    if idx < urls.count {
                        notSubmittedPaths.append(contentsOf: urls[idx...].map(\.path))
                    }
                    GSYLog.warning(.trash, "NSWorkspace.recycle 单项回调待定 operationID=\(operationID.uuidString) path=\(url.path)；停止隔离重试与后续批次")
                    return RecycleBatchResult(
                        moved: Self.stableUniqueMovedPairs(allMoved),
                        failureReasons: failureReasons,
                        attemptedPaths: Self.stableUniquePaths(attemptedPaths),
                        pendingPaths: Self.stableUniquePaths(pendingPaths),
                        submissionUnknownPaths: Self.stableUniquePaths(submissionUnknownPaths),
                        notSubmittedPaths: Self.stableUniquePaths(notSubmittedPaths),
                        preSubmitRejection: preSubmitRejection
                    )
                }
                if singleAttempt.moved.isEmpty {
                    failureReasons[url.path] = singleAttempt.errorDescription
                        ?? batchAttempt.errorDescription
                        ?? TrashFailureSummary.unknownRecycleReasonKey
                }
            }
        }
        return RecycleBatchResult(
            moved: Self.stableUniqueMovedPairs(allMoved),
            failureReasons: failureReasons,
            attemptedPaths: Self.stableUniquePaths(attemptedPaths),
            pendingPaths: Self.stableUniquePaths(pendingPaths),
            submissionUnknownPaths: Self.stableUniquePaths(submissionUnknownPaths),
            notSubmittedPaths: Self.stableUniquePaths(notSubmittedPaths),
            preSubmitRejection: preSubmitRejection
        )
    }

    /// 单次 recycle 调用——把 NSWorkspace 的回调 async 化。
    /// 返回：(成功 pair 列表, 系统错误原因)。
    /// 注意：error≠nil 不代表全失败，trashed 可能有部分项。
    private static let recycleSubmissionQueue = DispatchQueue(
        label: "com.amux.ai.clean.trash.recycle",
        qos: .userInitiated
    )

    typealias WorkspaceRecycleOperation = @Sendable (
        [URL],
        @escaping @Sendable ([(String, String)], String?) -> Void
    ) -> Void
    typealias LateRecycleHandler = @Sendable ([(String, String)], UUID) -> Void

    private static func recycleOnce(
        urls: [URL],
        operationID: UUID,
        timeoutSeconds: TimeInterval,
        ledger: any TrashPendingOperationLedger,
        duplicateClaimFence: DuplicateDeletionClaimFence? = nil,
        submissionObserver: (@Sendable () -> Void)? = nil
    ) async -> RecycleAttempt {
        await executeRecycleOnce(
            urls: urls,
            operationID: operationID,
            timeoutSeconds: timeoutSeconds,
            ledger: ledger,
            submissionQueue: recycleSubmissionQueue,
            workspaceRecycle: { urls, callback in
                NSWorkspace.shared.recycle(urls) { trashed, error in
                    callback(
                        trashed.map { ($0.key.path, $0.value.path) },
                        error?.localizedDescription
                    )
                }
            },
            lateHandler: { pairs, operationID in
                Task { @MainActor in
                    Self.reconcileLateRecycle(pairs: pairs, operationID: operationID)
                }
            },
            duplicateClaimFence: duplicateClaimFence,
            submissionObserver: submissionObserver
        )
    }

    /// Injectable deterministic boundary used by tests for queue starvation and a synchronously
    /// blocked AppKit call. Tests provide scripted closures and temporary fixtures only.
    static func executeRecycleOnce(
        urls: [URL],
        operationID: UUID,
        attemptID: UUID = UUID(),
        timeoutSeconds: TimeInterval,
        ledger: any TrashPendingOperationLedger,
        submissionQueue: DispatchQueue,
        workspaceRecycle: @escaping WorkspaceRecycleOperation,
        lateHandler: @escaping LateRecycleHandler,
        duplicateClaimFence: DuplicateDeletionClaimFence? = nil,
        submissionObserver: (@Sendable () -> Void)? = nil
    ) async -> RecycleAttempt {
        await withCheckedContinuation { (cc: CheckedContinuation<RecycleAttempt, Never>) in
            let gate = RecycleOnceGate(cc: cc)
            let normalizedPaths = urls.map { normalizePath($0.path) }

            // v2026.07.16: the watchdog starts before enqueue. Queue starvation is therefore
            // `notSubmitted`; after the queue obtains a claim, a synchronous AppKit stall is
            // `submissionUnknown`; only a returned API awaiting callback is `callbackPending`.
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0.05, timeoutSeconds)
            ) {
                let state = gate.resolveTimeout(operationID: operationID)
                if state != nil {
                    GSYLog.warning(.trash, "等待 NSWorkspace.recycle 边界超时 operationID=\(operationID.uuidString) state=\(String(describing: state)) batchSize=\(urls.count)")
                }
            }

            // Apple 要求带 completion 的 recycle 从“活动 dispatch queue”调用，并在同一
            // queue 回调。使用专用串行队列既遵守该合同，也不会把文件操作提交压到主线程。
            submissionQueue.async {
                guard gate.beginClaim() else { return }
                // v2026.07.17 Duplicate post-hash fence: this runs on the exact serial queue
                // directly beside every batch and fallback single-item AppKit submission. It
                // rechecks the retained survivor plus this attempt's target identities; the
                // complete content hash is intentionally not repeated for every batch.
                if let rejection = duplicateClaimFence?.rejection(blocking: normalizedPaths) {
                    GSYLog.notice(
                        .trash,
                        "Duplicate claim fence blocked before ledger claim operationID=\(operationID.uuidString) targets=\(normalizedPaths.count)"
                    )
                    gate.resolvePreSubmitRejection(rejection)
                    return
                }
                let claim = ledger.claim(
                    paths: normalizedPaths,
                    operationID: operationID,
                    attemptID: attemptID
                )
                switch claim {
                case .rejected(let rejection, let invalidatedPaths):
                    publishLedgerInvalidation(paths: invalidatedPaths, operationID: operationID)
                    gate.resolvePreSubmitRejection(rejection)
                    return
                case .claimed:
                    // `flock`/identity work itself can take time. Check the same source proof and
                    // explicit cancellation token once more after ledger claim, then clear the
                    // exact attempt if it changed. No `NSWorkspace.recycle` call has happened.
                    if let rejection = duplicateClaimFence?.rejection(blocking: normalizedPaths) {
                        let released = ledger.finish(
                            paths: normalizedPaths,
                            operationID: operationID,
                            attemptID: attemptID
                        )
                        if !released {
                            GSYLog.error(
                                .trash,
                                "Duplicate claim fence could not release exact attempt operationID=\(operationID.uuidString) attemptID=\(attemptID.uuidString)"
                            )
                        }
                        gate.resolvePreSubmitRejection(rejection)
                        return
                    }
                    guard gate.finishClaim() else {
                        // The watchdog won while flock/identity verification was in progress.
                        // No AppKit call is allowed after that not-submitted result.
                        _ = ledger.finish(
                            paths: normalizedPaths,
                            operationID: operationID,
                            attemptID: attemptID
                        )
                        return
                    }
                }

                // v2026.07.17 exact progress boundary: full hashing, queue wait, both
                // claim-fence checks and the durable ledger claim are still cancellable
                // pre-submit work. Publish `.submittingToTrash` only beside the first actual
                // NSWorkspace invocation. The operation-scoped gate keeps batch/fallback calls
                // from producing duplicate boundary events.
                submissionObserver?()
                workspaceRecycle(urls) { pairs, errorDescription in
                    if let errorDescription {
                        GSYLog.warning(.trash, "NSWorkspace.recycle 单批失败 operationID=\(operationID.uuidString) batchSize=\(urls.count) moved=\(pairs.count) err=\(errorDescription)")
                    }
                    guard ledger.markCallbackObserved(
                        paths: normalizedPaths,
                        operationID: operationID,
                        attemptID: attemptID
                    ) else {
                        // **v2026.07.16 exact-attempt gate**: duplicate/late events from an old
                        // generation must not resume a continuation, clear the current attempt,
                        // write Undo, or invalidate a replacement path.
                        GSYLog.warning(.trash, "Trash pending ledger callback transition was stale or already terminal operationID=\(operationID.uuidString) attemptID=\(attemptID.uuidString)")
                        return
                    }
                    let callbackValue = RecycleAttempt(
                        moved: pairs,
                        errorDescription: errorDescription
                    )
                    let resolution = gate.claimCallback()
                    switch resolution {
                    case .resumed:
                        if !ledger.markRetryReady(
                            paths: normalizedPaths,
                            operationID: operationID,
                            attemptID: attemptID
                        ) {
                            GSYLog.error(.trash, "Trash pending ledger retry-ready transition failed operationID=\(operationID.uuidString) attemptID=\(attemptID.uuidString)")
                        }
                        // Persist the retry ownership state before resuming. Otherwise the
                        // awaiting batch loop can race ahead and have its legitimate retry
                        // rejected while the callback thread is still writing `retryReady`.
                        gate.resumeClaimedCallback(callbackValue)

                    case .lateAfterTimeout:
                        GSYLog.info(.trash, "NSWorkspace.recycle 延迟回调 operationID=\(operationID.uuidString) moved=\(pairs.count)；执行一次迟到结果对账")
                        guard ledger.finish(
                            paths: normalizedPaths,
                            operationID: operationID,
                            attemptID: attemptID
                        ) else {
                            // A concurrent exact-attempt terminal already won. Never replay its
                            // side effects from this callback.
                            GSYLog.error(.trash, "Trash pending ledger late terminal clear failed operationID=\(operationID.uuidString) attemptID=\(attemptID.uuidString)")
                            return
                        }
                        lateHandler(pairs, operationID)

                    case .ignoredDuplicate:
                        // This branch is unreachable after an accepted first callback, but clear
                        // the exact generation fail-closed if the gate and ledger ever diverge.
                        _ = ledger.finish(
                            paths: normalizedPaths,
                            operationID: operationID,
                            attemptID: attemptID
                        )
                    }
                }
                if ledger.markAPIReturned(
                    paths: normalizedPaths,
                    operationID: operationID,
                    attemptID: attemptID
                ) {
                    gate.markAPIReturned()
                } else {
                    // Leave the gate in the more conservative submission-unknown phase. A stale
                    // API-return event may belong to an older attempt and cannot advance the new
                    // generation to callbackPending.
                    GSYLog.warning(.trash, "Trash pending ledger API-return transition was stale or already terminal operationID=\(operationID.uuidString) attemptID=\(attemptID.uuidString)")
                }
            }
        }
    }

    /// timeout 后系统仍可能给出真实成功 pair。v2026.07.16 起只对第一份迟到回调做
    /// exactly-once 对账：补写 Undo 并广播原路径变化；没有 pair 时仅保留日志。
    @MainActor
    private static func reconcileLateRecycle(
        pairs: [(String, String)],
        operationID: UUID
    ) {
        guard !pairs.isEmpty else { return }
        let unique = stableUniqueMovedPairs(pairs)
        let undoPairs = unique.map {
            UndoHistoryStore.Record.FilePair(original: $0.0, trashed: $0.1)
        }
        UndoHistoryStore.shared.addRecord(
            source: "NSWorkspace",
            filePairs: undoPairs
        )
        NotificationCenter.default.post(
            name: .gsyTrashDidMove,
            object: nil,
            userInfo: [
                "paths": unique.map(\.0),
                "source": "NSWorkspace",
                "operationID": operationID.uuidString
            ]
        )
    }

    private static func stableUniqueMovedPairs(_ pairs: [(String, String)]) -> [(String, String)] {
        var seen = Set<String>()
        return pairs.filter { seen.insert($0.0).inserted }
    }

    // MARK: - lastOutcome 快照（OperationResultSheet 消费）

    private let outcomeLock = NSLock()
    private var _lastOutcome: TrashOutcome?

    private func recordOutcome(_ outcome: TrashOutcome) {
        outcomeLock.lock()
        _lastOutcome = outcome
        outcomeLock.unlock()
    }

    /// 暴露最后一次 moveToTrash 的结构化结果。UI 在 await 后立刻读。
    public func snapshotLastOutcome() -> TrashOutcome? {
        outcomeLock.lock()
        defer { outcomeLock.unlock() }
        return _lastOutcome
    }
}

/// One operation may use multiple recycle batches and single-item diagnostic retries. The UI
/// needs one irreversible-boundary transition, not one event per AppKit call. Callback execution
/// occurs outside the lock so observers may enqueue onto MainActor without lock inversion.
private final class RecycleSubmissionProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didNotify = false
    private let callback: @Sendable () -> Void

    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func notifyOnce() {
        lock.lock()
        guard !didNotify else {
            lock.unlock()
            return
        }
        didNotify = true
        lock.unlock()
        callback()
    }
}

/// `recycleOnce` 用的单次 continuation 守门员，避免 NSWorkspace 偶发的多次回调导致双 resume crash。
private final class RecycleOnceGate: @unchecked Sendable {
    enum CallbackResolution: Equatable {
        case resumed
        case lateAfterTimeout
        case ignoredDuplicate
    }

    private enum Phase {
        case waiting
        case claiming
        case apiClaimed
        case apiReturned
        case callbackCompleted
        case timedOutNotSubmitted
        case timedOutSubmissionUnknown
        case timedOutCallbackPending
        case lateReconciled
    }

    private let lock = NSLock()
    private var phase: Phase = .waiting
    private let cc: CheckedContinuation<TrashPipeline.RecycleAttempt, Never>

    init(cc: CheckedContinuation<TrashPipeline.RecycleAttempt, Never>) {
        self.cc = cc
    }

    func beginClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .waiting = phase else { return false }
        phase = .claiming
        return true
    }

    func finishClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .claiming = phase else { return false }
        phase = .apiClaimed
        return true
    }

    func resolvePreSubmitRejection(_ rejection: TrashPendingOperationRejection) {
        lock.lock()
        guard case .claiming = phase else { lock.unlock(); return }
        phase = .callbackCompleted
        lock.unlock()
        cc.resume(returning: TrashPipeline.RecycleAttempt(
            moved: [],
            errorDescription: nil,
            state: .preSubmitRejected(rejection)
        ))
    }

    func markAPIReturned() {
        lock.lock()
        switch phase {
        case .apiClaimed:
            phase = .apiReturned
        case .timedOutSubmissionUnknown:
            phase = .timedOutCallbackPending
        case .waiting, .claiming, .apiReturned, .callbackCompleted,
             .timedOutNotSubmitted, .timedOutCallbackPending, .lateReconciled:
            break
        }
        lock.unlock()
    }

    @discardableResult
    func resolveTimeout(operationID: UUID) -> TrashPipeline.RecycleAttempt.State? {
        let state: TrashPipeline.RecycleAttempt.State
        lock.lock()
        switch phase {
        case .waiting, .claiming:
            phase = .timedOutNotSubmitted
            state = .notSubmittedBudgetExpired
        case .apiClaimed:
            phase = .timedOutSubmissionUnknown
            state = .submissionUnknown(operationID: operationID)
        case .apiReturned:
            phase = .timedOutCallbackPending
            state = .callbackPending(operationID: operationID)
        case .callbackCompleted, .timedOutNotSubmitted, .timedOutSubmissionUnknown,
             .timedOutCallbackPending, .lateReconciled:
            lock.unlock()
            return nil
        }
        lock.unlock()
        cc.resume(returning: TrashPipeline.RecycleAttempt(
            moved: [],
            errorDescription: nil,
            state: state
        ))
        return state
    }

    /// Claims the first callback generation without resuming the continuation yet. The caller
    /// must persist its exact-attempt terminal/retry state before `resumeClaimedCallback` so the
    /// resumed batch loop cannot outrun the ledger transaction.
    func claimCallback() -> CallbackResolution {
        lock.lock()
        switch phase {
        case .apiClaimed, .apiReturned:
            phase = .callbackCompleted
            lock.unlock()
            return .resumed
        case .timedOutSubmissionUnknown, .timedOutCallbackPending:
            phase = .lateReconciled
            lock.unlock()
            return .lateAfterTimeout
        case .waiting, .claiming, .callbackCompleted, .timedOutNotSubmitted, .lateReconciled:
            lock.unlock()
            return .ignoredDuplicate
        }
    }

    func resumeClaimedCallback(_ value: TrashPipeline.RecycleAttempt) {
        cc.resume(returning: value)
    }
}
