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

    func test_conflictsExposeLocalizedRunningAppName() {
        let row = makeRow(title: "Chrome Cache",
                          path: "/Users/me/Library/Caches/Google/Chrome",
                          bundlePrefix: "com.google.Chrome")

        let conflicts = RunningAppGuard.conflicts(
            rows: [row],
            runningApplications: [
                .init(bundleID: "com.google.Chrome", localizedName: "Google Chrome")
            ]
        )

        XCTAssertEqual(conflicts.map(\.runningAppName), ["Google Chrome"])
    }

    func test_conflictsPreferExactMainAppOverEarlierHelperProcess() {
        let row = makeRow(title: "Chrome Cache",
                          path: "/Users/me/Library/Caches/Google/Chrome",
                          bundlePrefix: "com.google.Chrome")

        let conflicts = RunningAppGuard.conflicts(
            rows: [row],
            runningApplications: [
                .init(bundleID: "com.google.Chrome.helper", localizedName: "Google Chrome Helper"),
                .init(bundleID: "com.google.Chrome", localizedName: "Google Chrome")
            ]
        )

        XCTAssertEqual(conflicts.map(\.runningAppName), ["Google Chrome"])
    }

    func test_conflictsRejectSimilarSiblingPrefix() {
        let row = makeRow(title: "Foo Cache",
                          path: "/Users/me/Library/Caches/com.foo",
                          bundlePrefix: "com.foo")

        let conflicts = RunningAppGuard.conflicts(
            rows: [row],
            runningBundleIDs: ["com.foobar"]
        )

        XCTAssertTrue(conflicts.isEmpty)
    }

    func test_skipPlanFiltersOnlyConflictingRows() {
        let running = makeRow(title: "WeChat Cache",
                              path: "/Users/me/Library/Caches/com.tencent.xinWeChat",
                              bundlePrefix: "com.tencent.xinWeChat")
        let idle = makeRow(title: "Plain Cache",
                           path: "/Users/me/Library/Caches/plain",
                           bundlePrefix: nil)

        let plan = RunningAppGuard.makePlan(
            rows: [running, idle],
            runningApplications: [
                .init(bundleID: "com.tencent.xinWeChat", localizedName: "WeChat")
            ],
            resolution: .skipConflictingItems
        )

        XCTAssertEqual(plan.rows.map(\.id), [idle.id])
        XCTAssertEqual(plan.skippedConflicts.map(\.path), [running.url.path])
    }

    func test_moveAllPlanKeepsEveryRowWithoutPretendingAnythingWasSkipped() {
        let row = makeRow(title: "WeChat Cache",
                          path: "/Users/me/Library/Caches/com.tencent.xinWeChat",
                          bundlePrefix: "com.tencent.xinWeChat")

        let plan = RunningAppGuard.makePlan(
            rows: [row],
            runningApplications: [
                .init(bundleID: "com.tencent.xinWeChat", localizedName: "WeChat")
            ],
            resolution: .moveAllToTrash
        )

        XCTAssertEqual(plan.rows, [row])
        XCTAssertTrue(plan.skippedConflicts.isEmpty)
    }

    func test_skipPlanKeepsDialogConfirmedPathSkippedAfterAppQuits() {
        let row = makeRow(title: "WeChat Cache",
                          path: "/Users/me/Library/Caches/com.tencent.xinWeChat",
                          bundlePrefix: "com.tencent.xinWeChat")
        let confirmed = RunningAppGuard.Conflict(
            path: row.url.path,
            title: row.title,
            bundleIDPrefix: "com.tencent.xinWeChat",
            runningBundleID: "com.tencent.xinWeChat",
            runningAppName: "WeChat"
        )

        let plan = RunningAppGuard.makePlan(
            rows: [row],
            runningApplications: [],
            resolution: .skipConflictingItems,
            confirmedConflicts: [confirmed]
        )

        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertEqual(plan.skippedConflicts, [confirmed])
    }

    func test_skipPlanUnionsDialogConflictsWithNewlyRunningApps() {
        let weChat = makeRow(title: "WeChat Cache",
                             path: "/Users/me/Library/Caches/com.tencent.xinWeChat",
                             bundlePrefix: "com.tencent.xinWeChat")
        let chrome = makeRow(title: "Chrome Cache",
                             path: "/Users/me/Library/Caches/Google/Chrome",
                             bundlePrefix: "com.google.Chrome")
        let confirmedWeChat = RunningAppGuard.Conflict(
            path: weChat.url.path,
            title: weChat.title,
            bundleIDPrefix: "com.tencent.xinWeChat",
            runningBundleID: "com.tencent.xinWeChat",
            runningAppName: "WeChat"
        )

        let plan = RunningAppGuard.makePlan(
            rows: [weChat, chrome],
            runningApplications: [
                .init(bundleID: "com.google.Chrome", localizedName: "Google Chrome")
            ],
            resolution: .skipConflictingItems,
            confirmedConflicts: [confirmedWeChat]
        )

        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertEqual(Set(plan.skippedConflicts.map(\.path)), Set([weChat.url.path, chrome.url.path]))
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
