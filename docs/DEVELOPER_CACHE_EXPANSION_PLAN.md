# Developer Cache Expansion Plan

## Goal

Developer Artifacts, Old Dev Versions, Developer Workflow, and Common App Caches need broader, evidence-backed coverage. This plan expands coverage without turning the app into a risky "delete anything named cache/build" tool.

Rules:

- Prefer official tool cleanup commands when they exist.
- Separate project build outputs from global dependency caches.
- Treat SDKs, toolchains, credentials, config, database/profile roots, and sync roots as blocked unless a dedicated workflow handles them.
- Keep every new UI-facing label in `Localizable.xcstrings`.
- Back every path family with fixture tests and SafetyEngine integration tests before enabling it by default.

## Current Gaps

Current code already has three building blocks:

- `DevArtifactScanner`: project-tree directory-name scanner with sibling marker guards.
- `DeveloperWorkflow`: grouped workflow cards for Apple, Android, and Web/Node.
- `CommonAppCacheScanner`: explicit vendor-rule app cache scanner.

The weakness is coverage and product shape:

- Backend ecosystems are not first-class workflows. JVM, Go, Rust, Zig, Bazel, CMake, Python, and container/tool caches are scattered between `vendors.yaml` and a small set of project rules.
- Old Dev Versions is mostly Apple/Android oriented. It does not cover old Java/Scala/Coursier JVMs, Rust toolchains, Go toolchains, Zig cache generations, or versioned SDK/tool managers.
- Common App Cache has a good safety model but needs more app families and fixture-backed rules.

## Source Evidence

Use these sources as validation anchors. They are evidence, not permission to delete blindly.

- Gradle user home / caches: https://docs.gradle.org/current/userguide/directory_layout.html
- Gradle build cache: https://docs.gradle.org/current/userguide/build_cache.html
- Maven local repository: https://maven.apache.org/guides/introduction/introduction-to-repositories.html
- Go clean flags for build/test/module caches: https://pkg.go.dev/cmd/go
- Cargo target dir and config: https://doc.rust-lang.org/cargo/reference/config.html
- Zig build cache: https://ziglang.org/learn/build-system/
- Bazel clean / output base: https://bazel.build/docs/user-manual and https://bazel.build/remote/output-directories
- pip cache management: https://pip.pypa.io/en/stable/topics/caching/ and https://pip.pypa.io/en/stable/cli/pip_cache/
- Poetry cache and cache-dir: https://python-poetry.org/docs/cli/ and https://python-poetry.org/docs/configuration/
- Coursier cache: https://get-coursier.io/docs/cache and https://get-coursier.io/docs/cli-overview

## P0: Backend Developer Workflow

Add a new `BackendWorkflow` or split into four workflows if the UI becomes too dense:

- `workflow.jvm`
- `workflow.go`
- `workflow.rust-zig`
- `workflow.native-build`

### JVM / Backend Frameworks

| Capability | Paths or scanner | Risk | Action |
| --- | --- | --- | --- |
| Gradle user cache | `~/.gradle/caches`, `~/.gradle/build-cache-*` if present, `~/.gradle/configuration-cache` | safe/confirm | Prefer `gradle --stop` hint; Trash path fallback. |
| Gradle wrapper dists | `~/.gradle/wrapper/dists` | confirm | Keep newest N by version/mtime. |
| Maven local repository | `~/.m2/repository` | confirm | Large shared dependency cache; never touch `settings.xml` or `settings-security.xml`. |
| Maven wrapper | `~/.m2/wrapper` | safe | Recreated by `mvnw`. |
| Project `target/` | siblings `pom.xml`, `build.sbt`, `project/build.properties`, `Cargo.toml` handled by ecosystem-specific rules | safe | Add markers to avoid random `target` dirs. |
| SBT/Ivy/Coursier | `~/.ivy2/cache`, `~/Library/Caches/Coursier/v1`, `~/.coursier/cache/v1` | confirm | Dependency cache; clear via Coursier/SBT when possible, Trash fallback. |
| Spring/Quarkus/Micronaut outputs | Project `target/`, `build/`, `.gradle/` with framework markers | safe | Do not add framework-specific guessed global paths; they mostly use Maven/Gradle outputs. |

Project rules to add:

- `jvm.maven_target`: `target` with `pom.xml`.
- `jvm.gradle_build`: `build` with `build.gradle` / `build.gradle.kts` / `settings.gradle`.
- `jvm.sbt_target`: `target` with `build.sbt` or `project/build.properties`.
- `jvm.bloop`: `.bloop` with `build.sbt` / `scala-cli` markers.
- `jvm.metals`: `.metals` with Scala project markers, confirm if it contains workspace state.

### Go

| Capability | Paths or scanner | Risk | Action |
| --- | --- | --- | --- |
| Go build cache | `go env GOCACHE`, fallback `~/Library/Caches/go-build` | safe | Prefer `go clean -cache`; also offer size preview. |
| Go test cache | command-only | safe | `go clean -testcache`; no path deletion needed. |
| Go module cache | `go env GOMODCACHE`, fallback `~/go/pkg/mod` | confirm | Prefer `go clean -modcache`; warn about redownload. |
| Project build outputs | `bin/`, `dist/`, `coverage.out`, `*.test` with `go.mod` marker | safe/confirm | Only under detected Go project root. |
| `vendor/` | sibling `go.mod` | confirm | Existing rule is correct; keep confirm. |

Project rules to add:

- `go.bin`: `bin` with `go.mod`, confirm if contains executable outputs.
- `go.coverage`: `coverage`, `.cover`, `coverage.out` with `go.mod`, safe.
- `go.tmp`: `.gocache` / `.gotmp` with `go.mod`, safe.

### Rust / Zig

| Capability | Paths or scanner | Risk | Action |
| --- | --- | --- | --- |
| Cargo project output | `target` with `Cargo.toml` | safe | Already exists; add target-dir override detection later. |
| Cargo registry | `~/.cargo/registry/cache`, `~/.cargo/registry/src`, `~/.cargo/git/db` | safe/confirm | Existing global rules mostly correct; keep `~/.cargo/bin` blocked. |
| Rustup downloads | `~/.rustup/downloads` | safe | Existing rule is correct. |
| Rustup old toolchains | `~/.rustup/toolchains/*` | confirm | Add Old Dev Versions keep-current + keep-newest policy; never delete active default. |
| Zig local cache | `.zig-cache`, `zig-cache`, `zig-out` with `build.zig` / `build.zig.zon` | safe | Official docs say generated build cache can be deleted; `zig-out` is output, confirm for release artifacts. |
| Zig global cache | `~/Library/Caches/zig` or `~/.cache/zig` when detected from `zig env` | confirm | Prefer command/env detection; versioned cache may be costly to redownload/rebuild. |

Project rules to add:

- `zig.local_cache`: `.zig-cache` and legacy `zig-cache` with `build.zig` / `build.zig.zon`, safe.
- `zig.out`: `zig-out` with `build.zig`, confirm.
- `rust.cargo_target_dir_override`: detect `.cargo/config.toml` `target-dir` later, not P0 unless parser is added.

### Native / Polyglot Build Tools

| Capability | Paths or scanner | Risk | Action |
| --- | --- | --- | --- |
| Bazel output symlinks | `bazel-bin`, `bazel-out`, `bazel-testlogs`, `bazel-<workspace>` under workspace | safe | Prefer `bazel clean`; symlink outputs can be removed. |
| Bazel output base | `~/Library/Caches/bazel`, `~/.cache/bazel`, output base from `bazel info output_base` | confirm | `bazel clean --expunge` stops server and removes full output base. Use command recipe. |
| CMake | `build/`, `cmake-build-*`, `CMakeFiles`, `CMakeCache.txt` under project with `CMakeLists.txt` | safe/confirm | `build/` safe, generated files confirm if root-level. |
| Ninja/Meson | `builddir`, `.ninja_deps`, `.ninja_log`, `meson-private` with `meson.build` | safe | Project-local generated outputs. |
| ccache/sccache | `~/Library/Caches/ccache`, `~/Library/Caches/Mozilla.sccache` / `~/.cache/sccache` | safe/confirm | Prefer official tool cleanup if installed; otherwise Trash cache dirs. |

## P1: Old Dev Versions

Expand from Apple/Android to all versioned developer stores:

- Gradle wrapper distributions: keep latest 2 versions per distribution type.
- Rustup toolchains: keep active default + latest stable/nightly; confirm others.
- Coursier JVMs: managed JVM directory under Coursier cache, keep latest per major.
- SDKMAN/asdf/mise versions: confirm only, never delete current `global` / `local` selected version.
- Bazel install/output bases: confirm and prefer `bazel clean --expunge`.
- Go installed toolchains managed by `go env GOTOOLCHAIN` / `~/Library/Caches/go-build`: do not guess; add detection only after fixture evidence.

Required scanner abstraction:

- `VersionedToolchainScanner` with provider-specific active-version resolver.
- Each provider must have tests for "current version is never returned".

## P1: Common App Cache Expansion

Keep this separate from developer workflows. Common App Cache should use explicit vendor rules and installed-app/running-app guards.

Add families in this order:

1. Browser cache: Chrome, Edge, Brave, Arc, Firefox, Safari cache subdirs only.
2. Electron apps: Slack, Discord, Notion, Obsidian, Linear, Postman, ChatGPT, Claude, Codex cache/log/update subdirs.
3. Communication apps: WeChat, Zoom, Tencent Meeting, WhatsApp, Teams safe subset.
4. Cloud sync: Google Drive, Dropbox, OneDrive cache only, always confirm and running-app guarded.
5. Design/media/game: Adobe media cache, Figma, Sketch, Blender, Steam/Epic/Battle.net cache only, always confirm.

Never include in Common App Cache:

- Browser profile roots, cookies, history, login data, local state.
- Chat DBs, received files, media roots.
- Cloud sync document roots.
- Office group-container roots.
- VM bundles, disk images, snapshots.
- Credential/config roots.

## Implementation Slices

### Slice A: Source-grounded rule model

- Add `commandRecipe` to developer cards for tools with official clean commands.
- Add `agePolicy` / `keepLatest` metadata for versioned caches.
- Add `requiresRunningProcessStopped` guard for Gradle, Bazel, browsers, Electron apps, sync clients.

### Slice B: Backend workflow cards

- Add `BackendWorkflow`.
- Add cards for JVM, Go, Rust/Zig, Native Build Tools.
- Add i18n keys for workflow/card titles and summaries.
- Add `WorkflowDetailViewTests` for empty home and fixture home.

### Slice C: Project artifact rules

- Extend `DevArtifactRules` with JVM, Go, Zig, CMake, Bazel, Meson/Ninja rules.
- Add false-positive tests: random `target`, random `build`, random `vendor`, random `.cache` must not match without markers.
- Add golden grouped-count tests so new rules are intentional.

### Slice D: Command-backed cleanup

- Extend `SubprocessExecutor.defaultAllowlist` with exact safe commands only:
  - `go clean -cache`
  - `go clean -testcache`
  - `go clean -modcache`
  - `bazel clean` / `bazel clean --expunge`
  - package-manager cache commands only after command semantics are tested
- UI must display command before running.

### Slice E: Common App Cache batch 2

- Extend `vendors.yaml` `category: common_app_cache` only with verified app cache/log paths.
- Add blocked-neighbor tests for every app family.
- Add fixture tests that cache roots appear but profile/data roots never appear.

## Acceptance Criteria

- New backend workflow cards appear only on machines with evidence of that ecosystem.
- No new rule can match `~/Library`, `~/Documents`, `~/Desktop`, browser profiles, chat DBs, credentials, or SDK roots.
- All destructive paths still go through `TrashPipeline` or an explicitly allowlisted tool cleanup command.
- `swift test` passes for ScanKit, SafetyKit, and AppUI.
- Regression cases to run after implementation:
  - `scan-recommended`
  - `tree-drilldown`
  - `trash-pipeline-dryrun`
  - `workflow-apple` existing coverage
  - new `workflow-backend` fixture case
