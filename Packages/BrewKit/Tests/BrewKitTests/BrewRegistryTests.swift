import XCTest
@testable import BrewKit

/// Step 16-B2 —— BrewRegistry 解析 `*.jws.json` + Controller outdated 判定。
final class BrewRegistryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("brewkit-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 契约 1：formula payload 二级 JSON 解出 name+versions.stable

    func test_parseFormula_提取所有name_versions_stable() throws {
        let inner = """
        [{"name":"a2ps","versions":{"stable":"4.15.8"}},\
        {"name":"git-lfs","versions":{"stable":"3.7.1"}}]
        """
        try writeJWS(payload: inner, to: root.appendingPathComponent("formula.jws.json"))
        let registry = BrewRegistry.load(cacheDirectory: root)
        XCTAssertEqual(registry.formulaLatest["a2ps"], "4.15.8")
        XCTAssertEqual(registry.formulaLatest["git-lfs"], "3.7.1")
        XCTAssertEqual(registry.formulaLatest.count, 2)
    }

    // MARK: - 契约 2：cask payload 解 token + version（注意字段名差异）

    func test_parseCask_提取所有token_version() throws {
        let inner = """
        [{"token":"0-ad","version":"0.28.0"},\
        {"token":"copilot-cli","version":"0.0.500"}]
        """
        try writeJWS(payload: inner, to: root.appendingPathComponent("cask.jws.json"))
        let registry = BrewRegistry.load(cacheDirectory: root)
        XCTAssertEqual(registry.caskLatest["0-ad"], "0.28.0")
        XCTAssertEqual(registry.caskLatest["copilot-cli"], "0.0.500")
    }

    // MARK: - 契约 3：缺失文件返回空 map 而不抛错

    func test_load_缺失文件_返回空registry() {
        let registry = BrewRegistry.load(cacheDirectory: root)
        XCTAssertTrue(registry.formulaLatest.isEmpty)
        XCTAssertTrue(registry.caskLatest.isEmpty)
        XCTAssertEqual(registry.formulaStatus, .missing)
        XCTAssertEqual(registry.caskStatus, .missing)
        XCTAssertEqual(registry.diagnostics, [], "缺失 cache 是预期离线状态，不应生成故障诊断")
    }

    func test_load_nil目录_返回空() {
        let registry = BrewRegistry.load(cacheDirectory: nil)
        XCTAssertTrue(registry.formulaLatest.isEmpty)
        XCTAssertTrue(registry.caskLatest.isEmpty)
    }

    // MARK: - 契约 4：损坏 JSON 不崩

    func test_parseFormula_损坏外层json_返回空() throws {
        let bad = "{this is not json".data(using: .utf8)!
        try bad.write(to: root.appendingPathComponent("formula.jws.json"))
        let registry = BrewRegistry.load(cacheDirectory: root)
        XCTAssertTrue(registry.formulaLatest.isEmpty)
        XCTAssertEqual(registry.diagnostics.count, 1)
        XCTAssertEqual(registry.diagnostics.first?.source, .formulaRegistry)
        XCTAssertEqual(registry.diagnostics.first?.stage, .decodeDocument)
        XCTAssertEqual(registry.diagnostics.first?.reason, .malformed)
    }

    func test_parseFormula_payload非字符串_返回空() throws {
        let outer: [String: Any] = ["payload": 42]
        let data = try JSONSerialization.data(withJSONObject: outer)
        try data.write(to: root.appendingPathComponent("formula.jws.json"))
        let registry = BrewRegistry.load(cacheDirectory: root)
        XCTAssertTrue(registry.formulaLatest.isEmpty)
    }

    func test_parseFormula_payload内层非数组_返回空() throws {
        try writeJWS(payload: "{\"not\":\"array\"}", to: root.appendingPathComponent("formula.jws.json"))
        let registry = BrewRegistry.load(cacheDirectory: root)
        XCTAssertTrue(registry.formulaLatest.isEmpty)
    }

    // MARK: - 契约 5：缺关键字段的条目被跳过，不影响其他条目

    func test_parseFormula_部分条目缺字段_跳过该条目() throws {
        let inner = """
        [{"name":"ok","versions":{"stable":"1.0"}},\
        {"name":"no-stable","versions":{"head":null}},\
        {"versions":{"stable":"x"}}]
        """
        try writeJWS(payload: inner, to: root.appendingPathComponent("formula.jws.json"))
        let registry = BrewRegistry.load(cacheDirectory: root)
        XCTAssertEqual(registry.formulaLatest, ["ok": "1.0"])
        XCTAssertEqual(registry.diagnostics.count, 1)
        XCTAssertEqual(registry.diagnostics.first?.stage, .decodeEntry)
        XCTAssertEqual(registry.diagnostics.first?.rejectedEntryCount, 2)
    }

    /// v2026.07.18 regression：权限拒绝必须区别于 cache 尚不存在，并保持全程只读。
    func test_load_formula权限拒绝_cask缺失_只返回权限诊断() {
        let formulaPath = root.appendingPathComponent("formula.jws.json").path
        let reader = BrewFileReader(read: { url in
            if url.path == formulaPath {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.fileReadNoPermission.rawValue
                )
            }
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileNoSuchFile.rawValue
            )
        })

        let registry = BrewRegistry.load(cacheDirectory: root, fileReader: reader)

        XCTAssertEqual(registry.formulaLatest, [:])
        XCTAssertEqual(registry.caskLatest, [:])
        XCTAssertEqual(registry.diagnostics.count, 1)
        XCTAssertEqual(registry.diagnostics.first?.source, .formulaRegistry)
        XCTAssertEqual(registry.diagnostics.first?.stage, .read)
        XCTAssertEqual(registry.diagnostics.first?.reason, .permissionDenied)
        XCTAssertEqual(registry.formulaStatus, .unavailable)
        XCTAssertEqual(registry.caskStatus, .missing)
    }

    // MARK: - 契约 6：latestVersion(for:kind:) 按 kind 路由查找

    func test_latestVersion_按kind路由() throws {
        try writeJWS(payload: "[{\"name\":\"git\",\"versions\":{\"stable\":\"2.49.0\"}}]",
                     to: root.appendingPathComponent("formula.jws.json"))
        try writeJWS(payload: "[{\"token\":\"git\",\"version\":\"99.0\"}]",
                     to: root.appendingPathComponent("cask.jws.json"))
        let registry = BrewRegistry.load(cacheDirectory: root)
        XCTAssertEqual(registry.latestVersion(for: "git", kind: .formula), "2.49.0")
        XCTAssertEqual(registry.latestVersion(for: "git", kind: .cask), "99.0")
        XCTAssertNil(registry.latestVersion(for: "absent", kind: .formula))
    }

    // MARK: - 契约 7：Controller.outdated 把 installed != latest 的全标出

    func test_controller_outdated_命中可升级() throws {
        let prefix = try setupPrefix()
        try makeFormula(at: prefix, name: "tool", version: "1.0.0")
        try makeFormula(at: prefix, name: "utopdate", version: "2.0.0")
        try writeJWS(payload: """
        [{"name":"tool","versions":{"stable":"1.1.0"}},\
        {"name":"utopdate","versions":{"stable":"2.0.0"}}]
        """, to: root.appendingPathComponent("formula.jws.json"))

        let controller = BrewController(prefix: prefix)
        let registry = BrewRegistry.load(cacheDirectory: root)
        let out = controller.outdated(using: registry)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.package.name, "tool")
        XCTAssertEqual(out.first?.package.version, "1.0.0")
        XCTAssertEqual(out.first?.latestVersion, "1.1.0")
    }

    // MARK: - 契约 8：registry 中无该包则 outdated 略过（无更新信息 ≠ 可升级）

    func test_controller_outdated_无registry信息_跳过() throws {
        let prefix = try setupPrefix()
        try makeFormula(at: prefix, name: "lonely", version: "0.1")
        // formula.jws.json 故意缺失
        let controller = BrewController(prefix: prefix)
        let registry = BrewRegistry.load(cacheDirectory: root)
        XCTAssertTrue(controller.outdated(using: registry).isEmpty)
    }

    // MARK: - 契约 9：cask 同样可以走 outdated

    func test_controller_outdated_cask可升级() throws {
        let prefix = try setupPrefix()
        try makeCask(at: prefix, name: "myapp", version: "1.0")
        try writeJWS(payload: "[{\"token\":\"myapp\",\"version\":\"2.0\"}]",
                     to: root.appendingPathComponent("cask.jws.json"))
        let controller = BrewController(prefix: prefix)
        let registry = BrewRegistry.load(cacheDirectory: root)
        let out = controller.outdated(using: registry)
        XCTAssertEqual(out.map(\.package.name), ["myapp"])
        XCTAssertEqual(out.first?.latestVersion, "2.0")
    }

    // MARK: - 契约 10：同名多 version 各自判定（旧 + 新都装着，只升级旧的）

    func test_controller_outdated_同名多version_每个独立判定() throws {
        let prefix = try setupPrefix()
        try makeFormula(at: prefix, name: "git-lfs", version: "3.7.0")
        try makeFormula(at: prefix, name: "git-lfs", version: "3.7.1")
        try writeJWS(payload: "[{\"name\":\"git-lfs\",\"versions\":{\"stable\":\"3.7.1\"}}]",
                     to: root.appendingPathComponent("formula.jws.json"))
        let controller = BrewController(prefix: prefix)
        let registry = BrewRegistry.load(cacheDirectory: root)
        let out = controller.outdated(using: registry)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.package.version, "3.7.0")
    }

    // MARK: - helpers

    /// 写一个合成 JWS 文件：{"payload": "<inner-json-string>"}
    private func writeJWS(payload inner: String, to url: URL) throws {
        let envelope: [String: Any] = ["payload": inner, "signatures": []]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try data.write(to: url)
    }

    /// 制造一个最简 brew prefix（Cellar/Caskroom 子目录）。
    private func setupPrefix() throws -> URL {
        let prefix = root.appendingPathComponent("brew", isDirectory: true)
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("Cellar"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("Caskroom"), withIntermediateDirectories: true)
        return prefix
    }

    private func makeFormula(at prefix: URL, name: String, version: String) throws {
        let dir = prefix.appendingPathComponent("Cellar/\(name)/\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 无 receipt 即可，BrewController 也能列出
    }

    private func makeCask(at prefix: URL, name: String, version: String) throws {
        let dir = prefix.appendingPathComponent("Caskroom/\(name)/\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
