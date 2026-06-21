import XCTest
@testable import ScanKit

/// v1.3 P0-A：DirInodeSet 目录入队去重表的纯单元测试。
///
/// 这里只验证语义契约（不依赖文件系统），与 BulkScanner 集成行为解耦：
/// 1. 首次插入返回 true，第二次返回 false；
/// 2. inode==0 视为"内核未提供"——保守允许通过，永远返回 true（不去重）；
/// 3. reset 后状态清空；
/// 4. 与 InodeSet 在相同 (dev,ino) 上独立计数，互不污染。
final class DirInodeSetTests: XCTestCase {

    func test_首次插入返回true_重复插入返回false() {
        let set = DirInodeSet()
        XCTAssertTrue(set.insertIfFirstSeen(device: 1, inode: 100), "首次插入应返回 true")
        XCTAssertFalse(set.insertIfFirstSeen(device: 1, inode: 100), "重复插入必须返回 false")
        XCTAssertEqual(set.count, 1)
    }

    func test_inode为0时永远允许通过_不去重() {
        // 防御：内核没填 inode 时若强行去重，会把同名挂载点全部当一个，不可接受。
        let set = DirInodeSet()
        XCTAssertTrue(set.insertIfFirstSeen(device: 1, inode: 0))
        XCTAssertTrue(set.insertIfFirstSeen(device: 1, inode: 0),
                      "inode==0 即使多次进入，也应一律 true（保守允许）")
        // 上述两次因 inode==0 不会进 Set，count 应仍为 0
        XCTAssertEqual(set.count, 0)
    }

    func test_不同device相同inode不互相覆盖() {
        // APFS firmlink 跨卷场景：/Users 与 /System/Volumes/Data/Users 同一 inode 不同 dev
        // —— 必须按 (dev,ino) 双键判定，否则会误把另一卷的目录也跳过。
        let set = DirInodeSet()
        XCTAssertTrue(set.insertIfFirstSeen(device: 1, inode: 42))
        XCTAssertTrue(set.insertIfFirstSeen(device: 2, inode: 42),
                      "device 不同，必须独立计数")
        XCTAssertEqual(set.count, 2)
    }

    func test_reset后状态清空_重新插入再次返回true() {
        let set = DirInodeSet()
        _ = set.insertIfFirstSeen(device: 1, inode: 100)
        _ = set.insertIfFirstSeen(device: 1, inode: 101)
        XCTAssertEqual(set.count, 2)

        set.reset()
        XCTAssertEqual(set.count, 0)
        XCTAssertTrue(set.insertIfFirstSeen(device: 1, inode: 100),
                      "reset 后再次插入应当 true")
    }

    func test_与InodeSet在同样key上独立计数_互不污染() {
        // BulkScanner 同时持有 inodeSet（文件字节）与 dirInodeSet（目录入队），
        // 两者必须互不感知。
        let dirSet = DirInodeSet()
        let fileSet = InodeSet()
        XCTAssertTrue(dirSet.insertIfFirstSeen(device: 1, inode: 7))
        XCTAssertTrue(fileSet.insertIfFirstSeen(device: 1, inode: 7),
                      "InodeSet 不应受到 DirInodeSet 已插入的影响")
        XCTAssertEqual(dirSet.count, 1)
        XCTAssertEqual(fileSet.count, 1)
    }
}
