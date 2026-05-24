import XCTest
import SafetyKit
@testable import AppUI

final class TrashPipelineDryRunTests: XCTestCase {

    func test_dryRun遇到不存在路径计入skipped() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashDryRun-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let real = dir + "/real.txt"
        try "ok".write(toFile: real, atomically: true, encoding: .utf8)

        let missing1 = dir + "/no-such-file-1.bin"
        let missing2 = dir + "/no-such-file-2.bin"

        let pipe = TrashPipeline()
        let (present, missing, err) = await pipe.moveToTrash(
            paths: [real, missing1, missing2],
            dryRun: true
        )
        print("[dryRun-mixed] present=\(present) missing=\(missing) err=\(err ?? "nil")")
        XCTAssertEqual(present, 1)
        XCTAssertEqual(missing, 2)
        XCTAssertNotNil(err)
    }

    func test_dryRun全路径都存在时error为nil() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashDryRun-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let f1 = dir + "/a.txt"
        let f2 = dir + "/b.txt"
        let f3 = dir + "/c.txt"
        try "a".write(toFile: f1, atomically: true, encoding: .utf8)
        try "b".write(toFile: f2, atomically: true, encoding: .utf8)
        try "c".write(toFile: f3, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let (present, missing, err) = await pipe.moveToTrash(
            paths: [f1, f2, f3],
            dryRun: true
        )
        print("[dryRun-all-exist] present=\(present) missing=\(missing) err=\(err ?? "nil")")
        XCTAssertEqual(present, 3)
        XCTAssertEqual(missing, 0)
        XCTAssertNil(err)
    }

    // MARK: - M4 安全闸门

    /// M4 闸门核心：partitionByForbid 必须把 hardForbid 路径完全切走。
    /// 这是单元级的拦截策略验证，不依赖 NSWorkspace。
    func test_partitionByForbid_系统路径被拦截() {
        let safety = SafetyEngine()
        let paths = [
            "/System",
            "/System/Library/Frameworks",
            "/usr/bin/ls",
            "/etc/hosts",
            "/Applications/Safari.app",
            "/var/folders/zz/abc/T/normal-tempfile.bin"
        ]
        let r = TrashPipeline.partitionByForbid(paths: paths, safety: safety)
        XCTAssertTrue(r.allowed.contains("/var/folders/zz/abc/T/normal-tempfile.bin"),
                      "tempdir 应被允许通过")
        XCTAssertFalse(r.allowed.contains("/System"))
        XCTAssertFalse(r.allowed.contains("/usr/bin/ls"))
        XCTAssertFalse(r.allowed.contains("/etc/hosts"))
        XCTAssertFalse(r.allowed.contains("/Applications/Safari.app"))
        XCTAssertEqual(r.rejected.count, 5)
        XCTAssertTrue(r.rejected.allSatisfy { $0.reason == .hardForbidPrefix })
    }

    /// M4 闸门：含 `..` 路径穿越尝试一律拦截（dotDotInPath）。
    func test_partitionByForbid_路径穿越被拦截() {
        let safety = SafetyEngine()
        let r = TrashPipeline.partitionByForbid(
            paths: ["/Users/foo/Library/Caches/MyApp/../../../../etc/passwd"],
            safety: safety
        )
        XCTAssertTrue(r.allowed.isEmpty)
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertEqual(r.rejected.first?.reason, .dotDotInPath)
    }

    /// M4 闸门：相对路径一律拦截（不能裸传 "Caches/foo"）。
    func test_partitionByForbid_相对路径被拦截() {
        let safety = SafetyEngine()
        let r = TrashPipeline.partitionByForbid(
            paths: ["Caches/foo", "./bar", "no-leading-slash"],
            safety: safety
        )
        XCTAssertTrue(r.allowed.isEmpty)
        XCTAssertEqual(r.rejected.count, 3)
        XCTAssertTrue(r.rejected.allSatisfy { $0.reason == .relativePath })
    }

    /// M4 闸门：敏感凭证路径（~/.ssh、~/.aws 等）一律拦截。
    func test_partitionByForbid_敏感凭证被拦截() {
        let safety = SafetyEngine()
        let home = "/Users/m4test"
        let paths = [
            home + "/.ssh/id_rsa",
            home + "/.aws/credentials",
            home + "/.gnupg/pubring.kbx",
            home + "/.config/gh/hosts.yml",
            home + "/.kube/config",
            home + "/Library/Caches/MyApp/foo.bin" // 这条该放过
        ]
        let r = TrashPipeline.partitionByForbid(paths: paths, safety: safety, home: home)
        XCTAssertEqual(r.allowed, [home + "/Library/Caches/MyApp/foo.bin"])
        XCTAssertEqual(r.rejected.count, 5)
        XCTAssertTrue(r.rejected.allSatisfy { $0.reason == .sensitiveCredential })
    }

    /// M4 闸门 dryRun：混合 safe + forbid 时，forbid 路径不计入 present，只计 skipped；
    /// error 文案带"被安全策略拦截"。
    func test_dryRun混合forbid路径只统计allowed() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashSafety-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let safe1 = dir + "/safe1.txt"
        let safe2 = dir + "/safe2.txt"
        try "a".write(toFile: safe1, atomically: true, encoding: .utf8)
        try "b".write(toFile: safe2, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let (present, skipped, err) = await pipe.moveToTrash(
            paths: [safe1, "/System/Library/Frameworks", safe2, "/etc/hosts"],
            dryRun: true
        )
        XCTAssertEqual(present, 2, "只 safe1+safe2 被计入 present")
        XCTAssertEqual(skipped, 2, "/System 和 /etc 各计 skipped 一次")
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("被安全策略拦截") == true,
                      "error 文案需含拦截原因，实际=\(err ?? "nil")")
    }

    /// M4 闸门 正式模式：全部 forbid 时直接短路，不调 NSWorkspace.recycle，
    /// 也不会改变 movedCount=0、skipped=N 的语义。
    func test_正式模式全forbid时短路不调recycle() async throws {
        let pipe = TrashPipeline()
        let (moved, skipped, err) = await pipe.moveToTrash(
            paths: ["/System", "/usr", "/etc"],
            dryRun: false
        )
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, 3)
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("safety-blocked") == true,
                      "error 应以 safety-blocked 起头，实际=\(err ?? "nil")")
        XCTAssertTrue(err?.contains("hardForbidPrefix") == true,
                      "应附带机器可读首条原因 hardForbidPrefix")
    }

    /// M4 闸门：传空数组——保持原有 (0, 0, nil) 语义不变。
    func test_空数组保持0_0_nil() async throws {
        let pipe = TrashPipeline()
        let (moved, skipped, err) = await pipe.moveToTrash(paths: [], dryRun: false)
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, 0)
        XCTAssertNil(err)
    }
}

