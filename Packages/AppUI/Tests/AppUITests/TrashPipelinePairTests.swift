import XCTest
@testable import AppUI

/// Step 7-5：TrashPipeline 返回 trashedPairs 的语义验证。
///
/// 设计：四个 return path 中三个是确定性的（dry-run / 全 forbid / 空数组），
/// 必须返回空 `[]`。第四个（NSWorkspace.recycle 真把文件移入用户废纸篓）不能靠
/// 快速启动/退出 App 冒充 UI 验收；它只允许在明确授权的 C4 中对临时 fixture 验证。
///
/// 这条 test 把"非 recycle 路径必返回空 pairs"作为契约钉住，避免后续重构误改语义。
final class TrashPipelinePairTests: XCTestCase {

    func test_defaultPipelinesOwnUniqueTemporaryRecoveryDomains() throws {
        let first = TrashPipeline()
        let second = TrashPipeline()
        let firstLocations = try XCTUnwrap(first.recoveryStorageLocationsForTesting)
        let secondLocations = try XCTUnwrap(second.recoveryStorageLocationsForTesting)

        let applicationSupport = try XCTUnwrap(FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first).resolvingSymlinksInPath().standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL

        for locations in [firstLocations, secondLocations] {
            let root = locations.root.resolvingSymlinksInPath().standardizedFileURL
            XCTAssertTrue(
                root.path == temporaryDirectory.path
                    || root.path.hasPrefix(temporaryDirectory.path + "/"),
                "Default test recovery storage must stay under the process temporary directory"
            )
            XCTAssertFalse(
                root.path == applicationSupport.path
                    || root.path.hasPrefix(applicationSupport.path + "/"),
                "A package test must never resolve recovery storage inside Application Support"
            )
            XCTAssertFalse(
                root.path.contains("/Application Support/AmuxAIClean"),
                "v2026.07.20 regression: test recovery must never touch the production brand root"
            )
            for file in [
                locations.pendingOperationLedger,
                locations.completionJournal,
                locations.undoHistory
            ] {
                XCTAssertTrue(
                    file.standardizedFileURL.path.hasPrefix(locations.root.path + "/"),
                    "Every durable Trash owner must belong to the same isolated root"
                )
            }
        }

        XCTAssertNotEqual(firstLocations.root, secondLocations.root)
        XCTAssertNotEqual(
            firstLocations.pendingOperationLedger,
            secondLocations.pendingOperationLedger
        )
        XCTAssertNotEqual(firstLocations.completionJournal, secondLocations.completionJournal)
        XCTAssertNotEqual(firstLocations.undoHistory, secondLocations.undoHistory)
    }

    func test_productionSurfacesUseTheNamedProductionFactory() throws {
        // v2026.07.20: the internal bare initializer deliberately means isolated test storage.
        // Lock the two production assembly surfaces to the named factory so a future refactor
        // cannot silently ship a temporary recovery owner or make tests use the shared owner.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppUI", isDirectory: true)
        for filename in ["MainView.swift", "UninstallScreen.swift"] {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("TrashPipeline.production("), filename)
            XCTAssertFalse(source.contains("?? TrashPipeline(vendors:"), filename)
        }

        let pipelineSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("TrashPipeline.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            pipelineSource.contains("public convenience init("),
            "External production callers must not gain access to the isolated test initializer"
        )

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ))
        for case let sourceURL as URL in enumerator
            where sourceURL.pathExtension == "swift"
                && sourceURL.lastPathComponent != "TrashPipeline.swift" {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertNil(
                source.range(of: #"TrashPipeline\s*\("#, options: .regularExpression),
                "\(sourceURL.lastPathComponent) must select the named production factory"
            )
        }
    }

    func test_undoPersistenceDependenciesHaveNoSharedDefault() throws {
        // v2026.07.20: a compatibility stub may produce moved pairs without a journal receipt.
        // Requiring the caller to choose the Undo owner makes production/test storage selection
        // a compile-time decision instead of an implicit write to user Application Support.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppUI", isDirectory: true)
        let dependencyOwnerFiles = [
            "TrashActionCoordinator.swift",
            "DeletionInteractionCoordinator.swift",
            "WorkflowDetailView.swift",
            "MainView.swift",
            "BrewScreen.swift",
            "DuplicateScreen.swift",
            "UninstallScreen.swift",
            "UndoHistoryScreen.swift",
        ]
        for filename in dependencyOwnerFiles {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("undoHistoryStore: UndoHistoryStore = .shared"),
                "\(filename) must require an explicit production or fixture Undo owner"
            )
        }
        let pipelineOwnerViewFiles = [
            "WorkflowDetailView.swift",
            "MainView.swift",
            "BrewScreen.swift",
            "DuplicateScreen.swift",
            "UninstallScreen.swift",
        ]
        for filename in pipelineOwnerViewFiles {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("undoHistoryStore: UndoHistoryStore"),
                "\(filename) pipeline injection must carry an explicit Undo owner"
            )
            XCTAssertFalse(
                source.contains("undoHistoryStore: .shared"),
                "\(filename) must not silently redirect an injected pipeline into user history"
            )
        }

        let main = try String(
            contentsOf: sourceRoot.appendingPathComponent("MainView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            main.contains("pipeline: uninstallPipeline"),
            "MainView must not let the uninstall surface construct a production pipeline"
        )
        XCTAssertTrue(
            main.contains("UndoHistoryScreen(store: undoHistoryStore)"),
            "MainView must keep recent cleanup inside its explicit Undo persistence domain"
        )

        let undoHistoryScreen = try String(
            contentsOf: sourceRoot.appendingPathComponent("UndoHistoryScreen.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(undoHistoryScreen.contains("init(store: UndoHistoryStore)"))
        XCTAssertFalse(
            undoHistoryScreen.contains("UndoHistoryStore.shared"),
            "UndoHistoryScreen must not bypass the composition root's explicit store"
        )
    }

    func test_productionLedgerAndJournalPathsAreNotPublicBareInitializers() throws {
        // v2026.07.20: omitting a test URL must be a compile-time impossible way to reach the
        // user's Application Support recovery files. The pending ledger's active registry is
        // part of the same isolated domain and therefore has no shared default either.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppUI", isDirectory: true)
        let ledger = try String(
            contentsOf: sourceRoot.appendingPathComponent("TrashPendingOperationLedger.swift"),
            encoding: .utf8
        )
        let journal = try String(
            contentsOf: sourceRoot.appendingPathComponent("TrashCompletionJournal.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(ledger.contains("private convenience init()"))
        XCTAssertTrue(journal.contains("private convenience init()"))
        XCTAssertFalse(
            ledger.contains("activeOperationRegistry: TrashActiveOperationRegistry = .shared")
        )
    }

    func test_dryRun返回空trashedPairs() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashPair-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let f = dir + "/x.txt"
        try "x".write(toFile: f, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let (_, _, _, pairs) = await pipe.moveToTrash(paths: [f], dryRun: true)
        XCTAssertTrue(pairs.isEmpty,
                      "dryRun 不真删，绝不能返回任何 (orig,trashed) pair；实际=\(pairs)")
    }

    func test_全forbid短路返回空trashedPairs() async throws {
        let pipe = TrashPipeline()
        // /System / /usr / /etc 都是 hardForbid，partitionByForbid 会切走所有路径，
        // 直接早退不调 NSWorkspace.recycle，pairs 必空。
        let (moved, skipped, _, pairs) = await pipe.moveToTrash(
            paths: ["/System", "/usr", "/etc"],
            dryRun: false
        )
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, 3)
        XCTAssertTrue(pairs.isEmpty,
                      "全部被安全策略拦截，没有任何文件进入废纸篓，pairs 必为空；实际=\(pairs)")
    }

    func test_空数组返回空trashedPairs() async throws {
        let pipe = TrashPipeline()
        let (moved, skipped, err, pairs) = await pipe.moveToTrash(paths: [], dryRun: false)
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, 0)
        XCTAssertNil(err)
        XCTAssertTrue(pairs.isEmpty)
    }

    func test_typedSubmission_安全拒绝明确停在recycle之前() async {
        let pipe = TrashPipeline()
        let disposition = await pipe.submitToTrashReturningDisposition(
            paths: ["/System"],
            accessDeniedPaths: [],
            vendorOverrideRequest: nil
        )

        guard case .preSubmitRejected(.safety(let preflight)) = disposition else {
            return XCTFail("A hard safety boundary must not be represented as a recycle result")
        }
        XCTAssertEqual(preflight.rejections.map(\.path), ["/System"])
        XCTAssertTrue(preflight.vendorOverrideEligiblePaths.isEmpty)
    }

    func test_typedSubmission_空请求明确停在recycle之前() async {
        let pipe = TrashPipeline()
        let disposition = await pipe.submitToTrashReturningDisposition(
            paths: [],
            accessDeniedPaths: [],
            vendorOverrideRequest: nil
        )

        guard case .preSubmitRejected(.emptyRequest) = disposition else {
            return XCTFail("An empty request cannot produce a recycle completion")
        }
    }

    // MARK: - v2026.06.16 修复 #2：lastOutcome 快照 + 分批/失败隔离

    /// 快照契约 #1：moveToTrash 返回后立刻能拿到 TrashOutcome；
    /// 全 forbid 场景 → safetyRejected 计满、movedPairs/failedPaths 空。
    /// 验证旧接口仍保留可审计的拒绝明细；Professional UI 必须消费上面的 typed
    /// pre-submit disposition，不能把该 outcome 包装成 OperationResultSheet。
    func test_lastOutcome_全forbid_safetyRejected聚合() async throws {
        let pipe = TrashPipeline()
        let blocked = ["/System", "/usr", "/etc"]
        _ = await pipe.moveToTrash(paths: blocked, dryRun: false)

        let outcome = pipe.snapshotLastOutcome()
        XCTAssertNotNil(outcome, "moveToTrash 后必须能 snapshotLastOutcome；nil 会让 UI 回退到拼接字符串")
        XCTAssertTrue(outcome!.movedPairs.isEmpty)
        XCTAssertTrue(outcome!.failedPaths.isEmpty)
        XCTAssertEqual(outcome!.safetyRejected.count, blocked.count,
                       "全部被 SafetyEngine 拦的路径必须按条聚合，给 OperationResultSheet 展开列表用")
        XCTAssertTrue(outcome!.missingPaths.isEmpty)
    }

    /// 快照契约 #2：dryRun + missing 路径 → missingPaths 收集，无 movedPairs/failedPaths/safetyRejected。
    /// 验证 dryRun 也能给 UI 一个可消费的结构化结果。
    func test_lastOutcome_dryRun_missingPaths聚合() async throws {
        let pipe = TrashPipeline()
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        let missing = ["\(tempRoot)/gsyclean-not-exist-1-\(UUID().uuidString)",
                       "\(tempRoot)/gsyclean-not-exist-2-\(UUID().uuidString)"]
        _ = await pipe.moveToTrash(paths: missing, dryRun: true)

        let outcome = pipe.snapshotLastOutcome()
        XCTAssertNotNil(outcome)
        XCTAssertTrue(outcome!.movedPairs.isEmpty)
        XCTAssertTrue(outcome!.failedPaths.isEmpty)
        XCTAssertTrue(outcome!.safetyRejected.isEmpty)
        XCTAssertEqual(Set(outcome!.missingPaths), Set(missing),
                       "dryRun 必须把不存在的路径明细给 UI，避免只显示一个总数")
    }

    /// 快照契约 #3：空数组 → 4 个明细全空，但 snapshot 仍返回非 nil。
    /// 兜住 UI 在 await 后无脑调用 snapshot 的场景。
    func test_lastOutcome_空数组也返回非nil() async throws {
        let pipe = TrashPipeline()
        _ = await pipe.moveToTrash(paths: [], dryRun: false)
        let outcome = pipe.snapshotLastOutcome()
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome!.totalSubmitted, 0)
    }

    /// 分批 recycle 契约：批大小默认 32 是私有实现细节，这里只验证"大量路径下不抛异常、
    /// SafetyEngine 拒绝聚合正确"——确保分批改动没有偷偷漏拒绝任何 forbid 路径。
    /// 用 64 条 /System/... 路径（一定全被 hardForbid 拦），触发 partitionByForbid 大批次处理。
    func test_大批量全forbid不丢拒绝项() async throws {
        let pipe = TrashPipeline()
        let paths = (0..<64).map { "/System/Library/GsyCleanTestFakePath\($0)" }
        let (moved, skipped, _, pairs) = await pipe.moveToTrash(paths: paths, dryRun: false)
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, paths.count, "64 条 forbid 路径必须全部进入 skipped，分批不能漏拒绝")
        XCTAssertTrue(pairs.isEmpty)

        let outcome = pipe.snapshotLastOutcome()
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome!.safetyRejected.count, paths.count,
                       "大批量场景下 safetyRejected 必须按条聚合，不允许丢失任何被拦项")
    }

    // MARK: - v2026.06.22 (P0-3) 原子返回 outcome（取代 side-channel snapshot）

    /// **P0-3**：`moveToTrashReturningOutcome` 必须把 outcome 直接作为返回值给出，
    /// 不依赖 `snapshotLastOutcome()` 这种单槽位 side-channel。
    /// 这是修复"两次并发 moveToTrash 互相覆盖快照→ 写错 UndoHistory / 展示错 Sheet"的硬要求。
    func test_P0_3_moveToTrashReturningOutcome_直接返回outcome() async throws {
        let pipe = TrashPipeline()
        let blocked = ["/System", "/usr", "/etc"]
        let (legacy, outcome) = await pipe.moveToTrashReturningOutcome(paths: blocked, dryRun: false)

        // legacy 4 元组与旧接口保持一致
        XCTAssertEqual(legacy.0, 0)
        XCTAssertEqual(legacy.1, blocked.count)
        // outcome 直接由返回值给出（非 nil），不依赖后续 snapshot
        let unwrapped = try XCTUnwrap(outcome,
            "moveToTrashReturningOutcome 必须把 outcome 作为返回值给出，不依赖 side-channel 槽位")
        XCTAssertEqual(unwrapped.safetyRejected.count, blocked.count)
        XCTAssertTrue(unwrapped.movedPairs.isEmpty)
    }

    /// **P0-3**：并发场景验证——两次并发调用 moveToTrashReturningOutcome 的 outcome
    /// 必须各自独立，不会因为共享 lastOutcome 槽位互相覆盖。
    func test_P0_3_并发调用_outcome各自独立不被覆盖() async throws {
        let pipe = TrashPipeline()
        async let r1 = pipe.moveToTrashReturningOutcome(paths: ["/System"], dryRun: false)
        async let r2 = pipe.moveToTrashReturningOutcome(paths: ["/usr", "/etc"], dryRun: false)
        let (out1, out2) = await (r1, r2)
        // 关键不变量：每次调用拿到的 outcome 应对应自己请求的 paths 数量
        let safetyCount1 = out1.outcome?.safetyRejected.count ?? -1
        let safetyCount2 = out2.outcome?.safetyRejected.count ?? -1
        XCTAssertEqual(safetyCount1, 1, "调用 1 的 outcome 必须对应自己的 1 条请求")
        XCTAssertEqual(safetyCount2, 2, "调用 2 的 outcome 必须对应自己的 2 条请求")
    }
}
