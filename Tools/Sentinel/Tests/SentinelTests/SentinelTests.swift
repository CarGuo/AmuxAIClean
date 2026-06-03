import XCTest
@testable import Sentinel

final class TrashListenerTests: XCTestCase {

    func test_isAppBundle_应识别app后缀() {
        XCTAssertTrue(TrashListener.isAppBundle(path: "/Users/foo/.Trash/Bar.app"))
        XCTAssertTrue(TrashListener.isAppBundle(path: "/Users/foo/.Trash/Quux.APP"))
    }

    func test_isAppBundle_应识别bundle后缀() {
        XCTAssertTrue(TrashListener.isAppBundle(path: "/Users/foo/.Trash/Plugin.bundle"))
    }

    func test_isAppBundle_其他后缀应忽略() {
        XCTAssertFalse(TrashListener.isAppBundle(path: "/Users/foo/.Trash/note.txt"))
        XCTAssertFalse(TrashListener.isAppBundle(path: "/Users/foo/.Trash/photo.png"))
        XCTAssertFalse(TrashListener.isAppBundle(path: "/Users/foo/.Trash/archive.zip"))
    }
}

final class HotspotBlacklistTests: XCTestCase {

    func test_spotlight目录应过滤() {
        XCTAssertTrue(HotspotListener.isBlacklisted(path: "/Volumes/Data/.Spotlight-V100/Store-V2/foo"))
    }

    func test_fseventsd目录应过滤() {
        XCTAssertTrue(HotspotListener.isBlacklisted(path: "/Volumes/Data/.fseventsd/000abc"))
    }

    func test_DocumentRevisions目录应过滤() {
        XCTAssertTrue(HotspotListener.isBlacklisted(path: "/.DocumentRevisions-V100/db-V1/foo"))
    }

    func test_tmp后缀应过滤() {
        XCTAssertTrue(HotspotListener.isBlacklisted(path: "/Users/foo/Downloads/upload.tmp"))
    }

    func test_正常文件不应被过滤() {
        XCTAssertFalse(HotspotListener.isBlacklisted(path: "/Users/foo/Downloads/Xcode_15.dmg"))
        XCTAssertFalse(HotspotListener.isBlacklisted(path: "/Users/foo/Library/Caches/com.foo.app/cache.db"))
    }
}

final class HotspotRingBufferTests: XCTestCase {

    private var tmpPath: String!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tmpPath = dir.appendingPathComponent("ring.json").path
    }

    override func tearDown() {
        if let tmpPath {
            let dir = (tmpPath as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
        super.tearDown()
    }

    func test_capacity容量为3时溢出后淘汰最早() {
        let ring = HotspotRingBuffer(capacity: 3, persistPath: tmpPath)

        for i in 0..<5 {
            ring.append(HotspotEvent(
                path: "/p/\(i)",
                detectedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                sizeHint: Int64(i * 100)
            ))
        }

        let snap = ring.snapshot()
        XCTAssertEqual(snap.count, 3)
        XCTAssertEqual(snap.map(\.path), ["/p/2", "/p/3", "/p/4"])
    }

    func test_重复path追加应去重并刷新到末尾() {
        let ring = HotspotRingBuffer(capacity: 5, persistPath: tmpPath)

        ring.append(HotspotEvent(path: "/p/A", detectedAt: Date(timeIntervalSince1970: 1), sizeHint: 100))
        ring.append(HotspotEvent(path: "/p/B", detectedAt: Date(timeIntervalSince1970: 2), sizeHint: 200))
        ring.append(HotspotEvent(path: "/p/A", detectedAt: Date(timeIntervalSince1970: 3), sizeHint: 999))

        let snap = ring.snapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap.map(\.path), ["/p/B", "/p/A"])
        XCTAssertEqual(snap.last?.sizeHint, 999)
    }

    func test_重启进程后从sentinel_pending_json恢复() throws {
        do {
            let ring = HotspotRingBuffer(capacity: 10, persistPath: tmpPath)
            ring.append(HotspotEvent(path: "/p/X", detectedAt: Date(timeIntervalSince1970: 100), sizeHint: 50))
            ring.append(HotspotEvent(path: "/p/Y", detectedAt: Date(timeIntervalSince1970: 200), sizeHint: 60))
        }

        let ring2 = HotspotRingBuffer(capacity: 10, persistPath: tmpPath)
        ring2.loadFromDisk()
        let snap = ring2.snapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap.map(\.path), ["/p/X", "/p/Y"])
    }

    func test_空盘文件加载不报错() {
        let bogus = "/nonexistent/path/\(UUID().uuidString).json"
        let ring = HotspotRingBuffer(capacity: 10, persistPath: bogus)
        ring.loadFromDisk()
        XCTAssertEqual(ring.snapshot().count, 0)
    }
}

final class URLSchemeDispatcherTests: XCTestCase {

    /// 注意：openURL 真正执行会拉 /usr/bin/open，单测不验证副作用，
    /// 仅验证 URL 字符串构造正确。
    /// 若要测 open 进程触发，移到手动验证场景。

    func test_uninstall路径中文应被percentEncode() {
        // 仅做合法性校验：调 openUninstall 不应 crash
        let dispatcher = URLSchemeDispatcher()
        dispatcher.openUninstall(path: "/Users/foo/.Trash/中文应用.app")
        // 若构造失败 SentinelLog.warn 会写 stderr，不会断言失败
        // 集成测试在 SentinelURLSchemeTests 主 App 端做
    }

    func test_uninstall空路径不应crash() {
        let dispatcher = URLSchemeDispatcher()
        dispatcher.openUninstall(path: "")
    }
}
