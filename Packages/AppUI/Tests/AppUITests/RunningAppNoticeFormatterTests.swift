import Foundation
import XCTest
@testable import AppUI

final class RunningAppNoticeFormatterTests: XCTestCase {
    private let appNames = ["WeChat", "Chrome", "Xcode"]

    func test_englishLocaleUsesEnglishListRulesWithLocalizedTemplate() {
        let locale = Locale(identifier: "en")

        XCTAssertEqual(
            RunningAppNoticeFormatter.appNameList(appNames, locale: locale),
            "WeChat, Chrome, and Xcode"
        )
        XCTAssertEqual(
            RunningAppNoticeFormatter.text(
                localizedTemplate: "Running: %@. When you continue, choose whether to skip their related items or still try to move all selected items to Trash.",
                appNames: appNames,
                locale: locale
            ),
            "Running: WeChat, Chrome, and Xcode. When you continue, choose whether to skip their related items or still try to move all selected items to Trash."
        )
    }

    func test_simplifiedChineseLocaleUsesChineseListRulesWithLocalizedTemplate() {
        let locale = Locale(identifier: "zh-Hans")

        XCTAssertEqual(
            RunningAppNoticeFormatter.appNameList(appNames, locale: locale),
            "WeChat、Chrome和Xcode"
        )
        XCTAssertEqual(
            RunningAppNoticeFormatter.text(
                localizedTemplate: "正在运行：%@。你可以跳过相关项目，或仍尝试将全部所选项目移到废纸篓；受保护路径仍会被安全规则拦截。",
                appNames: appNames,
                locale: locale
            ),
            "正在运行：WeChat、Chrome和Xcode。你可以跳过相关项目，或仍尝试将全部所选项目移到废纸篓；受保护路径仍会被安全规则拦截。"
        )
    }
}
