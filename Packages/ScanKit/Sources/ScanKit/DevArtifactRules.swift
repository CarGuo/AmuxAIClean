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
        case general          // 通用：.cache / .turbo

        public var id: String { rawValue }

        /// i18n key —— UI 层用 `String(localized:)` 拿翻译；ScanKit 不做翻译。
        /// 形如 `ecosystem.web` / `ecosystem.appleMobile` 等。
        public var localizationKey: String { "ecosystem.\(rawValue)" }

        public var displayName: String {
            switch self {
            case .web:            return "Web / Node 生态"
            case .appleMobile:    return "iOS / macOS"
            case .androidFlutter: return "Android / Flutter"
            case .rust:           return "Rust"
            case .go:             return "Go"
            case .python:         return "Python"
            case .jvm:            return "JVM（Maven / Gradle 全局缓存）"
            case .general:        return "通用缓存"
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
                pruneSubtree: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.directoryName = directoryName.lowercased()
        self.siblingMarkers = siblingMarkers
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
              subtitle: "JavaScript 依赖，运行 npm/yarn/pnpm install 重建"),
        .init(id: "web.next",
              displayName: ".next",
              directoryName: ".next",
              siblingMarkers: ["package.json", "next.config.js", "next.config.mjs", "next.config.ts"],
              ecosystem: .web, verdict: .safe,
              subtitle: "Next.js 构建缓存"),
        .init(id: "web.nuxt",
              displayName: ".nuxt",
              directoryName: ".nuxt",
              siblingMarkers: ["package.json", "nuxt.config.js", "nuxt.config.ts"],
              ecosystem: .web, verdict: .safe,
              subtitle: "Nuxt 构建缓存"),
        .init(id: "web.svelte_kit",
              displayName: ".svelte-kit",
              directoryName: ".svelte-kit",
              siblingMarkers: ["package.json", "svelte.config.js"],
              ecosystem: .web, verdict: .safe,
              subtitle: "SvelteKit 构建缓存"),
        .init(id: "web.parcel_cache",
              displayName: ".parcel-cache",
              directoryName: ".parcel-cache",
              siblingMarkers: ["package.json"],
              ecosystem: .web, verdict: .safe,
              subtitle: "Parcel 构建缓存"),
        .init(id: "web.expo",
              displayName: ".expo",
              directoryName: ".expo",
              siblingMarkers: ["package.json", "app.json", "app.config.js", "app.config.ts"],
              ecosystem: .web, verdict: .safe,
              subtitle: "Expo（React Native）本地缓存"),
        .init(id: "web.dist",
              displayName: "dist",
              directoryName: "dist",
              siblingMarkers: ["package.json"],
              ecosystem: .web, verdict: .safe,
              subtitle: "前端打包产物（Vite / Webpack）"),
        .init(id: "web.out_next",
              displayName: "out",
              directoryName: "out",
              siblingMarkers: ["package.json"],
              ecosystem: .web, verdict: .confirm,
              subtitle: "Next.js export 产物（也常见于其他 Web 项目）"),
        .init(id: "web.coverage",
              displayName: "coverage",
              directoryName: "coverage",
              siblingMarkers: ["package.json", "jest.config.js", "jest.config.ts", "vitest.config.ts"],
              ecosystem: .web, verdict: .safe,
              subtitle: "前端测试覆盖率报告"),

        // MARK: iOS / macOS
        .init(id: "apple.pods",
              displayName: "Pods",
              directoryName: "pods",
              siblingMarkers: ["Podfile", "Podfile.lock"],
              ecosystem: .appleMobile, verdict: .confirm,
              subtitle: "CocoaPods 依赖目录，pod install 重建"),
        .init(id: "apple.swiftpm_build",
              displayName: ".build",
              directoryName: ".build",
              siblingMarkers: ["Package.swift"],
              ecosystem: .appleMobile, verdict: .safe,
              subtitle: "Swift Package Manager 本地构建产物"),
        .init(id: "apple.spm_dot",
              displayName: ".swiftpm",
              directoryName: ".swiftpm",
              siblingMarkers: ["Package.swift"],
              ecosystem: .appleMobile, verdict: .confirm,
              subtitle: "SwiftPM 配置 / Xcode workspace 数据"),
        .init(id: "apple.carthage",
              displayName: "Carthage",
              directoryName: "carthage",
              siblingMarkers: ["Cartfile", "Cartfile.resolved"],
              ecosystem: .appleMobile, verdict: .safe,
              subtitle: "Carthage 依赖产物"),
        .init(id: "apple.xcuserdata",
              displayName: "xcuserdata",
              directoryName: "xcuserdata",
              siblingMarkers: [],
              ecosystem: .appleMobile, verdict: .safe,
              subtitle: "Xcode 个人 workspace 状态（无需兄弟兜底，本目录只在 .xcodeproj/.xcworkspace 内）"),

        // MARK: Android / Flutter
        .init(id: "android.gradle_proj",
              displayName: ".gradle",
              directoryName: ".gradle",
              siblingMarkers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "项目级 Gradle 缓存（非 ~/.gradle 全局缓存，那条单独有）"),
        .init(id: "android.build_gradle",
              displayName: "build（Gradle 项目）",
              directoryName: "build",
              siblingMarkers: ["build.gradle", "build.gradle.kts", "pom.xml"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "Android / JVM 构建产物"),
        .init(id: "android.cxx",
              displayName: ".cxx",
              directoryName: ".cxx",
              siblingMarkers: ["build.gradle", "build.gradle.kts", "CMakeLists.txt"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "Android NDK / CMake 中间产物"),
        .init(id: "flutter.dart_tool",
              displayName: ".dart_tool",
              directoryName: ".dart_tool",
              siblingMarkers: ["pubspec.yaml"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "Flutter / Dart 工具缓存"),
        .init(id: "flutter.build",
              displayName: "build（Flutter 项目）",
              directoryName: "build",
              siblingMarkers: ["pubspec.yaml"],
              ecosystem: .androidFlutter, verdict: .safe,
              subtitle: "Flutter 构建产物"),

        // MARK: Rust
        .init(id: "rust.target",
              displayName: "target",
              directoryName: "target",
              siblingMarkers: ["Cargo.toml"],
              ecosystem: .rust, verdict: .safe,
              subtitle: "Rust / Cargo 构建产物，cargo build 重建"),

        // MARK: Go
        .init(id: "go.vendor",
              displayName: "vendor",
              directoryName: "vendor",
              siblingMarkers: ["go.mod"],
              ecosystem: .go, verdict: .confirm,
              subtitle: "Go module vendor，go mod vendor 重建"),

        // MARK: Python
        .init(id: "py.pycache",
              displayName: "__pycache__",
              directoryName: "__pycache__",
              siblingMarkers: [],
              ecosystem: .python, verdict: .safe,
              subtitle: "Python 字节码缓存，运行时自动重建"),
        .init(id: "py.venv",
              displayName: ".venv / venv",
              directoryName: ".venv",
              siblingMarkers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
              ecosystem: .python, verdict: .confirm,
              subtitle: "Python 虚拟环境（删后需重建）"),
        .init(id: "py.venv2",
              displayName: "venv",
              directoryName: "venv",
              siblingMarkers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
              ecosystem: .python, verdict: .confirm,
              subtitle: "Python 虚拟环境（venv 命名变体）"),
        .init(id: "py.pytest_cache",
              displayName: ".pytest_cache",
              directoryName: ".pytest_cache",
              siblingMarkers: [],
              ecosystem: .python, verdict: .safe,
              subtitle: "pytest 测试缓存"),
        .init(id: "py.mypy_cache",
              displayName: ".mypy_cache",
              directoryName: ".mypy_cache",
              siblingMarkers: [],
              ecosystem: .python, verdict: .safe,
              subtitle: "mypy 类型检查缓存"),
        .init(id: "py.tox",
              displayName: ".tox",
              directoryName: ".tox",
              siblingMarkers: ["tox.ini", "pyproject.toml"],
              ecosystem: .python, verdict: .safe,
              subtitle: "tox 测试虚拟环境"),

        // MARK: 通用
        .init(id: "general.turbo",
              displayName: ".turbo",
              directoryName: ".turbo",
              siblingMarkers: ["package.json", "turbo.json"],
              ecosystem: .general, verdict: .safe,
              subtitle: "Turborepo 任务缓存"),
        .init(id: "general.cache",
              displayName: ".cache",
              directoryName: ".cache",
              siblingMarkers: ["package.json"],
              ecosystem: .general, verdict: .safe,
              subtitle: "通用 .cache（仅在 Node 项目下命中）"),
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
