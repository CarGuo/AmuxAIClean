import XCTest
@testable import AppUI

/// Step 7-5：TrashPipeline 返回 trashedPairs 的语义验证。
///
/// 设计：四个 return path 中三个是确定性的（dry-run / 全 forbid / 空数组），
/// 必须返回空 `[]`。第四个（NSWorkspace.recycle 真把文件移入用户废纸篓）
/// 在 SPM 测试沙箱里不稳定，留给 RegressionRunner 的 undo-history-restore case
/// 跑真实 .app 验证。
///
/// 这条 test 把"非 recycle 路径必返回空 pairs"作为契约钉住，避免后续重构误改语义。
final class TrashPipelinePairTests: XCTestCase {

    func test_dryRun返回空trashedPairs() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashPair-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let f = dir + "/x.txt"
        try "x".write(toFile: f, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let (_, _, _, pairs) = await pipe.moveToTrash(paths: [f], dryRun: true)
        XCTAssertTrue(pairs.isEmpty,
                      "dryRun 不真删，绝不能返回任何 (orig,trashed) pair；实际=\(pairs)")
    }

    func test_全forbid短路返回空trashedPairs() async throws {
        let pipe = TrashPipeline()
        // /System / /usr / /etc 都是 hardForbid，partitionByForbid 会切走所有路径，
        // 直接早退不调 NSWorkspace.recycle，pairs 必空。
        let (moved, skipped, _, pairs) = await pipe.moveToTrash(
            paths: ["/System", "/usr", "/etc"],
            dryRun: false
        )
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, 3)
        XCTAssertTrue(pairs.isEmpty,
                      "全部被安全策略拦截，没有任何文件进入废纸篓，pairs 必为空；实际=\(pairs)")
    }

    func test_空数组返回空trashedPairs() async throws {
        let pipe = TrashPipeline()
        let (moved, skipped, err, pairs) = await pipe.moveToTrash(paths: [], dryRun: false)
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, 0)
        XCTAssertNil(err)
        XCTAssertTrue(pairs.isEmpty)
    }
}
