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

    func testIncrementalAggregationMatchesSinglePassAndReturnsCanonicalCheckpoint() throws {
        let parent = "/Users/tester/Library/Caches/Example"
        let existing = [
            SmartCareCandidate(
                source: .recommended,
                bucketID: .appCache,
                path: parent,
                title: "Example",
                bytes: 1_000,
                verdict: .safe
            )
        ]
        let rows = [
            makeRow(path: "\(parent)/Child", bytes: 200, verdict: .confirm),
            makeRow(path: "/Users/tester/Library/Caches/Other", bytes: 500)
        ]

        let incremental = try SmartCareSummaryBuilder.aggregateCheckingCancellation(
            existingCandidates: existing,
            rows: rows,
            source: .commonAppCache,
            home: "/Users/tester"
        )
        let singlePass = SmartCareSummaryBuilder.build(
            candidates: existing + SmartCareSummaryBuilder.candidates(
                from: rows,
                source: .commonAppCache,
                home: "/Users/tester"
            )
        )

        XCTAssertEqual(incremental.summary, singlePass)
        XCTAssertEqual(incremental.candidates.map(\.path), [
            parent,
            "/Users/tester/Library/Caches/Other"
        ])
        XCTAssertEqual(incremental.candidates.first?.verdict, .confirm)
    }

    func testStableSortCancelsDuringMergeWithoutTimingRace() {
        let values = Array((0..<10_000).reversed())
        var cancellationChecks = 0

        let result = SmartCareCancellableAlgorithms.stableSorted(
            values,
            by: <,
            shouldCancel: {
                cancellationChecks += 1
                return cancellationChecks == 4
            }
        )

        XCTAssertNil(result)
        XCTAssertEqual(cancellationChecks, 4)
    }

    func testStableSortPreservesEqualElementOrder() {
        struct Entry: Equatable {
            let key: Int
            let originalIndex: Int
        }
        let values = [
            Entry(key: 2, originalIndex: 0),
            Entry(key: 1, originalIndex: 1),
            Entry(key: 2, originalIndex: 2),
            Entry(key: 1, originalIndex: 3)
        ]

        let result = SmartCareCancellableAlgorithms.stableSorted(
            values,
            by: { $0.key < $1.key },
            shouldCancel: { false }
        )

        XCTAssertEqual(result, [
            Entry(key: 1, originalIndex: 1),
            Entry(key: 1, originalIndex: 3),
            Entry(key: 2, originalIndex: 0),
            Entry(key: 2, originalIndex: 2)
        ])
    }

    func testFinalSummaryConstructionCancelsInsidePrioritySort() {
        let items = (0..<4_096).map { index in
            SmartCareItem(
                id: "/tmp/confirm/\(index)",
                bucketID: .systemJunk,
                path: "/tmp/confirm/\(index)",
                title: "\(index)",
                bytes: Int64(index),
                verdict: .confirm
            )
        }
        let bucket = SmartCareBucketSummary(id: .systemJunk, items: items)
        var cancellationChecks = 0
        let flattenChecks = ((items.count - 1) / SmartCareAggregationCancellation.checkStride) + 1
        let cancellationCheckInSort = flattenChecks + 4

        let result = SmartCareSummary.make(
            buckets: [bucket],
            shouldCancel: {
                cancellationChecks += 1
                // flatten 完成后再经过 sort entry 和两个 merge checkpoint，
                // 因此取消发生在优先级排序已实际处理数据之后。
                return cancellationChecks == cancellationCheckInSort
            }
        )

        XCTAssertNil(result)
        XCTAssertEqual(cancellationChecks, cancellationCheckInSort)
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

    func testRemovingChildAlsoDropsStaleAncestorCandidateButNotSimilarPrefix() {
        let parent = "/Users/tester/Library/Caches/App"
        let sibling = "/Users/tester/Library/Caches/Application"
        let summary = SmartCareSummaryBuilder.build(candidates: [
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: parent,
                               title: "App",
                               bytes: 100,
                               verdict: .safe),
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: sibling,
                               title: "Application",
                               bytes: 200,
                               verdict: .safe)
        ])

        let remaining = SmartCareSummaryBuilder.removing(
            paths: [parent + "/child/cache.bin"],
            from: summary
        )

        XCTAssertEqual(remaining.items.map(\.path), [sibling])
    }

    func testRemovingCandidates_20k批量路径保持线性对数级并保留前缀碰撞项() throws {
        let count = 20_000
        var candidates: [SmartCareCandidate] = []
        var removedPaths: [String] = []
        candidates.reserveCapacity(count + 1)
        removedPaths.reserveCapacity(count)
        for index in 0..<count {
            let root = "/tmp/smart-care-removal/root-\(index)"
            candidates.append(SmartCareCandidate(
                source: .commonAppCache,
                bucketID: .appCache,
                path: root,
                title: "root-\(index)",
                bytes: 1,
                verdict: .safe
            ))
            removedPaths.append(root + "/child.bin")
        }
        let prefixCollision = "/tmp/smart-care-removal/root-1-keep"
        candidates.append(SmartCareCandidate(
            source: .commonAppCache,
            bucketID: .appCache,
            path: prefixCollision,
            title: "keep",
            bytes: 1,
            verdict: .safe
        ))

        let started = Date()
        let result = try SmartCareSummaryBuilder.removingCandidatesCheckingCancellation(
            paths: removedPaths,
            from: candidates
        )
        let elapsed = Date().timeIntervalSince(started)
        let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
            || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"

        XCTAssertEqual(result.candidates.map(\.path), [prefixCollision])
        XCTAssertLessThan(elapsed, isCI ? 4.0 : 2.0,
                          "20k×20k overlap 必须走索引，不能退化成 Array.contains O(n²)")
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
