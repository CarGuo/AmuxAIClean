import XCTest
@testable import AppUI

/// Step 7-5：UndoHistoryStore 单测。
///
/// 覆盖：
/// 1. addRecord 头插 + LRU + 持久化到磁盘
/// 2. loadHistory 跨实例读取（验 Codable + atomic write）
/// 3. 历史与恢复能力分离：trashedPath 消失后仍保留最近操作记录
/// 4. restoreRecord happy path：把 trashed 文件 mv 回 original，record 自动从 history 删除
/// 5. 同名冲突先形成显式 plan；skip / restore-with-new-name 都不触碰现有文件
@MainActor
final class UndoHistoryStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UHSTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storeURL(in dir: URL) -> URL {
        dir.appendingPathComponent("UndoHistory.json")
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

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode([UndoHistoryStore.Record].self, from: data)
        XCTAssertEqual(persisted.map(\.source), (30..<40).reversed().map { "src\($0)" },
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

    func testRestoreRecordHappyPathMovesFileBackAndRemovesRecord() async throws {
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
        // record 已被 history 移除
        XCTAssertEqual(store.history.count, 0)
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
        XCTAssertEqual(store.history[0].filePairs, [
            .init(original: blockedOriginal.path, trashed: blockedTrashed.path)
        ])
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
        XCTAssertTrue(store.history.isEmpty)
    }
}
