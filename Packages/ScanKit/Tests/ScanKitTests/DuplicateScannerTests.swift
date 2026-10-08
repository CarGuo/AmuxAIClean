import XCTest
@testable import ScanKit

/// `DuplicateScanner` 行为测试。
///
/// 覆盖：
///  1. 两份完全相同 → 1 组 2 份（reliability=full）
///  2. 同 size 不同内容 → 不分组
///  3. 不同 size → 不分组
///  4. > 256MB 大文件 → 仅 prefixOnly
///  5. < minBytes → 不参与
///  6. hardlink 同 inode → 不去重为 2 份（fs 已经物理共享，列出来误导用户）
///  7. 空目录 → 空结果
///  8. 多组返回按总占用倒序
///  9. TCC 路径跳过（root 命中 TCC 应直接返回空 + 事件）
/// 10. 安全契约：DuplicateScanner / DuplicateGroup 公开 API 不含删除入口
/// 11. 三份相同文件 → 1 组 3 份，reclaimableBytes = 2×size
/// 12. 同 size + 同 64KB 前缀但后段不同（小文件） → 不分组（全文件 hash 把它们区分开）
/// 13. TB 级稀疏文件仍按 logical size 分组，但占用 / 可释放按 allocated bytes 展示
final class DuplicateScannerTests: XCTestCase {

    // MARK: - 公共脚手架

    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dupscan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 写一个 size 字节的文件，内容为 byte 重复填充。
    @discardableResult
    private func writeFile(_ url: URL, size: Int, fillByte: UInt8 = 0x41) throws -> URL {
        let data = Data(repeating: fillByte, count: size)
        try data.write(to: url)
        return url
    }

    /// 写一个文件：前 prefixSize 字节是 prefixByte，后续是 tailByte，总长度 size。
    @discardableResult
    private func writeFile(_ url: URL, size: Int, prefixSize: Int, prefixByte: UInt8, tailByte: UInt8) throws -> URL {
        var data = Data(repeating: prefixByte, count: min(prefixSize, size))
        if size > prefixSize {
            data.append(Data(repeating: tailByte, count: size - prefixSize))
        }
        try data.write(to: url)
        return url
    }

    private func allocatedBytes(of url: URL) throws -> Int64 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int64(metadata.st_blocks) * 512
    }

    // MARK: - 1. 两份完全相同 → 1 组 2 份

    func testTwoIdenticalFilesProduceOneGroup() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try writeFile(root.appendingPathComponent("a.bin"), size: 2 * 1024 * 1024, fillByte: 0xAB)
        let b = try writeFile(root.appendingPathComponent("b.bin"), size: 2 * 1024 * 1024, fillByte: 0xAB)

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()

        XCTAssertEqual(groups.count, 1, "应当恰好检测到 1 组重复")
        XCTAssertEqual(groups.first?.paths.count, 2)
        XCTAssertEqual(groups.first?.reliability, .full)
        XCTAssertEqual(groups.first?.logicalBytes, 2 * 1024 * 1024)
        XCTAssertEqual(groups.first?.totalBytes, try allocatedBytes(of: a) + allocatedBytes(of: b))
        XCTAssertEqual(groups.first?.reclaimableBytes, try allocatedBytes(of: b))
        let group = try XCTUnwrap(groups.first)
        let fingerprint = try XCTUnwrap(group.contentFingerprint)
        XCTAssertEqual(fingerprint.logicalBytes, group.logicalBytes)
        XCTAssertTrue(group.files.allSatisfy { $0.snapshotIdentity != nil })
        for file in group.files {
            let identity = try XCTUnwrap(file.snapshotIdentity)
            XCTAssertTrue(identity.isRegularFile)
            XCTAssertEqual(identity.logicalBytes, group.logicalBytes)
            XCTAssertEqual(
                DuplicateScanner.verifyFullContent(
                    path: file.path,
                    expectedIdentity: identity,
                    expectedFingerprint: fingerprint
                ),
                .verified
            )
        }
    }

    // MARK: - 2. 同 size 不同内容 → 不分组

    func testSameSizeDifferentContentNoGroup() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root.appendingPathComponent("a.bin"), size: 2 * 1024 * 1024, fillByte: 0x11)
        try writeFile(root.appendingPathComponent("b.bin"), size: 2 * 1024 * 1024, fillByte: 0x22)

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()
        XCTAssertTrue(groups.isEmpty, "同 size 不同内容不应判为重复")
    }

    // MARK: - 3. 不同 size → 不分组

    func testDifferentSizeNoGroup() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root.appendingPathComponent("a.bin"), size: 2 * 1024 * 1024, fillByte: 0xAA)
        try writeFile(root.appendingPathComponent("b.bin"), size: 3 * 1024 * 1024, fillByte: 0xAA)

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()
        XCTAssertTrue(groups.isEmpty, "size 不同直接淘汰，不应触发任何 hash")
    }

    // MARK: - 4. 大文件（> 256MB） → 仅 prefixOnly

    /// 注意：本测试创建 ~257MB × 2 = 514MB 临时文件；CI 上空间充裕。
    /// 用稀疏文件（truncate）避免实际占用 SSD。
    ///
    /// **关键测试设计**（v1.2 review fix #8）：除了写一致的头部 128KB（让 prefix hash 命中），
    /// 还要在文件**尾部**写不同的 8 字节，让两文件的全文件 hash 必然不一致。
    /// 这样能真正验证「>阈值就该跳过 full hash」——若未来有人移除大文件分流逻辑，
    /// full hash 会把这两份判为不同从而**让本测试失败**，暴露行为变更。
    /// 否则两份都是稀疏全 0，无论是否做 full hash 都一致，测试无法分辨。
    func testLargeFileBeyondThresholdMarkedPrefixOnly() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let size = Int(DuplicateScanner.largeFileFullHashThreshold) + 1024 * 1024 // +1MB
        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        FileManager.default.createFile(atPath: a.path, contents: nil)
        FileManager.default.createFile(atPath: b.path, contents: nil)
        let fdA = open(a.path, O_WRONLY)
        let fdB = open(b.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fdA, 0)
        XCTAssertGreaterThanOrEqual(fdB, 0)
        defer { close(fdA); close(fdB) }
        // 写头 128KB（让 prefix hash 一致）
        let header = [UInt8](repeating: 0xCD, count: 128 * 1024)
        header.withUnsafeBufferPointer { buf in
            _ = write(fdA, buf.baseAddress, buf.count)
            _ = write(fdB, buf.baseAddress, buf.count)
        }
        // 文件 size 撑到 size（稀疏）
        XCTAssertEqual(ftruncate(fdA, off_t(size)), 0)
        XCTAssertEqual(ftruncate(fdB, off_t(size)), 0)
        // 在文件**尾部**写不同的 8 字节，让全文件 hash 必然不一致；
        // 配合 size > 阈值的断言，可真正验证大文件确实没被做 full hash。
        XCTAssertEqual(lseek(fdA, off_t(size - 8), SEEK_SET), off_t(size - 8))
        XCTAssertEqual(lseek(fdB, off_t(size - 8), SEEK_SET), off_t(size - 8))
        let tailA: [UInt8] = [0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA]
        let tailB: [UInt8] = [0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB]
        tailA.withUnsafeBufferPointer { _ = write(fdA, $0.baseAddress, $0.count) }
        tailB.withUnsafeBufferPointer { _ = write(fdB, $0.baseAddress, $0.count) }

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()
        XCTAssertEqual(groups.count, 1, "大文件 prefix 一致应作为一组返回")
        XCTAssertEqual(groups.first?.reliability, .prefixOnly,
                       "大文件不应做全文件 hash，必须以 prefixOnly 标记；尾部 8 字节不同时若做了 full hash 会把它们判为不同组，本断言会失败")
        XCTAssertEqual(groups.first?.paths.count, 2)
    }

    // MARK: - 5. < minBytes → 不参与

    func testFilesBelowMinBytesIgnored() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root.appendingPathComponent("a.bin"), size: 100 * 1024, fillByte: 0x55) // 100 KB
        try writeFile(root.appendingPathComponent("b.bin"), size: 100 * 1024, fillByte: 0x55)

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()
        XCTAssertTrue(groups.isEmpty, "小于 minBytes 的文件不应进入 size 桶")
    }

    // MARK: - 6. Hardlink → 同 inode 跳过

    func testHardlinkedFilesAreDeduplicatedByInode() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        try writeFile(a, size: 2 * 1024 * 1024, fillByte: 0x77)
        // 创建 hardlink b → a
        XCTAssertEqual(link(a.path, b.path), 0, "创建 hardlink 应当成功")

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()
        XCTAssertTrue(groups.isEmpty,
            "hardlink 同 inode 应被视为同一个文件（fs 已物理共享），不应误报为重复")
    }

    // MARK: - 7. 空目录 → 空结果

    func testEmptyDirectoryReturnsEmpty() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - 8. 多组返回按总占用倒序

    func testMultipleGroupsSortedByTotalBytesDescending() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 小组：2 份 × 1.5MB = 3MB
        try writeFile(root.appendingPathComponent("small1.bin"), size: 1_500_000, fillByte: 0x01)
        try writeFile(root.appendingPathComponent("small2.bin"), size: 1_500_000, fillByte: 0x01)
        // 大组：2 份 × 5MB = 10MB
        try writeFile(root.appendingPathComponent("big1.bin"), size: 5 * 1024 * 1024, fillByte: 0x02)
        try writeFile(root.appendingPathComponent("big2.bin"), size: 5 * 1024 * 1024, fillByte: 0x02)

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()
        XCTAssertEqual(groups.count, 2)
        XCTAssertGreaterThan(groups[0].totalBytes, groups[1].totalBytes,
                             "应按 totalBytes 倒序")
        XCTAssertEqual(groups[0].logicalBytes, 5 * 1024 * 1024)
        XCTAssertEqual(groups[1].logicalBytes, 1_500_000)
    }

    // MARK: - 9. TCC 路径跳过

    func testTCCRootIsSkippedWithEvent() async throws {
        // 用 TCC 雷区路径作为 root：~/Library/Mail
        let home = NSHomeDirectory()
        let root = URL(fileURLWithPath: "\(home)/Library/Mail")
        XCTAssertTrue(TCCSkipList.shouldSkip(root.path), "前置：~/Library/Mail 应在 TCC 雷区")

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        var sawTCCEvent = false
        var incompleteIssues: [ScanIncompleteIssue] = []
        var groups: [DuplicateGroup] = []
        for await event in scanner.scan() {
            switch event {
            case .tccProtectedSkipped: sawTCCEvent = true
            case .incomplete(let issue): incompleteIssues.append(issue)
            case .finished(let g): groups = g
            default: continue
            }
        }
        XCTAssertTrue(sawTCCEvent, "TCC 雷区 root 应触发 tccProtectedSkipped 事件")
        XCTAssertEqual(
            incompleteIssues,
            [ScanIncompleteIssue(path: root.path, reason: .tccProtectedSkipped)]
        )
        XCTAssertTrue(groups.isEmpty, "TCC 雷区 root 不能产生任何重复组")
    }

    // MARK: - 10. 安全契约：DuplicateScanner 没有删除 API

    func testSafetyContractNoDeletionAPI() throws {
        // 编译期契约：DuplicateScanner 公开 API 仅暴露 scan / scanToCompletion / 只读属性。
        // 任何 trash / unlink / removeItem / NSWorkspace.recycle 都不应在该类型出现。
        // 用反射逐个枚举 Mirror children 检查：DuplicateGroup 与 DuplicateScanner 都不能含
        // "trash" / "delete" / "remove" / "recycle" / "unlink" 命名的可见字段。
        let group = DuplicateGroup(
            hashKey: "k",
            logicalBytes: 1,
            files: [
                DuplicateFile(path: "/x", allocatedBytes: 1),
                DuplicateFile(path: "/y", allocatedBytes: 1)
            ],
            reliability: .full
        )
        let mirror = Mirror(reflecting: group)
        for child in mirror.children {
            let name = (child.label ?? "").lowercased()
            XCTAssertFalse(name.contains("trash"), "DuplicateGroup 不应有 trash 字段：\(name)")
            XCTAssertFalse(name.contains("delete"), "DuplicateGroup 不应有 delete 字段：\(name)")
            XCTAssertFalse(name.contains("remove"), "DuplicateGroup 不应有 remove 字段：\(name)")
            XCTAssertFalse(name.contains("recycle"), "DuplicateGroup 不应有 recycle 字段：\(name)")
            XCTAssertFalse(name.contains("unlink"), "DuplicateGroup 不应有 unlink 字段：\(name)")
        }
        // 同时校验源代码层面：扫描器源文件不应出现删除关键字（白盒检查）。
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ScanKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ScanKit
            .appendingPathComponent("Sources/ScanKit/DuplicateScanner.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in ["removeItem", "NSWorkspace.recycle", "trashItem", "unlink("] {
            XCTAssertFalse(source.contains(forbidden),
                "DuplicateScanner.swift 不应包含删除调用：\(forbidden)")
        }
    }

    // MARK: - 11. 三份相同 → 1 组 3 份

    func testThreeIdenticalFilesProduceGroupOfThree() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = 2 * 1024 * 1024
        try writeFile(root.appendingPathComponent("a.bin"), size: payload, fillByte: 0x99)
        let b = try writeFile(root.appendingPathComponent("b.bin"), size: payload, fillByte: 0x99)
        let c = try writeFile(root.appendingPathComponent("c.bin"), size: payload, fillByte: 0x99)

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.paths.count, 3)
        XCTAssertEqual(groups.first?.reclaimableBytes, try allocatedBytes(of: b) + allocatedBytes(of: c),
                       "3 份重复的可释放主值应是默认移走两份的 allocated bytes")
    }

    // MARK: - 12. 同 size + 同 64KB 前缀但后段不同 → 全文件 hash 区分

    func testSamePrefixDifferentTailDistinguishedByFullHash() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 文件总长 1.5MB，前 128KB 完全一致（前缀 hash 命中），后段不同
        let total = 1_500_000
        try writeFile(
            root.appendingPathComponent("a.bin"),
            size: total, prefixSize: 128 * 1024,
            prefixByte: 0xEE, tailByte: 0x01
        )
        try writeFile(
            root.appendingPathComponent("b.bin"),
            size: total, prefixSize: 128 * 1024,
            prefixByte: 0xEE, tailByte: 0x02
        )

        let scanner = DuplicateScanner(roots: [root], minBytes: 1024 * 1024)
        let groups = await scanner.scanToCompletion()
        XCTAssertTrue(groups.isEmpty,
            "前缀一致但后段不同的小文件，应被全文件 hash 区分开，不视为重复")
    }

    // MARK: - 13. 稀疏文件：logical 分组 + allocated 占用

    func testSparseFilesUseLogicalSizeForIdentityButAllocatedBytesForDiskUsage() async throws {
        let root = try makeTempRoot()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }

        let logicalSize: Int64 = 2 * 1_024 * 1_024 * 1_024 * 1_024
        let a = root.appendingPathComponent("Docker-a.raw")
        let b = root.appendingPathComponent("Docker-b.raw")
        for url in [a, b] {
            let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, S_IRUSR | S_IWUSR)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { continue }
            XCTAssertEqual(ftruncate(fd, off_t(logicalSize)), 0)
            let prefix = [UInt8](repeating: 0xD0, count: DuplicateScanner.prefixHashBytes)
            prefix.withUnsafeBufferPointer { buffer in
                XCTAssertEqual(write(fd, buffer.baseAddress, buffer.count), buffer.count)
            }
            XCTAssertEqual(close(fd), 0)
        }

        let allocatedA = try allocatedBytes(of: a)
        let allocatedB = try allocatedBytes(of: b)
        XCTAssertLessThan(allocatedA + allocatedB, 64 * 1_024 * 1_024,
                          "测试前置：两个 2 TiB logical 文件必须是低物理占用的 sparse 文件")

        let groups = await DuplicateScanner(roots: [root], minBytes: 1).scanToCompletion()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.logicalBytes, logicalSize,
                       "内容分组仍必须使用 logical size")
        XCTAssertEqual(groups.first?.totalBytes, allocatedA + allocatedB,
                       "重复组占用不能把 4 TiB logical 容量当成磁盘占用")
        XCTAssertEqual(groups.first?.reclaimableBytes, allocatedB,
                       "默认保留第一份时，可释放应是第二份的 allocated bytes")
    }

    /// v2026.07.18 producer-ownership regression: cancellation of the outer duplicate stream
    /// must not report settled while an uncooperative child BulkScanner producer is still alive.
    func testScanSessionCancellationTransitivelyJoinsChildProducer() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = DuplicateChildSettlementProbe()
        let scanner = DuplicateScanner(
            roots: [root],
            minBytes: 1,
            bulkSessionFactory: { _, _, _ in
                let pair = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .unbounded)
                let continuation = pair.continuation
                let producer = Task.detached {
                    await probe.runIgnoringCancellation()
                    continuation.finish()
                }
                return BulkScanner.ScanSession(events: pair.stream, producer: producer)
            }
        )
        let session = scanner.scanSession()

        var childStarted = false
        for _ in 0..<200 {
            if await probe.didStart() {
                childStarted = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(childStarted)

        session.cancel()
        let waiter = Task {
            await session.waitForTermination()
            await probe.markOuterFinished()
        }
        try await Task.sleep(for: .milliseconds(100))
        let finishedBeforeChild = await probe.didFinishOuter()
        XCTAssertFalse(finishedBeforeChild,
                       "outer session must retain ownership until the child walker exits")

        await probe.releaseChild()
        await waiter.value
        let finishedAfterChild = await probe.didFinishOuter()
        XCTAssertTrue(finishedAfterChild)
    }

    func testMixedHardlinkAndIndependentCopyKeepsSharedInodeFirst() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Independent single-link copy has a lexicographically smaller name ("a_single.bin")
        // and older mtime, while the hardlinked pair ("z_link1.bin", "z_link2.bin") has nlink == 2.
        let single = try writeFile(root.appendingPathComponent("a_single.bin"), size: 64 * 1024, fillByte: 0x5C)
        let hard1 = try writeFile(root.appendingPathComponent("z_link1.bin"), size: 64 * 1024, fillByte: 0x5C)
        let hard2 = root.appendingPathComponent("z_link2.bin")
        XCTAssertEqual(link(hard1.path, hard2.path), 0, "link(2) should succeed")

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: single.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: hard1.path)

        let groups = await DuplicateScanner(roots: [root], minBytes: 1024).scanToCompletion()
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.files.count, 2)
        XCTAssertGreaterThan(group.files[0].nlink, 1,
                             "Keeper (files[0]) must prefer the hardlinked inode so deleting files.dropFirst() frees disk space")
        XCTAssertEqual(group.files[1].path, single.path,
                       "Single-link copy must be positioned in files.dropFirst() as the removable duplicate")
        XCTAssertEqual(group.reclaimableBytes, try allocatedBytes(of: single))
    }

    func testVerifyFullContentReplacedByFIFODoesNotBlock() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = try writeFile(root.appendingPathComponent("victim.bin"), size: 4096, fillByte: 0x33)
        var targetStat = stat()
        XCTAssertEqual(lstat(target.path, &targetStat), 0)
        let identity = DuplicateFileIdentity(stat: targetStat)
        let fingerprint = try XCTUnwrap(DuplicateContentFingerprint(
            sha256Hex: String(repeating: "0", count: 64),
            logicalBytes: 4096
        ))

        try FileManager.default.removeItem(at: target)
        XCTAssertEqual(mkfifo(target.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertNil(DuplicateScanner.fullSHA256Hex(path: target.path),
                     "Opening a FIFO during hashing must not block and must return nil")
        let verification = DuplicateScanner.verifyFullContent(
            path: target.path,
            expectedIdentity: identity,
            expectedFingerprint: fingerprint
        )
        XCTAssertEqual(verification, .identityChangedOrUnavailable,
                       "Opening a FIFO during verification must not block and must report .identityChangedOrUnavailable")
    }
}

private actor DuplicateChildSettlementProbe {
    private var started = false
    private var childReleased = false
    private var outerFinished = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func runIgnoringCancellation() async {
        started = true
        guard !childReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseChild() {
        childReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func markOuterFinished() { outerFinished = true }
    func didStart() -> Bool { started }
    func didFinishOuter() -> Bool { outerFinished }
}
