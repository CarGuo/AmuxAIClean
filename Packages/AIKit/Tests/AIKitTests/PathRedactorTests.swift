import XCTest
@testable import AIKit

/// M5 / 2026-06：去敏契约 ≥ 8 case，钉死出网前的隐私边界。
/// 任何 PR 削弱去敏能力都必须先改这里的契约。
final class PathRedactorTests: XCTestCase {

    private let r = PathRedactor()

    // 1
    func test_users_prefix_redacted() {
        XCTAssertEqual(r.redact("/Users/guoshuyu/Library/Caches/foo"),
                       "/Users/<USER>/Library/Caches/foo")
    }

    func test_all_user_prefixes_redacted() {
        let input = "/Users/guoshuyu/a also /Users/alice/b and /home/bob/c"
        let out = r.redact(input)
        XCTAssertFalse(out.contains("guoshuyu"))
        XCTAssertFalse(out.contains("alice"))
        XCTAssertFalse(out.contains("bob"))
        XCTAssertEqual(out, "/Users/<USER>/a also /Users/<USER>/b and /home/<USER>/c")
    }

    // 2
    func test_users_root_only() {
        XCTAssertEqual(r.redact("/Users/guoshuyu"),
                       "/Users/<USER>")
    }

    // 3
    func test_home_linux_style_prefix_redacted() {
        XCTAssertEqual(r.redact("/home/alice/.cache/uv"),
                       "/home/<USER>/.cache/uv")
    }

    // 4
    func test_uuid_lowercase_redacted() {
        let input = "/Users/guoshuyu/Library/Developer/Xcode/iOS DeviceSupport/abcdef12-3456-7890-abcd-ef1234567890"
        let out = r.redact(input)
        XCTAssertTrue(out.contains("<USER>"))
        XCTAssertTrue(out.contains("<UUID>"))
        XCTAssertFalse(out.contains("abcdef12-3456-7890-abcd-ef1234567890"))
    }

    // 5
    func test_uuid_uppercase_redacted() {
        let input = "/Library/Developer/CoreSimulator/Devices/B7F6E9C1-1234-4567-89AB-CDEF01234567/data"
        let out = r.redact(input)
        XCTAssertTrue(out.contains("<UUID>"))
        XCTAssertFalse(out.contains("B7F6E9C1-1234-4567-89AB-CDEF01234567"))
    }

    // 6
    func test_email_redacted() {
        let out = r.redact("/Users/guoshuyu/Library/Mobile Documents/com~apple~CloudDocs/from-alice@example.com.eml")
        XCTAssertTrue(out.contains("<EMAIL>"))
        XCTAssertFalse(out.contains("alice@example.com"))
    }

    // 7
    func test_volume_user_defined_redacted_system_keeps() {
        XCTAssertEqual(r.redact("/Volumes/Macintosh HD/Users/guoshuyu/x"),
                       "/Volumes/Macintosh HD/Users/<USER>/x",
                       "系统卷白名单应保留")
        XCTAssertEqual(r.redact("/Volumes/MyBackup/photos"),
                       "/Volumes/<VOLUME>/photos",
                       "用户自定义卷名应打码")
    }

    func test_all_user_defined_volumes_redacted() {
        XCTAssertEqual(r.redact("/Volumes/MyBackup/a and /Volumes/WorkDisk/b"),
                       "/Volumes/<VOLUME>/a and /Volumes/<VOLUME>/b")
    }

    // 8
    func test_no_op_for_clean_path() {
        XCTAssertEqual(r.redact("/Applications/Safari.app"),
                       "/Applications/Safari.app")
        XCTAssertEqual(r.redact(""), "")
    }

    // 9 - 批量
    func test_batch_redact() {
        let out = r.redact(["/Users/guoshuyu/a", "/Users/guoshuyu/b", "/tmp/x"])
        XCTAssertEqual(out, ["/Users/<USER>/a", "/Users/<USER>/b", "/tmp/x"])
    }

    func test_data_volume_and_lowercase_users_redacted() {
        XCTAssertEqual(
            r.redact("/System/Volumes/Data/Users/guoshuyu/Library/Caches/foo"),
            "/Users/<USER>/Library/Caches/foo"
        )
        XCTAssertEqual(
            r.redact("/users/alice/Documents/secret.txt"),
            "/Users/<USER>/Documents/secret.txt"
        )
    }
}
