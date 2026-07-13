import Foundation

/// Backend developer workflow for JVM, Go, Rust/Zig, and native build caches.
///
/// This complements [DevArtifactScanner] project-tree discovery:
/// - project outputs are found by marker-guarded rules such as `pom.xml + target`
///   or `build.zig + .zig-cache`;
/// - this workflow exposes global dependency/build caches as reviewable cards.
public struct BackendWorkflow: DeveloperWorkflow {
    public let id: String = "workflow.backend"
    public let displayName: String = "workflow.backend.displayName"
    public let subtitle: String = "workflow.backend.subtitle"

    public init() {}

    public func cards(home: URL) -> [DeveloperCard] {
        var result: [DeveloperCard] = []
        result.reserveCapacity(14)

        appendJVM(home: home, into: &result)
        appendGo(home: home, into: &result)
        appendRustZig(home: home, into: &result)
        appendNativeBuild(home: home, into: &result)

        return result
    }

    private func appendJVM(home: URL, into result: inout [DeveloperCard]) {
        let gradleRoot = home.appendingPathComponent(".gradle", isDirectory: true)
        if Self.dirExists(gradleRoot) {
            result.append(DeveloperCard(
                id: "card.backend.gradle-caches",
                title: "card.backend.gradle-caches.title",
                summary: "card.backend.gradle-caches.summary",
                source: .literal(paths: [
                    "~/.gradle/caches",
                    "~/.gradle/configuration-cache",
                    "~/.gradle/build-scan-data",
                ]),
                recipe: .filesystem,
                risk: .safe))

            result.append(DeveloperCard(
                id: "card.backend.gradle-wrapper-dists",
                title: "card.backend.gradle-wrapper-dists.title",
                summary: "card.backend.gradle-wrapper-dists.summary",
                source: .literal(paths: ["~/.gradle/wrapper/dists"]),
                recipe: .filesystem,
                risk: .confirm))
        }

        let m2Root = home.appendingPathComponent(".m2", isDirectory: true)
        if Self.dirExists(m2Root) {
            result.append(DeveloperCard(
                id: "card.backend.maven-repository",
                title: "card.backend.maven-repository.title",
                summary: "card.backend.maven-repository.summary",
                source: .literal(paths: ["~/.m2/repository"]),
                recipe: .filesystem,
                risk: .confirm))

            result.append(DeveloperCard(
                id: "card.backend.maven-wrapper",
                title: "card.backend.maven-wrapper.title",
                summary: "card.backend.maven-wrapper.summary",
                source: .literal(paths: ["~/.m2/wrapper"]),
                recipe: .filesystem,
                risk: .safe))
        }

        let jvmCacheProbes = [
            home.appendingPathComponent(".ivy2/cache", isDirectory: true),
            home.appendingPathComponent("Library/Caches/Coursier/v1", isDirectory: true),
            home.appendingPathComponent(".coursier/cache/v1", isDirectory: true),
        ]
        if jvmCacheProbes.contains(where: Self.dirExists) {
            result.append(DeveloperCard(
                id: "card.backend.jvm-dependency-caches",
                title: "card.backend.jvm-dependency-caches.title",
                summary: "card.backend.jvm-dependency-caches.summary",
                source: .literal(paths: [
                    "~/.ivy2/cache",
                    "~/Library/Caches/Coursier/v1",
                    "~/.coursier/cache/v1",
                ]),
                recipe: .filesystem,
                risk: .confirm))
        }
    }

    private func appendGo(home: URL, into result: inout [DeveloperCard]) {
        let buildCache = home.appendingPathComponent("Library/Caches/go-build", isDirectory: true)
        if Self.dirExists(buildCache) {
            result.append(DeveloperCard(
                id: "card.backend.go-build-cache",
                title: "card.backend.go-build-cache.title",
                summary: "card.backend.go-build-cache.summary",
                source: .literal(paths: ["~/Library/Caches/go-build"]),
                recipe: .filesystem,
                risk: .safe))
        }

        let modCache = home.appendingPathComponent("go/pkg/mod", isDirectory: true)
        if Self.dirExists(modCache) {
            result.append(DeveloperCard(
                id: "card.backend.go-module-cache",
                title: "card.backend.go-module-cache.title",
                summary: "card.backend.go-module-cache.summary",
                // `cache/download` is a descendant of `pkg/mod`. Listing both roots makes
                // the scanner recursively measure the same bytes twice and gives the UI a
                // selection that differs from the folded deletion request. Keep the highest
                // existing root so displayed bytes and the eventual Trash request share one
                // canonical ownership boundary.
                source: .literal(paths: ["~/go/pkg/mod"]),
                recipe: .filesystem,
                risk: .confirm))
        }
    }

    private func appendRustZig(home: URL, into result: inout [DeveloperCard]) {
        let cargoRoot = home.appendingPathComponent(".cargo", isDirectory: true)
        if Self.dirExists(cargoRoot) {
            result.append(DeveloperCard(
                id: "card.backend.cargo-caches",
                title: "card.backend.cargo-caches.title",
                summary: "card.backend.cargo-caches.summary",
                source: .literal(paths: [
                    "~/.cargo/registry/cache",
                    "~/.cargo/registry/src",
                    "~/.cargo/git/db",
                ]),
                recipe: .filesystem,
                risk: .safe))
        }

        let rustupRoot = home.appendingPathComponent(".rustup", isDirectory: true)
        if Self.dirExists(rustupRoot) {
            result.append(DeveloperCard(
                id: "card.backend.rustup-downloads",
                title: "card.backend.rustup-downloads.title",
                summary: "card.backend.rustup-downloads.summary",
                source: .literal(paths: ["~/.rustup/downloads"]),
                recipe: .filesystem,
                risk: .safe))

            result.append(DeveloperCard(
                id: "card.backend.rustup-toolchains",
                title: "card.backend.rustup-toolchains.title",
                summary: "card.backend.rustup-toolchains.summary",
                source: .literal(paths: ["~/.rustup/toolchains"]),
                recipe: .filesystem,
                risk: .confirm))
        }

        let zigCacheProbes = [
            home.appendingPathComponent("Library/Caches/zig", isDirectory: true),
            home.appendingPathComponent(".cache/zig", isDirectory: true),
        ]
        if zigCacheProbes.contains(where: Self.dirExists) {
            result.append(DeveloperCard(
                id: "card.backend.zig-global-cache",
                title: "card.backend.zig-global-cache.title",
                summary: "card.backend.zig-global-cache.summary",
                source: .literal(paths: [
                    "~/Library/Caches/zig",
                    "~/.cache/zig",
                ]),
                recipe: .filesystem,
                risk: .confirm))
        }
    }

    private func appendNativeBuild(home: URL, into result: inout [DeveloperCard]) {
        let bazelProbes = [
            home.appendingPathComponent("Library/Caches/bazel", isDirectory: true),
            home.appendingPathComponent(".cache/bazel", isDirectory: true),
        ]
        if bazelProbes.contains(where: Self.dirExists) {
            result.append(DeveloperCard(
                id: "card.backend.bazel-cache",
                title: "card.backend.bazel-cache.title",
                summary: "card.backend.bazel-cache.summary",
                source: .literal(paths: [
                    "~/Library/Caches/bazel",
                    "~/.cache/bazel",
                ]),
                recipe: .filesystem,
                risk: .confirm))
        }

        let compilerCacheProbes = [
            home.appendingPathComponent("Library/Caches/ccache", isDirectory: true),
            home.appendingPathComponent(".cache/ccache", isDirectory: true),
            home.appendingPathComponent("Library/Caches/Mozilla.sccache", isDirectory: true),
            home.appendingPathComponent(".cache/sccache", isDirectory: true),
        ]
        if compilerCacheProbes.contains(where: Self.dirExists) {
            result.append(DeveloperCard(
                id: "card.backend.compiler-caches",
                title: "card.backend.compiler-caches.title",
                summary: "card.backend.compiler-caches.summary",
                source: .literal(paths: [
                    "~/Library/Caches/ccache",
                    "~/.cache/ccache",
                    "~/Library/Caches/Mozilla.sccache",
                    "~/.cache/sccache",
                ]),
                recipe: .filesystem,
                risk: .safe))
        }
    }

    private static func dirExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}
