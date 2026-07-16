import SafetyKit
import XCTest
@testable import AppUI

final class DeletionUXPolicyTests: XCTestCase {
    private actor ScriptedRecycleOperation {
        private var attempts: [TrashPipeline.RecycleAttempt]
        private var calls: [[String]] = []

        init(attempts: [TrashPipeline.RecycleAttempt]) {
            self.attempts = attempts
        }

        func run(urls: [URL]) -> TrashPipeline.RecycleAttempt {
            calls.append(urls.map(\.path))
            guard !attempts.isEmpty else {
                return TrashPipeline.RecycleAttempt(
                    moved: [],
                    errorDescription: "Unexpected recycle invocation"
                )
            }
            return attempts.removeFirst()
        }

        func recordedCalls() -> [[String]] {
            calls
        }
    }

    func test_previewAvailabilityMatchesBuildConfiguration() {
#if DEBUG
        XCTAssertTrue(DeletionPreviewPolicy.isEnabledInCurrentBuild)
#else
        XCTAssertFalse(DeletionPreviewPolicy.isEnabledInCurrentBuild)
#endif
    }

    func test_professionalPreflightRoutesSimpleStrictAndBlockedWithoutPreviewOrFakeResult() throws {
        XCTAssertEqual(
            ProfessionalDeletionPreflightRouter.route(
                DeletionPreflight(allowedPaths: ["/tmp/cache"], rejections: [])
            ),
            .simpleConfirmation
        )

        let vendorPath = "/Users/test/Library/Android/sdk/system-images"
        let strictPreflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: vendorPath, reason: SafetyRejection.vendorPathRule.rawValue)
            ],
            vendorOverrideEligiblePaths: [vendorPath]
        )
        guard case .strictConfirmation(let request) =
                ProfessionalDeletionPreflightRouter.route(strictPreflight) else {
            return XCTFail("Vendor-only rejection must route directly to strict confirmation")
        }
        XCTAssertEqual(request.paths, [vendorPath])

        let hardPath = "/Users/test/Library"
        let hardPreflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: hardPath, reason: SafetyRejection.rootOrAboveHome.rawValue)
            ]
        )
        XCTAssertEqual(
            ProfessionalDeletionPreflightRouter.route(hardPreflight),
            .blockedExplanation(hardPreflight.rejections)
        )
    }

    func test_finalDeniedPathsCanOnlyGrowAfterConfirmation() {
        XCTAssertEqual(
            DeletionDeniedPathPolicy.final(
                frozen: ["/frozen"],
                current: ["/current"]
            ),
            ["/frozen", "/current"]
        )
    }

    func test_professionalModeCanInitiateOnlyVendorPathRuleForbid() {
        XCTAssertTrue(DeletionEntryPolicy.canInitiate(
            verdict: .forbid,
            rejection: .vendorPathRule,
            allowsVendorPathOverride: true
        ))
        XCTAssertTrue(DeletionEntryPolicy.requiresVendorPathOverride(
            verdict: .forbid,
            rejection: .vendorPathRule,
            allowsVendorPathOverride: true
        ))

        let hardBoundaries: [SafetyRejection] = [
            .rootOrAboveHome,
            .outsideUserDeletionScope,
            .hardForbidPrefix,
            .userDocumentsRoot,
            .systemVolume,
            .insideAppBundle,
            .sensitiveCredential,
            .accessDenied,
            .userWhitelisted,
            .bundleSystemCritical,
            .bundleDataProtected,
            .dotDotInPath,
            .relativePath,
        ]
        for rejection in hardBoundaries {
            XCTAssertFalse(DeletionEntryPolicy.canInitiate(
                verdict: .forbid,
                rejection: rejection,
                allowsVendorPathOverride: true
            ), "Professional mode must not open hard boundary: \(rejection.rawValue)")
        }
    }

    func test_normalModeKeepsVendorPathRuleLocked() {
        XCTAssertFalse(DeletionEntryPolicy.canInitiate(
            verdict: .forbid,
            rejection: .vendorPathRule,
            allowsVendorPathOverride: false
        ))
        XCTAssertFalse(DeletionEntryPolicy.requiresVendorPathOverride(
            verdict: .forbid,
            rejection: .vendorPathRule,
            allowsVendorPathOverride: false
        ))
    }

    func test_incompleteAccessEvidenceBlocksEvenOtherwiseSelectableItems() {
        for verdict in [SafetyVerdict.safe, .confirm, .forbid] {
            let rejection: SafetyRejection = verdict == .forbid ? .vendorPathRule : .ok
            XCTAssertFalse(DeletionEntryPolicy.canInitiate(
                verdict: verdict,
                rejection: rejection,
                hasCompleteAccessEvidence: false,
                allowsVendorPathOverride: true
            ))
        }
    }

    func test_deleteSheetRequestFreezesPreviewedRows() throws {
        let first = makeRow(title: "First", path: "/tmp/first", bundlePrefix: nil)
        let second = makeRow(title: "Second", path: "/tmp/second", bundlePrefix: nil)
        var currentSelection = [first]
        var currentDeniedPaths: Set<String> = ["/tmp/first/locked"]
        var currentCategoryID = "user.cache"
        var currentScanSessionID = UUID()
        let request = DeleteSheetRequest(
            items: currentSelection,
            accessDeniedPaths: currentDeniedPaths,
            preparedInteraction: try makePreparedInteraction(
                rows: currentSelection,
                origin: .largeFiles,
                categoryID: currentCategoryID,
                scanSessionID: currentScanSessionID,
                revision: 9
            )
        )

        currentSelection.append(second)
        currentDeniedPaths = ["/tmp/second/locked"]
        currentCategoryID = "developer.cache"
        currentScanSessionID = UUID()
        let plan = DeleteExecutionPlanner.makePlan(
            rows: request.items,
            action: .moveToTrash(
                resolution: .moveAllToTrash,
                runningApplications: [],
                confirmedConflicts: []
            )
        )

        XCTAssertEqual(plan.rows, [first])
        XCTAssertEqual(currentSelection, [first, second])
        XCTAssertEqual(request.accessDeniedPaths, ["/tmp/first/locked"])
        XCTAssertEqual(request.sourceCategoryID, "user.cache")
        XCTAssertNotEqual(request.scanSessionID, currentScanSessionID)
        XCTAssertEqual(request.preparedInteraction.plan.intent.snapshotIdentity.revision, 9)
        XCTAssertEqual(request.origin, .largeFiles)
        XCTAssertEqual(currentDeniedPaths, ["/tmp/second/locked"])
        XCTAssertEqual(currentCategoryID, "developer.cache")
        XCTAssertFalse(plan.dryRun)
    }

    func test_frozenRequestDenialStillBlocksParentAfterLiveContextChanges() throws {
        let home = "/Users/tester"
        let parentPath = "\(home)/Library/Caches/example"
        let deniedChildPath = "\(parentPath)/unscanned"
        let row = makeRow(title: "Example Cache", path: parentPath, bundlePrefix: nil)
        let request = DeleteSheetRequest(
            items: [row],
            accessDeniedPaths: [deniedChildPath],
            preparedInteraction: try makePreparedInteraction(
                rows: [row],
                categoryID: "user.cache"
            )
        )

        // 模拟 sheet 关闭后用户切换类目：当前 coordinator 的 denial 已换成另一批。
        let changedLiveDeniedPaths: Set<String> = ["\(home)/Library/Caches/other"]
        let frozenPartition = TrashPipeline.partitionByForbid(
            paths: request.items.map(\.url.path),
            safety: SafetyEngine(),
            accessDeniedPaths: request.accessDeniedPaths,
            home: home
        )
        let changedLivePartition = TrashPipeline.partitionByForbid(
            paths: request.items.map(\.url.path),
            safety: SafetyEngine(),
            accessDeniedPaths: changedLiveDeniedPaths,
            home: home
        )

        XCTAssertTrue(frozenPartition.allowed.isEmpty)
        XCTAssertEqual(frozenPartition.rejected.map(\.path), [parentPath])
        XCTAssertEqual(frozenPartition.rejected.map(\.reason), [.accessDenied])
        XCTAssertEqual(changedLivePartition.allowed, [parentPath],
                       "该对照证明执行层若回读切换后的 live denial，会错误放行原请求")
    }

    func test_deleteSubmissionHandoffWaitsForDismissalAndCannotBeOverwritten() throws {
        let firstRow = makeRow(title: "First", path: "/tmp/first", bundlePrefix: nil)
        let secondRow = makeRow(title: "Second", path: "/tmp/second", bundlePrefix: nil)
        let first = DeleteSubmission.professional(
            request: DeleteSheetRequest(
                items: [firstRow],
                accessDeniedPaths: [],
                preparedInteraction: try makePreparedInteraction(
                    rows: [firstRow],
                    categoryID: "first"
                )
            ),
            executionPlan: ToolTrashExecutionPlan(
                paths: [firstRow.url.path],
                runningAppSkipped: []
            )
        )
        let second = DeleteSubmission.professional(
            request: DeleteSheetRequest(
                items: [secondRow],
                accessDeniedPaths: [],
                preparedInteraction: try makePreparedInteraction(
                    rows: [secondRow],
                    categoryID: "second"
                )
            ),
            executionPlan: ToolTrashExecutionPlan(
                paths: [secondRow.url.path],
                runningAppSkipped: []
            )
        )
        var handoff = DeleteSubmissionHandoff()

        XCTAssertTrue(handoff.schedule(first))
        XCTAssertTrue(handoff.hasPending)
        XCTAssertFalse(handoff.schedule(second))
        XCTAssertEqual(handoff.pending, first)
        XCTAssertEqual(handoff.takeAfterSheetDismissal(), first)
        XCTAssertFalse(handoff.hasPending)
        XCTAssertNil(handoff.takeAfterSheetDismissal())
    }

    func test_skipDecisionUsesLatestRunningApplicationSnapshot() {
        let row = makeRow(
            title: "WeChat Cache",
            path: "/tmp/wechat-cache",
            bundlePrefix: "com.tencent.xinWeChat"
        )

        let beforeLaunch = DeleteExecutionPlanner.makePlan(
            rows: [row],
            action: .moveToTrash(
                resolution: .skipConflictingItems,
                runningApplications: [],
                confirmedConflicts: []
            )
        )
        let afterLaunch = DeleteExecutionPlanner.makePlan(
            rows: [row],
            action: .moveToTrash(
                resolution: .skipConflictingItems,
                runningApplications: [
                    .init(bundleID: "com.tencent.xinWeChat", localizedName: "WeChat")
                ],
                confirmedConflicts: []
            )
        )

        XCTAssertEqual(beforeLaunch.rows, [row])
        XCTAssertTrue(beforeLaunch.runningAppSkipped.isEmpty)
        XCTAssertTrue(afterLaunch.rows.isEmpty)
        XCTAssertEqual(afterLaunch.runningAppSkipped.map(\.runningAppName), ["WeChat"])
        XCTAssertEqual(
            afterLaunch.runningAppSkippedResultItems,
            [.init(path: row.url.path, itemTitle: row.title, appName: "WeChat")]
        )
    }

    func test_moveAllDecisionIsAlwaysARealTrashRequest() {
        let row = makeRow(
            title: "Chrome Cache",
            path: "/tmp/chrome-cache",
            bundlePrefix: "com.google.Chrome"
        )

        let plan = DeleteExecutionPlanner.makePlan(
            rows: [row],
            action: .moveToTrash(
                resolution: .moveAllToTrash,
                runningApplications: [
                    .init(bundleID: "com.google.Chrome", localizedName: "Google Chrome")
                ],
                confirmedConflicts: []
            )
        )

        XCTAssertFalse(plan.dryRun)
        XCTAssertEqual(plan.rows, [row])
        XCTAssertTrue(plan.runningAppSkipped.isEmpty)
    }

    func test_previewRemainsADeveloperDryRunWithoutFilteringRows() {
        let row = makeRow(
            title: "Chrome Cache",
            path: "/tmp/chrome-cache",
            bundlePrefix: "com.google.Chrome"
        )

        let plan = DeleteExecutionPlanner.makePlan(
            rows: [row],
            action: .preview
        )

        XCTAssertTrue(plan.dryRun)
        XCTAssertEqual(plan.rows, [row])
        XCTAssertTrue(plan.runningAppSkipped.isEmpty)
    }

    func test_runningAppSkippedHasItsOwnPartialResultCategory() {
        XCTAssertEqual(
            OperationResultStatusPolicy.status(
                succeededCount: 1,
                failedCount: 0,
                runningAppSkippedCount: 1
            ),
            .partial
        )
    }

    func test_pendingRecycleHasDedicatedUnknownStatus() {
        XCTAssertEqual(
            OperationResultStatusPolicy.status(
                succeededCount: 2,
                failedCount: 1,
                runningAppSkippedCount: 0,
                pendingCount: 1
            ),
            .pending
        )
    }

    func test_smartCareProjectionFiltersPathsAndAccountingItemsTogether() async throws {
        let running = SmartCareItem(
            id: "wechat",
            bucketID: .appCache,
            path: "/tmp/wechat-cache",
            title: "WeChat Cache",
            bytes: 10,
            verdict: .safe,
            runningBundleIDPrefix: "com.tencent.xinWeChat"
        )
        let idle = SmartCareItem(
            id: "plain",
            bucketID: .systemJunk,
            path: "/tmp/plain-cache",
            title: "Plain Cache",
            bytes: 20,
            verdict: .safe
        )
        let request = SmartCareCleanRequest(items: [running, idle])

        let projection = try await DeleteExecutionPlanner.makeSmartCarePlanAsync(
            request: request,
            action: .moveToTrash(
                resolution: .skipConflictingItems,
                runningApplications: [
                    .init(bundleID: "com.tencent.xinWeChat", localizedName: "WeChat")
                ],
                confirmedConflicts: []
            )
        )

        XCTAssertEqual(projection.execution.paths, [idle.path])
        XCTAssertEqual(projection.submittedItems.map(\.id), [idle.id])
        XCTAssertEqual(projection.execution.runningAppSkipped.map(\.path), [running.path])
        XCTAssertEqual(projection.execution.runningAppSkippedResultItems.map(\.path), [running.path])
    }

    func test_runningConflictProjectionPrecomputesNamesAndCountOffTheViewPath() async throws {
        let rows = [
            makeRow(title: "WeChat Cache", path: "/tmp/wechat-a", bundlePrefix: "com.tencent.xinWeChat"),
            makeRow(title: "WeChat Logs", path: "/tmp/wechat-b", bundlePrefix: "com.tencent.xinWeChat"),
            makeRow(title: "Chrome Cache", path: "/tmp/chrome", bundlePrefix: "com.google.Chrome")
        ]

        let projection = try await DeleteExecutionPlanner.runningConflictProjectionAsync(
            rows: rows,
            runningApplications: [
                .init(bundleID: "com.tencent.xinWeChat", localizedName: "WeChat"),
                .init(bundleID: "com.google.Chrome", localizedName: "Google Chrome")
            ]
        )

        XCTAssertEqual(projection.uniquePathCount, 3)
        XCTAssertEqual(projection.appNames, ["WeChat", "Google Chrome"])
        XCTAssertEqual(projection.conflicts.map(\.path), rows.map(\.url.path))
    }

    func test_allRunningSkippedDoesNotCrossResultPresentationBoundary() {
        let intentID = UUID()
        let state = DeletionSubmissionState.awaitingConfirmation(
            intentID: intentID,
            planID: UUID()
        )

        XCTAssertFalse(state.hasReachedSubmissionBoundary)
        XCTAssertFalse(state.mayPresentOperationResult)
    }

    func test_recycleFailureReasonSurvivesOutcomeToResultPayload() {
        let path = "/tmp/docker.raw"
        let reason = "The file is in use."
        let outcome = TrashOutcome(
            movedPairs: [],
            failedPaths: [path],
            safetyRejected: [],
            missingPaths: [],
            failureReasons: [path: reason]
        )

        XCTAssertEqual(outcome.failureReasons[path], reason)
    }

    func test_recycleBatchPartialSuccessRetriesOnlyUnmovedAndKeepsSpecificReason() async {
        let first = "/tmp/first"
        let failed = "/tmp/locked"
        let third = "/tmp/third"
        let operation = ScriptedRecycleOperation(attempts: [
            TrashPipeline.RecycleAttempt(
                moved: [
                    (first, "/Users/test/.Trash/first"),
                    (third, "/Users/test/.Trash/third")
                ],
                errorDescription: "Some items could not be moved."
            ),
            TrashPipeline.RecycleAttempt(
                moved: [],
                errorDescription: "The item is in use."
            )
        ])

        let result = await TrashPipeline.executeRecycleBatches(
            urls: [first, failed, third].map(URL.init(fileURLWithPath:)),
            recycle: { urls in await operation.run(urls: urls) }
        )

        XCTAssertEqual(result.moved.map(\.0), [first, third])
        XCTAssertEqual(result.failureReasons, [failed: "The item is in use."])
        let calls = await operation.recordedCalls()
        XCTAssertEqual(calls, [[first, failed, third], [failed]])
    }

    func test_recycleBatchRetriesUnmovedEvenWithoutBatchErrorAndClearsRecoveredFailure() async {
        let first = "/tmp/first"
        let recovered = "/tmp/recovered"
        let operation = ScriptedRecycleOperation(attempts: [
            TrashPipeline.RecycleAttempt(
                moved: [(first, "/Users/test/.Trash/first")],
                errorDescription: nil
            ),
            TrashPipeline.RecycleAttempt(
                moved: [(recovered, "/Users/test/.Trash/recovered")],
                errorDescription: "A stale error accompanied a successful move."
            )
        ])

        let result = await TrashPipeline.executeRecycleBatches(
            urls: [first, recovered].map(URL.init(fileURLWithPath:)),
            recycle: { urls in await operation.run(urls: urls) }
        )

        XCTAssertEqual(result.moved.map(\.0), [first, recovered])
        XCTAssertTrue(result.failureReasons.isEmpty)
        let calls = await operation.recordedCalls()
        XCTAssertEqual(calls, [[first, recovered], [recovered]])
    }

    func test_recyclePendingBatchStopsWithoutRetryingOrSubmittingLaterBatches() async {
        let first = "/tmp/first"
        let second = "/tmp/second"
        let third = "/tmp/third"
        let operationID = UUID()
        let operation = ScriptedRecycleOperation(attempts: [
            TrashPipeline.RecycleAttempt(
                moved: [],
                errorDescription: nil,
                state: .callbackPending(operationID: operationID)
            )
        ])

        let result = await TrashPipeline.executeRecycleBatches(
            urls: [first, second, third].map(URL.init(fileURLWithPath:)),
            batchSize: 2,
            recycle: { urls in await operation.run(urls: urls) }
        )

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(result.failureReasons.isEmpty)
        XCTAssertEqual(result.attemptedPaths, [first, second])
        XCTAssertEqual(result.pendingPaths, [first, second])
        XCTAssertEqual(result.notSubmittedPaths, [third])
        let calls = await operation.recordedCalls()
        XCTAssertEqual(calls, [[first, second]])
    }

    func test_recyclePendingSingleRetryDoesNotDuplicateUnknownPath() async {
        let first = "/tmp/first"
        let second = "/tmp/second"
        let laterBatch = "/tmp/later"
        let operation = ScriptedRecycleOperation(attempts: [
            TrashPipeline.RecycleAttempt(
                moved: [],
                errorDescription: "Batch completed without moving the items."
            ),
            TrashPipeline.RecycleAttempt(
                moved: [],
                errorDescription: nil,
                state: .callbackPending(operationID: UUID())
            )
        ])

        let result = await TrashPipeline.executeRecycleBatches(
            urls: [first, second, laterBatch].map(URL.init(fileURLWithPath:)),
            batchSize: 2,
            recycle: { urls in await operation.run(urls: urls) }
        )

        XCTAssertEqual(result.attemptedPaths, [first, second])
        XCTAssertEqual(result.pendingPaths, [first])
        XCTAssertEqual(result.notSubmittedPaths, [laterBatch])
        XCTAssertEqual(
            result.failureReasons,
            [second: "Batch completed without moving the items."]
        )
        let calls = await operation.recordedCalls()
        XCTAssertEqual(calls, [[first, second], [first]])
    }

    func test_recycleBudgetExpiryBeforeBatchMarksEverythingNotSubmitted() async {
        let first = "/tmp/first"
        let second = "/tmp/second"
        let operation = ScriptedRecycleOperation(attempts: [
            TrashPipeline.RecycleAttempt(
                moved: [],
                errorDescription: nil,
                state: .notSubmittedBudgetExpired
            )
        ])

        let result = await TrashPipeline.executeRecycleBatches(
            urls: [first, second].map(URL.init(fileURLWithPath:)),
            batchSize: 1,
            recycle: { urls in await operation.run(urls: urls) }
        )

        XCTAssertTrue(result.attemptedPaths.isEmpty)
        XCTAssertTrue(result.pendingPaths.isEmpty)
        XCTAssertEqual(result.notSubmittedPaths, [first, second])
        XCTAssertTrue(result.failureReasons.isEmpty)
        let calls = await operation.recordedCalls()
        XCTAssertEqual(calls, [[first]])
    }

    func test_trashOutcomeDropsFailureReasonForPathThatIsNotFinallyFailed() {
        let outcome = TrashOutcome(
            movedPairs: [("/tmp/recovered", "/Users/test/.Trash/recovered")],
            failedPaths: ["/tmp/failed"],
            safetyRejected: [],
            missingPaths: [],
            failureReasons: [
                "/tmp/recovered": "stale",
                "/tmp/failed": "locked"
            ]
        )

        XCTAssertEqual(outcome.failureReasons, ["/tmp/failed": "locked"])
    }

    func test_previewPolicyIsLimitedToNormalDeleteSheetAndAbsentFromProfessionalUninstall() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deleteSheet = try String(contentsOf: root
            .appendingPathComponent("Packages/AppUI/Sources/AppUI/DeleteSheet.swift"), encoding: .utf8)
        let uninstall = try String(contentsOf: root
            .appendingPathComponent("Packages/AppUI/Sources/AppUI/UninstallScreen.swift"), encoding: .utf8)
        let mainView = try String(contentsOf: root
            .appendingPathComponent("Packages/AppUI/Sources/AppUI/MainView.swift"), encoding: .utf8)

        XCTAssertTrue(deleteSheet.contains("if DeletionPreviewPolicy.isEnabledInCurrentBuild"))
        XCTAssertFalse(uninstall.contains("DeletionPreviewPolicy"))
        XCTAssertFalse(uninstall.contains("uninstall.button.preview"))
        XCTAssertFalse(uninstall.contains("dryRun: true"))
        XCTAssertFalse(deleteSheet.contains(".disabled(!dryRun"))
        XCTAssertTrue(mainView.contains("let deniedSnapshot = suppliedDeniedPaths ?? accessDeniedPathsSnapshot()"))
        XCTAssertTrue(mainView.contains("accessDeniedPaths: deniedSnapshot"))
        XCTAssertGreaterThanOrEqual(
            mainView.components(separatedBy: "DeletionDeniedPathPolicy.final(").count - 1,
            2,
            "Smart Care 与统一 Professional 执行入口都必须走安全证据单调合并；vendor override 复用 Professional 入口，不应为凑计数复制执行逻辑"
        )
        XCTAssertTrue(mainView.contains("current: smartCareSession.deletionDeniedPaths"))
        XCTAssertTrue(mainView.contains("frozen: request.accessDeniedPaths"))
        XCTAssertTrue(mainView.contains("current: accessDeniedPathsSnapshot()"))
        XCTAssertTrue(mainView.contains("accessDeniedPaths: finalDeniedPaths"))
        XCTAssertTrue(mainView.contains("let categoryID = request.sourceCategoryID"))
        XCTAssertFalse(mainView.contains("accessDeniedPaths ?? accessDeniedPathsSnapshot()"))
    }

    func test_professionalOverrideEligibilitySeparatesModeRevalidationAndHardBoundary() {
        XCTAssertEqual(
            ProfessionalOverridePolicy.eligibility(
                verdict: .forbid,
                rejection: .vendorPathRule,
                accessEvidence: .complete,
                mode: .normal
            ),
            .requiresProfessionalMode(.vendorPathRule)
        )
        XCTAssertEqual(
            ProfessionalOverridePolicy.eligibility(
                verdict: .forbid,
                rejection: .vendorPathRule,
                accessEvidence: .complete,
                mode: .professional
            ),
            .eligible(.vendorPathRule)
        )
        XCTAssertEqual(
            ProfessionalOverridePolicy.eligibility(
                verdict: .safe,
                rejection: .ok,
                accessEvidence: .incomplete(.permissionDenied),
                mode: .professional
            ),
            .requiresTargetRevalidation(.scanIncomplete(.permissionDenied))
        )
        XCTAssertEqual(
            ProfessionalOverridePolicy.eligibility(
                verdict: .forbid,
                rejection: .rootOrAboveHome,
                accessEvidence: .complete,
                mode: .professional
            ),
            .nonBypassable(.rootOrAboveHome)
        )
    }

    func test_deletionIntentFreezesOrderedIdentityAndRejectsDuplicateStandardizedPath() throws {
        let identity = DeletionSnapshotIdentity(
            sessionID: UUID(),
            revision: 42,
            categoryID: "developer.cache"
        )
        let first = makeIntentCandidate(path: "/tmp/a", verdict: .safe, rejection: .ok)
        let second = makeIntentCandidate(path: "/tmp/b", verdict: .confirm, rejection: .ok)
        let createdAt = Date(timeIntervalSince1970: 123)
        let intent = try DeletionIntent(
            origin: .largeFiles,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [first, second],
            createdAt: createdAt
        )

        XCTAssertEqual(intent.candidates.map(\.id), [first.id, second.id])
        XCTAssertEqual(intent.candidates.map(\.standardizedPath), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(intent.snapshotIdentity, identity)
        XCTAssertEqual(intent.createdAt, createdAt)

        let duplicate = makeIntentCandidate(
            path: "/tmp/folder/../a",
            verdict: .safe,
            rejection: .ok
        )
        XCTAssertThrowsError(try DeletionIntent(
            origin: .tree,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [first, duplicate]
        )) { error in
            XCTAssertEqual(error as? DeletionIntentValidationError, .duplicatePath("/tmp/a"))
        }
    }

    func test_vendorAtomicPreflightProducesOneStrictItemAndKeepsSafeSiblingNormal() throws {
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 7)
        let vendor = makeIntentCandidate(
            path: "/Users/test/Library/Android/sdk/system-images",
            verdict: .forbid,
            rejection: .vendorPathRule
        )
        let safe = makeIntentCandidate(
            path: "/Users/test/Library/Caches/plain",
            verdict: .safe,
            rejection: .ok
        )
        let intent = try DeletionIntent(
            origin: .scanSelection,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [vendor, safe]
        )
        let preflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: vendor.rawPath, reason: SafetyRejection.vendorPathRule.rawValue),
                .init(path: safe.rawPath, reason: SafetyRejection.batchContainsForbidden.rawValue)
            ],
            vendorOverrideEligiblePaths: [vendor.rawPath, safe.rawPath]
        )

        let decision = try DeletionConfirmationPlanner.makeDecision(
            intent: intent,
            preflight: preflight,
            currentSnapshotIdentity: identity
        )
        guard case .requiresConfirmation(let plan) = decision else {
            return XCTFail("Vendor preflight must produce a confirmation plan")
        }
        XCTAssertEqual(plan.strictOverrideItems.map(\.id), [vendor.id])
        XCTAssertEqual(plan.normalItems.map(\.id), [safe.id])
        XCTAssertTrue(plan.nonBypassableItems.isEmpty)
    }

    func test_hardPreflightRejectionRemainsConfirmationDataNotSubmissionResult() throws {
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 3)
        let candidate = makeIntentCandidate(
            path: "/Users/test/Library",
            verdict: .forbid,
            rejection: .rootOrAboveHome
        )
        let intent = try DeletionIntent(
            origin: .tree,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [candidate]
        )
        let decision = try DeletionConfirmationPlanner.makeDecision(
            intent: intent,
            preflight: DeletionPreflight(
                allowedPaths: [],
                rejections: [
                    .init(path: candidate.rawPath, reason: SafetyRejection.rootOrAboveHome.rawValue)
                ]
            ),
            currentSnapshotIdentity: identity
        )

        guard case .requiresConfirmation(let plan) = decision else {
            return XCTFail("A hard rejection must remain confirmation/explanation data")
        }
        XCTAssertEqual(
            plan.nonBypassableItems.map(\.disposition),
            [.nonBypassable(.safety(.rootOrAboveHome))]
        )
        XCTAssertFalse(DeletionSubmissionState.awaitingConfirmation(
            intentID: intent.id,
            planID: plan.id
        ).mayPresentOperationResult)
    }

    func test_changedSnapshotCannotReuseOldPlanIdentity() throws {
        let original = DeletionSnapshotIdentity(sessionID: UUID(), revision: 1)
        let current = DeletionSnapshotIdentity(sessionID: UUID(), revision: 2)
        let candidate = makeIntentCandidate(path: "/tmp/cache", verdict: .safe, rejection: .ok)
        let intent = try DeletionIntent(
            origin: .stash,
            mode: .professional,
            snapshotIdentity: original,
            candidates: [candidate]
        )
        let plan = try DeletionConfirmationPlanner.makePlan(
            intent: intent,
            preflight: DeletionPreflight(allowedPaths: [candidate.rawPath], rejections: []),
            currentSnapshotIdentity: current
        )

        XCTAssertEqual(plan.changedSinceScanItems.map(\.id), [candidate.id])
        XCTAssertTrue(plan.submittableItems.isEmpty)
    }

    func test_strictAuthorizationBindsExactPathReasonAndRequiresTypedProof() throws {
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 9)
        let candidate = makeIntentCandidate(
            path: "/Users/test/Library/Android/sdk/system-images",
            verdict: .forbid,
            rejection: .vendorPathRule
        )
        let intent = try DeletionIntent(
            origin: .workflowFilesystem,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [candidate]
        )
        let plan = try DeletionConfirmationPlan(
            intent: intent,
            items: [
                .init(candidate: candidate, disposition: .strictOverride(.vendorPathRule))
            ]
        )

        XCTAssertThrowsError(try DeletionExecutionAuthorization.make(
            plan: plan,
            selectedCandidateIDs: [candidate.id],
            runningAppChoice: .noConflicts,
            proof: .standard(confirmedAt: Date())
        )) { error in
            XCTAssertEqual(error as? DeletionAuthorizationError, .strictConfirmationRequired)
        }

        let authorization = try DeletionExecutionAuthorization.make(
            plan: plan,
            selectedCandidateIDs: [candidate.id],
            runningAppChoice: .noConflicts,
            proof: .professionalStrict(confirmationToken: "DELETE", confirmedAt: Date())
        )
        XCTAssertEqual(authorization.paths, [candidate.standardizedPath])
        XCTAssertEqual(authorization.overrideBindings, [
            .init(path: candidate.standardizedPath, reason: .vendorPathRule)
        ])
        XCTAssertEqual(authorization.snapshotIdentity, identity)
    }

    func test_resultPresentationRequiresARealSubmissionReceipt() {
        let intentID = UUID()
        let authorizationID = UUID()
        let submissionID = UUID()
        let preparing = DeletionSubmissionState.preparing(intentID: intentID)
        let submitting = DeletionSubmissionState.submitting(
            intentID: intentID,
            authorizationID: authorizationID,
            submissionID: submissionID
        )
        let submitted = DeletionSubmissionState.submitted(DeletionSubmissionReceipt(
            id: submissionID,
            authorizationID: authorizationID,
            intentID: intentID,
            submittedPaths: ["/tmp/cache"]
        ))

        XCTAssertFalse(preparing.mayPresentOperationResult)
        XCTAssertFalse(submitting.mayPresentOperationResult)
        XCTAssertTrue(submitting.hasReachedSubmissionBoundary)
        XCTAssertTrue(submitted.mayPresentOperationResult)
        XCTAssertTrue(submitted.hasReachedSubmissionBoundary)
    }

    private func makeIntentCandidate(
        path: String,
        verdict: SafetyVerdict,
        rejection: SafetyRejection,
        accessEvidence: DeletionAccessEvidence = .complete,
        bundlePrefix: String? = nil
    ) -> DeletionIntentCandidate {
        DeletionIntentCandidate(
            path: path,
            title: URL(fileURLWithPath: path).lastPathComponent,
            isDirectory: true,
            bytes: 1,
            fileCount: 1,
            verdict: verdict,
            rejection: rejection,
            accessEvidence: accessEvidence,
            runningBundleIDPrefix: bundlePrefix
        )
    }

    private func makeRow(title: String, path: String, bundlePrefix: String?) -> RowItem {
        RowItem(
            id: path,
            url: URL(fileURLWithPath: path),
            title: title,
            isDirectory: true,
            bytes: 1,
            logicalBytes: 1,
            fileCount: 1,
            verdict: .safe,
            rejection: .ok,
            runningBundleIDPrefix: bundlePrefix
        )
    }

    private func makePreparedInteraction(
        rows: [RowItem],
        origin: DeleteRequestOrigin = .scanSelection,
        categoryID: String,
        scanSessionID: UUID = UUID(),
        revision: UInt64 = 0
    ) throws -> DeletionPreparedInteraction {
        let intent = try DeletionIntent(
            origin: origin,
            mode: .professional,
            snapshotIdentity: DeletionSnapshotIdentity(
                sessionID: scanSessionID,
                revision: revision,
                categoryID: categoryID
            ),
            candidates: rows.map {
                makeIntentCandidate(
                    path: $0.url.path,
                    verdict: .safe,
                    rejection: .ok,
                    bundlePrefix: $0.runningBundleIDPrefix
                )
            }
        )
        let plan = try DeletionConfirmationPlan(
            intent: intent,
            items: intent.candidates.map {
                DeletionConfirmationItem(candidate: $0, disposition: .normal)
            }
        )
        return DeletionPreparedInteraction(
            plan: plan,
            vendorOverrideRequest: nil,
            scanIncompleteOverrideRequest: nil,
            carriedRunningAppSkipped: []
        )
    }
}
