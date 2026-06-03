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
        let (present, missing, err, _) = await pipe.moveToTrash(
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
        let (present, missing, err, _) = await pipe.moveToTrash(
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
        let (present, skipped, err, _) = await pipe.moveToTrash(
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
        let (moved, skipped, err, _) = await pipe.moveToTrash(
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
        let (moved, skipped, err, _) = await pipe.moveToTrash(paths: [], dryRun: false)
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, 0)
        XCTAssertNil(err)
    }

    // MARK: - v1.3.zzzz Phase 2-B：accessDenied 一票否决

    /// 上层注入的 accessDeniedPaths 命中即拒、reason=`.accessDenied`，且**不再走 SafetyEngine**。
    /// 即使是个看起来 safe 的临时目录路径，只要被列入 accessDeniedPaths 也会被以 .accessDenied 拒绝。
    func test_partitionByForbid_accessDeniedPaths硬否决_不走SafetyEngine() {
        let safety = SafetyEngine()
        let denied = "/Users/foo/Library/Caches/MyApp/locked-subdir"
        let allowed = "/Users/foo/Library/Caches/MyApp/normal-subdir"
        let r = TrashPipeline.partitionByForbid(
            paths: [denied, allowed],
            safety: safety,
            accessDeniedPaths: [denied],
            home: "/Users/foo"
        )
        XCTAssertEqual(r.allowed, [allowed])
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertEqual(r.rejected.first?.path, denied)
        XCTAssertEqual(r.rejected.first?.reason, .accessDenied,
                       "accessDenied 应以新增的 .accessDenied 原因区分，便于审计/日志")
    }

    /// 同一路径既在 accessDeniedPaths 也命中 SafetyEngine forbid（hardForbidPrefix）时，
    /// **优先级**：accessDenied 高于 forbid，reason 必须是 .accessDenied 而非 .hardForbidPrefix。
    /// 这是为了避免日志里把"上层一票否决"误归为 SafetyEngine 拦截。
    func test_partitionByForbid_accessDenied优先级高于forbid() {
        let safety = SafetyEngine()
        let p = "/System/Library/Frameworks"
        let r = TrashPipeline.partitionByForbid(
            paths: [p],
            safety: safety,
            accessDeniedPaths: [p]
        )
        XCTAssertTrue(r.allowed.isEmpty)
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertEqual(r.rejected.first?.reason, .accessDenied,
                       "accessDenied 优先；不应被覆盖为 .hardForbidPrefix")
    }

    /// dryRun：accessDenied 路径不会进 present 计数，只进 skipped；error 文案附带 accessDenied 首因。
    func test_dryRun_accessDenied路径不计入present() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashAcc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let safe1 = dir + "/safe1.txt"
        let denied1 = dir + "/locked.txt"
        try "a".write(toFile: safe1, atomically: true, encoding: .utf8)
        try "b".write(toFile: denied1, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        pipe.setAccessDeniedPaths([denied1])
        let (present, skipped, err, _) = await pipe.moveToTrash(
            paths: [safe1, denied1],
            dryRun: true
        )
        XCTAssertEqual(present, 1, "只 safe1 应进 present；denied1 即使存在也算 skipped")
        XCTAssertEqual(skipped, 1)
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("accessDenied") == true,
                      "error 应附带首条原因 accessDenied，实际=\(err ?? "nil")")
    }

    /// 正式模式：全部 accessDenied 时短路，不调 NSWorkspace.recycle；
    /// movedCount=0、skipped=N、error 以 safety-blocked 起头并附 accessDenied。
    func test_正式模式全accessDenied时短路不调recycle() async throws {
        let pipe = TrashPipeline()
        let denied = ["/Users/foo/Library/Application Support/SystemMigration/.locked",
                      "/Users/foo/Library/CloudStorage/iCloud Drive (Archive)"]
        pipe.setAccessDeniedPaths(Set(denied))
        let (moved, skipped, err, _) = await pipe.moveToTrash(paths: denied, dryRun: false)
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, denied.count)
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("safety-blocked") == true,
                      "error 应以 safety-blocked 起头，实际=\(err ?? "nil")")
        XCTAssertTrue(err?.contains("accessDenied") == true,
                      "应附带机器可读首条原因 accessDenied")
    }

    /// 默认情况下（未注入 accessDeniedPaths），新参数不应改变历史行为。
    func test_partitionByForbid_默认空accessDenied不影响历史行为() {
        let safety = SafetyEngine()
        let p = "/var/folders/zz/abc/T/normal-tempfile.bin"
        let r1 = TrashPipeline.partitionByForbid(paths: [p], safety: safety)
        let r2 = TrashPipeline.partitionByForbid(paths: [p], safety: safety, accessDeniedPaths: [])
        XCTAssertEqual(r1.allowed, r2.allowed)
        XCTAssertEqual(r1.rejected.count, r2.rejected.count)
    }

    // MARK: - v1.3.zzzz Phase 2-F-A：firmlink 路径标准化

    /// **场景**：BulkScanner 给的 deniedPaths 形态是 `/private/var/folders/...`（macOS firmlink 实际路径），
    /// selectedRows 给的 url.path 形态是 `/var/folders/...`（Foundation 默认折叠形态）。
    /// 标准化前 `Set.contains` 落空 → 漏拦。
    /// 标准化后 partitionByForbid 应把两种形态视为等价，**任一侧标准化都能命中**。
    func test_partitionByForbid_firmlink私有var形态命中折叠后的var形态() {
        let safety = SafetyEngine()
        // accessDeniedPaths 给 /private/var/... 形态（BulkScanner 期间拿到的真实路径）
        let denied: Set<String> = ["/private/var/folders/zz/abc/T/locked-app-cache"]
        // selectedRows 给的 url.path 形态是 /var/folders/...（Foundation 默认）
        let selected = "/var/folders/zz/abc/T/locked-app-cache"
        let r = TrashPipeline.partitionByForbid(
            paths: [selected],
            safety: safety,
            accessDeniedPaths: denied
        )
        XCTAssertEqual(r.allowed.count, 0, "/var/.. 形态的 selected 应被 /private/var/.. 形态的 denied 命中")
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertEqual(r.rejected.first?.reason, .accessDenied)
        XCTAssertEqual(r.rejected.first?.path, selected,
                       "rejected 应保留原始路径形态便于 UI/日志展示，而非替换为标准化形态")
    }

    /// 反向同理：denied 给 /var/... 折叠形态，selected 给 /private/var/... 真实形态，也要命中。
    func test_partitionByForbid_firmlink折叠var形态命中私有var形态() {
        let safety = SafetyEngine()
        let denied: Set<String> = ["/var/folders/zz/abc/T/another-locked"]
        let selected = "/private/var/folders/zz/abc/T/another-locked"
        let r = TrashPipeline.partitionByForbid(
            paths: [selected],
            safety: safety,
            accessDeniedPaths: denied
        )
        XCTAssertEqual(r.allowed.count, 0)
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertEqual(r.rejected.first?.reason, .accessDenied)
    }

    /// setAccessDeniedPaths 入集时已经标准化：snapshotAccessDeniedPaths 出来的应该是折叠后的形态。
    /// 验证 normalize-on-write 已生效；这是为了让 lookups 走的循环里 normalize 是幂等空操作。
    func test_setAccessDeniedPaths_注入时即标准化为var折叠形态() {
        let pipe = TrashPipeline()
        pipe.setAccessDeniedPaths([
            "/private/var/folders/zz/abc/T/x",
            "/var/folders/zz/abc/T/y",
            "/Users/foo/Library/Caches/MyApp"
        ])
        let snap = pipe.snapshotAccessDeniedPaths()
        XCTAssertTrue(snap.contains("/var/folders/zz/abc/T/x"),
                      "/private/var/.. 入集后应折叠为 /var/..；snap=\(snap)")
        XCTAssertTrue(snap.contains("/var/folders/zz/abc/T/y"),
                      "/var/.. 入集后应保持 /var/..")
        XCTAssertTrue(snap.contains("/Users/foo/Library/Caches/MyApp"),
                      "非 firmlink 路径应原样保留")
    }

    // MARK: - v1.3.zzzz Phase 3-A：DeletionPipeline 协议层 setAccessDeniedPaths

    /// **场景**：MainView 收敛掉 `if let trash = pipeline as? TrashPipeline` cast 后，
    /// 直接对 `pipeline: any DeletionPipeline` 调 setAccessDeniedPaths。
    /// 自定义没显式实现该方法的 DeletionPipeline 实现（如下面的 StubPipeline）应走协议默认 no-op，
    /// **不应崩、不应抛**——这是协议层契约（v1.3.zzzz 路线 B 删 Helper 后真实运行时实际只剩 TrashPipeline 一份；
    /// 此 case 仍保留，防止未来新加 DeletionPipeline 实现忘了走默认 no-op 的回归）。
    func test_DeletionPipeline协议默认setAccessDeniedPaths为无操作() async {
        // 用一个最小自定义实现：除 moveToTrash 外什么都不写，验证协议默认 no-op 生效。
        struct StubPipeline: DeletionPipeline {
            func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
                return (paths.count, 0, nil, [])
            }
        }
        let stub: any DeletionPipeline = StubPipeline()
        // 默认 no-op：不抛、不崩
        stub.setAccessDeniedPaths([
            "/private/var/folders/zz/abc/T/x",
            "/var/folders/zz/abc/T/y",
        ])
        // moveToTrash 行为不受影响
        let (present, skipped, err, _) = await stub.moveToTrash(paths: ["/a", "/b"], dryRun: true)
        XCTAssertEqual(present, 2)
        XCTAssertEqual(skipped, 0)
        XCTAssertNil(err)
    }

    /// TrashPipeline 自己 override 了协议默认实现，setAccessDeniedPaths 必须**真**入集。
    /// 这条与 [test_setAccessDeniedPaths_注入时即标准化为var折叠形态] 互补：
    /// 这里走 `any DeletionPipeline` 静态分派，验证 dynamic dispatch 仍命中 TrashPipeline 实现。
    func test_TrashPipeline作为DeletionPipeline时setAccessDeniedPaths真入集() {
        let pipe: any DeletionPipeline = TrashPipeline()
        pipe.setAccessDeniedPaths(["/private/var/folders/test/A"])
        // 通过 cast 回 TrashPipeline 才能读 snapshot（snapshot 是包内可见，不是协议方法）
        let trash = pipe as! TrashPipeline
        let snap = trash.snapshotAccessDeniedPaths()
        XCTAssertEqual(snap, ["/var/folders/test/A"],
                       "走 protocol 类型调用时仍应命中 TrashPipeline 真实现 + firmlink 折叠；snap=\(snap)")
    }
}

