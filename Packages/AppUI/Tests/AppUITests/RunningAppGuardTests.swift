import SafetyKit
import XCTest
@testable import AppUI

final class RunningAppGuardTests: XCTestCase {

    func test_conflictsMatchBundleIDPrefix() {
        let rows = [
            makeRow(title: "WeChat Cache",
                    path: "/Users/me/Library/Caches/com.tencent.xinWeChat",
                    bundlePrefix: "com.tencent.xinWeChat"),
            makeRow(title: "Plain Cache",
                    path: "/Users/me/Library/Caches/plain",
                    bundlePrefix: nil)
        ]

        let conflicts = RunningAppGuard.conflicts(
            rows: rows,
            runningBundleIDs: ["com.tencent.xinWeChat", "com.apple.finder"]
        )

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].title, "WeChat Cache")
        XCTAssertEqual(conflicts[0].runningBundleID, "com.tencent.xinWeChat")
    }

    func test_conflictsAllowPrefixChildren() {
        let row = makeRow(title: "Adobe Media Cache",
                          path: "/Users/me/Library/Application Support/Adobe/Common/Media Cache",
                          bundlePrefix: "com.adobe")

        let conflicts = RunningAppGuard.conflicts(
            rows: [row],
            runningBundleIDs: ["com.adobe.PremierePro.24"]
        )

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].bundleIDPrefix, "com.adobe")
    }

    func test_conflictsIgnoreNonMatchingRows() {
        let row = makeRow(title: "Zoom Cache",
                          path: "/Users/me/Library/Caches/us.zoom.xos",
                          bundlePrefix: "us.zoom.xos")

        let conflicts = RunningAppGuard.conflicts(
            rows: [row],
            runningBundleIDs: ["com.apple.finder"]
        )

        XCTAssertTrue(conflicts.isEmpty)
    }

    private func makeRow(title: String, path: String, bundlePrefix: String?) -> RowItem {
        RowItem(id: path,
                url: URL(fileURLWithPath: path),
                title: title,
                isDirectory: true,
                bytes: 1,
                logicalBytes: 1,
                fileCount: 1,
                verdict: .safe,
                rejection: .ok,
                runningBundleIDPrefix: bundlePrefix)
    }
}
