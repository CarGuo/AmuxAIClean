import Foundation
import ScanKit
import XCTest
@testable import AppUI

final class VirtualMemoryTooltipFormatterTests: XCTestCase {
    func test_englishTooltipUsesLocalizedLabelsAndPluralCount() {
        let text = VirtualMemoryTooltipFormatter.text(
            for: snapshot(swapFileCount: 2, swapFileBytes: 2_000, sleepImageBytes: 4_000),
            locale: Locale(identifier: "en"),
            formatBytes: { "\($0) B" },
            localize: localizer([
                "capacity.swap.allocated.hint.real": "Real file size of %lld swapfiles",
                "capacity.sleepimage": "Sleep image",
                "capacity.swap.used": "Swap used",
                "capacity.swap.used.hint": "Same key as Activity Monitor's Swap Used",
                "capacity.sleepimage.hint": "Disable hibernation before removing sleepimage"
            ])
        )

        XCTAssertTrue(text.contains("Real file size of 2 swapfiles: 2000 B"), "actual=\(text)")
        XCTAssertTrue(text.contains("Sleep image: 4000 B"))
        XCTAssertTrue(text.contains("Swap used: 1000 B / 3000 B"))
        XCTAssertFalse(text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        })
    }

    func test_chineseTooltipUsesLocalizedLabels() {
        let text = VirtualMemoryTooltipFormatter.text(
            for: snapshot(swapFileCount: 1, swapFileBytes: 2_000, sleepImageBytes: 4_000),
            locale: Locale(identifier: "zh-Hans"),
            formatBytes: { "\($0) B" },
            localize: localizer([
                "capacity.swap.allocated.hint.real": "%lld 个 swapfile 的真实文件大小",
                "capacity.sleepimage": "休眠镜像",
                "capacity.swap.used": "swap 已用",
                "capacity.swap.used.hint": "活动监视器 Swap Used 同口径",
                "capacity.sleepimage.hint": "不使用休眠时可停用休眠镜像"
            ])
        )

        XCTAssertTrue(text.contains("1 个 swapfile 的真实文件大小: 2000 B"), "actual=\(text)")
        XCTAssertTrue(text.contains("休眠镜像: 4000 B"))
        XCTAssertTrue(text.contains("swap 已用: 1000 B / 3000 B"))
    }

    func test_fallbackTooltipExplainsSysctlSourceInSelectedLocale() {
        let text = VirtualMemoryTooltipFormatter.text(
            for: snapshot(swapFileCount: 0, swapFileBytes: 0, sleepImageBytes: 0),
            locale: Locale(identifier: "en"),
            formatBytes: { "\($0) B" },
            localize: localizer([
                "capacity.swap.allocated": "Swap allocated",
                "capacity.swap.allocated.hint.fallback": "From sysctl vm.swapusage total",
                "capacity.swap.used": "Swap used",
                "capacity.swap.used.hint": "Same key as Activity Monitor's Swap Used"
            ])
        )

        XCTAssertTrue(text.contains("Swap allocated: 3000 B"), "actual=\(text)")
        XCTAssertTrue(text.contains("From sysctl vm.swapusage total"))
    }

    private func snapshot(
        swapFileCount: Int,
        swapFileBytes: Int64,
        sleepImageBytes: Int64
    ) -> SwapProbe.Snapshot {
        SwapProbe.Snapshot(
            swapTotalBytes: 3_000,
            swapUsedBytes: 1_000,
            swapFreeBytes: 2_000,
            encrypted: true,
            swapFileBytesOnDisk: swapFileBytes,
            swapFileCount: swapFileCount,
            sleepImageBytes: sleepImageBytes
        )
    }

    private func localizer(_ values: [String: String]) -> (String) -> String {
        { key in values[key] ?? "MISSING:\(key)" }
    }
}
