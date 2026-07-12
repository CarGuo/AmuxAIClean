import XCTest
@testable import ScanKit

final class DevArtifactRulesTests: XCTestCase {

    func testAllIDsAreUnique() {
        let ids = DevArtifactRules.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "DevArtifactRules.all 出现重复 ID：\(ids)")
    }

    func testDirectoryNamesAreLowercased() {
        for rule in DevArtifactRules.all {
            XCTAssertEqual(rule.directoryName, rule.directoryName.lowercased(),
                           "rule \(rule.id) directoryName 必须全小写：\(rule.directoryName)")
        }
    }

    func testRulesForReturnsExactMatch() {
        let nodeModulesRules = DevArtifactRules.rules(for: "node_modules")
        XCTAssertFalse(nodeModulesRules.isEmpty, "应能查到 node_modules 规则")
        XCTAssertTrue(nodeModulesRules.allSatisfy { $0.directoryName == "node_modules" })
    }

    func testRulesForCaseInsensitive() {
        let lower = DevArtifactRules.rules(for: "node_modules")
        let upper = DevArtifactRules.rules(for: "NODE_MODULES")
        XCTAssertEqual(Set(lower.map(\.id)), Set(upper.map(\.id)),
                       "rules(for:) 应不区分大小写")
    }

    func testGroupedCoversAllRules() {
        let grouped = DevArtifactRules.grouped()
        let flat = grouped.flatMap { $0.1 }
        XCTAssertEqual(Set(flat.map(\.id)), DevArtifactRules.allIDs,
                       "grouped 应覆盖所有规则，无遗漏无重复")
    }

    func testGroupedOrderMatchesEcosystemAllCases() {
        let order = DevArtifactRules.grouped().map(\.0)
        XCTAssertEqual(order, DevArtifactRule.Ecosystem.allCases,
                       "grouped 顺序应严格按 Ecosystem.allCases")
    }

    func testBuildRulesRequireSiblingMarkers() {
        // build/ 在 macOS 系统里到处都有，必须有兄弟兜底（build.gradle / pubspec.yaml / pom.xml 等）
        let buildRules = DevArtifactRules.rules(for: "build")
        XCTAssertFalse(buildRules.isEmpty, "应有 build 规则")
        for rule in buildRules {
            XCTAssertFalse(rule.siblingMarkers.isEmpty,
                           "build 规则 \(rule.id) 必须有 siblingMarkers 兜底，否则误命中风险极高")
        }
    }

    func testNodeModulesRequiresPackageJson() {
        let rules = DevArtifactRules.rules(for: "node_modules")
        XCTAssertTrue(rules.contains { $0.siblingMarkers.contains("package.json") },
                      "node_modules 必须有以 package.json 为兜底的规则")
    }

    func testTargetRulesRequireProjectMarkers() {
        let rules = DevArtifactRules.rules(for: "target")
        XCTAssertFalse(rules.isEmpty, "应有 target 规则")
        for rule in rules {
            XCTAssertFalse(rule.siblingMarkers.isEmpty,
                           "target 规则 \(rule.id) 必须有 siblingMarkers 兜底，否则误命中风险极高")
        }
        XCTAssertTrue(rules.contains { $0.id == "rust.target" && $0.siblingMarkers.contains("Cargo.toml") },
                      "Rust target 必须有 Cargo.toml 兜底")
        XCTAssertTrue(rules.contains { $0.id == "jvm.maven_target" && $0.siblingMarkers.contains("pom.xml") },
                      "Maven target 必须有 pom.xml 兜底")
        XCTAssertTrue(rules.contains { $0.id == "jvm.sbt_target" && $0.siblingMarkers.contains("build.sbt") },
                      "sbt target 必须有 build.sbt 兜底")
    }

    func testBackendAndNativeRulesKeepMarkerGuards() {
        for rule in DevArtifactRules.all where [.jvm, .go, .zig, .nativeBuild].contains(rule.ecosystem) {
            XCTAssertFalse(rule.siblingMarkers.isEmpty,
                           "\(rule.id) 覆盖后端/本机构建生态，必须用项目 marker 限定命中边界")
        }

        let zigRules = DevArtifactRules.all.filter { $0.ecosystem == .zig }
        XCTAssertFalse(zigRules.isEmpty, "应覆盖 Zig 项目产物")
        let zigMarkers = Set(["build.zig", "build.zig.zon"])
        XCTAssertTrue(zigRules.allSatisfy { !Set($0.siblingMarkers).isDisjoint(with: zigMarkers) },
                      "Zig 规则必须由 build.zig / build.zig.zon 证明项目边界")

        let nativeRules = DevArtifactRules.all.filter { $0.ecosystem == .nativeBuild }
        XCTAssertFalse(nativeRules.isEmpty, "应覆盖 Bazel / CMake / Meson 等本机构建产物")
        XCTAssertTrue(nativeRules.contains { $0.id == "native.bazel_bin" })
        XCTAssertTrue(nativeRules.contains { $0.id == "native.cmake_build" })
        XCTAssertTrue(nativeRules.contains { $0.id == "native.cmake_build_dir" })
        XCTAssertTrue(nativeRules.contains { $0.id == "native.meson_builddir" })
    }

    // MARK: - v1.3 P0-D 新增字段兜底

    /// xcuserdata 规则必须带 .xcodeproj / .xcworkspace 父路径后缀兜底——
    /// 这是它唯一可靠的命中条件（xcuserdata 同级通常没有任何 marker 文件）。
    func test_xcuserdata规则带有父路径后缀兜底() {
        let rules = DevArtifactRules.rules(for: "xcuserdata")
        XCTAssertFalse(rules.isEmpty, "应至少有一条 xcuserdata 规则")
        XCTAssertTrue(rules.contains { Set($0.parentSuffixMarkers) == Set([".xcodeproj", ".xcworkspace"]) },
                      "xcuserdata 规则必须配置 .xcodeproj / .xcworkspace 父路径后缀兜底")
    }

    /// py.pycache 规则必须带 .py 兄弟扩展名兜底——
    /// 一些纯脚本目录没有 setup.py / pyproject.toml 等精确 marker，但只要同级有 .py 文件就应当命中。
    func test_pycache规则带有py兄弟扩展名兜底() {
        let rules = DevArtifactRules.rules(for: "__pycache__")
        XCTAssertFalse(rules.isEmpty, "应至少有一条 __pycache__ 规则")
        XCTAssertTrue(rules.contains { $0.siblingExtensionMarkers.contains(".py") },
                      "py.pycache 规则必须包含 .py 兄弟扩展名兜底")
    }

    /// DevArtifactRule.init 默认值兼容性：旧调用方不传新字段时两个兜底列表应当为空。
    func test_新字段默认值为空_向后兼容() {
        let rule = DevArtifactRule(id: "test.compat",
                                   displayName: "compat",
                                   directoryName: "compat",
                                   siblingMarkers: [],
                                   ecosystem: .web,
                                   verdict: .safe,
                                   subtitle: "compat test")
        XCTAssertTrue(rule.siblingExtensionMarkers.isEmpty,
                      "未显式传值时 siblingExtensionMarkers 默认应为空")
        XCTAssertTrue(rule.parentSuffixMarkers.isEmpty,
                      "未显式传值时 parentSuffixMarkers 默认应为空")
    }
}
