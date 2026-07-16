import XCTest
@testable import AppUI
import ScanKit

/// v2026.07.15：锁定容量卡的用户可见口径。
///
/// 根因：曾把 `volumeAvailableCapacityForImportantUsage` 直接接到 headline 和
/// Available 行，macOS 的动态可回收估算因此被误报成已经空闲的硬盘空间。
/// 本测试确保 View 的投影层不会在后续重构中重新混用两种容量口径。
final class VolumeCapacityDisplayContractTests: XCTestCase {

    private func localizedValue(_ key: String, locale: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            root.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
                break
            }
        }
        let catalogURL = root.appendingPathComponent(
            "Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings"
        )
        let data = try Data(contentsOf: catalogURL)
        let rootJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(rootJSON["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings[key] as? [String: Any])
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
        let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
        return try XCTUnwrap(unit["value"] as? String)
    }

    func test_主显示只使用物理空闲_可回收估算保持独立() {
        let snapshot = VolumeCapacity.Snapshot(
            volumeName: "Test",
            totalBytes: 500,
            availableBytes: 60,
            estimatedReclaimableBytes: 140
        )

        let display = VolumeCapacityDisplayValues(snapshot: snapshot)

        XCTAssertEqual(display.headlineUsedBytes, 440)
        XCTAssertEqual(display.physicalFreeBytes, 60)
        XCTAssertEqual(display.estimatedReclaimableBytes, 140)
        XCTAssertEqual(display.availableIfReclaimedBytes, 200)
        XCTAssertNotEqual(display.physicalFreeBytes, display.availableIfReclaimedBytes,
                          "预计释放后可用不得重新冒充当前物理空闲")
    }

    func test_缺少系统估算时_主显示仍保持完整() {
        let snapshot = VolumeCapacity.Snapshot(
            volumeName: "Test",
            totalBytes: 500,
            availableBytes: 60
        )

        let display = VolumeCapacityDisplayValues(snapshot: snapshot)

        XCTAssertEqual(display.headlineUsedBytes, 440)
        XCTAssertEqual(display.physicalFreeBytes, 60)
        XCTAssertNil(display.estimatedReclaimableBytes)
        XCTAssertNil(display.availableIfReclaimedBytes)
    }

    /// v2026.07.15：锁定窄侧栏的三步关系，不再把三个数字展示成三个互不相关的分类。
    /// tooltip 解释系统估算本身，不把动态容量变化错误绑定到 Simulator 或内部日志标签。
    func test_回收关系文案表达当前值加系统估算得到预计上限() throws {
        XCTAssertEqual(try localizedValue("capacity.legend.available", locale: "zh-Hans"), "当前空闲")
        XCTAssertEqual(try localizedValue("capacity.legend.system_reclaimable", locale: "zh-Hans"), "macOS 可能释放")
        XCTAssertEqual(try localizedValue("capacity.legend.available_if_reclaimed", locale: "zh-Hans"), "预计可用上限")

        XCTAssertEqual(try localizedValue("capacity.legend.available", locale: "en"), "Available Now")
        XCTAssertEqual(try localizedValue("capacity.legend.system_reclaimable", locale: "en"), "macOS May Release")
        XCTAssertEqual(try localizedValue("capacity.legend.available_if_reclaimed", locale: "en"), "Est. Maximum Available")

        let tooltipKeys = [
            "capacity.reclaimable.info.relationship",
            "capacity.reclaimable.info.changes",
            "capacity.reclaimable.info.action"
        ]
        for locale in ["en", "zh-Hans"] {
            let tooltip = try tooltipKeys
                .map { try localizedValue($0, locale: locale) }
                .joined(separator: " ")
                .lowercased()
            XCTAssertFalse(tooltip.contains("simulator"))
            XCTAssertFalse(tooltip.contains("mobileasset"))
        }

        let englishChanges = try localizedValue("capacity.reclaimable.info.changes", locale: "en")
        let englishAction = try localizedValue("capacity.reclaimable.info.action", locale: "en")
        XCTAssertTrue(englishChanges.contains("Apple Intelligence models"))
        XCTAssertTrue(englishAction.contains("turning off Apple Intelligence"))
        XCTAssertTrue(englishAction.contains("on-device models"))

        let chineseChanges = try localizedValue("capacity.reclaimable.info.changes", locale: "zh-Hans")
        let chineseAction = try localizedValue("capacity.reclaimable.info.action", locale: "zh-Hans")
        XCTAssertTrue(chineseChanges.contains("例如设备端 Apple Intelligence 模型"))
        XCTAssertTrue(chineseAction.contains("关闭 Apple Intelligence"))
        XCTAssertTrue(chineseAction.contains("移除其设备端模型"))
    }
}
