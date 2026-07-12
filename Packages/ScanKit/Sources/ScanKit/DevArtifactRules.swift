import Foundation

/// 开发者构建产物 / 依赖目录的命中规则集。
///
/// 设计目标：能在用户家目录（`~`）里快速找到「可放心删」的开发框架副产品（缓存目录、
/// 构建产物、依赖目录），覆盖主流前后端 / 移动 / 桌面框架。
///
/// 关键设计：
/// 1. **目录名匹配**：每条规则锁定一个目录名（如 `node_modules`、`build`、`Pods`、
///    `target`），扫描器在 BFS 时一旦命中就把「整棵」子树作为一项收集，并对该子树
///    剪枝不再深入下钻（避免重复统计 + 速度成倍提升）。
/// 2. **兄弟脚手架兜底**：仅靠目录名极易误命中。例如 macOS 系统里到处是叫 `build`、
///    `Caches`、`vendor` 的目录。所以每条规则可以选填「需要兄弟里至少有一个脚手架
///    文件」，例如 `node_modules` 必须兄弟里有 `package.json`、`build/` 必须兄弟
///    里有 `build.gradle` / `pubspec.yaml` / `pom.xml`。
/// 3. **生态分组**：每条规则归属一个 [Ecosystem]，UI 设置面板按生态展示更直观。
/// 4. **危险等级**：用于驱动默认勾选——`safe` 默认勾选，`confirm` 必须用户确认。
///    如 `node_modules` 默认勾上（一条 `npm install` 即可重建），但 `Pods` 给
///    `confirm`（CocoaPods 没装的人可能会下载半天）。
///
/// 业界对比：
/// - JetBrains Toolbox 「Clean disk」按 IDE 内置的 build cache 列表清；
/// - npkill 仅扫 `node_modules`；
/// - dev-cleaner、CleanMyMac 「Developer junk」都用类似规则，但通常没做兄弟兜底，
///   误命中率较高。
public struct DevArtifactRule: Identifiable, Hashable, Sendable {

    public enum Ecosystem: String, CaseIterable, Hashable, Sendable, Identifiable {
        case web              // Node / React / Vue / Next / Nuxt / Electron / RN
        case appleMobile      // iOS / macOS：CocoaPods / SPM cache / Carthage / xcuserdata
        case androidFlutter   // Android Studio / Gradle / Flutter / Dart
        case rust
        case go
        case python
        case jvm              // Maven / Gradle 缓存仓
        case zig
        case nativeBuild      // Bazel / CMake / Meson / Ninja 等本机构建系统
        case general          // 通用：.cache / .turbo

        public var id: String { rawValue }

        /// i18n key —— UI 层用 `String(localized:)` 拿翻译；ScanKit 不做翻译。
        /// 形如 `ecosystem.web` / `ecosystem.appleMobile` 等。
        public var localizationKey: String { "ecosystem.\(rawValue)" }

        /// i18n key —— UI 层用 `String(localized: LocalizedStringResource(stringLiteral: ecosystem.displayName), bundle: .module)` 或
        /// `Text(LocalizedStringKey(ecosystem.displayName), bundle: .module)` 渲染。
        /// 与 `localizationKey` 等价，保留两个名字仅为兼容旧调用方。
        public var displayName: String {
            switch self {
            case .web:            return "ecosystem.web.displayName"
            case .appleMobile:    return "ecosystem.appleMobile.displayName"
            case .androidFlutter: return "ecosystem.androidFlutter.displayName"
            case .rust:           return "ecosystem.rust.displayName"
            case .go:             return "ecosystem.go.displayName"
            case .python:         return "ecosystem.python.displayName"
            case .jvm:            return "ecosystem.jvm.displayName"
            case .zig:            return "ecosystem.zig.displayName"
            case .nativeBuild:    return "ecosystem.nativeBuild.displayName"
            case .general:        return "ecosystem.general.displayName"
            }
        }
    }

    public enum Verdict: String, Hashable, Sendable {
        /// 删了也安全（依赖一条命令重建：npm install / pod install / cargo build）。
        case safe
        /// 慎重——重建可能耗时（`Pods` 重新拉、Gradle 全局缓存重新下载）。
        case confirm
    }

    public let id: String
    public let displayName: String
    /// 匹配的目录名（精确小写比较；规则全部用小写存）。
    public let directoryName: String
    /// 兄弟脚手架文件名候选——任一存在即视为「真项目」。空数组表示「不要求兄弟兜底」。
    /// 注意是「兄弟」不是「父」：`X/node_modules` 的兄弟指的是 X 下与 node_modules 同级的文件。
    public let siblingMarkers: [String]
    /// v1.3 P0-D 兜底：兄弟文件扩展名候选——任一兄弟以这些扩展名结尾即视为命中。
    /// 用于 `__pycache__` 这种"必然与同级 .py 共存"但缺少明确脚手架文件的场景。
    /// 扩展名带前导点（如 `".py"`），小写比较。空数组表示不启用。
    public let siblingExtensionMarkers: [String]
    /// v1.3 P0-D 兜底：父目录路径后缀候选——父目录路径以这些后缀结尾即视为命中。
    /// 用于 `xcuserdata` 这种"必然嵌在 .xcodeproj/.xcworkspace 内"但没有同级文件的场景。
    /// 比较时已对 parent.path 标准化；后缀含前导点（如 `".xcodeproj"`）。空数组表示不启用。
    public let parentSuffixMarkers: [String]
    /// 命中后是否需要往下钻找该子树里**更内层**的同名 / 其他规则——一律 false：
    /// 命中即整棵剪枝（性能 + 避免重复计数）。语义上保留作扩展位。
    public let pruneSubtree: Bool
    public let ecosystem: Ecosystem
    public let verdict: Verdict
    public let subtitle: String

    public init(id: String,
                displayName: String,
                directoryName: String,
                siblingMarkers: [String],
                ecosystem: Ecosystem,
                verdict: Verdict,
                subtitle: String,
                pruneSubtree: Bool = true,
                siblingExtensionMarkers: [String] = [],
                parentSuffixMarkers: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.directoryName = directoryName.lowercased()
        self.siblingMarkers = siblingMarkers
        self.siblingExtensionMarkers = siblingExtensionMarkers.map { $0.lowercased() }
        self.parentSuffixMarkers = parentSuffixMarkers.map { $0.lowercased() }
        self.pruneSubtree = pruneSubtree
        self.ecosystem = ecosystem
        self.verdict = verdict
        self.subtitle = subtitle
    }
}

/// 全部内置规则。所有规则**默认全开**——UI 层在 AppSettings 里维护一份「关掉的 ID」白名单，
/// 调用 [DevArtifactScanner] 时按需过滤。
public enum DevArtifactRules {

    /// v1.4：内置规则全集（按生态分组）。
    /// 顺序仅影响 UI 列表展示，扫描时用字典查找无序。
    public static let all: [DevArtifactRule] = [
        // MARK: Web / Node
        .init(id: "web.node_modules",
              displayName: "node_modules",
              directoryName: "node_modules",
              siblingMarkers: ["package.json"],
              ecosystem: .web, verdict: .safe,
              subtitle: "rule.web.node_modules.subtitle"),
        .init(id: "web.next",
              displayName: ".next",
              directoryName: ".next",
              siblingMarkers: ["package.json", "next.config.js", "next.config.mjs", "next.config.ts"],
              ecosystem: .web, verdict: .safe,
              subtitle: "rule.web.next.subtitle"),
        .init(id: "web.nuxt",
              displayName: ".nuxt",
              directoryName: ".nuxt",
              siblingMarkers: ["package.json", "nuxt.config.js", "nuxt.config.ts"],
              ecosystem: .web, verdict: .safe,
              subtitle: "rule.web.nuxt.subtitle"),
        .init(id: "web.svelte_kit",
              displayName: ".svelte-kit",
              directoryName: ".svelte-kit",
              siblingMarkers: ["package.json", "svelte.config.js"],
              ecosystem: .web, verdict: .safe,
              subtitle: "rule.web.svelte_kit.subtitle"),
        .init(id: "web.parcel_cache",
              displayName: ".parcel-cache",
              directoryName: ".parcel-cache",
              siblingMarkers: ["package.json"],
              ecosystem: .web, verdict: .safe,
              subtitle: "rule.web.parcel_cache.subtitle"),
        .init(id: "web.expo",
              displayName: ".expo",
              directoryName: ".expo",
              siblingMarkers: ["package.json", "app.json", "app.config.js", "app.config.ts"],
              ecosystem: .web, verdict: .safe,
              subtitle: "rule.web.expo.subtitle"),
        .init(id: "web.dist",
              displayName: "dist",
              directoryName: "dist",
              siblingMarkers: ["package.json"],
              ecosystem: .web, verdict: .safe,
              subtitle: "rule.web.dist.subtitle"),
        .init(id: "web.out_next",
              displayName: "out",
              directoryName: "out",
              siblingMarkers: ["package.json"],
              ecosystem: .web, verdict: .confirm,
              subtitle: "rule.web.out_next.subtitle"),
        .init(id: "web.coverage",
              displayName: "coverage",
              directoryName: "coverage",
              siblingMarkers: ["package.json", "jest.config.js", "jest.config.ts", "vitest.config.ts"],
              ecosystem: .web, verdict: .safe,
              subtitle: "rule.web.coverage.subtitle"),

        // MARK: iOS / macOS
        .init(id: "apple.pods",
              displayName: "Pods",
              directoryName: "pods",
              siblingMarkers: ["Podfile", "Podfile.lock"],
              ecosystem: .appleMobile, verdict: .confirm,
              subtitle: "rule.apple.pods.subtitle"),
        .init(id: "apple.swiftpm_build",
              displayName: ".build",
              directoryName: ".build",
              siblingMarkers: ["Package.swift"],
              ecosystem: .appleMobile, verdict: .safe,
              subtitle: "rule.apple.swiftpm_build.subtitle"),
        .init(id: "apple.spm_dot",
              displayName: ".swiftpm",
              directoryName: ".swiftpm",
              siblingMarkers: ["Package.swift"],
              ecosystem: .appleMobile, verdict: .confirm,
              subtitle: "rule.apple.spm_dot.subtitle"),
        .init(id: "apple.carthage",
              displayName: "Carthage",
              directoryName: "carthage",
              siblingMarkers: ["Cartfile", "Cartfile.resolved"],
              ecosystem: .appleMobile, verdict: .safe,
              subtitle: "rule.apple.carthage.subtitle"),
        .init(id: "apple.xcuserdata",
              displayName: "xcuserdata",
              directoryName: "xcuserdata",
              siblingMarkers: [],
              ecosystem: .appleMobile, verdict: .safe,
              subtitle: "rule.apple.xcuserdata.subtitle",
              parentSuffixMarkers: [".xcodeproj", ".xcworkspace"]),

        // MARK: Android / Flutter
        .init(id: "android.gradle_proj",
              displayName: ".gradle",
              directoryName: ".gradle",
              siblingMarkers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "rule.android.gradle_proj.subtitle"),
        .init(id: "android.build_gradle",
              displayName: "rule.android.build_gradle.displayName",
              directoryName: "build",
              siblingMarkers: ["build.gradle", "build.gradle.kts", "pom.xml"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "rule.android.build_gradle.subtitle"),
        .init(id: "android.cxx",
              displayName: ".cxx",
              directoryName: ".cxx",
              siblingMarkers: ["build.gradle", "build.gradle.kts", "CMakeLists.txt"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "rule.android.cxx.subtitle"),
        .init(id: "flutter.dart_tool",
              displayName: ".dart_tool",
              directoryName: ".dart_tool",
              siblingMarkers: ["pubspec.yaml"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "rule.flutter.dart_tool.subtitle"),
        .init(id: "flutter.build",
              displayName: "rule.flutter.build.displayName",
              directoryName: "build",
              siblingMarkers: ["pubspec.yaml"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "rule.flutter.build.subtitle"),

        // MARK: Rust
        .init(id: "rust.target",
              displayName: "target",
              directoryName: "target",
              siblingMarkers: ["Cargo.toml"],
              ecosystem: .rust, verdict: .safe,
              subtitle: "rule.rust.target.subtitle"),

        // MARK: Zig
        .init(id: "zig.local_cache_dot",
              displayName: ".zig-cache",
              directoryName: ".zig-cache",
              siblingMarkers: ["build.zig", "build.zig.zon"],
              ecosystem: .zig, verdict: .safe,
              subtitle: "rule.zig.local_cache.subtitle"),
        .init(id: "zig.local_cache_legacy",
              displayName: "zig-cache",
              directoryName: "zig-cache",
              siblingMarkers: ["build.zig", "build.zig.zon"],
              ecosystem: .zig, verdict: .safe,
              subtitle: "rule.zig.local_cache.subtitle"),
        .init(id: "zig.out",
              displayName: "zig-out",
              directoryName: "zig-out",
              siblingMarkers: ["build.zig", "build.zig.zon"],
              ecosystem: .zig, verdict: .confirm,
              subtitle: "rule.zig.out.subtitle"),

        // MARK: Go
        .init(id: "go.vendor",
              displayName: "vendor",
              directoryName: "vendor",
              siblingMarkers: ["go.mod"],
              ecosystem: .go, verdict: .confirm,
              subtitle: "rule.go.vendor.subtitle"),
        .init(id: "go.bin",
              displayName: "bin",
              directoryName: "bin",
              siblingMarkers: ["go.mod"],
              ecosystem: .go, verdict: .confirm,
              subtitle: "rule.go.bin.subtitle"),
        .init(id: "go.coverage",
              displayName: "coverage",
              directoryName: "coverage",
              siblingMarkers: ["go.mod"],
              ecosystem: .go, verdict: .safe,
              subtitle: "rule.go.coverage.subtitle"),

        // MARK: Python
        .init(id: "py.pycache",
              displayName: "__pycache__",
              directoryName: "__pycache__",
              siblingMarkers: ["__init__.py", "pyproject.toml", "setup.py", "requirements.txt", "Pipfile"],
              ecosystem: .python, verdict: .safe,
              subtitle: "rule.py.pycache.subtitle",
              siblingExtensionMarkers: [".py"]),
        .init(id: "py.venv",
              displayName: ".venv / venv",
              directoryName: ".venv",
              siblingMarkers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
              ecosystem: .python, verdict: .confirm,
              subtitle: "rule.py.venv.subtitle"),
        .init(id: "py.venv2",
              displayName: "venv",
              directoryName: "venv",
              siblingMarkers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
              ecosystem: .python, verdict: .confirm,
              subtitle: "rule.py.venv2.subtitle"),
        .init(id: "py.pytest_cache",
              displayName: ".pytest_cache",
              directoryName: ".pytest_cache",
              siblingMarkers: [],
              ecosystem: .python, verdict: .safe,
              subtitle: "rule.py.pytest_cache.subtitle"),
        .init(id: "py.mypy_cache",
              displayName: ".mypy_cache",
              directoryName: ".mypy_cache",
              siblingMarkers: [],
              ecosystem: .python, verdict: .safe,
              subtitle: "rule.py.mypy_cache.subtitle"),
        .init(id: "py.tox",
              displayName: ".tox",
              directoryName: ".tox",
              siblingMarkers: ["tox.ini", "pyproject.toml"],
              ecosystem: .python, verdict: .safe,
              subtitle: "rule.py.tox.subtitle"),

        // MARK: JVM / Backend
        .init(id: "jvm.maven_target",
              displayName: "target",
              directoryName: "target",
              siblingMarkers: ["pom.xml"],
              ecosystem: .jvm, verdict: .safe,
              subtitle: "rule.jvm.maven_target.subtitle"),
        .init(id: "jvm.sbt_target",
              displayName: "target",
              directoryName: "target",
              siblingMarkers: ["build.sbt"],
              ecosystem: .jvm, verdict: .safe,
              subtitle: "rule.jvm.sbt_target.subtitle"),
        .init(id: "jvm.gradle_build",
              displayName: "build",
              directoryName: "build",
              siblingMarkers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
              ecosystem: .jvm, verdict: .safe,
              subtitle: "rule.jvm.gradle_build.subtitle"),
        .init(id: "jvm.bloop",
              displayName: ".bloop",
              directoryName: ".bloop",
              siblingMarkers: ["build.sbt", "scala-cli.project", "project"],
              ecosystem: .jvm, verdict: .safe,
              subtitle: "rule.jvm.bloop.subtitle"),
        .init(id: "jvm.metals",
              displayName: ".metals",
              directoryName: ".metals",
              siblingMarkers: ["build.sbt", "scala-cli.project", "project"],
              ecosystem: .jvm, verdict: .confirm,
              subtitle: "rule.jvm.metals.subtitle"),

        // MARK: Native / Polyglot build systems
        .init(id: "native.cmake_build_dir",
              displayName: "build",
              directoryName: "build",
              siblingMarkers: ["CMakeLists.txt"],
              ecosystem: .nativeBuild, verdict: .safe,
              subtitle: "rule.native.cmake_build.subtitle"),
        .init(id: "native.cmake_build",
              displayName: "cmake-build-*",
              directoryName: "cmake-build-debug",
              siblingMarkers: ["CMakeLists.txt"],
              ecosystem: .nativeBuild, verdict: .safe,
              subtitle: "rule.native.cmake_build.subtitle"),
        .init(id: "native.cmake_build_release",
              displayName: "cmake-build-release",
              directoryName: "cmake-build-release",
              siblingMarkers: ["CMakeLists.txt"],
              ecosystem: .nativeBuild, verdict: .safe,
              subtitle: "rule.native.cmake_build.subtitle"),
        .init(id: "native.cmake_files",
              displayName: "CMakeFiles",
              directoryName: "cmakefiles",
              siblingMarkers: ["CMakeCache.txt"],
              ecosystem: .nativeBuild, verdict: .safe,
              subtitle: "rule.native.cmake_files.subtitle"),
        .init(id: "native.bazel_bin",
              displayName: "bazel-bin",
              directoryName: "bazel-bin",
              siblingMarkers: ["WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel"],
              ecosystem: .nativeBuild, verdict: .safe,
              subtitle: "rule.native.bazel_output.subtitle"),
        .init(id: "native.bazel_out",
              displayName: "bazel-out",
              directoryName: "bazel-out",
              siblingMarkers: ["WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel"],
              ecosystem: .nativeBuild, verdict: .safe,
              subtitle: "rule.native.bazel_output.subtitle"),
        .init(id: "native.bazel_testlogs",
              displayName: "bazel-testlogs",
              directoryName: "bazel-testlogs",
              siblingMarkers: ["WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel"],
              ecosystem: .nativeBuild, verdict: .safe,
              subtitle: "rule.native.bazel_output.subtitle"),
        .init(id: "native.meson_private",
              displayName: "meson-private",
              directoryName: "meson-private",
              siblingMarkers: ["meson.build"],
              ecosystem: .nativeBuild, verdict: .safe,
              subtitle: "rule.native.meson_private.subtitle"),
        .init(id: "native.meson_builddir",
              displayName: "builddir",
              directoryName: "builddir",
              siblingMarkers: ["meson.build"],
              ecosystem: .nativeBuild, verdict: .safe,
              subtitle: "rule.native.meson_builddir.subtitle"),

        // MARK: 通用
        .init(id: "general.turbo",
              displayName: ".turbo",
              directoryName: ".turbo",
              siblingMarkers: ["package.json", "turbo.json"],
              ecosystem: .general, verdict: .safe,
              subtitle: "rule.general.turbo.subtitle"),
        .init(id: "general.cache",
              displayName: ".cache",
              directoryName: ".cache",
              siblingMarkers: ["package.json"],
              ecosystem: .general, verdict: .safe,
              subtitle: "rule.general.cache.subtitle"),
    ]

    /// 内置全集 ID 集合。
    public static var allIDs: Set<String> { Set(all.map(\.id)) }

    /// 按目录名（小写）反查规则。多条同名规则全部返回（如 `build` / `venv` 兄弟标记不同）。
    public static func rules(for directoryName: String) -> [DevArtifactRule] {
        let key = directoryName.lowercased()
        return all.filter { $0.directoryName == key }
    }

    /// 按生态分组返回（UI 设置面板用）。
    public static func grouped() -> [(DevArtifactRule.Ecosystem, [DevArtifactRule])] {
        DevArtifactRule.Ecosystem.allCases.map { eco in
            (eco, all.filter { $0.ecosystem == eco })
        }
    }
}
