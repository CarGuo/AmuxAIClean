import XCTest
@testable import AppUI

/// v1.2 P2-4：QuickLookController 纯函数路径过滤单测。
///
/// QLPreviewPanel 在 swift test 进程里没法真渲染（无 NSWindow），
/// 所以这里只测 `filterPreviewable` 的边界——这正是我们防"闪退到错误占位"的护栏。
final class QuickLookControllerTests: XCTestCase {

    func test_存在的文件应通过过滤() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-\(UUID().uuidString).txt")
        try "hello".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = QuickLookController.filterPreviewable(urls: [tmp])
        XCTAssertEqual(result, [tmp])
    }

    func test_不存在的路径应被过滤掉() {
        let fake = URL(fileURLWithPath: "/tmp/__quicklook_does_not_exist_\(UUID().uuidString).bin")
        let result = QuickLookController.filterPreviewable(urls: [fake])
        XCTAssertTrue(result.isEmpty, "不存在路径必须挡掉，否则 QLPreviewPanel 会闪到错误占位")
    }

    func test_目录路径应被过滤掉() {
        let dir = FileManager.default.temporaryDirectory
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        let result = QuickLookController.filterPreviewable(urls: [dir])
        XCTAssertTrue(result.isEmpty, "目录不能直接喂给 QLPreviewPanel")
    }

    func test_混合输入_保留有效顺序() throws {
        let f1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-\(UUID().uuidString).txt")
        let f2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-\(UUID().uuidString).txt")
        try "a".data(using: .utf8)!.write(to: f1)
        try "b".data(using: .utf8)!.write(to: f2)
        defer {
            try? FileManager.default.removeItem(at: f1)
            try? FileManager.default.removeItem(at: f2)
        }
        let fake = URL(fileURLWithPath: "/tmp/__nope_\(UUID().uuidString).x")
        let dir = FileManager.default.temporaryDirectory

        let result = QuickLookController.filterPreviewable(urls: [f1, fake, dir, f2])
        XCTAssertEqual(result, [f1, f2], "应保留两个有效文件且顺序不变")
    }

    @MainActor
    func test_preview空清单不写状态() {
        let qc = QuickLookController.shared
        qc._testReset()
        qc.preview(urls: [URL(fileURLWithPath: "/tmp/__no_\(UUID().uuidString)")])
        // 全无效 → guard 拦截，内部 urls 应仍为空，不会因为没 panel 抛出
        XCTAssertTrue(qc._testCurrentURLs.isEmpty)
    }
}
