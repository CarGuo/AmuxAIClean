import XCTest
@testable import AppUI

/// v1.2 P1-5：BatchSelection 纯逻辑单测。
@MainActor
final class BatchSelectionTests: XCTestCase {

    // MARK: - 基础 toggle

    func test_新建实例_无任何选中() {
        let b = BatchSelection()
        XCTAssertFalse(b.isSelected("/tmp/a"))
        XCTAssertEqual(b.selected, [])
    }

    func test_toggle_反复切换() {
        let b = BatchSelection()
        b.toggle("/tmp/a")
        XCTAssertTrue(b.isSelected("/tmp/a"))
        b.toggle("/tmp/a")
        XCTAssertFalse(b.isSelected("/tmp/a"))
    }

    func test_setSelected_显式开关() {
        let b = BatchSelection()
        b.setSelected("/tmp/a", true)
        XCTAssertTrue(b.isSelected("/tmp/a"))
        b.setSelected("/tmp/a", false)
        XCTAssertFalse(b.isSelected("/tmp/a"))
        // 关已关项不抛错
        b.setSelected("/tmp/a", false)
        XCTAssertFalse(b.isSelected("/tmp/a"))
    }

    func test_clear_清空所有() {
        let b = BatchSelection()
        b.toggle("/x"); b.toggle("/y"); b.toggle("/z")
        XCTAssertEqual(b.selected.count, 3)
        b.clear()
        XCTAssertEqual(b.selected, [])
    }

    // MARK: - selectAll / deselectAll 与 visible 交互

    func test_selectAll_只动可见集() {
        let b = BatchSelection()
        b.toggle("/hidden") // 隐藏的项
        b.selectAll(visible: ["/a", "/b", "/c"])
        // 隐藏项保留 + 可见全勾
        XCTAssertEqual(b.selected, ["/hidden", "/a", "/b", "/c"])
    }

    func test_deselectAll_只取消可见的_保留隐藏() {
        let b = BatchSelection()
        b.toggle("/hidden")
        b.selectAll(visible: ["/a", "/b"])
        b.deselectAll(visible: ["/a", "/b"])
        XCTAssertEqual(b.selected, ["/hidden"], "隐藏项不应被批量取消波及")
    }

    // MARK: - selectedCount / headerState 三态

    func test_headerState_空可见集_为none() {
        let b = BatchSelection()
        XCTAssertEqual(b.headerState(visible: []), .none)
    }

    func test_headerState_零选中_为none() {
        let b = BatchSelection()
        XCTAssertEqual(b.headerState(visible: ["/a", "/b"]), .none)
    }

    func test_headerState_部分选中_为partial() {
        let b = BatchSelection()
        b.toggle("/a")
        XCTAssertEqual(b.headerState(visible: ["/a", "/b"]), .partial)
    }

    func test_headerState_全选中_为all() {
        let b = BatchSelection()
        b.toggle("/a"); b.toggle("/b")
        XCTAssertEqual(b.headerState(visible: ["/a", "/b"]), .all)
    }

    func test_headerState_隐藏项不影响全选判断() {
        let b = BatchSelection()
        b.toggle("/a"); b.toggle("/b"); b.toggle("/hidden")
        XCTAssertEqual(b.headerState(visible: ["/a", "/b"]), .all,
                       "隐藏项被勾不影响 visible=[/a,/b] 的全选判定")
    }

    // MARK: - 求交集（trash 入参）

    func test_selectedItemsIntersecting_保留visible顺序() {
        let b = BatchSelection()
        b.toggle("/c"); b.toggle("/a"); b.toggle("/x")
        let result = b.selectedItemsIntersecting(visible: ["/a", "/b", "/c"])
        XCTAssertEqual(result, ["/a", "/c"], "/x 不可见 → 不出现；顺序按 visible")
    }

    func test_selectedItemsIntersecting_完全无交集() {
        let b = BatchSelection()
        b.toggle("/x"); b.toggle("/y")
        XCTAssertEqual(b.selectedItemsIntersecting(visible: ["/a", "/b"]), [])
    }

    // MARK: - 跨重排稳定性（path 作 key 的设计目的）

    func test_path作key_视图重排不丢选() {
        let b = BatchSelection()
        b.toggle("/Users/me/big.mp4")
        // 模拟：列表先按 size 排，再按 mtime 排——LargeFileItem 是值类型可能被重建，
        // 但只要 path 不变，BatchSelection 应当稳。
        let v1 = ["/Users/me/big.mp4", "/Users/me/other.zip"]
        let v2 = ["/Users/me/other.zip", "/Users/me/big.mp4"] // 不同顺序
        XCTAssertTrue(b.isSelected("/Users/me/big.mp4"))
        XCTAssertEqual(b.selectedCount(in: v1), 1)
        XCTAssertEqual(b.selectedCount(in: v2), 1)
    }
}
