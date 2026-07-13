import XCTest
@testable import ScanKit

final class BackendWorkflowCardsTests: XCTestCase {

    func test_emptyHome_hasNoBackendCards() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(BackendWorkflow().cards(home: home).isEmpty)
    }

    func test_jvmRoots_createGradleMavenAndCoursierCards() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(".gradle/caches", in: home)
        try makeDir(".m2/repository", in: home)
        try makeDir("Library/Caches/Coursier/v1", in: home)

        let cards = BackendWorkflow().cards(home: home)
        let ids = Set(cards.map(\.id))

        XCTAssertTrue(ids.contains("card.backend.gradle-caches"))
        XCTAssertTrue(ids.contains("card.backend.gradle-wrapper-dists"))
        XCTAssertTrue(ids.contains("card.backend.maven-repository"))
        XCTAssertTrue(ids.contains("card.backend.maven-wrapper"))
        XCTAssertTrue(ids.contains("card.backend.jvm-dependency-caches"))
        XCTAssertEqual(card(cards, "card.backend.gradle-caches")?.risk, .safe)
        XCTAssertEqual(card(cards, "card.backend.maven-repository")?.risk, .confirm)
    }

    func test_goRoots_createBuildAndModuleCacheCards() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir("Library/Caches/go-build", in: home)
        try makeDir("go/pkg/mod/cache/download", in: home)

        let cards = BackendWorkflow().cards(home: home)
        XCTAssertEqual(card(cards, "card.backend.go-build-cache")?.risk, .safe)
        XCTAssertEqual(card(cards, "card.backend.go-module-cache")?.risk, .confirm)
    }

    func test_goModuleCache_usesOnlyCanonicalParentRoot() throws {
        let home = try makeTmpHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        try makeDir("go/pkg/mod/cache/download", in: home)

        let moduleCard = try XCTUnwrap(card(BackendWorkflow().cards(home: home),
                                            "card.backend.go-module-cache"))
        guard case let .literal(paths) = moduleCard.source else {
            return XCTFail("Go module cache should use literal filesystem roots")
        }

        XCTAssertEqual(paths, ["~/go/pkg/mod"],
                       "A parent and its download-cache descendant must not be scanned or selected twice")
    }

    func test_rustZigRoots_createCargoRustupAndZigCards() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(".cargo/registry/cache", in: home)
        try makeDir(".rustup/downloads", in: home)
        try makeDir("Library/Caches/zig", in: home)

        let cards = BackendWorkflow().cards(home: home)
        XCTAssertEqual(card(cards, "card.backend.cargo-caches")?.risk, .safe)
        XCTAssertEqual(card(cards, "card.backend.rustup-downloads")?.risk, .safe)
        XCTAssertEqual(card(cards, "card.backend.rustup-toolchains")?.risk, .confirm)
        XCTAssertEqual(card(cards, "card.backend.zig-global-cache")?.risk, .confirm)
    }

    func test_nativeBuildRoots_createBazelAndCompilerCards() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(".cache/bazel", in: home)
        try makeDir(".cache/sccache", in: home)

        let cards = BackendWorkflow().cards(home: home)
        XCTAssertEqual(card(cards, "card.backend.bazel-cache")?.risk, .confirm)
        XCTAssertEqual(card(cards, "card.backend.compiler-caches")?.risk, .safe)
    }

    func test_allCardsUseFilesystemRecipe() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [
            ".gradle/caches",
            ".m2/repository",
            "Library/Caches/go-build",
            "go/pkg/mod/cache/download",
            ".cargo/registry/cache",
            ".rustup/downloads",
            ".cache/zig",
            ".cache/bazel",
            ".cache/ccache",
        ] {
            try makeDir(path, in: home)
        }

        let cards = BackendWorkflow().cards(home: home)
        XCTAssertFalse(cards.isEmpty)
        for card in cards {
            XCTAssertEqual(card.recipe, .filesystem, "\(card.id) should use TrashPipeline filesystem deletion")
            XCTAssertTrue(card.recipe.isExecutableInCurrentBuild)
            XCTAssertFalse(card.title.isEmpty)
            XCTAssertFalse(card.summary.isEmpty)
            XCTAssertLessThanOrEqual(card.summary.count, 90)
        }
    }

    private func card(_ cards: [DeveloperCard], _ id: String) -> DeveloperCard? {
        cards.first { $0.id == id }
    }

    private func makeTmpHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackendWorkflowCardsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDir(_ relativePath: String, in home: URL) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}
