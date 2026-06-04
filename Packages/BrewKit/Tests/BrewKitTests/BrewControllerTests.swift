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
    }

    // MARK: - 契约 3：单个 formula + 完整 INSTALL_RECEIPT 解析

    func test_单个formula_含完整receipt_全字段解析正确() throws {
        try makeFormula(name: "git-lfs", version: "3.7.0",
                        installedAt: Date(timeIntervalSince1970: 1_754_457_713),
                        installedOnRequest: true, tap: "homebrew/core")
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
        let pkgs = c.listCasks()
        XCTAssertEqual(pkgs.count, 1)
        let p = try XCTUnwrap(pkgs.first)
        XCTAssertEqual(p.name, "copilot-cli")
        XCTAssertEqual(p.version, "0.0.408")
        XCTAssertEqual(p.kind, .cask)
        XCTAssertNil(p.installedAt, "cask 没 receipt，installedAt 应为 nil")
        XCTAssertTrue(p.installedOnRequest, "cask 默认视作用户显式安装的 GUI app")
        XCTAssertNil(p.tap)
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
        let pkgs = c.listFormulae()
        XCTAssertEqual(pkgs.count, 1, "json 解析失败仍应返回 placeholder pkg")
        XCTAssertNil(pkgs[0].installedAt)
        XCTAssertFalse(pkgs[0].installedOnRequest, "失败默认 false（formula）")
        XCTAssertNil(pkgs[0].tap)
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
