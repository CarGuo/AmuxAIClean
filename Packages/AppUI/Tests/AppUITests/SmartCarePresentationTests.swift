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

    func test_scanScopeCards_使用同一语法下的三种不规则轮廓() {
        XCTAssertEqual(SmartCareScopeCardSilhouette(stage: .core), .forwardCut)
        XCTAssertEqual(SmartCareScopeCardSilhouette(stage: .appCaches), .crossCut)
        XCTAssertEqual(SmartCareScopeCardSilhouette(stage: .developerCaches), .trailingCut)
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
}
