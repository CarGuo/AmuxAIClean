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

    /// SECURITY.md 批级原子合同：dryRun 必须准确预演真删除语义。
    /// 混合 safe + forbid 时整批拒绝，不能把 safe 项报告成将会执行。
    func test_dryRun混合forbid路径整批原子拒绝() async throws {
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
        XCTAssertEqual(present, 0, "任一 forbid 时整批不会执行")
        XCTAssertEqual(skipped, 4, "整批所有路径都应计为未执行")
        XCTAssertNotNil(err)
        // 产品契约：dryRun 有 rejected 时，err 必须能定位到"安全策略拦截"这个语义。
        // xcstrings 里对应 key = trash.err.dryrun.safety_blocked %lld，
        // zh-Hans 值含"被安全策略拦截"，en 值含"blocked by safety policy"。
        // SwiftPM XCTest 进程默认不加载包本地化 lproj → 会拿到 raw key 名，
        // 因此此处三源都接受，锁的是"语义存在"而非"具体字面量"。
        let e = err ?? ""
        XCTAssertTrue(
            e.contains("被安全策略拦截")
                || e.contains("blocked by safety policy")
                || e.contains("safety_blocked"),
            "error 文案需含拦截语义（zh/en/raw-key 任一），实际=\(e)"
        )
    }

    func test_正式模式混合forbid整批拒绝且safe文件保持原位() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashAtomic-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(atPath: dir)) }
        let safe = dir + "/safe.txt"
        try "keep".write(toFile: safe, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let result = await pipe.moveToTrashReturningOutcome(
            paths: [safe, "/System/Library/Frameworks"],
            dryRun: false
        )

        XCTAssertEqual(result.legacy.0, 0)
        XCTAssertEqual(result.legacy.1, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safe),
                      "批内出现 forbid 后不得先移动其余安全路径")
        XCTAssertEqual(result.outcome?.movedPairs.count, 0)
        XCTAssertEqual(result.outcome?.safetyRejected.count, 2)
        XCTAssertTrue(result.outcome?.safetyRejected.contains {
            $0.path == safe && $0.reason == SafetyRejection.batchContainsForbidden.rawValue
        } == true)
    }

    func test_生产白名单子项保护父目录且不读取真实用户store() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashWhitelist-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(atPath: dir)) }
        let protectedChild = dir + "/keep/private.db"
        try FileManager.default.createDirectory(
            atPath: (protectedChild as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "keep".write(toFile: protectedChild, atomically: true, encoding: .utf8)

        let whitelist = WhitelistStore(storageURL: nil)
        await whitelist.add(path: protectedChild, reason: "test")
        let pipe = TrashPipeline(whitelistStore: whitelist)
        let result = await pipe.moveToTrashReturningOutcome(paths: [dir], dryRun: false)

        XCTAssertEqual(result.legacy.0, 0)
        XCTAssertEqual(result.legacy.1, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedChild))
        XCTAssertEqual(result.outcome?.safetyRejected.first?.reason,
                       SafetyRejection.userWhitelisted.rawValue)
    }

    /// 白名单是真实文件系统子树的保护合同，不只是一个 raw 字符串。
    /// 请求 leaf 本身不是 symlink，但它的中间父路径 alias 指向已加白目录；
    /// 没有 resolved 身份索引时，NSWorkspace 会把真实 protected/child 移入废纸篓。
    func test_生产白名单不能被中间symlink别名绕过() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GSYCleanTrashWhitelistSymlink-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }

        let protectedRoot = root.appendingPathComponent("protected", isDirectory: true)
        let protectedChild = protectedRoot.appendingPathComponent("child", isDirectory: true)
        let payload = protectedChild.appendingPathComponent("keep.bin")
        try FileManager.default.createDirectory(at: protectedChild, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: payload)

        let alias = root.appendingPathComponent("cache-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protectedRoot)
        let aliasedChild = alias.appendingPathComponent("child", isDirectory: true)
        XCTAssertEqual(
            aliasedChild.resolvingSymlinksInPath().standardizedFileURL.path,
            protectedChild.standardizedFileURL.path,
            "fixture 必须真的通过中间 symlink 解析到加白子树"
        )

        let whitelist = WhitelistStore(storageURL: nil)
        await whitelist.add(path: protectedRoot.path, reason: "symlink-contract")
        let pipe = TrashPipeline(whitelistStore: whitelist)
        let result = await pipe.moveToTrashReturningOutcome(
            paths: [aliasedChild.path],
            dryRun: true
        )

        XCTAssertEqual(result.legacy.0, 0)
        XCTAssertEqual(result.legacy.1, 1)
        XCTAssertEqual(result.outcome?.safetyRejected.first?.path, aliasedChild.path)
        XCTAssertEqual(result.outcome?.safetyRejected.first?.reason,
                       SafetyRejection.userWhitelisted.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    /// 反向重叠同样必须拦截：加白的是真实目录下的子项，
    /// 删除请求却是指向其父目录的 alias。放行 alias 父目录会连带移走加白子项。
    func test_生产白名单resolved子项会拒绝symlink父目录请求() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GSYCleanTrashWhitelistSymlinkParent-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }

        let protectedRoot = root.appendingPathComponent("protected", isDirectory: true)
        let protectedChild = protectedRoot.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedChild, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("cache-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protectedRoot)

        let whitelist = WhitelistStore(storageURL: nil)
        await whitelist.add(path: protectedChild.path, reason: "descendant-contract")
        let pipe = TrashPipeline(whitelistStore: whitelist)
        let result = await pipe.moveToTrashReturningOutcome(paths: [alias.path], dryRun: true)

        XCTAssertEqual(result.legacy.0, 0)
        XCTAssertEqual(result.legacy.1, 1)
        XCTAssertEqual(result.outcome?.safetyRejected.first?.reason,
                       SafetyRejection.userWhitelisted.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedChild.path))
    }

    /// resolved 保护仍必须遵守路径组件边界；`MyApp` 不能误伤
    /// 同级 `MyApplication`。这条防止 symlink 修复退化成字符串 hasPrefix 补丁。
    func test_partitionByForbid_白名单resolved索引保持路径组件边界() {
        let home = "/Users/foo"
        let protected = home + "/Library/Caches/MyApp"
        let sibling = home + "/Library/Caches/MyApplication"
        let result = TrashPipeline.partitionByForbid(
            paths: [sibling],
            safety: SafetyEngine(),
            whitelistPaths: [protected],
            home: home
        )

        XCTAssertEqual(result.allowed, [sibling])
        XCTAssertTrue(result.rejected.isEmpty)
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
        XCTAssertTrue(
            err?.contains("safety-blocked") == true
                || err?.contains("safety_blocked_only") == true
                || err?.contains("安全") == true,
            "error 应表达 safety-blocked 语义，实际=\(err ?? "nil")"
        )
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

    /// denied 是请求的后代时，删除请求的父目录会连带删除未扫描子树，必须整体拒绝。
    func test_partitionByForbid_accessDenied后代与请求父目录重叠时拒绝() {
        let home = "/Users/foo"
        let request = home + "/Library/Caches/MyApp"
        let deniedChild = request + "/locked/private"
        let result = TrashPipeline.partitionByForbid(
            paths: [request],
            safety: SafetyEngine(),
            accessDeniedPaths: [deniedChild],
            home: home
        )

        XCTAssertTrue(result.allowed.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, .accessDenied)
    }

    /// 请求位于 denied 目录内部时同样不可删除；权限拒绝覆盖整棵子树而不是一个节点。
    func test_partitionByForbid_请求是accessDenied后代时拒绝() {
        let home = "/Users/foo"
        let deniedParent = home + "/Library/Caches/MyApp/locked"
        let request = deniedParent + "/child/cache.db"
        let result = TrashPipeline.partitionByForbid(
            paths: [request],
            safety: SafetyEngine(),
            accessDeniedPaths: [deniedParent],
            home: home
        )

        XCTAssertTrue(result.allowed.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, .accessDenied)
    }

    /// 字符串前缀不是路径祖先关系；`MyApp` 不能误伤同级的 `MyApplication`。
    func test_partitionByForbid_accessDenied使用路径组件边界避免相似前缀误拒() {
        let home = "/Users/foo"
        let denied = home + "/Library/Caches/MyApp"
        let sibling = home + "/Library/Caches/MyApplication"
        let result = TrashPipeline.partitionByForbid(
            paths: [sibling],
            safety: SafetyEngine(),
            accessDeniedPaths: [denied],
            home: home
        )

        XCTAssertEqual(result.allowed, [sibling])
        XCTAssertTrue(result.rejected.isEmpty)
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

    /// dryRun 必须预演批级原子合同：一条 accessDenied 会让整批都不进入 present。
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
        XCTAssertEqual(present, 0, "accessDenied 是 forbid，整批都不会执行")
        XCTAssertEqual(skipped, 2)
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
        XCTAssertTrue(
            err?.contains("safety-blocked") == true
                || err?.contains("safety_blocked_only") == true
                || err?.contains("安全") == true,
            "error 应表达 safety-blocked 语义，实际=\(err ?? "nil")"
        )
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

    /// request-scoped 参数必须覆盖旧共享槽，而不是先 set 再 await 导致并发请求串值。
    func test_moveToTrashReturningOutcome_requestScopedDenied不读取共享槽() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashAtomicDenied-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: dir)) }

        let sharedDenied = dir.appendingPathComponent("shared.txt")
        let requestDenied = dir.appendingPathComponent("request.txt")
        try Data("shared".utf8).write(to: sharedDenied)
        try Data("request".utf8).write(to: requestDenied)

        let pipe = TrashPipeline()
        pipe.setAccessDeniedPaths([sharedDenied.path])
        let result = await pipe.moveToTrashReturningOutcome(
            paths: [sharedDenied.path, requestDenied.path],
            dryRun: true,
            accessDeniedPaths: [requestDenied.path]
        )

        XCTAssertEqual(result.legacy.0, 0, "request-scoped denied 触发整批原子拒绝")
        XCTAssertEqual(result.legacy.1, 2)
        let reasons = Dictionary(uniqueKeysWithValues:
            (result.outcome?.safetyRejected ?? []).map { ($0.path, $0.reason) })
        XCTAssertEqual(reasons[requestDenied.path], SafetyRejection.accessDenied.rawValue)
        XCTAssertEqual(reasons[sharedDenied.path], SafetyRejection.batchContainsForbidden.rawValue,
                       "共享槽不得串入本请求；该路径只能因批级原子性被拒")
    }

    /// 历史 force 符号即使仍被旧调用方触发，也必须保留 vendor `.forbid`。
    func test_moveToTrashForce_不能绕过vendorForbid() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashVendorForbid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: dir)) }

        let protected = dir.appendingPathComponent("protected-cache")
        try Data("protected".utf8).write(to: protected)
        let vendor = VendorRule(
            name: "SafetyContract",
            paths: [PathRule(path: protected.path, verdict: .forbid)]
        )
        let pipe = TrashPipeline(vendors: [vendor], home: dir.path)

        let result = await pipe.moveToTrashForce(paths: [protected.path], dryRun: true)

        XCTAssertEqual(result.legacy.0, 0)
        XCTAssertEqual(result.legacy.1, 1)
        XCTAssertEqual(result.outcome?.safetyRejected.first?.reason,
                       SafetyRejection.vendorPathRule.rawValue)
    }

    // MARK: - v2026.06.17 (AUDIT A2)：DeletionPipeline 协议层 setAccessDeniedPaths
    //
    // 历史背景：v1.3.zzzz Phase 3-A 协议化时给 setAccessDeniedPaths 留了 protocol extension
    // 默认 no-op，目的是不强迫每个实现都写。但 AUDIT A2 指出这是契约靠手记维系的脆弱点
    // ——"上层忘了调"会被静默放行而非 compile-error。v2026.06.17 取消默认实现，每个
    // DeletionPipeline 实现都必须显式提供（哪怕是 no-op，也要签字画押）。

    /// **场景**：MainView 收敛掉 `if let trash = pipeline as? TrashPipeline` cast 后，
    /// 直接对 `pipeline: any DeletionPipeline` 调 setAccessDeniedPaths。
    /// 自定义只接显式 no-op 的 StubPipeline 必须不影响 moveToTrash 行为——
    /// 这条防"未来某个 Stub 把 setAccessDeniedPaths 写错（如塞进类成员后干扰 moveToTrash）"。
    func test_DeletionPipeline显式no_op_stub不影响moveToTrash() async {
        // 用一个最小自定义实现：显式空实现 setAccessDeniedPaths。
        struct StubPipeline: DeletionPipeline {
            func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
                return (paths.count, 0, nil, [])
            }
            /// AUDIT A2 之后每个实现都必须显式写出；此处显式 no-op 表示 stub 不关心 accessDenied。
            func setAccessDeniedPaths(_ paths: Set<String>) { /* test stub: no-op */ }
        }
        let stub: any DeletionPipeline = StubPipeline()
        // 显式 no-op：不抛、不崩
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

    /// TrashPipeline 在自身类型上实现 setAccessDeniedPaths，paths 必须**真**入集。
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
