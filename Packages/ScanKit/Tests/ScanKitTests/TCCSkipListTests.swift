import XCTest
@testable import ScanKit

/// v1.1：TCC 雷区 skip list 单元测试。
/// 关键不变量：
/// - 媒体库后缀（.musiclibrary / .photoslibrary 等）必须 skip
/// - home 相对的敏感数据库目录（Mail / Messages / Calendars / Safari 等）必须 skip
/// - 普通缓存目录绝不应该误伤
final class TCCSkipListTests: XCTestCase {

    // MARK: - 媒体库后缀

    func testMusicLibrarySuffixIsSkipped() {
        XCTAssertTrue(TCCSkipList.shouldSkip("/Users/me/Music/Music Library.musiclibrary"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/anywhere/Foo.photoslibrary"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/x/y/z.tvlibrary"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/x/y/z.imovielibrary"))
    }

    func testNonLibraryPathIsNotSkipped() {
        XCTAssertFalse(TCCSkipList.shouldSkip("/Users/me/Library/Caches/com.example.app"))
        XCTAssertFalse(TCCSkipList.shouldSkip("/Users/me/Documents/foo"))
        XCTAssertFalse(TCCSkipList.shouldSkip("/tmp/anything"))
    }

    // MARK: - home 相对路径

    func testMailDirectoryIsSkipped() {
        let home = NSHomeDirectory()
        XCTAssertTrue(TCCSkipList.shouldSkip("\(home)/Library/Mail"))
        XCTAssertTrue(TCCSkipList.shouldSkip("\(home)/Library/Mail/V10/IMAP-foo"))
    }

    func testMessagesDirectoryIsSkipped() {
        let home = NSHomeDirectory()
        XCTAssertTrue(TCCSkipList.shouldSkip("\(home)/Library/Messages"))
        XCTAssertTrue(TCCSkipList.shouldSkip("\(home)/Library/Messages/chat.db"))
    }

    func testSafariDirectoryIsSkipped() {
        let home = NSHomeDirectory()
        XCTAssertTrue(TCCSkipList.shouldSkip("\(home)/Library/Safari"))
        XCTAssertTrue(TCCSkipList.shouldSkip("\(home)/Library/Safari/History.db"))
    }

    func testCallHistoryIsSkipped() {
        let home = NSHomeDirectory()
        XCTAssertTrue(TCCSkipList.shouldSkip("\(home)/Library/Application Support/CallHistoryDB"))
    }

    // MARK: - 边界

    func testPrefixCollisionIsNotMistakenlySkipped() {
        // 类似 ~/Library/MailStuff 不该被 ~/Library/Mail 误吞（必须严格目录分隔）
        let home = NSHomeDirectory()
        XCTAssertFalse(TCCSkipList.shouldSkip("\(home)/Library/MailStuff"))
        XCTAssertFalse(TCCSkipList.shouldSkip("\(home)/Library/SafariBackup"))
    }

    func testSystemAbsolutePathIsSkipped() {
        XCTAssertTrue(TCCSkipList.shouldSkip("/Library/Application Support/com.apple.TCC"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/Library/Application Support/com.apple.TCC/TCC.db"))
    }
}
