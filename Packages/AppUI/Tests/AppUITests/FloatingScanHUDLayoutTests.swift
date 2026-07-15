import AppKit
import Combine
import SwiftUI
import XCTest
@testable import AppUI

@MainActor
final class FloatingScanHUDLayoutTests: XCTestCase {
    func test_compactScanningContent_只保留单词状态且不携带动态详情() {
        let regular = FloatingHUDHeroContent(
            title: "Scanning developer caches with an unexpectedly long localized title",
            subtitle: "13s elapsed",
            value: "5.7 GB",
            percent: "· 72%"
        )

        let result = FloatingHUDContentPolicy.compact(
            activity: .scanning,
            scanningTitle: "Scanning",
            cleaningTitle: "Cleaning",
            regular: regular
        )

        XCTAssertEqual(
            result,
            FloatingHUDHeroContent(
                title: "Scanning",
                subtitle: nil,
                value: nil,
                percent: nil
            )
        )
    }

    func test_compactCleaningContent_保持单词状态且不误报为扫描() {
        let regular = FloatingHUDHeroContent(
            title: "Moving selected items to Trash",
            subtitle: "2s elapsed",
            value: "4.2 GB",
            percent: nil
        )

        let result = FloatingHUDContentPolicy.compact(
            activity: .cleaning,
            scanningTitle: "Scanning",
            cleaningTitle: "Cleaning",
            regular: regular
        )

        XCTAssertEqual(
            result,
            FloatingHUDHeroContent(
                title: "Cleaning",
                subtitle: nil,
                value: nil,
                percent: nil
            )
        )
    }

    func test_compactNonScanningContent_保留完成和空闲态原有信息() {
        let regular = FloatingHUDHeroContent(
            title: "Disk Ready",
            subtitle: nil,
            value: "128 GB",
            percent: "· 64%"
        )

        let result = FloatingHUDContentPolicy.compact(
            activity: .inactive,
            scanningTitle: "Scanning",
            cleaningTitle: "Cleaning",
            regular: regular
        )

        XCTAssertEqual(result, regular)
    }

    func test_compactWidthPolicy_异常长内容不会撑大HUD窗口() {
        XCTAssertEqual(
            IslandPanelGeometry.compactContentWidth(measured: 1_400, fallback: 470),
            IslandPanelGeometry.expandedContentWidth
        )
        XCTAssertEqual(
            IslandPanelGeometry.compactContentWidth(measured: 320, fallback: 470),
            320 + IslandPanelGeometry.stripSafetyMargin
        )
    }

    func test_geometryRefreshCoalescer_运行期刷新延后且同一轮只执行一次() {
        var pending: [FloatingPanelGeometryRefreshCoalescer.Action] = []
        let coalescer = FloatingPanelGeometryRefreshCoalescer { action in
            pending.append(action)
        }
        var refreshCount = 0

        coalescer.schedule { refreshCount += 1 }
        coalescer.schedule { refreshCount += 1 }

        XCTAssertEqual(refreshCount, 0, "SwiftUI update 周期内不得同步改 NSPanel frame")
        XCTAssertEqual(pending.count, 1, "同一 runloop 的尺寸发布必须合并")

        pending.removeFirst()()
        XCTAssertEqual(refreshCount, 1)

        coalescer.schedule { refreshCount += 1 }
        XCTAssertEqual(pending.count, 1, "上一轮完成后必须允许调度下一轮")
        pending.removeFirst()()
        XCTAssertEqual(refreshCount, 2)
    }

    func test_hostingPolicy_由Panel管理尺寸而不是让SwiftUI反写窗口约束() {
        let host = NSHostingView(rootView: Color.clear)
        let container = FloatingPanelHostingPolicy.makeContainer(
            hosting: host,
            frameSize: NSSize(width: 736, height: 225)
        )

        XCTAssertEqual(host.sizingOptions, [])
        XCTAssertTrue(host.translatesAutoresizingMaskIntoConstraints)
        XCTAssertTrue(host.autoresizingMask.contains(.width))
        XCTAssertTrue(host.autoresizingMask.contains(.height))
        XCTAssertTrue(host.superview === container)
        XCTAssertEqual(container.frame.size, NSSize(width: 736, height: 225))
        XCTAssertEqual(host.frame.size, NSSize(width: 736, height: 225))
    }

    func test_panelEnvelope_同一屏幕只增长不随扫描文案来回收缩() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let first = IslandPanelGeometry.nextEnvelope(
            previous: nil,
            required: NSSize(width: 736, height: 225),
            availableFrame: screen
        )
        let afterShorterContent = IslandPanelGeometry.nextEnvelope(
            previous: first,
            required: NSSize(width: 729, height: 225),
            availableFrame: screen
        )

        XCTAssertEqual(afterShorterContent, first)
    }

    func test_panelEnvelope_切到较小屏幕时仍受屏幕边缘约束() {
        let result = IslandPanelGeometry.nextEnvelope(
            previous: NSSize(width: 1400, height: 900),
            required: NSSize(width: 736, height: 225),
            availableFrame: NSRect(x: 0, y: 0, width: 1024, height: 768)
        )

        XCTAssertEqual(result.width, 1024 - IslandPanelGeometry.screenEdgeMargin * 2)
        XCTAssertEqual(result.height, 768 - IslandPanelGeometry.screenEdgeMargin * 2)
    }

    func test_framePolicy_忽略亚像素抖动但接受真实尺寸变化() {
        let current = NSRect(x: 474, y: 757, width: 736, height: 225)
        let subpixel = NSRect(x: 474.25, y: 757, width: 735.75, height: 225)
        let realChange = NSRect(x: 477.5, y: 757, width: 729, height: 225)

        XCTAssertFalse(
            IslandPanelGeometry.requiresFrameUpdate(current: current, proposed: subpixel)
        )
        XCTAssertTrue(
            IslandPanelGeometry.requiresFrameUpdate(current: current, proposed: realChange)
        )
    }

    func test_measurementState_过滤重复亚像素和无效尺寸发布() {
        let state = IslandHoverState()
        var published: [CGSize] = []
        let subscription = state.$expandedSize
            .dropFirst()
            .sink { published.append($0) }

        state.updateMeasuredSizes(
            strip: CGSize(width: 700, height: 38),
            expanded: CGSize(width: 540, height: 213)
        )
        state.updateMeasuredSizes(
            strip: CGSize(width: 700.25, height: 38),
            expanded: CGSize(width: 540.25, height: 213)
        )
        state.updateMeasuredSizes(
            strip: CGSize(width: CGFloat.nan, height: 38),
            expanded: CGSize(width: -1, height: 213)
        )

        XCTAssertEqual(published, [CGSize(width: 540, height: 213)])
        withExtendedLifetime(subscription) {}
    }
}
