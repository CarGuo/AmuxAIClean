import XCTest
@testable import ScanKit

/// CACHEDIR.TAG 检测器单元测试（Step 8-5）。
///
/// 覆盖三档：
/// 1. **合法 tag**（前 43 字节 = 标准签名）→ true
/// 2. **非法 tag**（任意字节差异 / 前 43 字节不足 / 签名错位）→ false
/// 3. **无 tag 文件** → false
///
/// 关键不变量：实现仅做字节精确比对，不做 UTF-8 normalize、不做 prefix 模糊匹配。
final class CacheDirTagTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CacheDirTagTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    /// 工具：在 dir 下写 CACHEDIR.TAG 文件，内容由调用方控制。
    private func writeTag(in dir: URL, content: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tag = dir.appendingPathComponent("CACHEDIR.TAG")
        try content.data(using: .utf8)!.write(to: tag)
    }

    /// 1) 合法 tag：前 43 字节正好 == 标准签名（后续可任意拓展，规范允许）。
    func testValidCacheDirTagDetected() throws {
        let dir = tempRoot.appendingPathComponent("cache_dir")
        let validContent = CacheDirTag.signature + "\n# This file is a cache directory tag.\n"
        try writeTag(in: dir, content: validContent)

        XCTAssertTrue(CacheDirTag.isCacheDirectory(at: dir.path),
                      "合法 tag 必须命中：前 43 字节为标准签名")
    }

    /// CACHEDIR.TAG 是分类信号，不是“可以跳过大小统计”的许可。
    /// 清理工具仍需遍历 tagged root，才能向用户展示真实可释放空间。
    func testBulkScannerTaggedRootStillScansPayload() async throws {
        let dir = tempRoot.appendingPathComponent("scanned_cache_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = dir.appendingPathComponent("payload.bin")
        try Data(repeating: 0x5A, count: 32_768).write(to: payload)
        try writeTag(in: dir, content: CacheDirTag.signature + "\n# cache payload\n")

        let scanner = BulkScanner(options: ScanOptions(mediaAware: false))
        var sawTagEvent = false
        var sawPayload = false
        var summary: ScanSummary?
        for await event in scanner.scan(root: dir) {
            switch event {
            case .cacheDirTagged(let path):
                sawTagEvent = (path == dir.path)
            case .node(let node):
                sawPayload = sawPayload || node.path == payload.path
            case .nodes(let nodes):
                sawPayload = sawPayload || nodes.contains { $0.path == payload.path }
            case .finished(let value):
                summary = value
            default:
                break
            }
        }

        XCTAssertTrue(sawTagEvent)
        XCTAssertTrue(sawPayload, "Tagged cache payload must still reach size aggregation")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(summary).totalLogicalBytes, 32_768)
    }

    /// 2) 非法 tag：签名首字节被改动 → 不命中。
    func testInvalidSignatureNotDetected() throws {
        let dir = tempRoot.appendingPathComponent("fake_cache_dir")
        // 把签名首字符 'S' 改成 's'（byte-exact 比对必须失败）
        let invalidContent = "signature: 8a477f597d28d172789f06886806bc55\n"
        try writeTag(in: dir, content: invalidContent)

        XCTAssertFalse(CacheDirTag.isCacheDirectory(at: dir.path),
                       "签名字节差异 1 字节也必须不命中（byte-exact）")
    }

    /// 2.b) 非法 tag：文件不足 43 字节（截断） → 不命中。
    func testTruncatedTagNotDetected() throws {
        let dir = tempRoot.appendingPathComponent("truncated_dir")
        try writeTag(in: dir, content: "Signature: 8a477f")  // 只有 17 字节

        XCTAssertFalse(CacheDirTag.isCacheDirectory(at: dir.path),
                       "截断（长度不足 43 字节）必须不命中")
    }

    /// 3) 无 tag：目录里根本没有 CACHEDIR.TAG 文件 → 不命中。
    func testNoTagFileNotDetected() throws {
        let dir = tempRoot.appendingPathComponent("normal_dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 故意不写 CACHEDIR.TAG

        XCTAssertFalse(CacheDirTag.isCacheDirectory(at: dir.path),
                       "目录不存在 CACHEDIR.TAG 时必须不命中")
    }

    /// 4) 边界：签名后追加非常长内容也应命中（验证仅读前 43 字节，不被尾部拖累）。
    func testValidSignatureWithLargeAppendedContent() throws {
        let dir = tempRoot.appendingPathComponent("big_cache_dir")
        // 签名 + 1MB 任意内容
        let payload = String(repeating: "x", count: 1_024 * 1_024)
        try writeTag(in: dir, content: CacheDirTag.signature + "\n" + payload)

        XCTAssertTrue(CacheDirTag.isCacheDirectory(at: dir.path),
                      "签名正确时即便附带大量后续内容也必须命中")
    }

    /// 5) 安全回归：CACHEDIR.TAG 若是命名管道（FIFO）或软链，必须立即返回 false 且绝不阻塞扫描线程。
    func testFIFOAndSymlinkTagRejectedWithoutBlocking() throws {
        let fifoDir = tempRoot.appendingPathComponent("fifo_cache_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: fifoDir, withIntermediateDirectories: true)
        let fifoTag = fifoDir.appendingPathComponent(CacheDirTag.fileName)
        XCTAssertEqual(mkfifo(fifoTag.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertFalse(CacheDirTag.isCacheDirectory(at: fifoDir.path),
                       "FIFO 伪造的 CACHEDIR.TAG 必须立即返回 false 且不能阻塞")

        let realDir = tempRoot.appendingPathComponent("real_tag_holder", isDirectory: true)
        try writeTag(in: realDir, content: CacheDirTag.signature + "\n")
        let symlinkDir = tempRoot.appendingPathComponent("symlink_cache_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkDir.appendingPathComponent(CacheDirTag.fileName),
            withDestinationURL: realDir.appendingPathComponent(CacheDirTag.fileName)
        )
        XCTAssertFalse(CacheDirTag.isCacheDirectory(at: symlinkDir.path),
                       "软链 CACHEDIR.TAG 必须被 O_NOFOLLOW 拒绝")
    }
}
