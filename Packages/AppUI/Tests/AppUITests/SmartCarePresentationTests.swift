import XCTest
@testable import AppUI

final class SmartCarePresentationTests: XCTestCase {
    func test_normalModeOnlyShowsImplementedBuckets() {
        XCTAssertEqual(
            SmartCarePresentation.normalBuckets,
            [.systemJunk, .appCache, .developerCache]
        )
    }

    func test_bucketPresentation_覆盖全部普通模式分桶() {
        for bucket in SmartCareBucketID.allCases {
            XCTAssertFalse(SmartCarePresentation.titleKey(for: bucket).isEmpty)
            XCTAssertFalse(SmartCarePresentation.subtitleKey(for: bucket).isEmpty)
            XCTAssertFalse(SmartCarePresentation.iconName(for: bucket).isEmpty)
        }
    }

    func test_primaryActionPresentation_覆盖全部状态按钮() {
        let actions: [SmartCarePrimaryAction] = [
            .startScan,
            .stopScan,
            .cleanSafeItems,
            .confirmClean,
            .cleaning,
            .scanAgain,
            .retry,
            .continueScan
        ]

        for action in actions {
            XCTAssertFalse(SmartCarePresentation.primaryActionTitleKey(for: action).isEmpty)
            XCTAssertFalse(SmartCarePresentation.primaryActionIconName(for: action).isEmpty)
        }
    }

    func test_scanAgainDispatchReturnsToSetupWithoutStartingScan() {
        XCTAssertEqual(
            SmartCarePrimaryActionDispatch.resolve(.scanAgain),
            .returnToSetup
        )
        XCTAssertEqual(
            SmartCarePrimaryActionDispatch.resolve(.startScan),
            .startScan
        )
    }

    func test_primaryActionPresentation_清理入口始终使用预览授权文案() {
        XCTAssertEqual(
            SmartCarePresentation.primaryActionTitleKey(for: .cleanSafeItems, requiresConfirmation: false),
            "smart_care.action.review_cleanup"
        )
        XCTAssertEqual(
            SmartCarePresentation.primaryActionTitleKey(for: .cleanSafeItems, requiresConfirmation: true),
            "smart_care.action.review_selected"
        )
        XCTAssertEqual(
            SmartCarePresentation.primaryActionIconName(for: .cleanSafeItems, requiresConfirmation: true),
            "exclamationmark.shield"
        )
    }

    func test_supportedBucketIcons_使用类别语义而非AI装饰图标() {
        XCTAssertEqual(SmartCarePresentation.iconName(for: .systemJunk), "trash")
        XCTAssertEqual(SmartCarePresentation.iconName(for: .appCache), "archivebox")
        XCTAssertEqual(SmartCarePresentation.iconName(for: .developerCache), "hammer")
    }

    func test_scanScopePresentation_每个范围都有独立语义() {
        let stages = SmartCareScanStage.allCases
        XCTAssertEqual(Set(stages.map(SmartCarePresentation.titleKey(for:))).count, stages.count)
        XCTAssertEqual(Set(stages.map(SmartCarePresentation.subtitleKey(for:))).count, stages.count)
        XCTAssertEqual(Set(stages.map(SmartCarePresentation.iconName(for:))).count, stages.count)
        XCTAssertNil(SmartCarePresentation.durationBadgeKey(for: .core))
        XCTAssertNil(SmartCarePresentation.durationBadgeKey(for: .appCaches))
        XCTAssertEqual(
            SmartCarePresentation.durationBadgeKey(for: .developerCaches),
            "smart_care.scope.may_take_longer"
        )
    }

    func test_developerCacheSelection_首次开启要求确认_其余变化直接应用() {
        XCTAssertEqual(
            SmartCareStageSelectionPolicy.decision(
                stage: .developerCaches,
                selected: true,
                developerWarningAcknowledged: false
            ),
            .confirmDeveloperCacheDuration
        )
        XCTAssertEqual(
            SmartCareStageSelectionPolicy.decision(
                stage: .developerCaches,
                selected: true,
                developerWarningAcknowledged: true
            ),
            .apply
        )
        XCTAssertEqual(
            SmartCareStageSelectionPolicy.decision(
                stage: .developerCaches,
                selected: false,
                developerWarningAcknowledged: false
            ),
            .apply
        )
        XCTAssertEqual(
            SmartCareStageSelectionPolicy.decision(
                stage: .core,
                selected: true,
                developerWarningAcknowledged: false
            ),
            .apply
        )
    }

    func test_scanScopeCards_使用同一语法下的三种不规则轮廓() {
        XCTAssertEqual(SmartCareScopeCardSilhouette(stage: .core), .forwardCut)
        XCTAssertEqual(SmartCareScopeCardSilhouette(stage: .appCaches), .crossCut)
        XCTAssertEqual(SmartCareScopeCardSilhouette(stage: .developerCaches), .trailingCut)
    }

    func test_scanActivityPresentation_覆盖真实扫描与整理状态() {
        let cases: [(SmartCareScanActivity, String, String)] = [
            (.scanning(.core), "smart_care.activity.scan.core", "doc.text.magnifyingglass"),
            (.scanning(.appCaches), "smart_care.activity.scan.app_cache", "shippingbox"),
            (.scanning(.developerCaches), "smart_care.activity.scan.developer_cache", "hammer"),
            (.organizing(.core), "smart_care.activity.organizing", "doc.text.magnifyingglass"),
            (.organizing(.appCaches), "smart_care.activity.organizing", "shippingbox"),
            (.organizing(.developerCaches), "smart_care.activity.organizing", "hammer"),
            (.finalizing, "smart_care.activity.finalizing", "checkmark.shield")
        ]

        for (activity, expectedKey, expectedIcon) in cases {
            XCTAssertEqual(SmartCarePresentation.activityTitleKey(for: activity), expectedKey)
            XCTAssertEqual(SmartCarePresentation.activityIconName(for: activity), expectedIcon)
        }
    }

    func test_stageProgressPresentation_由真实阶段状态驱动() {
        let progress = SmartCareProgress(
            activity: .organizing(.appCaches),
            completedStages: [.core],
            plannedStages: [.core, .appCaches, .developerCaches]
        )

        XCTAssertEqual(
            SmartCareStageProgressPresentation.status(for: .core, in: progress),
            .complete
        )
        XCTAssertEqual(
            SmartCareStageProgressPresentation.status(for: .appCaches, in: progress),
            .active
        )
        XCTAssertEqual(
            SmartCareStageProgressPresentation.status(for: .developerCaches, in: progress),
            .pending
        )
        XCTAssertEqual(
            SmartCareStageProgressPresentation.connectorStatus(after: .core, in: progress),
            .complete
        )
        XCTAssertEqual(
            SmartCareStageProgressPresentation.connectorStatus(after: .appCaches, in: progress),
            .active
        )
        XCTAssertEqual(SmartCareStageProgressPresentation.finalStatus(in: progress), .pending)
    }

    func test_stageProgressPresentation_选择性范围不会被数量碰撞误判完成() {
        let progress = SmartCareProgress(
            activity: .scanning(.core),
            completedStages: [.appCaches],
            plannedStages: [.core]
        )

        XCTAssertEqual(
            SmartCareStageProgressPresentation.connectorStatus(after: .core, in: progress),
            .active
        )
        XCTAssertEqual(SmartCareStageProgressPresentation.finalStatus(in: progress), .pending)

        let finalizing = SmartCareProgress(
            activity: .finalizing,
            completedStages: [.core],
            plannedStages: [.core]
        )
        XCTAssertEqual(
            SmartCareStageProgressPresentation.connectorStatus(after: .core, in: finalizing),
            .complete
        )
        XCTAssertEqual(SmartCareStageProgressPresentation.finalStatus(in: finalizing), .active)
    }

    func test_phasePresentation_覆盖全部SmartCare阶段() {
        let phases: [SmartCarePhase] = [
            .idle,
            .scanning(progress: SmartCareProgress()),
            .reviewing(summary: .empty),
            .confirming(selection: SmartCareSelection()),
            .cleaning(progress: SmartCareCleanProgress(completedCount: 0, totalCount: 1)),
            .completed(result: SmartCareResult(movedCount: 1, skippedCount: 0, releasedBytes: 100)),
            .failed(.scanFailed("error")),
            .cancelled(partial: nil)
        ]

        for phase in phases {
            XCTAssertFalse(SmartCarePresentation.phaseTitleKey(for: phase).isEmpty)
        }
    }

    func test_failurePresentation_不泄漏原始错误并提供对应恢复动作() {
        let scan = SmartCareFailurePresentation(
            error: .scanFailed("Common App Cache: 14 paths incomplete")
        )
        XCTAssertEqual(scan.titleKey, "smart_care.failure.scan.title")
        XCTAssertFalse(scan.detailText(locale: Locale(identifier: "en"))
            .contains("14 paths incomplete"))
        XCTAssertNotEqual(
            scan.detailText(locale: Locale(identifier: "en")),
            scan.detailText(locale: Locale(identifier: "zh-Hans"))
        )
        XCTAssertEqual(scan.primaryKey, "smart_care.action.retry_scan")
        XCTAssertEqual(SmartCareError.scanFailed("x").recovery, .retryScan)

        let cleanup = SmartCareFailurePresentation(
            error: .cleanFailed("The item is in use")
        )
        XCTAssertEqual(cleanup.titleKey, "smart_care.failure.clean.title")
        XCTAssertFalse(cleanup.detailText(locale: Locale(identifier: "zh-Hans"))
            .contains("The item is in use"))
        XCTAssertEqual(cleanup.primaryKey, "smart_care.action.review_cleanup_again")
        XCTAssertEqual(SmartCareError.cleanFailed("x").recovery, .reviewCleanup)
    }

    func test_scanLimitationPresentation_去重排序并限制可见路径数量() {
        let presentation = SmartCareScanLimitationProjection(
            paths: ["/C", "/A", "/B"],
            displayLimit: 2
        )

        XCTAssertEqual(presentation.totalCount, 3)
        XCTAssertEqual(presentation.displayedPaths, ["/A", "/B"])
        XCTAssertEqual(presentation.remainingCount, 1)
        XCTAssertFalse(presentation.isEmpty)
        XCTAssertNotNil(presentation.remainingText(locale: Locale(identifier: "en")))
        XCTAssertTrue(presentation.titleText(locale: Locale(identifier: "en")).contains("3"))
        XCTAssertNotEqual(
            presentation.titleText(locale: Locale(identifier: "en")),
            presentation.titleText(locale: Locale(identifier: "zh-Hans"))
        )
    }

    func test_completedPhasePresentation_区分完整与部分完成() {
        XCTAssertEqual(
            SmartCarePresentation.phaseTitleKey(for: .completed(result: SmartCareResult(
                movedCount: 1,
                skippedCount: 0,
                releasedBytes: 100
            ))),
            "smart_care.phase.completed"
        )
        XCTAssertEqual(
            SmartCarePresentation.phaseTitleKey(for: .completed(result: SmartCareResult(
                movedCount: 1,
                skippedCount: 1,
                releasedBytes: 100
            ))),
            "smart_care.phase.partial"
        )
    }

    func test_defaultRiskCopy_confirm按桶覆盖_forbid统一保护文案() {
        for bucket in SmartCareBucketID.allCases {
            let item = SmartCareItem(
                id: bucket.rawValue,
                bucketID: bucket,
                path: "/tmp/\(bucket.rawValue)",
                title: bucket.rawValue,
                bytes: 1,
                verdict: .confirm
            )
            XCTAssertNotNil(SmartCarePresentation.defaultRiskKey(for: item))
        }

        let safe = SmartCareItem(
            id: "safe",
            bucketID: .appCache,
            path: "/tmp/safe",
            title: "safe",
            bytes: 1,
            verdict: .safe
        )
        let forbidden = SmartCareItem(
            id: "forbid",
            bucketID: .developerCache,
            path: "/tmp/forbid",
            title: "forbid",
            bytes: 1,
            verdict: .forbid
        )

        XCTAssertNil(SmartCarePresentation.defaultRiskKey(for: safe))
        XCTAssertEqual(SmartCarePresentation.defaultRiskKey(for: forbidden),
                       "smart_care.risk.protected")
    }

    func test_normalModeRiskCopy_不直接展示规则原始备注() {
        let item = SmartCareItem(
            id: "wechat",
            bucketID: .appCache,
            path: "/tmp/wechat",
            title: "WeChat",
            bytes: 1,
            verdict: .confirm,
            riskNote: "原始规则备注不属于普通模式 UI"
        )

        XCTAssertEqual(
            SmartCarePresentation.defaultRiskKey(for: item),
            "smart_care.risk.app_cache"
        )
    }

    func test_aiFailurePresentation_覆盖全部类型化错误() {
        let kinds: [SmartCareAIReviewFailure.Kind] = [
            .configuration,
            .authentication,
            .credentialStorage,
            .rateLimit,
            .network,
            .server,
            .decoding,
            .unknown
        ]
        let keys = kinds.map(SmartCarePresentation.aiFailureSummaryKey(for:))
        XCTAssertEqual(Set(keys).count, kinds.count)
        XCTAssertTrue(keys.allSatisfy { !$0.isEmpty })
    }
}
