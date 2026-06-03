import XCTest
import ScanKit
import SafetyKit
@testable import AppUI

/// v1.2 安全集成测试：把"用户主动批删大文件"这条端到端链路的安全契约钉死。
///
/// 这套测试不是补"代码逻辑对不对"，而是补"未来谁改了某一环导致整条链路被绕过"
/// 这种回归——所以每个用例都对应一个 PITFALL：
///
/// 1. **批删走 NSWorkspace.recycle**（dryRun 闸门也只是计数，不真删）
/// 2. **可见∩选中 才进 trash 入参**（隐藏选区不被偷偷波及）
/// 3. **SafetyEngine 关键路径仍然 forbid**（系统目录被任何路径凑巧拼出来都拦得住）
/// 4. **TCCSkipList 仍然挡所有 TCC 雷区**（Mail / Photos / Apple Music / Messages …）
@MainActor
final class V12SafetyIntegrationTests: XCTestCase {

    // MARK: - 1. 批量 trash dryRun：不存在路径全部计入 missing，不抛异常

    func test_集成_TrashPipeline_dryRun_不动文件_只统计() async {
        // 造 3 个临时文件 + 2 个不存在路径
        let tmp = FileManager.default.temporaryDirectory
        let alive = (0..<3).map { _ in tmp.appendingPathComponent("e2e-\(UUID().uuidString).bin") }
        for u in alive {
            try? "x".data(using: .utf8)!.write(to: u)
        }
        defer {
            for u in alive { try? FileManager.default.removeItem(at: u) }
        }
        let dead = [
            tmp.appendingPathComponent("e2e-dead-\(UUID().uuidString)-1.bin"),
            tmp.appendingPathComponent("e2e-dead-\(UUID().uuidString)-2.bin"),
        ]

        let pipeline = TrashPipeline()
        let allPaths = (alive + dead).map(\.path)
        let (present, missing, err, _) = await pipeline.moveToTrash(paths: allPaths, dryRun: true)

        XCTAssertEqual(present, 3, "3 个真实文件应被识别")
        XCTAssertEqual(missing, 2, "2 个不存在路径应被列入 missing")
        XCTAssertNotNil(err, "missing>0 时应回 dryRun 提示")
        // 关键：dryRun 后文件必须仍在
        for u in alive {
            XCTAssertTrue(FileManager.default.fileExists(atPath: u.path),
                          "dryRun 必须不真删文件：\(u.path)")
        }
    }

    func test_集成_TrashPipeline_空清单不抛错() async {
        let pipeline = TrashPipeline()
        let (m, s, e, _) = await pipeline.moveToTrash(paths: [], dryRun: false)
        XCTAssertEqual(m, 0)
        XCTAssertEqual(s, 0)
        XCTAssertNil(e, "空清单不应被视为错误")
    }

    // MARK: - 2. BatchSelection × visible：trash 入参取交集

    func test_集成_BatchSelection_批删入参_仅含可见且勾选() {
        // 模拟：用户勾了 a/b/c，但 mtime 过滤后 visible 只有 a/c
        let batch = BatchSelection()
        ["/p/a", "/p/b", "/p/c"].forEach { batch.toggle($0) }
        let visible = ["/p/a", "/p/c"]

        let toTrash = batch.selectedItemsIntersecting(visible: visible)
        XCTAssertEqual(toTrash, ["/p/a", "/p/c"], "/p/b 已被筛选挡掉，不应进 trash 入参")

        // header 三态
        XCTAssertEqual(batch.headerState(visible: visible), .all,
                       "可见集都被勾，header 三态应为 .all")

        // 用户主动批删后，selected 清空（模拟 LargeFilesView 点击行为）
        batch.clear()
        XCTAssertTrue(batch.selected.isEmpty)
    }

    func test_集成_全选只覆盖visible_隐藏勾选不丢() {
        let batch = BatchSelection()
        batch.toggle("/Users/me/big-hidden-by-mtime.mp4") // 用户先勾了它
        // 然后切换 mtime 过滤把它隐藏，并对剩余 visible 按全选
        let visibleAfterFilter = ["/Users/me/big-1.mp4", "/Users/me/big-2.mp4"]
        batch.selectAll(visible: visibleAfterFilter)
        // 再切回筛选，原勾的应当还在
        XCTAssertTrue(batch.isSelected("/Users/me/big-hidden-by-mtime.mp4"))
        XCTAssertTrue(batch.isSelected("/Users/me/big-1.mp4"))
        // 但批删时只取 visible∩selected，所以隐藏项不会被偷删
        let trashTargets = batch.selectedItemsIntersecting(visible: visibleAfterFilter)
        XCTAssertFalse(trashTargets.contains("/Users/me/big-hidden-by-mtime.mp4"),
                       "隐藏项必须不进入批删入参")
    }

    // MARK: - 3. SafetyEngine：关键系统路径任何时候都不能被判 .safe

    /// 这里的契约是 **不会 .safe**——具体是 .forbid 还是 .confirm 由 vendors.yaml 决定，
    /// 比如 /Library 要让用户清 /Library/Caches，所以判 confirm（让二次确认接管）；
    /// 但 /System、/usr、/bin、~/Library 这种不能动的，就是 forbid。
    /// 真正不能容忍的是被判 .safe（默认勾选），这才会让自动清理沿误删链路冲下去。
    func test_集成_SafetyEngine_关键路径绝不会被判safe() {
        let engine = SafetyEngine()
        let home = NSHomeDirectory()
        let cases: [String] = [
            "/",
            "/System",
            "/usr",
            "/bin",
            "/Library",
            "\(home)/Library",
            "\(home)",
        ]
        for path in cases {
            let (verdict, _) = engine.evaluate(path: path, home: home)
            XCTAssertNotEqual(verdict, .safe, "SafetyEngine 绝不能把 \(path) 判为 safe")
        }
    }

    /// 收紧契约：用户家目录根、系统根这种不可恢复点必须是 forbid。
    func test_集成_SafetyEngine_最危险路径必须forbid() {
        let engine = SafetyEngine()
        let home = NSHomeDirectory()
        let mustForbid: [String] = [
            "/",
            "/System",
            "/usr",
            "/bin",
            "\(home)/Library",
            "\(home)",
        ]
        for path in mustForbid {
            let (verdict, _) = engine.evaluate(path: path, home: home)
            XCTAssertEqual(verdict, .forbid,
                           "\(path) 必须 forbid——一旦放过会造成不可恢复损坏")
        }
    }

    // MARK: - 4. TCCSkipList：所有 TCC 雷区都被识别

    func test_集成_TCCSkipList_命中常见雷区() {
        let home = NSHomeDirectory()
        let hits: [String] = [
            "\(home)/Library/Mail",
            "\(home)/Library/Mail/V10",
            "\(home)/Library/Messages",
            "\(home)/Library/Containers/com.apple.mail",
            "\(home)/Pictures/MyLibrary.photoslibrary",
            "\(home)/Music/MyMusic.musiclibrary",
            "\(home)/Movies/MyMovies.tvlibrary",
            "\(home)/Movies/MyMovies.imovielibrary",
            "/Library/Application Support/com.apple.TCC",
        ]
        for path in hits {
            XCTAssertTrue(TCCSkipList.shouldSkip(path),
                          "TCCSkipList 必须挡住 \(path)")
        }
    }

    func test_集成_TCCSkipList_普通用户路径放行() {
        let home = NSHomeDirectory()
        let pass: [String] = [
            "\(home)/Downloads/big.mp4",
            "\(home)/Documents/report.pdf",
            "\(home)/Movies/family.mov",       // 注意：Movies 目录本身放行，只挡 .tvlibrary/.imovielibrary
            "\(home)/Pictures/holiday.jpg",
            "/Users/Shared/x.zip",
        ]
        for path in pass {
            XCTAssertFalse(TCCSkipList.shouldSkip(path),
                           "TCCSkipList 不应误伤普通用户文件 \(path)")
        }
    }

    // MARK: - 5. 端到端：构造大文件 → 批选 → dryRun → 仍然存在

    func test_E2E_造文件_批选_dryRun_文件仍在() async throws {
        // 造一个独立 sandbox 目录，5 个 1MB 文件
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("gsy-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let mb = Data(count: 1024 * 1024)
        var paths: [String] = []
        for i in 0..<5 {
            let u = sandbox.appendingPathComponent("big-\(i).mp4")
            try mb.write(to: u)
            paths.append(u.path)
        }

        // 模拟 BatchSelection：勾 1, 3
        let batch = BatchSelection()
        batch.toggle(paths[1])
        batch.toggle(paths[3])

        let trashTargets = batch.selectedItemsIntersecting(visible: paths)
        XCTAssertEqual(trashTargets, [paths[1], paths[3]])

        // 走 dryRun → 不应真删
        let pipeline = TrashPipeline()
        let (present, missing, _, _) = await pipeline.moveToTrash(paths: trashTargets, dryRun: true)
        XCTAssertEqual(present, 2)
        XCTAssertEqual(missing, 0)

        // 关键不变量：dryRun 后所有 5 个文件都还在
        for p in paths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: p),
                          "dryRun 必须不真删 \(p)")
        }
    }
}
