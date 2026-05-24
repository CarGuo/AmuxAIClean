import XCTest
import AppKit
@testable import AppUI

/// M5（交互更便捷）：StatusItemController 菜单加速器与扫描态联动。
@MainActor
final class StatusItemControllerTests: XCTestCase {

    func test_菜单包含四个主要项目和两条分隔线() {
        let ctrl = StatusItemController()
        let menu = ctrl._testMenuSnapshot(scanning: false)
        // 4 个真菜单项 + 2 个 separator = 6
        XCTAssertEqual(menu.items.count, 6)
        XCTAssertTrue(menu.items[1].isSeparatorItem, "第 2 项应为分隔线")
        XCTAssertTrue(menu.items[4].isSeparatorItem, "第 5 项应为分隔线")
    }

    func test_所有菜单项都带keyEquivalent() {
        let ctrl = StatusItemController()
        let menu = ctrl._testMenuSnapshot(scanning: false)
        let realItems = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(realItems.count, 4)

        // 用 title 关键字匹配，避免硬编码顺序
        func find(_ keyword: String) -> NSMenuItem? {
            realItems.first { $0.title.contains(keyword) }
        }
        XCTAssertEqual(find("打开主窗口")?.keyEquivalent, "o")
        XCTAssertEqual(find("推荐扫描")?.keyEquivalent, "r")
        XCTAssertEqual(find("悬浮窗")?.keyEquivalent, "h")
        XCTAssertEqual(find("退出")?.keyEquivalent, "q")
    }

    func test_扫描中时开始扫描项被disable并改标题() {
        let ctrl = StatusItemController()
        let snap = ctrl._testMenuSnapshot(scanning: true)
        let scanItem = snap.items.first { $0.title.contains("扫描") && !$0.isSeparatorItem }
        XCTAssertNotNil(scanItem)
        XCTAssertFalse(scanItem!.isEnabled, "扫描中应 disable，避免重复点击导致会话覆盖")
        XCTAssertTrue(scanItem!.title.contains("扫描中"), "标题应反馈当前态")
    }

    func test_未扫描时开始扫描项enabled且为默认标题() {
        let ctrl = StatusItemController()
        let snap = ctrl._testMenuSnapshot(scanning: false)
        let scanItem = snap.items.first { $0.title.contains("推荐") }
        XCTAssertNotNil(scanItem)
        XCTAssertTrue(scanItem!.isEnabled)
        XCTAssertEqual(scanItem!.title, "开始推荐扫描")
    }

    func test_点击开始扫描在扫描中时被忽略() {
        let ctrl = StatusItemController()
        var scanCalled = 0
        var openCalled = 0
        ctrl.onStartRecommendedScan = { scanCalled += 1 }
        ctrl.onOpenMainWindow = { openCalled += 1 }
        ctrl.onQueryScanState = { true } // 模拟"正在扫描"

        let snap = ctrl._testMenuSnapshot(scanning: true)
        let scanItem = snap.items.first { $0.title.contains("扫描") && !$0.isSeparatorItem }!
        // 直接 perform action（NSStatusBar 真菜单会忽略 disabled item，
        // 这里手动 invoke 验证 controller 内部第二道防御也生效）
        _ = scanItem.target?.perform(scanItem.action, with: scanItem)

        XCTAssertEqual(scanCalled, 0, "isScanning=true 时 callback 不应被调用")
        XCTAssertEqual(openCalled, 0, "扫描中点击不应顺手开主窗口（避免抢焦）")
    }

    func test_点击开始扫描未扫描时正常触发callback() {
        let ctrl = StatusItemController()
        var scanCalled = 0
        var openCalled = 0
        ctrl.onStartRecommendedScan = { scanCalled += 1 }
        ctrl.onOpenMainWindow = { openCalled += 1 }
        ctrl.onQueryScanState = { false }

        let snap = ctrl._testMenuSnapshot(scanning: false)
        let scanItem = snap.items.first { $0.title.contains("推荐") }!
        _ = scanItem.target?.perform(scanItem.action, with: scanItem)

        XCTAssertEqual(scanCalled, 1)
        XCTAssertEqual(openCalled, 1, "未扫描时点击会顺手把主窗口拉前台")
    }

    func test_点击其他菜单项调到对应callback() {
        let ctrl = StatusItemController()
        var openCalled = 0
        var hudCalled = 0
        ctrl.onOpenMainWindow = { openCalled += 1 }
        ctrl.onToggleHUD = { hudCalled += 1 }

        let snap = ctrl._testMenuSnapshot(scanning: false)
        let openItem = snap.items.first { $0.title == "打开主窗口" }!
        let hudItem = snap.items.first { $0.title.contains("悬浮窗") }!
        _ = openItem.target?.perform(openItem.action, with: openItem)
        _ = hudItem.target?.perform(hudItem.action, with: hudItem)

        XCTAssertEqual(openCalled, 1)
        XCTAssertEqual(hudCalled, 1)
    }

    func test_onQueryScanState为nil时按未扫描处理() {
        let ctrl = StatusItemController()
        ctrl.onQueryScanState = nil
        var scanCalled = 0
        ctrl.onStartRecommendedScan = { scanCalled += 1 }
        ctrl.onOpenMainWindow = {}

        let snap = ctrl._testMenuSnapshot(scanning: false)
        let scanItem = snap.items.first { $0.title.contains("推荐") }!
        XCTAssertTrue(scanItem.isEnabled, "nil 闭包不应误判为扫描中")

        _ = scanItem.target?.perform(scanItem.action, with: scanItem)
        XCTAssertEqual(scanCalled, 1)
    }
}
