import XCTest
@testable import BrewKit

/// BrewKit MVP 端到端契约（Step 16-B）。
///
/// 全部用 tmp 目录搭 fake brew prefix（Cellar/Caskroom + INSTALL_RECEIPT.json），
/// 不依赖真机 brew 安装。每个 case 钉死一类不变量。
final class BrewControllerTests: XCTestCase {

    private var prefix: URL!

    override func setUpWithError() throws {
        prefix = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("brewkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: prefix)
    }

    // MARK: - 契约 1：detectDefault 既不命中 /opt/homebrew 也不命中 /usr/local 时...
    //         本地无法 mock 系统路径，仅断言 init(prefix:) 直接构造可工作。

    func test_init_with_prefix_可以直接构造() {
        let c = BrewController(prefix: prefix)
        XCTAssertEqual(c.prefix, prefix)
    }

    // MARK: - 契约 2：空 prefix（没 Cellar/Caskroom）返回 []

    func test_空prefix_listAll_返回空数组() {
        let c = BrewController(prefix: prefix)
        XCTAssertTrue(c.listAll().isEmpty)
        XCTAssertTrue(c.listFormulae().isEmpty)
        XCTAssertTrue(c.listCasks().isEmpty)
        // v2026.07.18 regression：两个可选安装根均不存在是可信 absence，不是读取失败。
        let result = c.listAllWithDiagnostics()
        XCTAssertEqual(result.status, .missing)
        XCTAssertTrue(result.isAuthoritativeEmpty)
        XCTAssertEqual(result.diagnostics, [])
    }

    // MARK: - 契约 3：单个 formula + 完整 INSTALL_RECEIPT 解析

    func test_单个formula_含完整receipt_全字段解析正确() throws {
        try makeFormula(name: "git-lfs", version: "3.7.0",
                        installedAt: Date(timeIntervalSince1970: 1_754_457_713),
                        installedOnRequest: true, tap: "homebrew/core")
        try Data(repeating: 0x42, count: 12_345)
            .write(to: prefix.appendingPathComponent("Cellar/git-lfs/3.7.0/bin"))
        let c = BrewController(prefix: prefix)
        let pkgs = c.listFormulae()
        XCTAssertEqual(pkgs.count, 1)
        let p = try XCTUnwrap(pkgs.first)
        XCTAssertEqual(p.name, "git-lfs")
        XCTAssertEqual(p.version, "3.7.0")
        XCTAssertEqual(p.kind, .formula)
        XCTAssertEqual(p.installedAt?.timeIntervalSince1970, 1_754_457_713)
        XCTAssertTrue(p.installedOnRequest)
        XCTAssertEqual(p.tap, "homebrew/core")
        XCTAssertGreaterThanOrEqual(p.sizeBytes, 12_345)
    }

    // MARK: - 契约 4：依赖（installed_on_request=false）正确归属

    func test_依赖类formula_installedOnRequest为false() throws {
        try makeFormula(name: "brotli", version: "1.1.0",
                        installedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        installedOnRequest: false, tap: "homebrew/core")
        let c = BrewController(prefix: prefix)
        let pkgs = c.listFormulae()
        XCTAssertEqual(pkgs.count, 1)
        XCTAssertFalse(pkgs[0].installedOnRequest, "依赖应是 false")
    }

    // MARK: - 契约 5：cask（无 INSTALL_RECEIPT.json）也能列出且默认 installedOnRequest=true

    func test_cask_无receipt_仍能列出_默认显式安装() throws {
        try makeCask(name: "copilot-cli", version: "0.0.408")
        let c = BrewController(prefix: prefix)
        let result = c.listCasksWithDiagnostics()
        let pkgs = result.packages
        XCTAssertEqual(pkgs.count, 1)
        let p = try XCTUnwrap(pkgs.first)
        XCTAssertEqual(p.name, "copilot-cli")
        XCTAssertEqual(p.version, "0.0.408")
        XCTAssertEqual(p.kind, .cask)
        XCTAssertNil(p.installedAt, "cask 没 receipt，installedAt 应为 nil")
        XCTAssertTrue(p.installedOnRequest, "cask 默认视作用户显式安装的 GUI app")
        XCTAssertNil(p.tap)
        XCTAssertEqual(result.diagnostics, [], "缺失 receipt 是预期状态，不应伪装成错误")
        XCTAssertEqual(result.status, .complete)
    }

    // MARK: - 契约 6：同一 name 多 version 全部列出

    func test_同名多version_全部列出() throws {
        try makeFormula(name: "node", version: "20.10.0",
                        installedAt: Date(), installedOnRequest: true, tap: nil)
        try makeFormula(name: "node", version: "22.1.0",
                        installedAt: Date(), installedOnRequest: true, tap: nil)
        let c = BrewController(prefix: prefix)
        let pkgs = c.listFormulae()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertEqual(Set(pkgs.map(\.version)), ["20.10.0", "22.1.0"])
    }

    // MARK: - 契约 7：损坏的 receipt（非法 json）不应让整个 prefix listing 崩溃

    func test_损坏receipt_不崩溃_其他字段降级为默认值() throws {
        try makeFormula(name: "broken", version: "1.0", receiptContents: "{ this is not json }")
        let c = BrewController(prefix: prefix)
        let result = c.listFormulaeWithDiagnostics()
        let pkgs = result.packages
        XCTAssertEqual(pkgs.count, 1, "json 解析失败仍应返回 placeholder pkg")
        XCTAssertNil(pkgs[0].installedAt)
        XCTAssertFalse(pkgs[0].installedOnRequest, "失败默认 false（formula）")
        XCTAssertNil(pkgs[0].tap)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.source, .installReceipt)
        XCTAssertEqual(result.diagnostics.first?.stage, .decodeDocument)
        XCTAssertEqual(result.diagnostics.first?.reason, .malformed)
        // v2026.07.18 regression：placeholder 仍可展示，但不能把损坏元数据标成完整。
        XCTAssertEqual(result.status, .partial)
    }

    /// v2026.07.18 regression：读取被拒绝与文件缺失不能再落入同一个静默 nil。
    func test_receipt权限拒绝_保留package并返回结构化诊断() throws {
        try makeFormula(name: "denied", version: "1.0",
                        installedAt: Date(), installedOnRequest: true, tap: nil)
        let deniedPath = prefix
            .appendingPathComponent("Cellar/denied/1.0/INSTALL_RECEIPT.json")
            .path
        let reader = BrewFileReader(read: { url in
            if url.path == deniedPath {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.fileReadNoPermission.rawValue
                )
            }
            return try Data(contentsOf: url)
        })
        let result = BrewController(prefix: prefix, fileReader: reader)
            .listFormulaeWithDiagnostics()

        XCTAssertEqual(result.packages.map(\.name), ["denied"])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.source, .installReceipt)
        XCTAssertEqual(result.diagnostics.first?.stage, .read)
        XCTAssertEqual(result.diagnostics.first?.reason, .permissionDenied)
        XCTAssertEqual(result.status, .partial)
    }

    func test_cellar枚举权限拒绝_区别于可选root缺失() {
        let cellar = prefix.appendingPathComponent("Cellar", isDirectory: true)
        let reader = BrewFileReader(
            read: { url in try Data(contentsOf: url) },
            contentsOfDirectory: { url in
                if url.path == cellar.path {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EACCES)
                    )
                }
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.fileNoSuchFile.rawValue
                )
            }
        )

        let result = BrewController(prefix: prefix, fileReader: reader)
            .listAllWithDiagnostics()

        XCTAssertEqual(result.packages, [])
        XCTAssertEqual(result.diagnostics.count, 1, "缺失 Caskroom 不报错，Cellar 权限拒绝必须保留")
        XCTAssertEqual(result.diagnostics.first?.source, .formulaInstallations)
        XCTAssertEqual(result.diagnostics.first?.stage, .enumerateRoot)
        XCTAssertEqual(result.diagnostics.first?.reason, .permissionDenied)
        // v2026.07.18 regression：无可信 package 时权限失败必须是 unavailable。
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertFalse(result.isAuthoritativeEmpty)
    }

    func test_formula版本目录枚举失败_保留其它package与局部诊断() throws {
        try makeFormula(name: "denied", version: "1.0",
                        installedAt: Date(), installedOnRequest: true, tap: nil)
        try makeFormula(name: "healthy", version: "2.0",
                        installedAt: Date(), installedOnRequest: true, tap: nil)
        let deniedNameDirectory = prefix.appendingPathComponent("Cellar/denied", isDirectory: true)
        let reader = BrewFileReader(
            read: { url in try Data(contentsOf: url) },
            contentsOfDirectory: { url in
                if url.path == deniedNameDirectory.path {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                return try FileManager.default.contentsOfDirectory(atPath: url.path)
            }
        )

        let result = BrewController(prefix: prefix, fileReader: reader)
            .listFormulaeWithDiagnostics()

        XCTAssertEqual(result.packages.map(\.name), ["healthy"])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.source, .formulaInstallations)
        XCTAssertEqual(result.diagnostics.first?.stage, .enumerateVersions)
        XCTAssertEqual(result.diagnostics.first?.reason, .unreadable)
        // v2026.07.18 regression：保留健康 package 的同时显式标记局部证据。
        XCTAssertEqual(result.status, .partial)
    }

    func test_package容量子树枚举失败_保留package但证据必须partial() throws {
        try makeFormula(name: "size-denied", version: "1.0",
                        installedAt: Date(), installedOnRequest: true, tap: nil)
        let versionDirectory = prefix.appendingPathComponent(
            "Cellar/size-denied/1.0",
            isDirectory: true
        )
        let sizeFileSystem = BrewPackageSizeFileSystem(
            contentsOfDirectory: { url in
                if url.path == versionDirectory.path {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return []
            },
            entryFacts: { _ in
                return BrewPackageSizeEntryFacts(kind: .other, allocatedBytes: nil)
            }
        )

        let result = BrewController(
            prefix: prefix,
            fileReader: .live,
            packageSizeFileSystem: sizeFileSystem
        ).listFormulaeWithDiagnostics()

        XCTAssertEqual(result.packages.map(\.name), ["size-denied"])
        XCTAssertEqual(result.packages.first?.sizeBytes, 0, "0B 只能是带 partial 的可信下界")
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.stage, .enumeratePackageSize)
        XCTAssertEqual(result.diagnostics.first?.reason, .permissionDenied)
        XCTAssertEqual(result.status, .partial)
    }

    func test_package容量子项metadata失败_保留已量到bytes并降为partial() throws {
        try makeFormula(name: "size-partial", version: "1.0",
                        installedAt: Date(), installedOnRequest: true, tap: nil)
        let versionDirectory = prefix.appendingPathComponent(
            "Cellar/size-partial/1.0",
            isDirectory: true
        )
        let good = versionDirectory.appendingPathComponent("good")
        let bad = versionDirectory.appendingPathComponent("bad")
        let sizeFileSystem = BrewPackageSizeFileSystem(
            contentsOfDirectory: { url in
                url.path == versionDirectory.path ? ["good", "bad"] : []
            },
            entryFacts: { url in
                if url.path == bad.path {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                if url.path == good.path {
                    return BrewPackageSizeEntryFacts(kind: .regularFile, allocatedBytes: 4_096)
                }
                return BrewPackageSizeEntryFacts(kind: .other, allocatedBytes: nil)
            }
        )

        let result = BrewController(
            prefix: prefix,
            fileReader: .live,
            packageSizeFileSystem: sizeFileSystem
        ).listFormulaeWithDiagnostics()

        XCTAssertEqual(result.packages.first?.sizeBytes, 4_096)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.stage, .inspectPackageSize)
        XCTAssertEqual(result.diagnostics.first?.reason, .unreadable)
        XCTAssertEqual(result.status, .partial)
    }

    // MARK: - 契约 8：listAll = formulae + casks 全部排序

    func test_listAll_formula加cask混合_按name排序() throws {
        try makeFormula(name: "zlib", version: "1.0",
                        installedAt: Date(), installedOnRequest: true, tap: nil)
        try makeFormula(name: "aria2", version: "1.0",
                        installedAt: Date(), installedOnRequest: true, tap: nil)
        try makeCask(name: "beta-cask", version: "1.0")
        let c = BrewController(prefix: prefix)
        let all = c.listAll()
        // formula 先于 cask 拼接，但每段内按 name 排序
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.name), ["aria2", "zlib", "beta-cask"])
        XCTAssertEqual(all.map(\.kind),
                       [.formula, .formula, .cask])
    }

    // MARK: - 契约 9：Hidden dotfiles（.metadata 等）正确忽略

    func test_caskroom里的_点开头目录_应被忽略() throws {
        // brew Caskroom 的 .metadata 子目录不应被认作 cask
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("Caskroom/.metadata/0.0.408",
                                              isDirectory: true),
            withIntermediateDirectories: true)
        try makeCask(name: "real-cask", version: "1.0")
        let c = BrewController(prefix: prefix)
        let casks = c.listCasks()
        XCTAssertEqual(casks.count, 1)
        XCTAssertEqual(casks[0].name, "real-cask")
    }

    func test_formula容量统计_同版本内硬链接去重且包含点brew目录() throws {
        try makeFormula(name: "git-hardlink", version: "2.45.0",
                        installedAt: Date(), installedOnRequest: true, tap: "homebrew/core")
        let verDir = prefix.appendingPathComponent("Cellar/git-hardlink/2.45.0", isDirectory: true)
        let binDir = verDir.appendingPathComponent("bin", isDirectory: true)
        let brewHiddenDir = verDir.appendingPathComponent(".brew", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brewHiddenDir, withIntermediateDirectories: true)

        let binary = binDir.appendingPathComponent("git")
        try Data(repeating: 0xAA, count: 65_536).write(to: binary)
        try FileManager.default.linkItem(at: binary, to: binDir.appendingPathComponent("git-receive-pack"))
        try FileManager.default.linkItem(at: binary, to: binDir.appendingPathComponent("git-upload-pack"))

        let formulaRB = brewHiddenDir.appendingPathComponent("git-hardlink.rb")
        try Data(repeating: 0xBB, count: 16_384).write(to: formulaRB)

        let pkgs = BrewController(prefix: prefix).listFormulae()
        let pkg = try XCTUnwrap(pkgs.first { $0.name == "git-hardlink" })
        let binAlloc = (try? binary.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 65_536
        let rbAlloc = (try? formulaRB.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 16_384
        let receiptAlloc = (try? verDir.appendingPathComponent("INSTALL_RECEIPT.json").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        XCTAssertEqual(pkg.sizeBytes, Int64(binAlloc + rbAlloc + receiptAlloc),
                       "同版本目录内的硬链接二进制只应统计一次，且 .brew 子目录应被计入")
    }

    func test_symlinkedCellarOrFormulaOrVersionDirectory_isNotFollowed() throws {
        let external = prefix.appendingPathComponent("external-target", isDirectory: true)
        let externalVer = external.appendingPathComponent("evil/1.0", isDirectory: true)
        try FileManager.default.createDirectory(at: externalVer, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 4096).write(to: externalVer.appendingPathComponent("payload"))

        // 1) Formula name directory is a symlink -> ignored
        try makeFormula(name: "real-pkg", version: "1.0",
                        installedAt: Date(), installedOnRequest: true, tap: "homebrew/core")
        try FileManager.default.createSymbolicLink(
            at: prefix.appendingPathComponent("Cellar/evil-pkg"),
            withDestinationURL: external.appendingPathComponent("evil")
        )
        // 2) Version directory is a symlink -> ignored
        try FileManager.default.createSymbolicLink(
            at: prefix.appendingPathComponent("Cellar/real-pkg/2.0-symlink"),
            withDestinationURL: externalVer
        )

        let controller = BrewController(prefix: prefix)
        let formulae = controller.listFormulae()
        XCTAssertEqual(formulae.count, 1)
        XCTAssertEqual(formulae.first?.name, "real-pkg")
        XCTAssertEqual(formulae.first?.version, "1.0")

        // 3) Entire Caskroom is a symlink -> treated as missing
        try FileManager.default.createSymbolicLink(
            at: prefix.appendingPathComponent("Caskroom"),
            withDestinationURL: external
        )
        let caskResult = controller.listCasksWithDiagnostics()
        XCTAssertTrue(caskResult.packages.isEmpty)
        XCTAssertEqual(caskResult.status, .missing)
    }

    // MARK: - helpers

    private func makeFormula(name: String, version: String,
                             installedAt: Date,
                             installedOnRequest: Bool,
                             tap: String?) throws {
        let dir = prefix.appendingPathComponent("Cellar/\(name)/\(version)",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var receipt: [String: Any] = [
            "time": installedAt.timeIntervalSince1970,
            "installed_on_request": installedOnRequest,
        ]
        if let tap {
            receipt["source"] = [
                "spec": "stable",
                "versions": ["stable": version],
                "tap": tap,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: receipt, options: .prettyPrinted)
        try data.write(to: dir.appendingPathComponent("INSTALL_RECEIPT.json"))
    }

    private func makeFormula(name: String, version: String, receiptContents: String) throws {
        let dir = prefix.appendingPathComponent("Cellar/\(name)/\(version)",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try receiptContents.write(to: dir.appendingPathComponent("INSTALL_RECEIPT.json"),
                                  atomically: true, encoding: .utf8)
    }

    private func makeCask(name: String, version: String) throws {
        let dir = prefix.appendingPathComponent("Caskroom/\(name)/\(version)",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
