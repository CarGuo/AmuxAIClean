import SafetyKit
import XCTest
@testable import AppUI

final class SmartCareSummaryBuilderTests: XCTestCase {
    func testBuildReturnsEveryBucketInStableOrder() {
        let summary = SmartCareSummaryBuilder.build(candidates: [])

        XCTAssertEqual(summary.buckets.map(\.id), SmartCareBucketID.allCases)
        XCTAssertTrue(summary.items.isEmpty)
    }

    func testRecommendedRowsAreClassifiedByMeaning() {
        let home = "/Users/tester"
        let rows = [
            makeRow(path: "\(home)/Library/Caches/com.example.app", bytes: 10),
            makeRow(path: "\(home)/Library/Logs/com.example.app", bytes: 20),
            makeRow(path: "\(home)/Library/Developer/Xcode/DerivedData/App", bytes: 30),
            makeRow(path: "\(home)/Downloads/archive.zip", bytes: 40, verdict: .confirm),
            makeRow(path: "\(home)/.Trash/old-project", bytes: 50, verdict: .confirm)
        ]

        let candidates = SmartCareSummaryBuilder.candidates(from: rows,
                                                             source: .recommended,
                                                             home: home)

        XCTAssertEqual(
            candidates.map(\.bucketID),
            [.appCache, .systemJunk, .developerCache, .largeFiles, .largeFiles]
        )
    }

    func testSummaryPrecomputesSafetyPartitions() {
        let summary = SmartCareSummaryBuilder.build(candidates: [
            SmartCareCandidate(source: .recommended,
                               bucketID: .systemJunk,
                               path: "/Users/tester/Library/Logs/Safe",
                               title: "Safe",
                               bytes: 10,
                               verdict: .safe),
            SmartCareCandidate(source: .recommended,
                               bucketID: .largeFiles,
                               path: "/Users/tester/Downloads/Review",
                               title: "Review",
                               bytes: 20,
                               verdict: .confirm),
            SmartCareCandidate(source: .recommended,
                               bucketID: .systemJunk,
                               path: "/Users/tester/Library/Logs/Protected",
                               title: "Protected",
                               bytes: 30,
                               verdict: .forbid)
        ])

        XCTAssertEqual(summary.safeItems.map(\.title), ["Safe"])
        XCTAssertEqual(summary.confirmItems.map(\.title), ["Review"])
        XCTAssertEqual(summary.forbidItems.map(\.title), ["Protected"])
        XCTAssertEqual(summary.buckets.first(where: { $0.id == .systemJunk })?.safeCount, 1)
    }

    func testDuplicatePathUsesMaximumBytesAndStrictestVerdict() {
        let path = "/Users/tester/Library/Caches/com.example.app"
        let summary = SmartCareSummaryBuilder.build(candidates: [
            SmartCareCandidate(source: .recommended,
                               bucketID: .appCache,
                               path: path,
                               title: "Example",
                               bytes: 100,
                               verdict: .safe),
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: path,
                               title: "Example Cache",
                               bytes: 80,
                               verdict: .confirm,
                               riskNote: "Shared cache")
        ])

        XCTAssertEqual(summary.items.count, 1)
        XCTAssertEqual(summary.items[0].bytes, 100)
        XCTAssertEqual(summary.items[0].verdict, .confirm)
        XCTAssertEqual(summary.items[0].riskNote, "Shared cache")
    }

    func testMoreSpecificSourceOwnsDisplayBucketWithoutLoweringRisk() {
        let path = "/Users/tester/Library/Developer/Xcode/DerivedData/App"
        let summary = SmartCareSummaryBuilder.build(candidates: [
            SmartCareCandidate(source: .recommended,
                               bucketID: .systemJunk,
                               path: path,
                               title: "App",
                               bytes: 10,
                               verdict: .forbid),
            SmartCareCandidate(source: .developer,
                               bucketID: .developerCache,
                               path: path,
                               title: "Xcode App",
                               bytes: 20,
                               verdict: .safe)
        ])

        XCTAssertEqual(summary.items.count, 1)
        XCTAssertEqual(summary.items[0].bucketID, .developerCache)
        XCTAssertEqual(summary.items[0].verdict, .forbid)
        XCTAssertEqual(summary.items[0].bytes, 20)
    }

    func testStandardizedPathsDeduplicate() {
        let summary = SmartCareSummaryBuilder.build(candidates: [
            SmartCareCandidate(source: .recommended,
                               bucketID: .appCache,
                               path: "/Users/tester/Library/Caches/../Caches/App",
                               title: "",
                               bytes: -20,
                               verdict: .safe),
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: "/Users/tester/Library/Caches/App",
                               title: "App Cache",
                               bytes: 40,
                               verdict: .safe)
        ])

        XCTAssertEqual(summary.items.count, 1)
        XCTAssertEqual(summary.items[0].path, "/Users/tester/Library/Caches/App")
        XCTAssertEqual(summary.items[0].bytes, 40)
        XCTAssertEqual(summary.items[0].title, "App Cache")
    }

    func testParentChildPathsCountOnceAndKeepParent() {
        let parent = "/Users/tester/Library/Caches/Google"
        let child = "\(parent)/Chrome"
        let summary = SmartCareSummaryBuilder.build(candidates: [
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: parent,
                               title: "Google",
                               bytes: 500,
                               verdict: .safe),
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: child,
                               title: "Chrome",
                               bytes: 300,
                               verdict: .safe)
        ])

        XCTAssertEqual(summary.items.map(\.path), [parent])
        XCTAssertEqual(summary.safeBytes, 500)
    }

    func testStricterDescendantEscalatesRetainedParent() {
        let parent = "/Users/tester/Library/Caches/Shared"
        let child = "\(parent)/UserData"
        let summary = SmartCareSummaryBuilder.build(candidates: [
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: parent,
                               title: "Shared",
                               bytes: 500,
                               verdict: .safe),
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: child,
                               title: "User Data",
                               bytes: 100,
                               verdict: .confirm,
                               riskNote: "Contains user data")
        ])

        XCTAssertEqual(summary.items.count, 1)
        XCTAssertEqual(summary.items[0].path, parent)
        XCTAssertEqual(summary.items[0].verdict, .confirm)
        XCTAssertEqual(summary.items[0].riskNote, "Contains user data")
        XCTAssertEqual(summary.safeBytes, 0)
        XCTAssertEqual(summary.confirmBytes, 500)
    }

    func testHierarchyCollapseHandlesTwentyThousandCandidatesWithinBudget() {
        var candidates: [SmartCareCandidate] = []
        candidates.reserveCapacity(20_200)
        for parentIndex in 0..<200 {
            let parent = "/Users/tester/Library/Caches/App\(parentIndex)"
            candidates.append(
                SmartCareCandidate(source: .commonAppCache,
                                   bucketID: .appCache,
                                   path: parent,
                                   title: "App\(parentIndex)",
                                   bytes: 10_000,
                                   verdict: .safe)
            )
            for childIndex in 0..<100 {
                candidates.append(
                    SmartCareCandidate(source: .commonAppCache,
                                       bucketID: .appCache,
                                       path: "\(parent)/Child\(childIndex)",
                                       title: "Child\(childIndex)",
                                       bytes: 100,
                                       verdict: .safe)
                )
            }
        }

        let started = CFAbsoluteTimeGetCurrent()
        let summary = SmartCareSummaryBuilder.build(candidates: candidates)
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
            || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"

        XCTAssertEqual(summary.items.count, 200)
        XCTAssertLessThan(elapsed, isCI ? 2.5 : 1.0)
    }

    func testRemovingOnlyDropsMovedPaths() {
        let moved = "/Users/tester/Library/Caches/Moved"
        let kept = "/Users/tester/Library/Caches/Kept"
        let summary = SmartCareSummaryBuilder.build(candidates: [
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: moved,
                               title: "Moved",
                               bytes: 10,
                               verdict: .safe),
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: kept,
                               title: "Kept",
                               bytes: 20,
                               verdict: .safe)
        ])

        let remaining = SmartCareSummaryBuilder.removing(paths: [moved], from: summary)

        XCTAssertEqual(remaining.items.map(\.path), [kept])
        XCTAssertEqual(remaining.buckets.map(\.id), SmartCareBucketID.allCases)
    }

    private func makeRow(path: String,
                         bytes: Int64,
                         verdict: SafetyVerdict = .safe) -> RowItem {
        RowItem(
            id: path,
            url: URL(fileURLWithPath: path),
            title: (path as NSString).lastPathComponent,
            isDirectory: true,
            bytes: bytes,
            logicalBytes: bytes,
            fileCount: 1,
            verdict: verdict,
            rejection: .ok
        )
    }
}
