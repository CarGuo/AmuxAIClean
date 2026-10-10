import XCTest
@testable import AppUI

final class UserGuideTests: XCTestCase {

    func test_userGuidePages_结构与专业模式占比及前后翻页() {
        let pages = UserGuidePage.allCases
        XCTAssertEqual(pages, [.normalMode, .proNavigation, .proDeletion, .proToolbox])

        XCTAssertFalse(UserGuidePage.normalMode.isProfessionalTopic)
        XCTAssertTrue(UserGuidePage.proNavigation.isProfessionalTopic)
        XCTAssertTrue(UserGuidePage.proDeletion.isProfessionalTopic)
        XCTAssertTrue(UserGuidePage.proToolbox.isProfessionalTopic)

        XCTAssertNil(UserGuidePage.normalMode.previousPage)
        XCTAssertEqual(UserGuidePage.normalMode.nextPage, .proNavigation)
        XCTAssertEqual(UserGuidePage.proNavigation.previousPage, .normalMode)
        XCTAssertEqual(UserGuidePage.proNavigation.nextPage, .proDeletion)
        XCTAssertEqual(UserGuidePage.proDeletion.previousPage, .proNavigation)
        XCTAssertEqual(UserGuidePage.proDeletion.nextPage, .proToolbox)
        XCTAssertEqual(UserGuidePage.proToolbox.previousPage, .proDeletion)
        XCTAssertNil(UserGuidePage.proToolbox.nextPage)

        var seenCardIDs = Set<String>()
        for (index, page) in pages.enumerated() {
            XCTAssertEqual(page.stepNumber, index + 1)
            XCTAssertEqual(page.cards.count, 4, "\(page.rawValue) 每页应包含 4 张核心指引卡片")
            for card in page.cards {
                XCTAssertTrue(
                    seenCardIDs.insert(card.id).inserted,
                    "卡片 id 必须唯一: \(card.id)"
                )
            }
        }

        let deletionIDs = UserGuidePage.proDeletion.cards.map(\.id)
        XCTAssertEqual(
            deletionIDs,
            [
                "pro_delete.direct",
                "pro_delete.batch",
                "pro_delete.stash",
                "pro_delete.recovery",
            ],
            "专业模式清理页必须覆盖单条直删、批量勾选、跨目录待处理与废纸篓还原"
        )
    }

    func test_userGuidePresentationPolicy_首启自动弹出与手动打开定位策略() {
        XCTAssertTrue(
            UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(
                userGuideCompleted: false,
                hasEvaluatedInitialUserGuide: false,
                hasConflictingModal: false,
                isRunningTests: false
            )
        )
        XCTAssertFalse(
            UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(
                userGuideCompleted: true,
                hasEvaluatedInitialUserGuide: false,
                hasConflictingModal: false,
                isRunningTests: false
            ),
            "已完成指引后再次启动不应自动弹出"
        )
        XCTAssertFalse(
            UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(
                userGuideCompleted: false,
                hasEvaluatedInitialUserGuide: true,
                hasConflictingModal: false,
                isRunningTests: false
            ),
            "同一会话评估过后不应重复自动弹出"
        )
        XCTAssertFalse(
            UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(
                userGuideCompleted: false,
                hasEvaluatedInitialUserGuide: false,
                hasConflictingModal: true,
                isRunningTests: false
            ),
            "已有其它 modal 占用时不抢占窗口"
        )
        XCTAssertFalse(
            UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(
                userGuideCompleted: false,
                hasEvaluatedInitialUserGuide: false,
                hasConflictingModal: false,
                isRunningTests: true
            ),
            "单元测试环境下不自动弹出首启向导"
        )

        XCTAssertEqual(
            UserGuidePresentationPolicy.initialPage(
                for: .normal,
                trigger: .automaticFirstLaunch
            ),
            .normalMode
        )
        XCTAssertEqual(
            UserGuidePresentationPolicy.initialPage(
                for: .professional,
                trigger: .automaticFirstLaunch
            ),
            .normalMode
        )
        XCTAssertEqual(
            UserGuidePresentationPolicy.initialPage(
                for: .normal,
                trigger: .manual
            ),
            .normalMode
        )
        XCTAssertEqual(
            UserGuidePresentationPolicy.initialPage(
                for: .professional,
                trigger: .manual
            ),
            .proNavigation,
            "在专业模式下手动点开指引时，应直接定位到专业模式章节"
        )
    }

    func test_userGuidePresentationPolicy_模式切换快捷按钮动作() {
        XCTAssertNil(
            UserGuidePresentationPolicy.targetModeForSwitchAction(
                currentPage: .normalMode,
                currentInterfaceMode: .normal
            )
        )
        XCTAssertEqual(
            UserGuidePresentationPolicy.targetModeForSwitchAction(
                currentPage: .proNavigation,
                currentInterfaceMode: .normal
            ),
            .professional
        )
        XCTAssertEqual(
            UserGuidePresentationPolicy.targetModeForSwitchAction(
                currentPage: .proDeletion,
                currentInterfaceMode: .normal
            ),
            .professional
        )
        XCTAssertEqual(
            UserGuidePresentationPolicy.targetModeForSwitchAction(
                currentPage: .normalMode,
                currentInterfaceMode: .professional
            ),
            .normal
        )
        XCTAssertNil(
            UserGuidePresentationPolicy.targetModeForSwitchAction(
                currentPage: .proToolbox,
                currentInterfaceMode: .professional
            )
        )
    }

    func test_userGuideLocalizations_中英文文案齐全且非空() {
        let zhLocale = Locale(identifier: "zh-Hans")
        let enLocale = Locale(identifier: "en")

        for page in UserGuidePage.allCases {
            let pageKeys = [
                page.modeBadgeKey,
                page.tabTitleKey,
                page.titleKey,
                page.subtitleKey,
                page.tipKey,
            ]
            for key in pageKeys {
                let zh = AppLocalization.string(key, locale: zhLocale)
                let en = AppLocalization.string(key, locale: enLocale)
                XCTAssertFalse(zh.isEmpty, "zh-Hans 缺失或为空: \(key)")
                XCTAssertFalse(en.isEmpty, "en 缺失或为空: \(key)")
                XCTAssertNotEqual(zh, key, "zh-Hans 未翻译 key: \(key)")
                XCTAssertNotEqual(en, key, "en 未翻译 key: \(key)")
            }

            for card in page.cards {
                let cardKeys = [
                    card.badgeKey,
                    card.titleKey,
                    card.bodyKey,
                    card.actionFlowKey,
                ]
                for key in cardKeys {
                    let zh = AppLocalization.string(key, locale: zhLocale)
                    let en = AppLocalization.string(key, locale: enLocale)
                    XCTAssertFalse(zh.isEmpty, "zh-Hans 缺失或为空: \(key)")
                    XCTAssertFalse(en.isEmpty, "en 缺失或为空: \(key)")
                    XCTAssertNotEqual(zh, key, "zh-Hans 未翻译 key: \(key)")
                    XCTAssertNotEqual(en, key, "en 未翻译 key: \(key)")
                }
            }
        }
    }
}
