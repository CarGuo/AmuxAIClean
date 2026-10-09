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

    func testOtherUsersInPublicFullDiskNamespaceAreAlsoSkipped() {
        XCTAssertTrue(TCCSkipList.shouldSkip("/Users/another-user/Library/Mail"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/Users/another-user/Library/Messages/chat.db"))
        XCTAssertTrue(TCCSkipList.shouldSkip(
            "/Users/another-user/Library/Containers/com.apple.Safari/Data"
        ))
    }

    // MARK: - 边界

    func testPrefixCollisionIsNotMistakenlySkipped() {
        // 类似 ~/Library/MailStuff 不该被 ~/Library/Mail 误吞（必须严格目录分隔）
        let home = NSHomeDirectory()
        XCTAssertFalse(TCCSkipList.shouldSkip("\(home)/Library/MailStuff"))
        XCTAssertFalse(TCCSkipList.shouldSkip("\(home)/Library/SafariBackup"))
        XCTAssertFalse(TCCSkipList.shouldSkip("/Users/another-user/Library/MailStuff"))
    }

    func testArbitraryCustomHomeSuffixDoesNotImpersonateTCCNamespace() {
        XCTAssertFalse(TCCSkipList.shouldSkip("/tmp/custom-home/Library/Mail"))
        XCTAssertFalse(TCCSkipList.shouldSkip(
            "/Volumes/backup/Users/another-user/Library/Messages"
        ))
    }

    func testSystemAbsolutePathIsSkipped() {
        XCTAssertTrue(TCCSkipList.shouldSkip("/Library/Application Support/com.apple.TCC"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/Library/Application Support/com.apple.TCC/TCC.db"))
    }

    func testCaseInsensitiveSuffixAndVarAliasesAreSkippedWhileProcessTempFixtureIsAllowed() {
        let home = NSHomeDirectory()
        XCTAssertTrue(TCCSkipList.shouldSkip("/anywhere/Photos.PHOTOSLIBRARY"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/anywhere/Photos.PHOTOSLIBRARY/item.dat"))
        XCTAssertTrue(TCCSkipList.shouldSkip("\(home)/library/MAIL"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/Users/another-user/LIBRARY/messages"))

        XCTAssertTrue(TCCSkipList.shouldSkip("/private/var/db/locationd"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/var/db/locationd"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/private/var/folders"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/var/folders"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/var/folders/policy-probe"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/private/var/folders/policy-probe"))
        XCTAssertTrue(TCCSkipList.shouldSkip("/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/secret"))

        let tempFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-fixture-\(UUID().uuidString)")
        XCTAssertFalse(TCCSkipList.shouldSkip(tempFixture.path),
                       "当前进程临时目录下的测试/工作区普通路径不应被 /var/folders 伞规则误伤")
        if tempFixture.path.hasPrefix("/var/folders/") {
            XCTAssertTrue(TCCSkipList.shouldSkip("/private" + tempFixture.path),
                          "系统选择器物理 /private/var/folders 命名空间仍保持 TCC 隐私跳过")
        }

        let tempPhotos = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photos.PHOTOSLIBRARY")
        XCTAssertTrue(TCCSkipList.shouldSkip(tempPhotos.path),
                      "即便位于当前进程临时目录，命中媒体库后缀的目录仍必须按 TCC 规则跳过")
    }
}
