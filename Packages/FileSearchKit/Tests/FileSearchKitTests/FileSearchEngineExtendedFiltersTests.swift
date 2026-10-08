import XCTest
@testable import FileSearchKit

/// Step 16-A2：date / tags / comment 三类 filter 端到端契约。
/// 与 [FileSearchEngineTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/FileSearchKit/Tests/FileSearchKitTests/FileSearchEngineTests.swift)
/// 同款 fixture 模式：tmp 目录建文件，setxattr 注入 Finder Comment，
/// URLResourceValues 写 tagNames 模拟 Finder tags。
final class FileSearchEngineExtendedFiltersTests: XCTestCase {

    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fskit-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    // MARK: - date

    func test_date_modifiedAfter_只命中较新文件() async throws {
        let old = try makeFile(name: "old.txt", mtime: Date(timeIntervalSince1970: 1_000_000_000))
        let new = try makeFile(name: "new.txt", mtime: Date(timeIntervalSince1970: 1_800_000_000))
        _ = old; _ = new

        let cutoff = Date(timeIntervalSince1970: 1_500_000_000)
        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.date(.modifiedAfter(cutoff))]))
        XCTAssertEqual(Set(names), ["new.txt"])
    }

    func test_date_modifiedBefore_只命中较旧文件() async throws {
        try makeFile(name: "old.txt", mtime: Date(timeIntervalSince1970: 1_000_000_000))
        try makeFile(name: "new.txt", mtime: Date(timeIntervalSince1970: 1_800_000_000))

        let cutoff = Date(timeIntervalSince1970: 1_500_000_000)
        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.date(.modifiedBefore(cutoff))]))
        XCTAssertEqual(Set(names), ["old.txt"])
    }

    func test_date_modifiedBetween_只命中区间内() async throws {
        try makeFile(name: "early.txt", mtime: Date(timeIntervalSince1970: 1_000_000_000))
        try makeFile(name: "mid.txt", mtime: Date(timeIntervalSince1970: 1_500_000_000))
        try makeFile(name: "late.txt", mtime: Date(timeIntervalSince1970: 1_800_000_000))

        let lo = Date(timeIntervalSince1970: 1_200_000_000)
        let hi = Date(timeIntervalSince1970: 1_600_000_000)
        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.date(.modifiedBetween(lo, hi))]))
        XCTAssertEqual(Set(names), ["mid.txt"])
    }

    // MARK: - tags

    func test_tags_hasTag_命中带指定tag的文件() async throws {
        let red = try makeFile(name: "red.txt", mtime: Date())
        let blue = try makeFile(name: "blue.txt", mtime: Date())
        try setTags(["Red"], for: red)
        try setTags(["Blue"], for: blue)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.tags(.hasTag("Red"))]))
        XCTAssertEqual(Set(names), ["red.txt"])
    }

    func test_tags_hasAnyOf_OR语义() async throws {
        let red = try makeFile(name: "red.txt", mtime: Date())
        let blue = try makeFile(name: "blue.txt", mtime: Date())
        let none = try makeFile(name: "none.txt", mtime: Date())
        try setTags(["Red"], for: red)
        try setTags(["Blue"], for: blue)
        _ = none

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.tags(.hasAnyOf(["Red", "Blue"]))]))
        XCTAssertEqual(Set(names), ["red.txt", "blue.txt"])
    }

    func test_tags_hasAllOf_AND语义() async throws {
        let both = try makeFile(name: "both.txt", mtime: Date())
        let onlyRed = try makeFile(name: "onlyred.txt", mtime: Date())
        try setTags(["Red", "Important"], for: both)
        try setTags(["Red"], for: onlyRed)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.tags(.hasAllOf(["Red", "Important"]))]))
        XCTAssertEqual(Set(names), ["both.txt"])
    }

    func test_tags_isEmpty_只命中无tag的文件() async throws {
        let red = try makeFile(name: "red.txt", mtime: Date())
        let plain = try makeFile(name: "plain.txt", mtime: Date())
        try setTags(["Red"], for: red)
        _ = plain

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.tags(.isEmpty)]))
        // 注意 fixtureRoot 本身（"."）也可能进入；过滤掉它
        let filtered = names.filter { $0 != fixtureRoot.lastPathComponent }
        XCTAssertTrue(filtered.contains("plain.txt"))
        XCTAssertFalse(filtered.contains("red.txt"))
    }

    // MARK: - comment

    func test_comment_contains_命中含子串的() async throws {
        let a = try makeFile(name: "a.txt", mtime: Date())
        let b = try makeFile(name: "b.txt", mtime: Date())
        try setFinderComment("Important project notes", for: a)
        try setFinderComment("Random scratch", for: b)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.comment(.contains("important"))]))
        XCTAssertEqual(Set(names), ["a.txt"])
    }

    func test_comment_equals_完全相等() async throws {
        let a = try makeFile(name: "a.txt", mtime: Date())
        let b = try makeFile(name: "b.txt", mtime: Date())
        try setFinderComment("exact", for: a)
        try setFinderComment("exact match more", for: b)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.comment(.equals("exact"))]))
        XCTAssertEqual(Set(names), ["a.txt"])
    }

    func test_comment_isEmpty_命中无comment文件() async throws {
        let a = try makeFile(name: "a.txt", mtime: Date())
        let b = try makeFile(name: "b.txt", mtime: Date())
        try setFinderComment("not empty", for: a)
        _ = b

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.comment(.isEmpty), .kind(.fileOnly)]))
        XCTAssertEqual(Set(names), ["b.txt"])
    }

    func test_readFinderComment_helper_直接读取写入的plist() throws {
        let url = try makeFile(name: "x.txt", mtime: Date())
        try setFinderComment("hello world", for: url)
        XCTAssertEqual(FileSearchEngine.readFinderComment(url: url), "hello world")
    }

    func test_readFinderComment_doesNotFollowSymlinkTarget() throws {
        let target = try makeFile(name: "target.txt", mtime: Date())
        try setFinderComment("secret-target-comment", for: target)
        let link = fixtureRoot.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(
            FileSearchEngine.readFinderComment(url: link),
            "",
            "readFinderComment must pass XATTR_NOFOLLOW and not read target xattr through a symlink"
        )
    }

    func test_fileExtension_respectsCaseSensitiveOption() async throws {
        try makeFile(name: "upper.SWIFT", mtime: Date())
        try makeFile(name: "lower.swift", mtime: Date())

        let engine = FileSearchEngine()
        var caseSensitiveOpts = FileSearchOptions()
        caseSensitiveOpts.caseSensitive = true
        let sensitiveNames = try await collectNames(
            engine.search(
                rootPath: fixtureRoot.path,
                filters: [.fileExtension(.includes, ["swift"])],
                options: caseSensitiveOpts
            )
        )
        XCTAssertEqual(Set(sensitiveNames), ["lower.swift"])
    }

    // MARK: - 组合：date + tags + comment 三者 AND 全满足

    func test_组合date_tags_comment_AND全满足才命中() async throws {
        let hit = try makeFile(name: "hit.txt", mtime: Date(timeIntervalSince1970: 1_700_000_000))
        try setTags(["Red"], for: hit)
        try setFinderComment("keep", for: hit)

        let missTag = try makeFile(name: "miss-tag.txt", mtime: Date(timeIntervalSince1970: 1_700_000_000))
        try setFinderComment("keep", for: missTag)

        let missComment = try makeFile(name: "miss-comment.txt", mtime: Date(timeIntervalSince1970: 1_700_000_000))
        try setTags(["Red"], for: missComment)

        let missDate = try makeFile(name: "miss-date.txt", mtime: Date(timeIntervalSince1970: 900_000_000))
        try setTags(["Red"], for: missDate)
        try setFinderComment("keep", for: missDate)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [
                              .date(.modifiedAfter(Date(timeIntervalSince1970: 1_500_000_000))),
                              .tags(.hasTag("Red")),
                              .comment(.contains("keep")),
                          ]))
        XCTAssertEqual(Set(names), ["hit.txt"])
    }

    // MARK: - helpers

    @discardableResult
    private func makeFile(name: String, mtime: Date) throws -> URL {
        let url = fixtureRoot.appendingPathComponent(name)
        try Data(repeating: 0x41, count: 10).write(to: url)
        var values = URLResourceValues()
        values.contentModificationDate = mtime
        var mutable = url
        try mutable.setResourceValues(values)
        return url
    }

    /// 直接写底层 xattr `com.apple.metadata:_kMDItemUserTags`（binary plist 字符串数组），
    /// 等价于 Finder 设置标签。setter `URLResourceValues.tagNames =` 在 macOS 26+ 才可用，
    /// v2026.07.16：为兼容当前部署目标 macOS 13.5，采用 xattr 直写。
    private func setTags(_ tags: [String], for url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: tags as NSArray, format: .binary, options: 0)
        try url.withUnsafeFileSystemRepresentation { cpath in
            guard let cpath else { throw NSError(domain: "fskit-test", code: -1) }
            let rc = data.withUnsafeBytes { raw -> Int32 in
                setxattr(cpath, "com.apple.metadata:_kMDItemUserTags",
                         raw.baseAddress, data.count, 0, 0)
            }
            if rc != 0 {
                throw NSError(domain: "fskit-test-setxattr-tags", code: Int(errno))
            }
        }
    }

    private func setFinderComment(_ comment: String, for url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: comment, format: .binary, options: 0)
        try url.withUnsafeFileSystemRepresentation { cpath in
            guard let cpath else { throw NSError(domain: "fskit-test", code: -1) }
            let rc = data.withUnsafeBytes { raw -> Int32 in
                setxattr(cpath, "com.apple.metadata:kMDItemFinderComment",
                         raw.baseAddress, data.count, 0, 0)
            }
            if rc != 0 {
                throw NSError(domain: "fskit-test-setxattr", code: Int(errno))
            }
        }
    }

    private func collectNames(_ stream: AsyncStream<FileSearchResult>) async throws -> [String] {
        var out: [String] = []
        for await r in stream { out.append(r.name) }
        return out
    }
}
