import Darwin
import CryptoKit
import XCTest
@testable import AppUI

/// Step 7-5：UndoHistoryStore 单测。
///
/// 覆盖：
/// 1. addRecord 头插 + LRU + 持久化到磁盘
/// 2. loadHistory 跨实例读取（验 Codable + flock/WAL 持久化合同）
/// 3. 历史与恢复能力分离：trashedPath 消失后仍保留最近操作记录
/// 4. restoreRecord happy path：把 trashed 文件 mv 回 original，但保留不可变操作事实并标记 restored
/// 5. missing / Trash 路径 ABA replacement 均 fail-closed，且不会删除历史
/// 6. 旧 JSON 无身份时拒绝猜测恢复；旧品牌目录通过 retained-source watermark 单调对账
/// 7. 同名冲突先形成显式 plan；skip / restore-with-new-name 都不触碰现有文件
@MainActor
final class UndoHistoryStoreTests: XCTestCase {

    private final class LockedEventSet: @unchecked Sendable {
        private let lock = NSLock()
        private var labels: Set<String> = []

        func insert(_ label: String) {
            lock.lock()
            labels.insert(label)
            lock.unlock()
        }

        func contains(_ label: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return labels.contains(label)
        }
    }

    private final class RecoveryRefreshProbeGate: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseFirst = DispatchSemaphore(value: 0)
        private var enteredCount = 0
        private var activeCount = 0
        private var peakActiveCount = 0

        func enter() {
            lock.lock()
            enteredCount += 1
            let ordinal = enteredCount
            activeCount += 1
            peakActiveCount = max(peakActiveCount, activeCount)
            lock.unlock()

            if ordinal == 1 {
                _ = releaseFirst.wait(timeout: .now() + 3)
            }

            lock.lock()
            activeCount -= 1
            lock.unlock()
        }

        func release() {
            releaseFirst.signal()
        }

        var hasEntered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return enteredCount > 0
        }

        var invocationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return enteredCount
        }

        var peakConcurrency: Int {
            lock.lock()
            defer { lock.unlock() }
            return peakActiveCount
        }
    }

    private final class PersistenceBootstrapGate: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseFirst = DispatchSemaphore(value: 0)
        private var enteredCount = 0

        func enterIfFirst() {
            lock.lock()
            enteredCount += 1
            let shouldWait = enteredCount == 1
            lock.unlock()
            if shouldWait {
                _ = releaseFirst.wait(timeout: .now() + 3)
            }
        }

        func release() {
            releaseFirst.signal()
        }

        var hasEntered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return enteredCount > 0
        }

        var invocationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return enteredCount
        }
    }

    private final class TwoSnapshotPersistenceGate: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseFirst = DispatchSemaphore(value: 0)
        private let releaseSecond = DispatchSemaphore(value: 0)
        private var enteredCount = 0

        func enter() {
            lock.lock()
            enteredCount += 1
            let ordinal = enteredCount
            lock.unlock()
            if ordinal == 1 {
                _ = releaseFirst.wait(timeout: .now() + 3)
            } else if ordinal == 2 {
                _ = releaseSecond.wait(timeout: .now() + 3)
            }
        }

        func releaseFirstSnapshot() { releaseFirst.signal() }
        func releaseSecondSnapshot() { releaseSecond.signal() }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return enteredCount
        }
    }

    private final class MigrationOutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UndoHistoryStore.LegacyMigrationOutcome?

        func set(_ value: UndoHistoryStore.LegacyMigrationOutcome) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: UndoHistoryStore.LegacyMigrationOutcome? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UHSTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storeURL(in dir: URL) -> URL {
        dir.appendingPathComponent("UndoHistory.json")
    }

    private func directHistorySources(at url: URL) throws -> Set<String> {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        return Set(records.compactMap { $0["source"] as? String })
    }

    private func canonicalWALURLs(nextTo destination: URL) -> [URL] {
        let parent = destination.deletingLastPathComponent()
        return [
            ".UndoHistory.schema4-cas.stage-0",
            ".UndoHistory.schema4-cas.stage-1",
            ".UndoHistory.schema4-cas.marker-0",
            ".UndoHistory.schema4-cas.marker-1"
        ].map { parent.appendingPathComponent($0) }
    }

    private func markerGeneration(at url: URL) -> UInt64? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let number = payload["generation"] as? NSNumber else { return nil }
        return number.uint64Value
    }

    private func rewriteMarkerRecord(
        at url: URL,
        transform: (inout [String: Any]) throws -> Void
    ) throws {
        var record = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        try transform(&record)
        let material: [String: Any] = [
            "slot": try XCTUnwrap(record["slot"]),
            "markerIdentity": try XCTUnwrap(record["markerIdentity"]),
            "payload": try XCTUnwrap(record["payload"])
        ]
        let materialData = try JSONSerialization.data(
            withJSONObject: material,
            options: [.sortedKeys]
        )
        record["checksum"] = SHA256.hash(data: materialData)
            .map { String(format: "%02x", $0) }
            .joined()
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])

        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func replacingPersistedDevice(in value: Any, with device: UInt64) -> Any {
        if var dictionary = value as? [String: Any] {
            for key in dictionary.keys {
                dictionary[key] = key == "device"
                    ? NSNumber(value: device)
                    : replacingPersistedDevice(in: dictionary[key] as Any, with: device)
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return array.map { replacingPersistedDevice(in: $0, with: device) }
        }
        return value
    }

    private func rewriteBootstrapRecordDevice(at url: URL, to device: UInt64) throws {
        var record = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var payload = try XCTUnwrap(record["payload"] as? [String: Any])
        payload = try XCTUnwrap(
            replacingPersistedDevice(in: payload, with: device) as? [String: Any]
        )
        let payloadData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        record["payload"] = payload
        record["checksum"] = SHA256.hash(data: payloadData)
            .map { String(format: "%02x", $0) }
            .joined()
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func testAddRecordHeadInsertsAndPersists() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)

        store.addRecord(source: "clean", filePairs: [
            .init(original: "/A/a.log", trashed: "/T/a.log"),
            .init(original: "/A/b.log", trashed: "/T/b.log")
        ])
        store.addRecord(source: "uninstall", filePairs: [
            .init(original: "/X/x.log", trashed: "/T/x.log")
        ])

        XCTAssertEqual(store.history.count, 2)
        // 头插：最新（uninstall）在前
        XCTAssertEqual(store.history.first?.source, "uninstall")
        XCTAssertEqual(store.history.last?.source, "clean")
        XCTAssertEqual(store.history.last?.fileCount, 2)
        // 持久化文件存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAddRecordRespectsMaxHistoryLRU() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: url, maxHistoryCount: 3)

        for i in 0..<5 {
            store.addRecord(source: "src\(i)", filePairs: [
                .init(original: "/A/\(i).log", trashed: "/T/\(i).log")
            ])
        }

        XCTAssertEqual(store.history.count, 3)
        // 最新 3 条：src4, src3, src2
        XCTAssertEqual(store.history.map { $0.source }, ["src4", "src3", "src2"])
    }

    func testBackgroundWritesAreFIFOAndFlushIncludesNewestSnapshot() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: dir)) }
        let store = UndoHistoryStore(
            storeURL: url,
            maxHistoryCount: 10,
            saveStrategy: .background
        )

        for index in 0..<40 {
            store.addRecord(source: "src\(index)", filePairs: [
                .init(original: "/original/\(index)", trashed: "/trash/\(index)")
            ])
        }
        await store.flushPendingWrites()

        let persisted = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        XCTAssertEqual(persisted.history.map(\.source), (30..<40).reversed().map { "src\($0)" },
                       "flush 后磁盘必须是最后一次内存快照，不能被较旧后台写反向覆盖")
    }

    func testReloadFromDiskAcrossInstances() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        // 准备一个真实存在的 trashed 路径，验证持久化 round-trip。
        let realTrashed = dir.appendingPathComponent("trashed.log").path
        try "x".write(toFile: realTrashed, atomically: true, encoding: .utf8)

        do {
            let s1 = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
            s1.addRecord(source: "clean", filePairs: [
                .init(original: "/A/a.log", trashed: realTrashed)
            ])
        }
        // 第二个实例要从盘上读出来
        let s2 = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        XCTAssertEqual(s2.history.count, 1)
        XCTAssertEqual(s2.history.first?.source, "clean")
        XCTAssertEqual(s2.history.first?.filePairs.first?.original, "/A/a.log")
        XCTAssertNotNil(s2.history.first?.filePairs.first?.trashedIdentity)
        XCTAssertEqual(s2.history.first?.recoveryStates.first?.status, .checking,
                       "跨进程的 available 观察不能直接沿用，必须重新做身份探测")
    }

    func testMissingTrashItemsDoNotEraseCleanupHistoryAfterReload() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        // 准备两个真实存在的 trashed 文件 + 一个不存在的
        let realA = dir.appendingPathComponent("realA.txt").path
        let realB = dir.appendingPathComponent("realB.txt").path
        try "a".write(toFile: realA, atomically: true, encoding: .utf8)
        try "b".write(toFile: realB, atomically: true, encoding: .utf8)
        let ghost = dir.appendingPathComponent("ghost.txt").path  // 不创建

        let store = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        // 全鬼记录：所有 pair 的 trashed 都不存在
        store.addRecord(source: "stale", filePairs: [
            .init(original: "/orig/g1.log", trashed: ghost),
            .init(original: "/orig/g2.log", trashed: dir.appendingPathComponent("ghost2.txt").path)
        ])
        // 部分存在：保留
        store.addRecord(source: "partial", filePairs: [
            .init(original: "/orig/p1.log", trashed: realA),
            .init(original: "/orig/p2.log", trashed: ghost)
        ])
        // 全存在
        store.addRecord(source: "alive", filePairs: [
            .init(original: "/orig/a.log", trashed: realB)
        ])

        XCTAssertEqual(store.history.count, 3)

        // v2026.07.18：重新加载不得把“废纸篓中已不存在”误判成“这次清理从未发生”。
        // 可恢复性由 prepareRestore/restoreRecord 在操作时重验，历史页保留最近批次事实。
        let reloaded = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        XCTAssertEqual(reloaded.history.count, 3)
        XCTAssertEqual(Set(reloaded.history.map { $0.source }), Set(["stale", "partial", "alive"]))
        let stale = try XCTUnwrap(reloaded.history.first { $0.source == "stale" })
        XCTAssertEqual(stale.filePairs.count, 2)
        let partial = try XCTUnwrap(reloaded.history.first { $0.source == "partial" })
        XCTAssertEqual(partial.filePairs.count, 2)
    }

    func testRestoreRecordHappyPathMovesFileBackAndMarksImmutableHistoryRestored() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)

        // 制造："trashed" 文件存在于 dir/trash/，"original" 路径在 dir/orig/ 下尚未存在（无冲突）
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        let origDir = dir.appendingPathComponent("orig", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        // 注意：origDir 故意不创建，验证 restoreRecord 会自动 createDirectory parent

        let trashedFile = trashDir.appendingPathComponent("foo.log")
        let originalFile = origDir.appendingPathComponent("foo.log")
        try "hello".write(to: trashedFile, atomically: true, encoding: .utf8)

        store.addRecord(source: "clean", filePairs: [
            .init(original: originalFile.path, trashed: trashedFile.path)
        ])
        XCTAssertEqual(store.history.count, 1)
        let record = store.history[0]

        let result = await store.restoreRecord(
            record,
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )
        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.renamedCount, 0)
        XCTAssertNil(result.firstFailure)
        // 文件已 mv 回 original，trashed 不应再存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashedFile.path))
        // v2026.07.18：成功恢复是 pair 状态，不会抹掉“这次清理发生过”的历史事实。
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history[0].filePairs, record.filePairs)
        XCTAssertEqual(store.history[0].recoveryStates, [
            .init(status: .restored, restoredDestination: originalFile.path)
        ])
        let reloaded = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(reloaded.history[0].filePairs, record.filePairs)
        XCTAssertEqual(reloaded.history[0].recoveryStates, [
            .init(status: .restored, restoredDestination: originalFile.path)
        ], "restored 是持久历史终态，重启后不能退回 missing/checking")
    }

    func testRestoreRecordPartialFailureKeepsRemainingRestorablePairs() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)

        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        let origDir = dir.appendingPathComponent("orig", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: origDir, withIntermediateDirectories: true)

        let okTrashed = trashDir.appendingPathComponent("ok.log")
        let blockedTrashed = trashDir.appendingPathComponent("blocked.log")
        let okOriginal = origDir.appendingPathComponent("ok.log")
        let blockedOriginalParent = origDir.appendingPathComponent("blocked-parent-file")
        let blockedOriginal = blockedOriginalParent.appendingPathComponent("blocked.log")

        try "ok".write(to: okTrashed, atomically: true, encoding: .utf8)
        try "blocked".write(to: blockedTrashed, atomically: true, encoding: .utf8)
        try "not-a-directory".write(to: blockedOriginalParent, atomically: true, encoding: .utf8)

        store.addRecord(source: "clean", filePairs: [
            .init(original: okOriginal.path, trashed: okTrashed.path),
            .init(original: blockedOriginal.path, trashed: blockedTrashed.path)
        ])
        let record = try XCTUnwrap(store.history.first)

        let result = await store.restoreRecord(
            record,
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertNotNil(result.firstFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: okOriginal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockedTrashed.path))
        XCTAssertEqual(store.history.count, 1, "partial 失败后不能整条移除，否则剩余文件失去恢复入口")
        XCTAssertEqual(store.history[0].filePairs, record.filePairs,
                       "部分恢复不能把已恢复 pair 从不可变操作事实中删掉")
        XCTAssertEqual(store.history[0].recoveryStates[0].status, .restored)
        XCTAssertEqual(store.history[0].recoveryStates[1].status, .available)
    }

    func testPrepareRestoreReportsConflictWithoutChangingEitherFile() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        let originalDir = dir.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)

        let trashed = trashDir.appendingPathComponent("settings.json")
        let original = originalDir.appendingPathComponent("settings.json")
        try Data("older".utf8).write(to: trashed)
        try Data("current".utf8).write(to: original)
        store.addRecord(source: "clean", filePairs: [
            .init(original: original.path, trashed: trashed.path)
        ])
        let record = try XCTUnwrap(store.history.first)

        let plan = await store.prepareRestore(record)

        XCTAssertTrue(plan.requiresConflictChoice)
        XCTAssertEqual(plan.readyCount, 0)
        XCTAssertEqual(plan.conflictPaths, [original.path])
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "current")
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "older")
    }

    func testBrokenSymlinkAtOriginalPathIsTreatedAsConflict() async throws {
        let dir = tempDir()
        let store = UndoHistoryStore(storeURL: storeURL(in: dir))
        let trashed = dir.appendingPathComponent("trash/item")
        let original = dir.appendingPathComponent("original/item")
        try FileManager.default.createDirectory(
            at: trashed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("older".utf8).write(to: trashed)
        try FileManager.default.createSymbolicLink(
            at: original,
            withDestinationURL: dir.appendingPathComponent("does-not-exist")
        )
        store.addRecord(source: "clean", filePairs: [
            .init(original: original.path, trashed: trashed.path)
        ])
        let record = try XCTUnwrap(store.history.first)

        let plan = await store.prepareRestore(record)
        XCTAssertEqual(plan.conflictPaths, [original.path])

        let result = await store.restoreRecord(
            record,
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.firstFailure, .destinationAlreadyExists(path: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: original.path),
                       dir.appendingPathComponent("does-not-exist").path)
    }

    func testSkipExistingLeavesCurrentAndTrashedFilesUntouched() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        let originalDir = dir.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)

        let trashed = trashDir.appendingPathComponent("settings.json")
        let original = originalDir.appendingPathComponent("settings.json")
        try Data("older".utf8).write(to: trashed)
        try Data("current".utf8).write(to: original)
        store.addRecord(source: "clean", filePairs: [
            .init(original: original.path, trashed: trashed.path)
        ])
        let record = try XCTUnwrap(store.history.first)

        let result = await store.restoreRecord(
            record,
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.renamedCount, 0)
        XCTAssertNotNil(result.firstFailure, "跳过冲突必须给用户可见原因")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "current")
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "older")
        XCTAssertEqual(store.history.first?.filePairs, record.filePairs,
                       "跳过后必须保留恢复记录，用户可以稍后改用新名称恢复")
    }

    func testRestoreWithUniqueNamePreservesCurrentFileAndRestoresOlderCopy() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        let originalDir = dir.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)

        let trashed = trashDir.appendingPathComponent("settings.json")
        let original = originalDir.appendingPathComponent("settings.json")
        try Data("older".utf8).write(to: trashed)
        try Data("current".utf8).write(to: original)
        store.addRecord(source: "clean", filePairs: [
            .init(original: original.path, trashed: trashed.path)
        ])
        let record = try XCTUnwrap(store.history.first)

        let notifiedPaths = LockedEventSet()
        let observer = NotificationCenter.default.addObserver(forName: .amuxUndoDidRestore, object: store, queue: nil) { notification in
            // v2026.10.08: directory enumeration resolves /var to /private/var on macOS.
            // Compare destination identities in one namespace, while still rejecting the
            // occupied original path; spelling aliases are not different restored files.
            for path in notification.userInfo?["paths"] as? [String] ?? [] {
                notifiedPaths.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = await store.restoreRecord(
            record,
            conflictPolicy: .restoreWithUniqueName,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.renamedCount, 1)
        XCTAssertNil(result.firstFailure)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "current",
                       "恢复冲突绝不能覆盖或移动用户后来创建的文件")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))

        let restoredCopies = try FileManager.default.contentsOfDirectory(
            at: originalDir,
            includingPropertiesForKeys: nil
        ).filter { $0.standardizedFileURL.path != original.standardizedFileURL.path }
        XCTAssertEqual(restoredCopies.count, 1)
        XCTAssertEqual(try String(contentsOf: restoredCopies[0], encoding: .utf8), "older")
        XCTAssertEqual(result.restoredOriginalPaths, [original.path])
        XCTAssertEqual(
            result.restoredPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [restoredCopies[0].resolvingSymlinksInPath().path]
        )
        XCTAssertTrue(notifiedPaths.contains(restoredCopies[0].resolvingSymlinksInPath().path))
        XCTAssertFalse(notifiedPaths.contains(original.resolvingSymlinksInPath().path),
                       "Only the actual restored destination may revive scan state")
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history[0].filePairs, record.filePairs)
        XCTAssertEqual(store.history[0].recoveryStates[0].status, .restored)
        XCTAssertEqual(
            store.history[0].recoveryStates[0].restoredDestination.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            },
            restoredCopies[0].resolvingSymlinksInPath().path
        )
    }

    func testMissingTrashItemRestoreRetainsFactAndMarksMissing() async throws {
        let dir = tempDir()
        let store = UndoHistoryStore(storeURL: storeURL(in: dir))
        let trash = dir.appendingPathComponent("trash-item")
        let quarantined = dir.appendingPathComponent("emptied-trash-item")
        let original = dir.appendingPathComponent("original/item")
        try Data("old".utf8).write(to: trash)
        store.addRecord(source: "clean", filePairs: [
            .init(original: original.path, trashed: trash.path)
        ])
        let record = try XCTUnwrap(store.history.first)
        try FileManager.default.moveItem(at: trash, to: quarantined)

        let result = await store.restoreRecord(
            record,
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.firstFailure, .trashedItemMissing(path: trash.path))
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history[0].filePairs, record.filePairs)
        XCTAssertEqual(store.history[0].recoveryStates[0].status, .missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let reloaded = UndoHistoryStore(storeURL: storeURL(in: dir))
        await reloaded.refreshRecoveryStates()
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history[0].recoveryStates[0].status, .missing)
    }

    func testTrashPathABAReplacementIsNeverRestored() async throws {
        let dir = tempDir()
        let store = UndoHistoryStore(storeURL: storeURL(in: dir))
        let trash = dir.appendingPathComponent("reused-name")
        let oldObject = dir.appendingPathComponent("old-object-kept-alive")
        let original = dir.appendingPathComponent("original/item")
        try Data("recorded object".utf8).write(to: trash)
        store.addRecord(source: "clean", filePairs: [
            .init(original: original.path, trashed: trash.path)
        ])
        let record = try XCTUnwrap(store.history.first)

        // 保留旧 inode，再在完全相同路径创建另一对象，稳定复现 pathname ABA。
        try FileManager.default.moveItem(at: trash, to: oldObject)
        try Data("replacement".utf8).write(to: trash)

        let result = await store.restoreRecord(
            record,
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.firstFailure, .trashedItemIdentityChanged(path: trash.path))
        XCTAssertEqual(try String(contentsOf: trash, encoding: .utf8), "replacement")
        XCTAssertEqual(try String(contentsOf: oldObject, encoding: .utf8), "recorded object")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(store.history[0].filePairs, record.filePairs)
        XCTAssertEqual(store.history[0].recoveryStates[0].status, .identityChanged)
    }

    func testLegacyJSONWithoutIdentityRefusesToRestoreCurrentPathOccupant() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let trash = dir.appendingPathComponent("legacy-path")
        let original = dir.appendingPathComponent("original/item")
        try Data("current occupant".utf8).write(to: trash)
        let recordID = UUID()
        let legacy: [[String: Any]] = [[
            "id": recordID.uuidString,
            "timestamp": "2026-07-18T00:00:00Z",
            "source": "legacy",
            "fileCount": 1,
            "filePairs": [["original": original.path, "trashed": trash.path]]
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        let store = UndoHistoryStore(storeURL: url)
        let record = try XCTUnwrap(store.history.first)
        XCTAssertNil(record.filePairs[0].trashedIdentity)
        XCTAssertEqual(record.recoveryStates[0].status, .unavailable)

        let result = await store.restoreRecord(
            record,
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.firstFailure, .trashedItemIdentityUnavailable(path: trash.path))
        XCTAssertEqual(try String(contentsOf: trash, encoding: .utf8), "current occupant")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(store.history.count, 1)
    }

    // v2026.10.14: static migration tests missed the production initializer dropping its
    // legacy URL. Exercise the same background configuration as shared, rooted only in temp.
    func testProductionBootstrapReconcilesHistoricalBrandDirectoryAcrossLaunches() async throws {
        let supportRoot = tempDir()
        let legacyURL = supportRoot.appendingPathComponent("GSYCleanMac/UndoHistory.json")
        let currentURL = supportRoot.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        let legacy = UndoHistoryStore(storeURL: legacyURL)
        legacy.addRecord(source: "before-upgrade", filePairs: [
            .init(
                original: supportRoot.appendingPathComponent("original/first").path,
                trashed: supportRoot.appendingPathComponent("trash/first").path
            )
        ])

        let firstLaunch = UndoHistoryStore(applicationSupportRoot: supportRoot)
        XCTAssertEqual(firstLaunch.storageState, .loading)
        for _ in 0..<1_000 where firstLaunch.storageState == .loading {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(firstLaunch.storageState, .ready)
        XCTAssertEqual(firstLaunch.history.map(\.source), ["before-upgrade"])
        XCTAssertEqual(try directHistorySources(at: currentURL), ["before-upgrade"])
        XCTAssertEqual(try directHistorySources(at: legacyURL), ["before-upgrade"])

        // An existing current store cannot suppress records appended by a still-running old
        // version. Reopening through the production configuration must merge both histories.
        let current = UndoHistoryStore(storeURL: currentURL)
        current.addRecord(source: "current-version", filePairs: [
            .init(
                original: supportRoot.appendingPathComponent("original/current").path,
                trashed: supportRoot.appendingPathComponent("trash/current").path
            )
        ])
        legacy.addRecord(source: "late-legacy", filePairs: [
            .init(
                original: supportRoot.appendingPathComponent("original/late").path,
                trashed: supportRoot.appendingPathComponent("trash/late").path
            )
        ])

        let nextLaunch = UndoHistoryStore(applicationSupportRoot: supportRoot)
        for _ in 0..<1_000 where nextLaunch.storageState == .loading {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(nextLaunch.storageState, .ready)
        XCTAssertEqual(nextLaunch.history.count, 3)
        XCTAssertEqual(
            Set(nextLaunch.history.map(\.source)),
            ["before-upgrade", "current-version", "late-legacy"]
        )
        XCTAssertEqual(
            try directHistorySources(at: currentURL),
            ["before-upgrade", "current-version", "late-legacy"]
        )
        XCTAssertEqual(try directHistorySources(at: legacyURL), ["before-upgrade", "late-legacy"])
    }

    func testProductionBootstrapRejectsCorruptHistoricalBrandStore() async throws {
        let supportRoot = tempDir()
        let legacyURL = supportRoot.appendingPathComponent("GSYCleanMac/UndoHistory.json")
        let currentURL = supportRoot.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corruptHistory = Data("not valid undo history".utf8)
        try corruptHistory.write(to: legacyURL)

        let loading = UndoHistoryStore(applicationSupportRoot: supportRoot)
        for _ in 0..<1_000 where loading.storageState == .loading {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(loading.storageState, .corrupt)
        XCTAssertTrue(loading.history.isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacyURL), corruptHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
    }

    func testLegacyStoreReconcilesWithoutOverwritingCurrentHistoryAndRetainsSource() throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        let legacyStore = UndoHistoryStore(storeURL: legacyURL)
        legacyStore.addRecord(source: "legacy", filePairs: [
            .init(original: "/original", trashed: "/trash")
        ])

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL
        )

        XCTAssertEqual(outcome, .migrated)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyURL.path),
            "safe-copy intentionally retains legacy because Darwin has no identity-bound unlink"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(UndoHistoryStore(storeURL: destinationURL).history.first?.source, "legacy")
        XCTAssertEqual(UndoHistoryStore(storeURL: legacyURL).history.first?.source, "legacy")

        // 新路径已有数据时，旧文件的新 UUID 必须做单调 union；不能以任何一边整体覆盖另一边。
        let secondLegacyURL = dir.appendingPathComponent("LegacyStore/second.json")
        let secondLegacy = UndoHistoryStore(storeURL: secondLegacyURL)
        secondLegacy.addRecord(source: "must-not-overwrite", filePairs: [
            .init(original: "/other-original", trashed: "/other-trash")
        ])
        let secondOutcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: secondLegacyURL,
            to: destinationURL
        )
        XCTAssertEqual(secondOutcome, .migrated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondLegacyURL.path))
        XCTAssertEqual(
            Set(UndoHistoryStore(storeURL: destinationURL).history.map(\.source)),
            Set(["legacy", "must-not-overwrite"])
        )
    }

    func testObservedLegacyRecordDoesNotReappearAfterCurrentHistoryRemovesIt() throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        let legacy = UndoHistoryStore(storeURL: legacyURL)
        legacy.addRecord(source: "legacy-visible-once", filePairs: [
            .init(original: "/original", trashed: "/trash")
        ])
        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL
            ),
            .migrated
        )

        // There is no product clear-history API today. This fixture models the required durable
        // contract for one: remove visible records but retain schema-4 reconciliation tombstones.
        // Writing an empty envelope without those tombstones would be an invalid future feature.
        var destinationObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: destinationURL)
            ) as? [String: Any]
        )
        destinationObject["records"] = []
        try JSONSerialization.data(withJSONObject: destinationObject).write(
            to: destinationURL,
            options: .atomic
        )

        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL
            ),
            .notNeeded
        )
        XCTAssertTrue(UndoHistoryStore(storeURL: destinationURL).history.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testAcknowledgedLegacyReceiptDoesNotReappearButLaterReceiptStillImports() async throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        let firstTrash = dir.appendingPathComponent("trash/first")
        let secondTrash = dir.appendingPathComponent("trash/second")
        try FileManager.default.createDirectory(
            at: firstTrash.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("first".utf8).write(to: firstTrash)
        try Data("second".utf8).write(to: secondTrash)

        func identity(at url: URL) throws -> TrashObjectIdentity {
            switch TrashObjectIdentity.probe(path: url.path) {
            case .present(let value): return value
            default: throw CocoaError(.fileReadUnknown)
            }
        }
        let firstReceipt = TrashUndoJournalEntry(
            operationID: UUID(),
            attemptID: UUID(),
            originalPath: dir.appendingPathComponent("original/first").path,
            trashedPath: firstTrash.path,
            originalIdentity: try identity(at: firstTrash),
            restoreScopeRoot: dir.path,
            recordedAt: Date(timeIntervalSince1970: 100)
        )
        let secondReceipt = TrashUndoJournalEntry(
            operationID: UUID(),
            attemptID: UUID(),
            originalPath: dir.appendingPathComponent("original/second").path,
            trashedPath: secondTrash.path,
            originalIdentity: try identity(at: secondTrash),
            restoreScopeRoot: dir.path,
            recordedAt: Date(timeIntervalSince1970: 200)
        )
        let legacy = UndoHistoryStore(storeURL: legacyURL, allowedRestoreRoots: [dir.path])
        let firstPersisted = await legacy.addJournalEntriesDurably(
            source: "legacy-first",
            entries: [firstReceipt]
        )
        XCTAssertTrue(firstPersisted)
        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL
            ),
            .migrated
        )

        let current = UndoHistoryStore(storeURL: destinationURL)
        let acknowledged = await current.acknowledgeCompletionJournal(ids: [firstReceipt.id])
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL
            ),
            .notNeeded,
            "An acknowledged receipt is intentionally absent and its observed watermark must prevent resurrection"
        )

        let secondPersisted = await legacy.addJournalEntriesDurably(
            source: "legacy-second",
            entries: [secondReceipt]
        )
        XCTAssertTrue(secondPersisted)
        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL
            ),
            .migrated
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: destinationURL)
            ) as? [String: Any]
        )
        let receipts = try XCTUnwrap(object["committedJournalIDs"] as? [String: Any])
        XCTAssertNil(receipts[firstReceipt.id])
        XCTAssertNotNil(receipts[secondReceipt.id])
    }

    func testFirstCreationWALMarkerSupportsImmediateReceiptPruneAndNextJournalCommit() async throws {
        // v2026.07.20 P0 regression: the first-create idle marker must describe the reserve
        // stage *after* its payload rewrite. This add -> acknowledge -> add sequence is the
        // shortest production-shaped proof that the next durable RMW can recover that marker.
        let dir = tempDir()
        let url = storeURL(in: dir)
        let firstTrash = dir.appendingPathComponent("trash/first")
        let secondTrash = dir.appendingPathComponent("trash/second")
        try FileManager.default.createDirectory(
            at: firstTrash.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("first".utf8).write(to: firstTrash)
        try Data("second".utf8).write(to: secondTrash)

        func entry(named name: String, trashed: URL) throws -> TrashUndoJournalEntry {
            let identity: TrashObjectIdentity
            switch TrashObjectIdentity.probe(path: trashed.path) {
            case .present(let value): identity = value
            default: throw CocoaError(.fileReadUnknown)
            }
            return TrashUndoJournalEntry(
                operationID: UUID(),
                attemptID: UUID(),
                originalPath: dir.appendingPathComponent("original/\(name)").path,
                trashedPath: trashed.path,
                originalIdentity: identity,
                restoreScopeRoot: dir.path
            )
        }

        let first = try entry(named: "first", trashed: firstTrash)
        let second = try entry(named: "second", trashed: secondTrash)
        let store = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])

        let firstPersisted = await store.addJournalEntriesDurably(
            source: "first",
            entries: [first]
        )
        XCTAssertTrue(firstPersisted)
        let firstAcknowledged = await store.acknowledgeCompletionJournal(ids: [first.id])
        XCTAssertTrue(firstAcknowledged)
        let secondPersisted = await store.addJournalEntriesDurably(
            source: "second",
            entries: [second]
        )
        XCTAssertTrue(secondPersisted)

        let reloaded = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        XCTAssertEqual(reloaded.storageState, .ready)
        XCTAssertEqual(reloaded.history.count, 2)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let receipts = try XCTUnwrap(object["committedJournalIDs"] as? [String: Any])
        XCTAssertNil(receipts[first.id])
        XCTAssertNotNil(receipts[second.id])
    }

    func testPersistedWALSurvivesMountDeviceRenumberAndNextWrite() throws {
        // v2026.07.20 P0 regression: Darwin st_dev identifies a mount instance, not a stable
        // cross-reboot volume. A valid WAL from the previous boot must retain authority when only
        // that mount number changes, while the next write normalizes the current boot's identity.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storeURL(in: dir)
        let seed = UndoHistoryStore(storeURL: url)
        for index in 0..<3 {
            seed.addRecord(source: "before-reboot-\(index)", filePairs: [
                .init(original: "/original/\(index)", trashed: "/trash/\(index)")
            ])
            seed.saveHistorySync()
        }

        let markerURLs = Array(canonicalWALURLs(nextTo: url).suffix(2))
        var metadata = stat()
        XCTAssertEqual(lstat(markerURLs[0].path, &metadata), 0)
        let currentDevice = UInt64(bitPattern: Int64(metadata.st_dev))
        let previousBootDevice = currentDevice == 0 ? 1 : currentDevice - 1
        for markerURL in markerURLs {
            try rewriteMarkerRecord(at: markerURL) { record in
                record = try XCTUnwrap(
                    replacingPersistedDevice(in: record, with: previousBootDevice)
                        as? [String: Any]
                )
            }
        }

        let recovered = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(recovered.storageState, .ready)
        XCTAssertEqual(recovered.history.count, 3)
        recovered.addRecord(source: "after-reboot", filePairs: [
            .init(original: "/original/after", trashed: "/trash/after")
        ])
        recovered.saveHistorySync()

        let reloaded = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(reloaded.storageState, .ready)
        XCTAssertEqual(reloaded.history.first?.source, "after-reboot")
    }

    func testPersistedWALStillRejectsStableMarkerIdentityMismatch() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storeURL(in: dir)
        let seed = UndoHistoryStore(storeURL: url)
        for index in 0..<3 {
            seed.addRecord(source: "record-\(index)", filePairs: [
                .init(original: "/original/\(index)", trashed: "/trash/\(index)")
            ])
            seed.saveHistorySync()
        }
        let markerURLs = Array(canonicalWALURLs(nextTo: url).suffix(2))
        let generations = markerURLs.map(markerGeneration(at:))
        let activeIndex = (generations[0] ?? 0) > (generations[1] ?? 0) ? 0 : 1
        try rewriteMarkerRecord(at: markerURLs[activeIndex]) { record in
            var identity = try XCTUnwrap(record["markerIdentity"] as? [String: Any])
            let inode = try XCTUnwrap(identity["inode"] as? NSNumber).uint64Value
            identity["inode"] = NSNumber(value: inode &+ 1)
            record["markerIdentity"] = identity
        }

        let rejected = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(rejected.storageState, .writeFailed)
        XCTAssertEqual(try directHistorySources(at: url).count, 3)
    }

    func testPersistedWALAcceptsMixedBootMarkerGenerations() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storeURL(in: dir)
        let seed = UndoHistoryStore(storeURL: url)
        for index in 0..<4 {
            seed.addRecord(source: "record-\(index)", filePairs: [
                .init(original: "/original/\(index)", trashed: "/trash/\(index)")
            ])
            seed.saveHistorySync()
        }
        let markerURLs = Array(canonicalWALURLs(nextTo: url).suffix(2))
        let generations = markerURLs.map(markerGeneration(at:))
        let olderIndex = (generations[0] ?? 0) < (generations[1] ?? 0) ? 0 : 1
        var metadata = stat()
        XCTAssertEqual(lstat(markerURLs[olderIndex].path, &metadata), 0)
        let currentDevice = UInt64(bitPattern: Int64(metadata.st_dev))
        let previousBootDevice = currentDevice == 0 ? 1 : currentDevice - 1
        try rewriteMarkerRecord(at: markerURLs[olderIndex]) { record in
            record = try XCTUnwrap(
                replacingPersistedDevice(in: record, with: previousBootDevice)
                    as? [String: Any]
            )
        }

        let recovered = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(recovered.storageState, .ready)
        XCTAssertEqual(recovered.history.first?.source, "record-3")
    }

    func testPersistedWALRejectsMixedDeviceDomainInsideOneGeneration() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storeURL(in: dir)
        let seed = UndoHistoryStore(storeURL: url)
        for index in 0..<3 {
            seed.addRecord(source: "record-\(index)", filePairs: [
                .init(original: "/original/\(index)", trashed: "/trash/\(index)")
            ])
            seed.saveHistorySync()
        }
        let markerURLs = Array(canonicalWALURLs(nextTo: url).suffix(2))
        let generations = markerURLs.map(markerGeneration(at:))
        let activeIndex = (generations[0] ?? 0) > (generations[1] ?? 0) ? 0 : 1
        try rewriteMarkerRecord(at: markerURLs[activeIndex]) { record in
            var payload = try XCTUnwrap(record["payload"] as? [String: Any])
            var version = try XCTUnwrap(payload["stageVersion"] as? [String: Any])
            var identity = try XCTUnwrap(version["objectIdentity"] as? [String: Any])
            let device = try XCTUnwrap(identity["device"] as? NSNumber).uint64Value
            identity["device"] = NSNumber(value: device == 0 ? 1 : device - 1)
            version["objectIdentity"] = identity
            payload["stageVersion"] = version
            record["payload"] = payload
        }

        XCTAssertEqual(UndoHistoryStore(storeURL: url).storageState, .writeFailed)
        XCTAssertEqual(try directHistorySources(at: url).count, 3)
    }

    func testInterruptedBootstrapSurvivesMountDeviceRenumber() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("current/UndoHistory.json")
        let legacy = UndoHistoryStore(storeURL: legacyURL)
        legacy.addRecord(source: "legacy", filePairs: [
            .init(original: "/legacy", trashed: "/trash/legacy")
        ])
        legacy.saveHistorySync()

        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL,
                transactionInterruptionHookForTesting: { $0 == "afterBootstrapStageFsync" }
            ),
            .rejected(.writeFailed)
        )
        let stage0URL = canonicalWALURLs(nextTo: destinationURL)[0]
        var metadata = stat()
        XCTAssertEqual(lstat(stage0URL.path, &metadata), 0)
        let currentDevice = UInt64(bitPattern: Int64(metadata.st_dev))
        try rewriteBootstrapRecordDevice(
            at: stage0URL,
            to: currentDevice == 0 ? 1 : currentDevice - 1
        )

        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL
            ),
            .migrated
        )
        XCTAssertEqual(UndoHistoryStore(storeURL: destinationURL).storageState, .ready)
        XCTAssertEqual(try directHistorySources(at: destinationURL), Set(["legacy"]))
    }

    func testPreparedWALSurvivesMountDeviceRenumber() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("current/UndoHistory.json")
        let legacy = UndoHistoryStore(storeURL: legacyURL)
        legacy.addRecord(source: "legacy", filePairs: [
            .init(original: "/legacy", trashed: "/trash/legacy")
        ])
        legacy.saveHistorySync()
        let current = UndoHistoryStore(storeURL: destinationURL)
        current.addRecord(source: "current", filePairs: [
            .init(original: "/current", trashed: "/trash/current")
        ])
        current.saveHistorySync()

        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL,
                transactionInterruptionHookForTesting: { $0 == "afterPreparedMarkerFsync" }
            ),
            .rejected(.writeFailed)
        )
        let markerURLs = Array(canonicalWALURLs(nextTo: destinationURL).suffix(2))
        var metadata = stat()
        XCTAssertEqual(lstat(markerURLs[0].path, &metadata), 0)
        let currentDevice = UInt64(bitPattern: Int64(metadata.st_dev))
        let previousBootDevice = currentDevice == 0 ? 1 : currentDevice - 1
        for markerURL in markerURLs {
            try rewriteMarkerRecord(at: markerURL) { record in
                record = try XCTUnwrap(
                    replacingPersistedDevice(in: record, with: previousBootDevice)
                        as? [String: Any]
                )
            }
        }

        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL
            ),
            .migrated
        )
        XCTAssertEqual(
            try directHistorySources(at: destinationURL),
            Set(["current", "legacy"])
        )
    }

    func testObservedLegacyRecordStillAcceptsMonotonicTerminalStateChange() async throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        let trashed = dir.appendingPathComponent("trash/legacy-terminal")
        let original = dir.appendingPathComponent("original/legacy-terminal")
        try FileManager.default.createDirectory(
            at: trashed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: trashed)
        let legacy = UndoHistoryStore(
            storeURL: legacyURL,
            allowedRestoreRoots: [dir.path]
        )
        legacy.addRecord(source: "legacy-terminal", filePairs: [
            .init(original: original.path, trashed: trashed.path)
        ])
        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL
            ),
            .migrated
        )

        let legacyRestore = await legacy.restoreRecord(
            try XCTUnwrap(legacy.history.first),
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )
        XCTAssertEqual(legacyRestore.restoredCount, 1)
        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL
            ),
            .migrated
        )
        let current = UndoHistoryStore(
            storeURL: destinationURL,
            allowedRestoreRoots: [dir.path]
        )
        XCTAssertEqual(current.history.first?.recoveryState(at: 0), .init(
            status: .restored,
            restoredDestination: original.path
        ))
    }

    func testLegacyMigrationRejectsSymlinkAndNeverPromotesItsTarget() throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let realURL = dir.appendingPathComponent("real-history.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        let realStore = UndoHistoryStore(storeURL: realURL)
        realStore.addRecord(source: "symlink-target", filePairs: [
            .init(original: "/original", trashed: "/trash")
        ])
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: legacyURL,
            withDestinationURL: realURL
        )

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL
        )

        XCTAssertEqual(outcome, .rejected(.readFailed))
        var metadata = stat()
        XCTAssertEqual(lstat(legacyURL.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: realURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testLegacyMigrationRejectsFIFOWithoutBlockingOrCreatingDestination() throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let creationResult = legacyURL.path.withCString {
            mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(creationResult, 0)

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL
        )

        XCTAssertEqual(outcome, .rejected(.readFailed))
        var metadata = stat()
        XCTAssertEqual(lstat(legacyURL.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFIFO)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testLegacyMigrationRejectsHardLinkedSource() throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let secondLink = dir.appendingPathComponent("legacy-second-link.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        let legacyStore = UndoHistoryStore(storeURL: legacyURL)
        legacyStore.addRecord(source: "hard-link", filePairs: [
            .init(original: "/original", trashed: "/trash")
        ])
        try FileManager.default.linkItem(at: legacyURL, to: secondLink)

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL
        )

        XCTAssertEqual(outcome, .rejected(.readFailed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondLink.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testLegacyMigrationRejectsSourceReplacementBeforeCommitAndDeletesNeitherObject() throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let heldOriginalURL = dir.appendingPathComponent("held-original.json")
        let replacementSeedURL = dir.appendingPathComponent("replacement-seed.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        let legacyStore = UndoHistoryStore(storeURL: legacyURL)
        legacyStore.addRecord(source: "original", filePairs: [
            .init(original: "/original", trashed: "/trash")
        ])
        let replacementStore = UndoHistoryStore(storeURL: replacementSeedURL)
        replacementStore.addRecord(source: "replacement", filePairs: [
            .init(original: "/replacement", trashed: "/replacement-trash")
        ])
        let replacementData = try Data(contentsOf: replacementSeedURL)

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL,
            beforeCommitHookForTesting: {
                try! FileManager.default.moveItem(at: legacyURL, to: heldOriginalURL)
                try! replacementData.write(to: legacyURL)
            }
        )

        XCTAssertEqual(outcome, .rejected(.readFailed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(
            UndoHistoryStore(storeURL: heldOriginalURL).history.first?.source,
            "original"
        )
        XCTAssertEqual(
            UndoHistoryStore(storeURL: legacyURL).history.first?.source,
            "replacement"
        )
    }

    func testLegacyMigrationDestinationRaceNeverOverwritesTargetOrDeletesSource() throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let destinationSeedURL = dir.appendingPathComponent("destination-seed.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        let legacyStore = UndoHistoryStore(storeURL: legacyURL)
        legacyStore.addRecord(source: "legacy", filePairs: [
            .init(original: "/original", trashed: "/trash")
        ])
        let destinationSeed = UndoHistoryStore(storeURL: destinationSeedURL)
        destinationSeed.addRecord(source: "raced-destination", filePairs: [
            .init(original: "/new", trashed: "/new-trash")
        ])
        let destinationData = try Data(contentsOf: destinationSeedURL)

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL,
            beforeCommitHookForTesting: {
                try! destinationData.write(to: destinationURL)
            }
        )

        XCTAssertEqual(outcome, .rejected(.writeFailed))
        XCTAssertEqual(
            UndoHistoryStore(storeURL: destinationURL).history.first?.source,
            "raced-destination"
        )
        XCTAssertEqual(UndoHistoryStore(storeURL: legacyURL).history.first?.source, "legacy")
    }

    func testLegacyWriteAfterSourceFenceConvergesNextBootstrapWithoutLosingCurrentAuthority() async throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let replacementSeedURL = dir.appendingPathComponent("replacement/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")

        let currentTrash = dir.appendingPathComponent("trash/current-restored")
        let currentOriginal = dir.appendingPathComponent("original/current-restored")
        try FileManager.default.createDirectory(
            at: currentTrash.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("current".utf8).write(to: currentTrash)
        let current = UndoHistoryStore(
            storeURL: destinationURL,
            allowedRestoreRoots: [dir.path]
        )
        current.addRecord(source: "current-restored", filePairs: [
            .init(original: currentOriginal.path, trashed: currentTrash.path)
        ])
        let restored = await current.restoreRecord(
            try XCTUnwrap(current.history.first),
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )
        XCTAssertEqual(restored.restoredCount, 1)

        let receiptTrash = dir.appendingPathComponent("trash/current-receipt")
        try Data("receipt".utf8).write(to: receiptTrash)
        let receiptIdentity: TrashObjectIdentity
        switch TrashObjectIdentity.probe(path: receiptTrash.path) {
        case .present(let value): receiptIdentity = value
        default: return XCTFail("Fixture identity must be readable")
        }
        let receipt = TrashUndoJournalEntry(
            operationID: UUID(),
            attemptID: UUID(),
            originalPath: dir.appendingPathComponent("original/current-receipt").path,
            trashedPath: receiptTrash.path,
            originalIdentity: receiptIdentity,
            restoreScopeRoot: dir.path,
            recordedAt: Date()
        )
        let receiptPersisted = await current.addJournalEntriesDurably(
            source: "current-receipt",
            entries: [receipt]
        )
        XCTAssertTrue(receiptPersisted)

        let legacy = UndoHistoryStore(storeURL: legacyURL)
        legacy.addRecord(source: "legacy-before-fence", filePairs: [
            .init(original: "/legacy/original", trashed: "/legacy/trash")
        ])
        try FileManager.default.createDirectory(
            at: replacementSeedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: legacyURL, to: replacementSeedURL)
        let lateLegacy = UndoHistoryStore(storeURL: replacementSeedURL)
        lateLegacy.addRecord(source: "legacy-after-fence", filePairs: [
            .init(original: "/legacy/late-original", trashed: "/legacy/late-trash")
        ])
        let replacementData = try Data(contentsOf: replacementSeedURL)

        let first = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL,
            afterSourceFenceHookForTesting: {
                try! replacementData.write(to: legacyURL, options: .atomic)
            }
        )
        XCTAssertEqual(first, .migrated)
        let firstSnapshot = UndoHistoryStore(
            storeURL: destinationURL,
            allowedRestoreRoots: [dir.path]
        )
        XCTAssertFalse(firstSnapshot.history.contains { $0.source == "legacy-after-fence" })
        XCTAssertEqual(
            firstSnapshot.history.first { $0.source == "current-restored" }?
                .recoveryState(at: 0),
            .init(status: .restored, restoredDestination: currentOriginal.path)
        )
        var firstObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: destinationURL)
            ) as? [String: Any]
        )
        var firstReceipts = try XCTUnwrap(
            firstObject["committedJournalIDs"] as? [String: Any]
        )
        XCTAssertNotNil(firstReceipts[receipt.id])

        // The retained replacement is the only possible authority for a non-cooperating write
        // that began after the final source fence. The next bootstrap must import its new UUID
        // while preserving destination terminal state and receipt evidence.
        let second = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL
        )
        XCTAssertEqual(second, .migrated)
        let converged = UndoHistoryStore(
            storeURL: destinationURL,
            allowedRestoreRoots: [dir.path]
        )
        XCTAssertTrue(converged.history.contains { $0.source == "legacy-after-fence" })
        XCTAssertEqual(
            converged.history.first { $0.source == "current-restored" }?
                .recoveryState(at: 0),
            .init(status: .restored, restoredDestination: currentOriginal.path)
        )
        firstObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: destinationURL)
            ) as? [String: Any]
        )
        firstReceipts = try XCTUnwrap(
            firstObject["committedJournalIDs"] as? [String: Any]
        )
        XCTAssertNotNil(firstReceipts[receipt.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testStaleStoreInstancesMergeInsteadOfLastWriterLosingHistory() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let first = UndoHistoryStore(storeURL: url)
        let staleSecond = UndoHistoryStore(storeURL: url)

        first.addRecord(source: "first-process", filePairs: [
            .init(original: "/first", trashed: "/trash/first")
        ])
        staleSecond.addRecord(source: "second-process", filePairs: [
            .init(original: "/second", trashed: "/trash/second")
        ])

        let reloaded = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(
            Set(reloaded.history.map(\.source)),
            Set(["first-process", "second-process"]),
            "Every writer must re-read and merge while holding the stable flock"
        )
    }

    func testCrashTempSweepWaitsForStableFlockAndPreservesLookalikes() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(
            storeURL: url,
            maxHistoryCount: 10,
            saveStrategy: .background
        )
        let stale = dir.appendingPathComponent(".UndoHistory.\(UUID().uuidString).tmp")
        let malformed = dir.appendingPathComponent(".UndoHistory.not-a-uuid.tmp")
        let extraSuffix = dir.appendingPathComponent(
            ".UndoHistory.\(UUID().uuidString).tmp.backup"
        )
        let protectedTarget = dir.appendingPathComponent("user-owned.json")
        let exactLookingSymlink = dir.appendingPathComponent(
            ".UndoHistory.\(UUID().uuidString).tmp"
        )
        try Data("stale".utf8).write(to: stale)
        try Data("malformed".utf8).write(to: malformed)
        try Data("keep".utf8).write(to: extraSuffix)
        try Data("user".utf8).write(to: protectedTarget)
        try FileManager.default.createSymbolicLink(
            at: exactLookingSymlink,
            withDestinationURL: protectedTarget
        )

        let lockURL = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)

        let mutationEntered = DispatchSemaphore(value: 0)
        store.setPersistenceMutationHookForTesting { kind in
            if kind == "snapshot" { mutationEntered.signal() }
        }
        store.addRecord(source: "temp-sweep", filePairs: [
            .init(original: "/original", trashed: "/trash")
        ])
        XCTAssertEqual(mutationEntered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stale.path),
            "The background mutation must wait for flock before sweeping temporary siblings"
        )

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        await store.flushPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraSuffix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exactLookingSymlink.path))
        XCTAssertEqual(try String(contentsOf: protectedTarget, encoding: .utf8), "user")
    }

    func testJournalMergeIsIdempotentAcrossStoreInstances() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let trashed = dir.appendingPathComponent("trash/item")
        try FileManager.default.createDirectory(
            at: trashed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: trashed)
        let identity: TrashObjectIdentity
        switch TrashObjectIdentity.probe(path: trashed.path) {
        case .present(let value): identity = value
        default: return XCTFail("Fixture identity must be readable")
        }
        let operationID = UUID()
        let entry = TrashUndoJournalEntry(
            operationID: operationID,
            attemptID: UUID(),
            originalPath: dir.appendingPathComponent("original/item").path,
            trashedPath: trashed.path,
            originalIdentity: identity,
            restoreScopeRoot: dir.path,
            recordedAt: Date(timeIntervalSince1970: 100)
        )
        let first = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        let staleSecond = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])

        let firstPersisted = await first.addJournalEntriesDurably(
            source: "clean",
            entries: [entry]
        )
        let secondPersisted = await staleSecond.addJournalEntriesDurably(
            source: "NSWorkspace",
            entries: [entry]
        )
        XCTAssertTrue(firstPersisted)
        XCTAssertTrue(secondPersisted)

        let reloaded = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history[0].journalOperationID, operationID)
        XCTAssertEqual(reloaded.history[0].filePairs.count, 1)
        XCTAssertEqual(reloaded.history[0].filePairs[0].journalID, entry.id)
        XCTAssertEqual(reloaded.history[0].source, "clean")
    }

    func testStaleRecoverySnapshotPreservesDurableJournalPairExtension() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storeURL(in: dir)
        let operationID = UUID()

        func makeEntry(name: String, recordedAt: TimeInterval) throws -> TrashUndoJournalEntry {
            let trashed = dir.appendingPathComponent("trash/\(name)")
            try FileManager.default.createDirectory(
                at: trashed.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(name.utf8).write(to: trashed)
            let identity: TrashObjectIdentity
            switch TrashObjectIdentity.probe(path: trashed.path) {
            case .present(let value): identity = value
            default: throw CocoaError(.fileReadUnknown)
            }
            return TrashUndoJournalEntry(
                operationID: operationID,
                attemptID: UUID(),
                originalPath: dir.appendingPathComponent("original/\(name)").path,
                trashedPath: trashed.path,
                originalIdentity: identity,
                restoreScopeRoot: dir.path,
                recordedAt: Date(timeIntervalSince1970: recordedAt)
            )
        }

        let firstEntry = try makeEntry(name: "first", recordedAt: 100)
        let secondEntry = try makeEntry(name: "second", recordedAt: 101)
        let seed = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        let seeded = await seed.addJournalEntriesDurably(source: "clean", entries: [firstEntry])
        XCTAssertTrue(seeded)

        let stale = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        let writer = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        let extended = await writer.addJournalEntriesDurably(source: "clean", entries: [secondEntry])
        XCTAssertTrue(extended)

        // Refresh persists the stale instance's one-pair projection. The locked merge must retain
        // the newer durable pair instead of classifying the valid monotonic extension as corrupt.
        await stale.refreshRecoveryStates()
        XCTAssertEqual(stale.storageState, .ready)
        XCTAssertEqual(stale.history.first?.filePairs.count, 2)

        let reloaded = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        XCTAssertEqual(
            Set(reloaded.history.first?.filePairs.compactMap(\.journalID) ?? []),
            Set([firstEntry.id, secondEntry.id])
        )
    }

    func testBackgroundBootstrapRetriesAfterSameStoreJournalExtension() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storeURL(in: dir)
        let operationID = UUID()

        func makeEntry(name: String, recordedAt: TimeInterval) throws -> TrashUndoJournalEntry {
            let trashed = dir.appendingPathComponent("trash/\(name)")
            try FileManager.default.createDirectory(
                at: trashed.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(name.utf8).write(to: trashed)
            let identity: TrashObjectIdentity
            switch TrashObjectIdentity.probe(path: trashed.path) {
            case .present(let value): identity = value
            default: throw CocoaError(.fileReadUnknown)
            }
            return TrashUndoJournalEntry(
                operationID: operationID,
                attemptID: UUID(),
                originalPath: dir.appendingPathComponent("original/\(name)").path,
                trashedPath: trashed.path,
                originalIdentity: identity,
                restoreScopeRoot: dir.path,
                recordedAt: Date(timeIntervalSince1970: recordedAt)
            )
        }

        let firstEntry = try makeEntry(name: "first", recordedAt: 100)
        let secondEntry = try makeEntry(name: "second", recordedAt: 101)
        let seed = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        let seeded = await seed.addJournalEntriesDurably(source: "clean", entries: [firstEntry])
        XCTAssertTrue(seeded)

        let loading = UndoHistoryStore(
            storeURL: url,
            saveStrategy: .background,
            loadStrategy: .background,
            allowedRestoreRoots: [dir.path]
        )
        let gate = PersistenceBootstrapGate()
        loading.setPersistenceMutationHookForTesting { kind in
            if kind == "bootstrap" { gate.enterIfFirst() }
        }
        for _ in 0..<400 where !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(gate.hasEntered)

        let append = Task {
            await loading.addJournalEntriesDurably(source: "clean", entries: [secondEntry])
        }
        // Wait until addJournalEntriesDurably has bumped its revision and enqueued behind the
        // blocked bootstrap; a timing sleep here would not prove the intended interleaving.
        for _ in 0..<400 where loading.persistenceRevisionForTesting == 0 {
            await Task.yield()
        }
        XCTAssertEqual(loading.persistenceRevisionForTesting, 1)
        gate.release()
        let appended = await append.value
        XCTAssertTrue(appended)
        // v2026.10.08: the journal append can itself publish `.ready` before the stale
        // bootstrap's MainActor continuation gets scheduled. Readiness is not evidence of
        // the required second read; wait for that hook without weakening the retry assertion.
        for _ in 0..<400 where gate.invocationCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0..<400 where loading.storageState == .loading {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(loading.storageState, .ready)
        XCTAssertGreaterThanOrEqual(gate.invocationCount, 2)
        XCTAssertEqual(loading.history.first?.filePairs.count, 2)
        XCTAssertEqual(
            Set(loading.history.first?.filePairs.compactMap(\.journalID) ?? []),
            Set([firstEntry.id, secondEntry.id])
        )
    }

    func testEachSameRecordMetadataMutationIsIndependentlyCorrupt() throws {
        func assertMutationRejected(
            _ mutate: (inout [String: Any]) -> Void,
            verifyDiskMutation: (UndoHistoryStore.Record) -> Void
        ) throws {
            let dir = tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = storeURL(in: dir)
            let stale = UndoHistoryStore(storeURL: url)
            stale.addRecord(source: "clean", filePairs: [
                .init(original: "/original", trashed: "/trash/original")
            ])

            var object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            var records = try XCTUnwrap(object["records"] as? [[String: Any]])
            mutate(&records[0])
            object["records"] = records
            try JSONSerialization.data(withJSONObject: object).write(to: url)

            stale.saveHistorySync()
            XCTAssertEqual(stale.storageState, .corrupt)
            let disk = UndoHistoryStore(storeURL: url)
            XCTAssertEqual(disk.storageState, .ready)
            verifyDiskMutation(try XCTUnwrap(disk.history.first))
        }

        try assertMutationRejected({ record in
            record["source"] = "arbitrary-rewrite"
        }, verifyDiskMutation: { record in
            XCTAssertEqual(record.source, "arbitrary-rewrite")
        })

        try assertMutationRejected({ record in
            record["timestamp"] = "2030-01-01T00:00:00Z"
        }, verifyDiskMutation: { record in
            XCTAssertEqual(record.timestamp, Date(timeIntervalSince1970: 1_893_456_000))
        })

        let rewrittenOperationID = UUID()
        try assertMutationRejected({ record in
            record["journalOperationID"] = rewrittenOperationID.uuidString
        }, verifyDiskMutation: { record in
            XCTAssertEqual(record.journalOperationID, rewrittenOperationID)
        })
    }

    func testConflictingRestoredDestinationsForSameRecordAreCorrupt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storeURL(in: dir)
        let seed = UndoHistoryStore(storeURL: url)
        seed.addRecord(source: "clean", filePairs: [
            .init(original: "/original", trashed: "/trash/original")
        ])

        func writeRestoredDestination(_ destination: String) throws {
            var object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            var records = try XCTUnwrap(object["records"] as? [[String: Any]])
            records[0]["recoveryStates"] = [[
                "status": "restored",
                "restoredDestination": destination
            ]]
            object["records"] = records
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }

        try writeRestoredDestination("/restored/first")
        let stale = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(stale.history.first?.recoveryState(at: 0).restoredDestination, "/restored/first")

        try writeRestoredDestination("/restored/second")
        stale.saveHistorySync()
        XCTAssertEqual(stale.storageState, .corrupt)
        let disk = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(
            disk.history.first?.recoveryState(at: 0).restoredDestination,
            "/restored/second"
        )
    }

    func testLegacyPathBearingPairIDMigratesAndPlaintextReceiptIsCleared() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let trashed = dir.appendingPathComponent("trash/private-item")
        let original = dir.appendingPathComponent("original/private-item")
        try FileManager.default.createDirectory(
            at: trashed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: trashed)
        let identity: TrashObjectIdentity
        switch TrashObjectIdentity.probe(path: trashed.path) {
        case .present(let value): identity = value
        default: return XCTFail("Fixture identity must be readable")
        }
        let entry = TrashUndoJournalEntry(
            operationID: UUID(),
            attemptID: UUID(),
            originalPath: original.path,
            trashedPath: trashed.path,
            originalIdentity: identity,
            restoreScopeRoot: dir.path,
            recordedAt: Date(timeIntervalSince1970: 100)
        )
        let store = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        let entryPersisted = await store.addJournalEntriesDurably(
            source: "clean",
            entries: [entry]
        )
        XCTAssertTrue(entryPersisted)

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        var record = try XCTUnwrap(records.first)
        var pairs = try XCTUnwrap(record["filePairs"] as? [[String: Any]])
        pairs[0]["journalID"] = entry.legacyPlaintextID
        record["filePairs"] = pairs
        records[0] = record
        object["records"] = records
        let receipts = try XCTUnwrap(object["committedJournalIDs"] as? [String: Any])
        let receiptDate = try XCTUnwrap(receipts[entry.id])
        object["committedJournalIDs"] = [entry.legacyPlaintextID: receiptDate]
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let migrated = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        XCTAssertEqual(migrated.storageState, .ready)
        XCTAssertEqual(migrated.history.first?.filePairs.first?.journalID, entry.id)

        let persisted = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let persistedReceipts = try XCTUnwrap(
            persisted["committedJournalIDs"] as? [String: Any]
        )
        XCTAssertTrue(persistedReceipts.isEmpty)
        let persistedRecords = try XCTUnwrap(persisted["records"] as? [[String: Any]])
        let persistedPairs = try XCTUnwrap(
            persistedRecords.first?["filePairs"] as? [[String: Any]]
        )
        XCTAssertEqual(persistedPairs.first?["journalID"] as? String, entry.id)
    }

    func testDuplicateJournalIDAcrossDifferentPairsIsTypedCorruption() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let trashed = dir.appendingPathComponent("trash/first")
        try FileManager.default.createDirectory(
            at: trashed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: trashed)
        let identity: TrashObjectIdentity
        switch TrashObjectIdentity.probe(path: trashed.path) {
        case .present(let value): identity = value
        default: return XCTFail("Fixture identity must be readable")
        }
        let entry = TrashUndoJournalEntry(
            operationID: UUID(),
            attemptID: UUID(),
            originalPath: dir.appendingPathComponent("original/first").path,
            trashedPath: trashed.path,
            originalIdentity: identity,
            restoreScopeRoot: dir.path
        )
        let store = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        let persistedEntry = await store.addJournalEntriesDurably(
            source: "clean",
            entries: [entry]
        )
        XCTAssertTrue(persistedEntry)

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        var record = try XCTUnwrap(records.first)
        var pairs = try XCTUnwrap(record["filePairs"] as? [[String: Any]])
        var duplicate = pairs[0]
        duplicate["original"] = dir.appendingPathComponent("original/second").path
        duplicate["trashed"] = dir.appendingPathComponent("trash/second").path
        pairs.append(duplicate)
        record["filePairs"] = pairs
        record["fileCount"] = 2
        var recoveryStates = try XCTUnwrap(record["recoveryStates"] as? [[String: Any]])
        recoveryStates.append(recoveryStates[0])
        record["recoveryStates"] = recoveryStates
        records[0] = record
        object["records"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let reloaded = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        XCTAssertEqual(reloaded.storageState, .corrupt)
        XCTAssertTrue(reloaded.history.isEmpty)
    }

    func testCorruptHistoryIsTypedAndNeverOverwrittenAsEmpty() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let corrupt = Data("{ definitely-not-history".utf8)
        try corrupt.write(to: url)

        let store = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(store.storageState, .corrupt)
        XCTAssertTrue(store.history.isEmpty)
        store.addRecord(source: "must-not-replace", filePairs: [
            .init(original: "/original", trashed: "/trash")
        ])

        XCTAssertEqual(store.storageState, .corrupt)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testUnreadableHistoryIsNotReportedAsEmptyReadyState() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        try Data("[]".utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0), 0)
        defer { _ = chmod(url.path, S_IRUSR | S_IWUSR) }

        let store = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(store.storageState, .readFailed)
        XCTAssertTrue(store.history.isEmpty)
    }

    func testOversizedHistoryIsRejectedBeforeDecode() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        try Data(
            repeating: 0x20,
            count: UndoHistoryStore.maximumStoreBytes + 1
        ).write(to: url)

        let store = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(
            store.storageState,
            .storeTooLarge(maxBytes: UndoHistoryStore.maximumStoreBytes)
        )
        XCTAssertTrue(store.history.isEmpty)
    }

    func testWideRecordDecodeRunsThroughAsyncBootstrapAndRejectsWholeRecord() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        try await Task.detached(priority: .utility) {
            var pairs: [[String: String]] = []
            pairs.reserveCapacity(UndoHistoryStore.maximumPairsPerRecord + 1)
            for index in 0...UndoHistoryStore.maximumPairsPerRecord {
                pairs.append([
                    "original": "/original/\(index)",
                    "trashed": "/trash/\(index)"
                ])
            }
            let object: [[String: Any]] = [[
                "id": UUID().uuidString,
                "timestamp": "2026-07-18T00:00:00Z",
                "source": "wide",
                "fileCount": pairs.count,
                "filePairs": pairs
            ]]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }.value

        let store = UndoHistoryStore(storeURL: url, loadStrategy: .background)
        XCTAssertEqual(store.storageState, .loading)
        for _ in 0..<200 where store.storageState == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            store.storageState,
            .recordRejected(maxPairs: UndoHistoryStore.maximumPairsPerRecord)
        )
        XCTAssertTrue(store.history.isEmpty, "A wide operation fact must not be silently truncated")
    }

    func testSourceSwapBetweenIdentityCheckAndRenameIsDetectedAndRolledBack() async throws {
        let dir = tempDir()
        let store = UndoHistoryStore(
            storeURL: storeURL(in: dir),
            allowedRestoreRoots: [dir.path]
        )
        let trash = dir.appendingPathComponent("trash/item")
        let displacedRecordedObject = dir.appendingPathComponent("recorded-object")
        let destination = dir.appendingPathComponent("original/item")
        try FileManager.default.createDirectory(
            at: trash.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("recorded".utf8).write(to: trash)
        store.addRecord(source: "clean", filePairs: [
            .init(original: destination.path, trashed: trash.path)
        ])
        let record = try XCTUnwrap(store.history.first)
        store.setRestoreBeforeRenameHookForTesting {
            try! FileManager.default.moveItem(at: trash, to: displacedRecordedObject)
            try! Data("replacement".utf8).write(to: trash)
        }

        let result = await store.restoreRecord(
            record,
            conflictPolicy: .skipExisting,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.firstFailure, .trashedItemIdentityChanged(path: trash.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: trash, encoding: .utf8), "replacement")
        XCTAssertEqual(
            try String(contentsOf: displacedRecordedObject, encoding: .utf8),
            "recorded"
        )
    }

    func testRestoreSideEffectSettlesAcrossUnrelatedHistoryPublication() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        let trash = dir.appendingPathComponent("trash/item")
        let destination = dir.appendingPathComponent("original/item")
        try FileManager.default.createDirectory(
            at: trash.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: trash)
        store.addRecord(source: "clean", filePairs: [
            .init(original: destination.path, trashed: trash.path)
        ])
        let record = try XCTUnwrap(store.history.first)
        let entered = LockedEventSet()
        let releaseRename = DispatchSemaphore(value: 0)
        store.setRestoreBeforeRenameHookForTesting {
            entered.insert("restore")
            _ = releaseRename.wait(timeout: .now() + 3)
        }

        let restore = Task {
            await store.restoreRecord(
                record,
                conflictPolicy: .skipExisting,
                locale: Locale(identifier: "en")
            )
        }
        for _ in 0..<400 where !entered.contains("restore") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(entered.contains("restore"))

        // Publish an equal durable envelope while the real rename owner is paused. A global
        // history-revision CAS would incorrectly discard the later restored terminal state.
        store.saveHistorySync()
        releaseRename.signal()
        let result = await restore.value

        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(store.history.first?.recoveryState(at: 0), .init(
            status: .restored,
            restoredDestination: destination.path
        ))
        let reloaded = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        XCTAssertEqual(reloaded.history.first?.recoveryState(at: 0), .init(
            status: .restored,
            restoredDestination: destination.path
        ))
    }

    func testCorruptLegacyStoreIsNotMovedOrPromoted() throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not valid undo history".utf8).write(to: legacyURL)

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL
        )

        XCTAssertEqual(outcome, .rejected(.corrupt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path),
                      "失败迁移必须保留旧数据供诊断/人工恢复")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path),
                       "损坏 JSON 不能被提升为当前存储")

        let bootstrapped = UndoHistoryStore(
            storeURL: destinationURL,
            legacyStoreURL: legacyURL
        )
        XCTAssertEqual(bootstrapped.storageState, .corrupt)
        XCTAssertTrue(bootstrapped.history.isEmpty)
    }

    func testOversizedLegacyStoreIsBoundedAndRetained() throws {
        let dir = tempDir()
        let legacyURL = dir.appendingPathComponent("LegacyStore/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("AmuxAIClean/UndoHistory.json")
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: legacyURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: legacyURL)
        try handle.truncate(atOffset: UInt64(UndoHistoryStore.maximumStoreBytes + 1))
        try handle.close()

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL
        )

        XCTAssertEqual(
            outcome,
            .rejected(.storeTooLarge(maxBytes: UndoHistoryStore.maximumStoreBytes))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testTwoStaleTenRecordInstancesKeepBothConcurrentNewestMutations() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let seed = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        for index in 0..<10 {
            seed.addRecord(source: "old\(index)", filePairs: [
                .init(original: "/old/\(index)", trashed: "/trash/old-\(index)")
            ])
        }
        let first = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        let staleSecond = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)

        first.addRecord(source: "concurrent-A", filePairs: [
            .init(original: "/new/A", trashed: "/trash/A")
        ])
        staleSecond.addRecord(source: "concurrent-B", filePairs: [
            .init(original: "/new/B", trashed: "/trash/B")
        ])

        let reloaded = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        XCTAssertEqual(reloaded.history.count, 10)
        XCTAssertTrue(reloaded.history.contains { $0.source == "concurrent-A" })
        XCTAssertTrue(reloaded.history.contains { $0.source == "concurrent-B" })
    }

    func testDuplicateRecordUUIDIsTypedCorruptionInsteadOfDictionaryTrap() throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: url)
        store.addRecord(source: "first", filePairs: [
            .init(original: "/one", trashed: "/trash/one")
        ])
        store.addRecord(source: "second", filePairs: [
            .init(original: "/two", trashed: "/trash/two")
        ])
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        records[1]["id"] = records[0]["id"]
        object["records"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let corrupted = UndoHistoryStore(storeURL: url)
        XCTAssertEqual(corrupted.storageState, .corrupt)
        XCTAssertTrue(corrupted.history.isEmpty)
    }

    func testCompletionJournalHealthUsesExactAttemptAuthorityAcrossUnrelatedAck() async throws {
        let dir = tempDir()
        let store = UndoHistoryStore(
            storeURL: storeURL(in: dir),
            allowedRestoreRoots: [dir.path]
        )
        let blockedAttemptA = TrashPendingAttemptIdentity(
            operationID: UUID(),
            attemptID: UUID()
        )
        store.reportCompletionJournalFailure(blockedAttempts: [blockedAttemptA])
        store.addRecord(source: "ordinary", filePairs: [
            .init(original: "/ordinary", trashed: "/trash/ordinary")
        ])

        XCTAssertEqual(store.storageState, .ready)
        XCTAssertEqual(store.completionJournalState, .blocked)

        // Operation B crosses a real Undo commit and receipt-prune path. Its success carries no
        // capability to clear operation A's independent ledger block.
        let trashedB = dir.appendingPathComponent("trash/operation-b")
        try FileManager.default.createDirectory(
            at: trashedB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("operation-b".utf8).write(to: trashedB)
        let identityB: TrashObjectIdentity
        switch TrashObjectIdentity.probe(path: trashedB.path) {
        case .present(let identity): identityB = identity
        default: return XCTFail("Fixture identity must be readable")
        }
        let entryB = TrashUndoJournalEntry(
            operationID: UUID(),
            attemptID: UUID(),
            originalPath: dir.appendingPathComponent("original/operation-b").path,
            trashedPath: trashedB.path,
            originalIdentity: identityB,
            restoreScopeRoot: dir.path
        )
        let persistedB = await store.addJournalEntriesDurably(
            source: "operation-b",
            entries: [entryB]
        )
        XCTAssertTrue(persistedB)
        _ = await store.acknowledgeCompletionJournal(ids: [entryB.id])
        XCTAssertEqual(store.storageState, .ready)
        XCTAssertEqual(store.completionJournalState, .blocked)

        store.synchronizeCompletionJournalAuthority(blockedAttempts: [blockedAttemptA])
        XCTAssertEqual(store.completionJournalState, .blocked)
        store.synchronizeCompletionJournalAuthority(blockedAttempts: [])
        XCTAssertEqual(store.completionJournalState, .ready)
    }

    func testDelayedPendingHealthProjectionCannotOverwriteNewerTerminalRevision() throws {
        let dir = tempDir()
        let store = UndoHistoryStore(
            storeURL: storeURL(in: dir),
            allowedRestoreRoots: [dir.path]
        )
        let attempt = TrashPendingAttemptIdentity(
            operationID: UUID(),
            attemptID: UUID()
        )
        store.synchronizeCompletionJournalAuthority(blockedAttempts: [])

        // Deterministically execute the MainActor mutations in the inverse order that two
        // non-structured callback Tasks may arrive: newer terminal first, delayed pending last.
        store.resolveCompletionJournalSettlement(
            attempts: [attempt],
            durablyBlocked: false,
            revision: 1
        )
        store.reportCompletionJournalSettlementPending(
            attempts: [attempt],
            revision: 0
        )

        XCTAssertEqual(store.completionJournalState, .ready)
        XCTAssertEqual(store.completionJournalSettlementRevisionCountForTesting, 1)
        // Production performs this eviction only after the FIFO transition queue is drained.
        store.retireCompletionJournalSettlementRevisions(attempts: [attempt])
        XCTAssertEqual(store.completionJournalSettlementRevisionCountForTesting, 0)
    }

    func testEmptyLedgerSnapshotCannotClearProcessLocalUnsettledAttempt() throws {
        let dir = tempDir()
        let store = UndoHistoryStore(
            storeURL: storeURL(in: dir),
            allowedRestoreRoots: [dir.path]
        )
        let attempt = TrashPendingAttemptIdentity(
            operationID: UUID(),
            attemptID: UUID()
        )
        store.reportCompletionJournalSettlementPending(
            attempts: [attempt],
            revision: 0
        )
        store.synchronizeCompletionJournalAuthority(blockedAttempts: [])
        XCTAssertEqual(store.completionJournalState, .blocked)

        let unrelated = TrashPendingAttemptIdentity(
            operationID: UUID(),
            attemptID: UUID()
        )
        store.resolveCompletionJournalSettlement(
            attempts: [unrelated],
            durablyBlocked: false,
            revision: 1
        )
        XCTAssertEqual(
            store.completionJournalState,
            .blocked,
            "Operation B terminal success carries no authority over operation A"
        )

        store.resolveCompletionJournalSettlement(
            attempts: [attempt],
            durablyBlocked: false,
            revision: 1
        )
        XCTAssertEqual(store.completionJournalState, .ready)
    }

    func testLegacyThreeFieldIdentityMatchesStrongerCurrentProbe() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let trash = dir.appendingPathComponent("trash/item")
        let original = dir.appendingPathComponent("original/item")
        try FileManager.default.createDirectory(
            at: trash.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: trash)
        let store = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        store.addRecord(source: "legacy", filePairs: [
            .init(original: original.path, trashed: trash.path)
        ])

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        var pairs = try XCTUnwrap(records[0]["filePairs"] as? [[String: Any]])
        var identity = try XCTUnwrap(pairs[0]["trashedIdentity"] as? [String: Any])
        identity.removeValue(forKey: "birthTimeSeconds")
        identity.removeValue(forKey: "birthTimeNanoseconds")
        identity.removeValue(forKey: "generation")
        pairs[0]["trashedIdentity"] = identity
        records[0]["filePairs"] = pairs
        object["records"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let migrated = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        let record = try XCTUnwrap(migrated.history.first)
        let plan = await migrated.prepareRestore(record)
        XCTAssertEqual(plan.readyCount, 1)
        XCTAssertTrue(plan.identityChangedTrashPaths.isEmpty)
    }

    func testSnapshotAndJournalMutationsShareOneFIFOQueueAndPublishUnion() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let original = dir.appendingPathComponent("journal-original")
        let trashed = dir.appendingPathComponent("journal-trash")
        try Data("identity".utf8).write(to: original)
        let identity: TrashObjectIdentity
        switch TrashObjectIdentity.probe(path: original.path) {
        case .present(let value): identity = value
        default: return XCTFail("Fixture identity must be readable")
        }
        let row = TrashUndoJournalEntry(
            operationID: UUID(),
            attemptID: UUID(),
            originalPath: original.path,
            trashedPath: trashed.path,
            originalIdentity: identity,
            restoreScopeRoot: dir.path
        )
        let store = UndoHistoryStore(
            storeURL: url,
            saveStrategy: .background,
            allowedRestoreRoots: [dir.path]
        )
        let entered = LockedEventSet()
        let releaseSnapshot = DispatchSemaphore(value: 0)
        store.setPersistenceMutationHookForTesting { kind in
            if kind == "snapshot" {
                entered.insert("snapshot")
                _ = releaseSnapshot.wait(timeout: .now() + 2)
            } else if kind == "journal" {
                entered.insert("journal")
            }
        }
        store.addRecord(source: "snapshot", filePairs: [
            .init(original: "/snapshot", trashed: "/trash/snapshot")
        ])
        for _ in 0..<200 where !entered.contains("snapshot") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(entered.contains("snapshot"))
        let journalTask = Task {
            await store.addJournalEntriesDurably(source: "journal", entries: [row])
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            entered.contains("journal"),
            "A journal mutation cannot overtake an earlier snapshot on another detached task"
        )
        releaseSnapshot.signal()
        let journalSucceeded = await journalTask.value
        XCTAssertTrue(journalSucceeded)
        await store.flushPendingWrites()

        XCTAssertTrue(store.history.contains { $0.source == "snapshot" })
        XCTAssertTrue(store.history.contains { $0.journalOperationID == row.operationID })
        let reloaded = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        XCTAssertTrue(reloaded.history.contains { $0.source == "snapshot" })
        XCTAssertTrue(reloaded.history.contains { $0.journalOperationID == row.operationID })
    }

    func testOlderBackgroundSnapshotCannotEraseNewerOptimisticHistory() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UndoHistoryStore(
            storeURL: storeURL(in: dir),
            saveStrategy: .background
        )
        let gate = TwoSnapshotPersistenceGate()
        let publicationAttempts = LockedEventSet()
        store.setPersistenceMutationHookForTesting { kind in
            if kind == "snapshot" { gate.enter() }
        }
        store.setPersistencePublicationHookForTesting { revision in
            publicationAttempts.insert(String(revision))
        }

        store.addRecord(source: "first", filePairs: [
            .init(original: "/first", trashed: "/trash/first")
        ])
        for _ in 0..<400 where gate.count < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(gate.count, 1)

        store.addRecord(source: "second", filePairs: [
            .init(original: "/second", trashed: "/trash/second")
        ])
        gate.releaseFirstSnapshot()
        for _ in 0..<400 where gate.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(gate.count, 2)
        // Snapshot 2 is blocked on the persistence queue, leaving snapshot 1's MainActor
        // completion free to run. It no longer owns publication after revision 2 was issued.
        for _ in 0..<400 where !publicationAttempts.contains("1") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            publicationAttempts.contains("1"),
            "The stale completion must reach the publication boundary before this assertion"
        )
        XCTAssertEqual(store.history.map(\.source), ["second", "first"])

        gate.releaseSecondSnapshot()
        await store.flushPendingWrites()
        XCTAssertEqual(store.history.map(\.source), ["second", "first"])
    }

    func testLateBackgroundBootstrapMergesWideCurrentProjectionOffMainActor() async throws {
        let dir = tempDir()
        let url = storeURL(in: dir)
        let seed = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        let widePairs = (0..<8_000).map { index in
            UndoHistoryStore.Record.FilePair(
                original: "/wide/original/\(index)",
                trashed: "/wide/trash/\(index)"
            )
        }
        seed.addRecord(source: "wide-disk", filePairs: widePairs)

        let loading = UndoHistoryStore(
            storeURL: url,
            maxHistoryCount: 10,
            saveStrategy: .background,
            loadStrategy: .background
        )
        loading.addRecord(source: "current", filePairs: [
            .init(original: "/current", trashed: "/trash/current")
        ])
        var heartbeat = 0
        while loading.storageState == .loading {
            heartbeat += 1
            await Task.yield()
        }
        await loading.flushPendingWrites()

        XCTAssertGreaterThan(heartbeat, 0)
        XCTAssertTrue(loading.history.contains { $0.source == "wide-disk" })
        XCTAssertTrue(loading.history.contains { $0.source == "current" })
    }

    func testRecoveryRefreshRevisionRestartsAfterLateBackgroundHistoryLoad() async throws {
        let dir = tempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: dir)) }
        let url = storeURL(in: dir)
        let trash = dir.appendingPathComponent("late-trash")
        try Data("recoverable".utf8).write(to: trash)

        let seed = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        seed.addRecord(source: "late-load", filePairs: [
            .init(
                original: dir.appendingPathComponent("original/item").path,
                trashed: trash.path
            )
        ])

        let loadingRevision = UndoHistoryRecoveryRefreshRevision(
            storageState: .loading,
            history: []
        )
        XCTAssertFalse(loadingRevision.shouldRefresh)

        let loading = UndoHistoryStore(
            storeURL: url,
            loadStrategy: .background,
            allowedRestoreRoots: [dir.path]
        )
        for _ in 0..<400 where loading.storageState == .loading {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(loading.storageState, .ready)
        XCTAssertEqual(loading.history.first?.recoveryState(at: 0).status, .checking)

        let loadedRevision = UndoHistoryRecoveryRefreshRevision(
            storageState: loading.storageState,
            history: loading.history
        )
        XCTAssertNotEqual(loadedRevision, loadingRevision)
        XCTAssertTrue(loadedRevision.shouldRefresh)

        await loading.refreshRecoveryStates()
        XCTAssertEqual(loading.history.first?.recoveryState(at: 0).status, .available)
        XCTAssertEqual(
            UndoHistoryRecoveryRefreshRevision(
                storageState: loading.storageState,
                history: loading.history
            ),
            loadedRevision,
            "Recovery-state publication must not recursively restart the view task"
        )
    }

    func testRecoveryRefreshIsSingleFlightAndCancelledOwnerCannotPublish() async throws {
        let dir = tempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: dir)) }
        let url = storeURL(in: dir)
        let trash = dir.appendingPathComponent("single-flight-trash")
        let movedAway = dir.appendingPathComponent("single-flight-moved")
        try Data("recoverable".utf8).write(to: trash)

        let seed = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        seed.addRecord(source: "single-flight", filePairs: [
            .init(
                original: dir.appendingPathComponent("original/item").path,
                trashed: trash.path
            )
        ])
        let store = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [dir.path])
        XCTAssertEqual(store.history.first?.recoveryState(at: 0).status, .checking)

        let gate = RecoveryRefreshProbeGate()
        store.setRecoveryRefreshProbeHookForTesting { _ in gate.enter() }
        let older = Task { await store.refreshRecoveryStates() }
        for _ in 0..<400 where !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(gate.hasEntered)

        // Change the real object while generation 1 is paused. Generation 2 must cancel and join
        // it before probing the new state; an available observation from the older owner cannot
        // race back over the authoritative missing result.
        try FileManager.default.moveItem(at: trash, to: movedAway)
        let newer = Task { await store.refreshRecoveryStates() }
        gate.release()
        await older.value
        await newer.value

        XCTAssertEqual(gate.invocationCount, 2)
        XCTAssertEqual(gate.peakConcurrency, 1)
        XCTAssertEqual(store.history.first?.recoveryState(at: 0).status, .missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedAway.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
    }

    func testLegacyMigrationBootstrapInterruptionsConvergeWithoutCreatingNewControlNames() throws {
        let boundaries = [
            "afterStage0Create",
            "afterStage1Create",
            "afterMarker0Create",
            "afterMarker1Create",
            "afterBootstrapStageFsync",
            "afterBootstrapMarkerFsync"
        ]
        for boundary in boundaries {
            let dir = tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let legacyURL = dir.appendingPathComponent("legacy/UndoHistory.json")
            let destinationURL = dir.appendingPathComponent("current/UndoHistory.json")
            let legacy = UndoHistoryStore(storeURL: legacyURL)
            legacy.addRecord(source: boundary, filePairs: [
                .init(original: "/old/\(boundary)", trashed: "/trash/\(boundary)")
            ])

            let interrupted = UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL,
                transactionInterruptionHookForTesting: { $0 == boundary }
            )
            XCTAssertEqual(interrupted, .rejected(.writeFailed), boundary)
            XCTAssertEqual(
                UndoHistoryStore.migrateLegacyStoreIfNeeded(
                    from: legacyURL,
                    to: destinationURL
                ),
                .migrated,
                boundary
            )
            XCTAssertEqual(
                UndoHistoryStore(storeURL: destinationURL).history.first?.source,
                boundary
            )
            let controlURLs = canonicalWALURLs(nextTo: destinationURL)
            XCTAssertEqual(controlURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 3)
            // First creation consumes one stage inode as canonical. The next ordinary write must
            // replenish that one fixed name instead of allocating an unbounded generation file.
            let destination = UndoHistoryStore(storeURL: destinationURL)
            destination.addRecord(source: "replenish", filePairs: [
                .init(original: "/replenish", trashed: "/trash/replenish")
            ])
            XCTAssertEqual(controlURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 4)
        }
    }

    func testPreparedWALInterruptionsRetryFromExactSnapshots() throws {
        let boundaries = [
            "afterRewritingMarkerFsync",
            "afterNewWALFsync",
            "afterOldWALFsync",
            "afterPreparedMarkerFsync"
        ]
        for boundary in boundaries {
            let dir = tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let legacyURL = dir.appendingPathComponent("legacy/UndoHistory.json")
            let destinationURL = dir.appendingPathComponent("current/UndoHistory.json")
            let legacy = UndoHistoryStore(storeURL: legacyURL)
            legacy.addRecord(source: "legacy-\(boundary)", filePairs: [
                .init(original: "/legacy", trashed: "/trash/legacy")
            ])
            let current = UndoHistoryStore(storeURL: destinationURL)
            current.addRecord(source: "current", filePairs: [
                .init(original: "/current", trashed: "/trash/current")
            ])

            XCTAssertEqual(
                UndoHistoryStore.migrateLegacyStoreIfNeeded(
                    from: legacyURL,
                    to: destinationURL,
                    transactionInterruptionHookForTesting: { $0 == boundary }
                ),
                .rejected(.writeFailed),
                boundary
            )
            XCTAssertEqual(
                UndoHistoryStore.migrateLegacyStoreIfNeeded(
                    from: legacyURL,
                    to: destinationURL
                ),
                .migrated,
                boundary
            )
            XCTAssertEqual(
                try directHistorySources(at: destinationURL),
                Set(["current", "legacy-\(boundary)"])
            )
        }
    }

    func testTornCanonicalNeverAutoRedoesPreparedWAL() throws {
        for boundary in ["afterDestinationTruncate", "afterDestinationPartialWrite"] {
            let dir = tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let legacyURL = dir.appendingPathComponent("legacy/UndoHistory.json")
            let destinationURL = dir.appendingPathComponent("current/UndoHistory.json")
            let legacy = UndoHistoryStore(storeURL: legacyURL)
            legacy.addRecord(source: "legacy", filePairs: [
                .init(original: "/legacy", trashed: "/trash/legacy")
            ])
            let current = UndoHistoryStore(storeURL: destinationURL)
            current.addRecord(source: "current", filePairs: [
                .init(original: "/current", trashed: "/trash/current")
            ])

            XCTAssertEqual(
                UndoHistoryStore.migrateLegacyStoreIfNeeded(
                    from: legacyURL,
                    to: destinationURL,
                    transactionInterruptionHookForTesting: { $0 == boundary }
                ),
                .rejected(.writeFailed),
                boundary
            )
            XCTAssertEqual(
                UndoHistoryStore.migrateLegacyStoreIfNeeded(
                    from: legacyURL,
                    to: destinationURL
                ),
                .rejected(.writeFailed),
                "Neither a zero-length canonical nor a staged-data prefix is exact old/new proof"
            )
            XCTAssertEqual(
                canonicalWALURLs(nextTo: destinationURL).filter {
                    FileManager.default.fileExists(atPath: $0.path)
                }.count,
                4,
                "Ambiguous canonical bytes must retain both data slots and both marker slots"
            )
            XCTAssertEqual(
                UndoHistoryStore(storeURL: destinationURL).storageState,
                .writeFailed
            )
        }
    }

    func testExactNewCanonicalFinishesPreparedWALAfterWriteAndFenceBoundaries() throws {
        for boundary in ["afterDestinationWrite", "afterDestinationFsync"] {
            let dir = tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let legacyURL = dir.appendingPathComponent("legacy/UndoHistory.json")
            let destinationURL = dir.appendingPathComponent("current/UndoHistory.json")
            let legacy = UndoHistoryStore(storeURL: legacyURL)
            legacy.addRecord(source: "legacy", filePairs: [
                .init(original: "/legacy", trashed: "/trash/legacy")
            ])
            let current = UndoHistoryStore(storeURL: destinationURL)
            current.addRecord(source: "current", filePairs: [
                .init(original: "/current", trashed: "/trash/current")
            ])

            XCTAssertEqual(
                UndoHistoryStore.migrateLegacyStoreIfNeeded(
                    from: legacyURL,
                    to: destinationURL,
                    transactionInterruptionHookForTesting: { $0 == boundary }
                ),
                .rejected(.writeFailed),
                boundary
            )
            XCTAssertEqual(
                UndoHistoryStore.migrateLegacyStoreIfNeeded(
                    from: legacyURL,
                    to: destinationURL
                ),
                .notNeeded,
                "An exact new canonical is the only automatic commit classification"
            )
            XCTAssertEqual(
                try directHistorySources(at: destinationURL),
                Set(["current", "legacy"])
            )
        }
    }

    func testDestinationReplacementAfterDescriptorFencePreservesExternalCanonical() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("current/UndoHistory.json")
        let heldDestinationURL = dir.appendingPathComponent("current/held-old-inode.json")
        let externalSeedURL = dir.appendingPathComponent("external/UndoHistory.json")
        let legacy = UndoHistoryStore(storeURL: legacyURL)
        legacy.addRecord(source: "legacy", filePairs: [
            .init(original: "/legacy", trashed: "/trash/legacy")
        ])
        let current = UndoHistoryStore(storeURL: destinationURL)
        current.addRecord(source: "current", filePairs: [
            .init(original: "/current", trashed: "/trash/current")
        ])
        let external = UndoHistoryStore(storeURL: externalSeedURL)
        external.addRecord(source: "external", filePairs: [
            .init(original: "/external", trashed: "/trash/external")
        ])
        let externalData = try Data(contentsOf: externalSeedURL)

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL,
            afterDestinationDescriptorFenceHookForTesting: {
                try! FileManager.default.moveItem(at: destinationURL, to: heldDestinationURL)
                try! externalData.write(to: destinationURL)
            }
        )

        XCTAssertEqual(outcome, .rejected(.writeFailed))
        XCTAssertEqual(try directHistorySources(at: destinationURL), Set(["external"]))
        XCTAssertEqual(
            try directHistorySources(at: heldDestinationURL),
            Set(["current", "legacy"]),
            "Descriptor-bound writes may update only the opened old inode after pathname replacement"
        )
        XCTAssertEqual(
            canonicalWALURLs(nextTo: destinationURL).filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            4
        )
    }

    func testDestinationReplacementBeforeDescriptorOpenPreservesOldAndExternalObjects() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("current/UndoHistory.json")
        let heldDestinationURL = dir.appendingPathComponent("current/held-before-open.json")
        let externalSeedURL = dir.appendingPathComponent("external/UndoHistory.json")
        let legacy = UndoHistoryStore(storeURL: legacyURL)
        legacy.addRecord(source: "legacy", filePairs: [
            .init(original: "/legacy", trashed: "/trash/legacy")
        ])
        let current = UndoHistoryStore(storeURL: destinationURL)
        current.addRecord(source: "current", filePairs: [
            .init(original: "/current", trashed: "/trash/current")
        ])
        let external = UndoHistoryStore(storeURL: externalSeedURL)
        external.addRecord(source: "external", filePairs: [
            .init(original: "/external", trashed: "/trash/external")
        ])
        let externalData = try Data(contentsOf: externalSeedURL)

        let outcome = UndoHistoryStore.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL,
            beforeDestinationCommitHookForTesting: {
                try! FileManager.default.moveItem(at: destinationURL, to: heldDestinationURL)
                try! externalData.write(to: destinationURL)
            }
        )

        XCTAssertEqual(outcome, .rejected(.writeFailed))
        XCTAssertEqual(try directHistorySources(at: destinationURL), Set(["external"]))
        XCTAssertEqual(
            try directHistorySources(at: heldDestinationURL),
            Set(["current"]),
            "The old destination must not be opened or rewritten after its pathname loses CAS"
        )
        XCTAssertEqual(
            canonicalWALURLs(nextTo: destinationURL).filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            4
        )
    }

    func testTwoValidMarkersAtSameGenerationAreRejectedAsConflictingAuthority() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destinationURL = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: destinationURL)
        for index in 0..<3 {
            store.addRecord(source: "record-\(index)", filePairs: [
                .init(original: "/\(index)", trashed: "/trash/\(index)")
            ])
        }
        let markerURLs = Array(canonicalWALURLs(nextTo: destinationURL).suffix(2))
        let generations = markerURLs.map(markerGeneration(at:))
        let activeIndex = (generations[0] ?? 0) > (generations[1] ?? 0) ? 0 : 1
        let inactiveIndex = activeIndex == 0 ? 1 : 0
        let activeGeneration = try XCTUnwrap(generations[activeIndex])

        var record = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURLs[inactiveIndex])
            ) as? [String: Any]
        )
        var payload = try XCTUnwrap(record["payload"] as? [String: Any])
        payload["generation"] = NSNumber(value: activeGeneration)
        record["payload"] = payload
        let material: [String: Any] = [
            "slot": try XCTUnwrap(record["slot"]),
            "markerIdentity": try XCTUnwrap(record["markerIdentity"]),
            "payload": payload
        ]
        let materialData = try JSONSerialization.data(
            withJSONObject: material,
            options: [.sortedKeys]
        )
        record["checksum"] = SHA256.hash(data: materialData)
            .map { String(format: "%02x", $0) }
            .joined()
        let conflictingData = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        let descriptor = markerURLs[inactiveIndex].path.withCString {
            Darwin.open($0, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        if descriptor >= 0 {
            let wrote = conflictingData.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return true }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            XCTAssertTrue(wrote)
            XCTAssertEqual(fsync(descriptor), 0)
            Darwin.close(descriptor)
        }

        let rejected = UndoHistoryStore(storeURL: destinationURL)
        XCTAssertEqual(rejected.storageState, .writeFailed)
        XCTAssertEqual(try directHistorySources(at: destinationURL).count, 3)
    }

    func testTornInactiveMarkerFallsBackButForeignStageFailsClosed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destinationURL = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: destinationURL)
        for index in 0..<3 {
            store.addRecord(source: "record-\(index)", filePairs: [
                .init(original: "/\(index)", trashed: "/trash/\(index)")
            ])
        }
        let controls = canonicalWALURLs(nextTo: destinationURL)
        let markerURLs = Array(controls.suffix(2))
        let generations = markerURLs.map(markerGeneration(at:))
        let activeIndex = (generations[0] ?? 0) > (generations[1] ?? 0) ? 0 : 1
        let inactiveIndex = activeIndex == 0 ? 1 : 0

        let inactiveFD = markerURLs[inactiveIndex].path.withCString {
            Darwin.open($0, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(inactiveFD, 0)
        if inactiveFD >= 0 {
            var tornByte: UInt8 = 0x7B
            XCTAssertEqual(Darwin.write(inactiveFD, &tornByte, 1), 1)
            XCTAssertEqual(fsync(inactiveFD), 0)
            Darwin.close(inactiveFD)
        }
        let recovered = UndoHistoryStore(storeURL: destinationURL)
        XCTAssertEqual(recovered.storageState, .ready)
        XCTAssertEqual(recovered.history.count, 3)

        let activeData = try Data(contentsOf: markerURLs[activeIndex])
        let activeObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: activeData) as? [String: Any]
        )
        let payload = try XCTUnwrap(activeObject["payload"] as? [String: Any])
        let stageName = try XCTUnwrap(payload["stageName"] as? String)
        let stageURL = dir.appendingPathComponent(stageName)
        let heldStageURL = dir.appendingPathComponent("held-owned-stage")
        try FileManager.default.moveItem(at: stageURL, to: heldStageURL)
        try Data("foreign-stage".utf8).write(to: stageURL)

        let rejected = UndoHistoryStore(storeURL: destinationURL)
        XCTAssertEqual(rejected.storageState, .writeFailed)
        XCTAssertEqual(try Data(contentsOf: stageURL), Data("foreign-stage".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldStageURL.path))
        XCTAssertEqual(try directHistorySources(at: destinationURL).count, 3)
    }

    func testRepeatedWritesKeepFourSecureControlFilesAndAllowOwned0644Canonical() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destinationURL = storeURL(in: dir)
        let store = UndoHistoryStore(storeURL: destinationURL, maxHistoryCount: 20)
        for index in 0..<12 {
            store.addRecord(source: "record-\(index)", filePairs: [
                .init(original: "/\(index)", trashed: "/trash/\(index)")
            ])
        }
        XCTAssertEqual(chmod(destinationURL.path, mode_t(0o644)), 0)
        store.addRecord(source: "after-0644", filePairs: [
            .init(original: "/after", trashed: "/trash/after")
        ])

        let controls = canonicalWALURLs(nextTo: destinationURL)
        XCTAssertEqual(controls.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 4)
        for url in controls {
            var metadata = stat()
            XCTAssertEqual(lstat(url.path, &metadata), 0, url.lastPathComponent)
            XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG, url.lastPathComponent)
            XCTAssertEqual(metadata.st_nlink, 1, url.lastPathComponent)
            XCTAssertEqual(metadata.st_mode & mode_t(0o777), mode_t(0o600), url.lastPathComponent)
        }
        XCTAssertEqual(
            UndoHistoryStore(storeURL: destinationURL).history.first?.source,
            "after-0644"
        )
    }

    func testAppReaderWaitsForWriterFlockAndNeverObservesTruncatedCanonical() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy/UndoHistory.json")
        let destinationURL = dir.appendingPathComponent("current/UndoHistory.json")
        let legacy = UndoHistoryStore(storeURL: legacyURL)
        legacy.addRecord(source: "legacy", filePairs: [
            .init(original: "/legacy", trashed: "/trash/legacy")
        ])
        let current = UndoHistoryStore(storeURL: destinationURL)
        current.addRecord(source: "current", filePairs: [
            .init(original: "/current", trashed: "/trash/current")
        ])

        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerFinished = DispatchGroup()
        let outcome = MigrationOutcomeBox()
        writerFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            outcome.set(UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL,
                transactionInterruptionHookForTesting: { boundary in
                    guard boundary == "afterDestinationTruncate" else { return false }
                    writerEntered.signal()
                    _ = releaseWriter.wait(timeout: .now() + 3)
                    return false
                }
            ))
            writerFinished.leave()
        }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            releaseWriter.signal()
        }

        let started = Date()
        let reader = UndoHistoryStore(storeURL: destinationURL)
        let blockedFor = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(
            blockedFor,
            0.15,
            "A cooperating App reader must wait while canonical bytes are between truncate and fsync"
        )
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(outcome.value, .migrated)
        XCTAssertEqual(reader.storageState, .ready)
        XCTAssertEqual(Set(reader.history.map(\.source)), Set(["current", "legacy"]))
    }

    func testBackgroundPersistenceCompletionPreservesResolvedRecoveryStates() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destinationURL = storeURL(in: dir)
        let trashedA = dir.appendingPathComponent("trashed-a.log")
        let trashedB = dir.appendingPathComponent("trashed-b.log")
        try Data("a".utf8).write(to: trashedA)
        try Data("b".utf8).write(to: trashedB)

        let seedStore = UndoHistoryStore(storeURL: destinationURL)
        seedStore.addRecord(source: "seed", filePairs: [
            .init(original: dir.appendingPathComponent("orig-a.log").path, trashed: trashedA.path)
        ])

        let store = UndoHistoryStore(
            storeURL: destinationURL,
            maxHistoryCount: 10,
            saveStrategy: .background
        )
        XCTAssertEqual(store.history.first?.recoveryStates.first?.status, .checking)
        await store.refreshRecoveryStates()
        XCTAssertEqual(store.history.first?.recoveryStates.first?.status, .available)

        store.addRecord(source: "second", filePairs: [
            .init(original: dir.appendingPathComponent("orig-b.log").path, trashed: trashedB.path)
        ])
        await store.flushPendingWrites()

        let seedRecord = try XCTUnwrap(store.history.first { $0.source == "seed" })
        XCTAssertEqual(
            seedRecord.recoveryStates.first?.status,
            .available,
            "后台持久化完成回写 envelope 时不得把已探测完成的 .available 状态重置回 .checking"
        )
    }
}
