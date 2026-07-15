import Foundation

/// Mole `app_protection_data.sh` 移植到 Swift 的运行期匹配引擎。
///
/// **职责**（Single Responsibility）：
/// - 只回答一个问题：「给定 bundle ID `com.example.foo`，是否命中受保护规则，命中哪一类」
/// - **不**做路径解析、**不**调用 SafetyEngine、**不**做 IO
///
/// **数据源**：[Resources/protected_bundles.json](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/Resources/protected_bundles.json)
///
/// **使用方**：[SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) `evaluateStandardized` 末尾叠加规则。
///
/// **性能契约**：
/// - 启动期一次性 decode JSON + 分桶预编译，O(n)，n ≈ 350 条规则
/// - 单次 `match(bundleID:)` 期望 O(1)（精确桶）或 O(prefixes) ≈ O(50)（通配桶）
public enum BundleProtection {
    /// 命中类型，决定 SafetyEngine 如何升级 verdict。
    public enum Kind: Sendable, Equatable {
        /// 系统核心组件 → 强制 `.forbid`（com.apple.finder / dock / Settings* 等）
        case systemCritical
        /// 用户敏感数据 → 升级到至少 `.confirm`（1Password / JetBrains / WeChat 等）
        case dataProtected
        /// Apple 自家但可被用户卸载（Xcode / Final Cut Pro / iWork） → 不升级，仅打标
        case appleUninstallable
    }

    /// 匹配结果。`pattern` 用于审计 / 单测断言。
    public struct Match: Sendable, Equatable {
        public let kind: Kind
        public let pattern: String
    }

    // MARK: - Public API

    /// 全局共享实例（懒加载 + 线程安全）。
    public static let shared: BundleProtectionMatcher = {
        do {
            return try BundleProtectionMatcher.loadFromBundle()
        } catch {
            // 普通扫描判定保持历史兼容：加载失败时 matcher 不产生额外命中。
            // 但失败状态必须被保留下来，删除能力层会据此拒绝铸造 vendor override，
            // 不能把“资源不可用”误当成“已确认没有受保护 bundle”。
            return BundleProtectionMatcher.unavailable(
                failure: BundleProtectionLoadFailure.classify(error),
                loadError: error
            )
        }
    }()

    /// 便捷入口。命中返回 Match，未命中返回 nil。
    public static func match(bundleID: String) -> Match? {
        shared.match(bundleID: bundleID)
    }
}

/// `protected_bundles.json` 的结构化加载失败原因。
///
/// 删除能力层只关心规则证据是否完整，不应解析不稳定的 NSError 文案；因此把底层错误
/// 归一化成可比较、可测试的有限状态。底层 `loadError` 仍保留给诊断日志使用。
public enum BundleProtectionLoadFailure: String, Sendable, Equatable {
    case resourceMissing
    case resourceUnreadable
    case invalidResource
    case unknown

    static func classify(_ error: Error) -> Self {
        if let bundleError = error as? BundleProtectionError,
           bundleError == .resourceMissing {
            return .resourceMissing
        }
        if error is DecodingError {
            return .invalidResource
        }
        if error is CocoaError {
            return .resourceUnreadable
        }
        return .unknown
    }
}

/// Bundle protection 规则证据的可用状态。
///
/// `.unavailable` 不会把普通扫描结果一刀切扩大为 forbid；它只表示安全能力层不能证明
/// “候选路径不属于受保护 bundle”，因此不得签发任何破坏性 override。
public enum BundleProtectionLoadState: Sendable, Equatable {
    case loaded
    case unavailable(BundleProtectionLoadFailure)

    public var hasCompleteEvidence: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// JSON 数据模型（与 protected_bundles.json schema 对齐）。
public struct BundleProtectionData: Sendable, Decodable, Equatable {
    public let version: Int
    public let source: String
    public let updatedAt: String
    public let systemCritical: [String]
    public let appleUninstallable: [String]
    public let dataProtected: [String]
    public let officialUninstallerRequired: [OfficialUninstaller]

    public struct OfficialUninstaller: Sendable, Decodable, Equatable {
        public let vendor: String
        public let bundlePrefixes: [String]
        public let nameFragments: [String]

        enum CodingKeys: String, CodingKey {
            case vendor
            case bundlePrefixes = "bundle_prefixes"
            case nameFragments = "name_fragments"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case source
        case updatedAt = "updated_at"
        case systemCritical = "system_critical"
        case appleUninstallable = "apple_uninstallable"
        case dataProtected = "data_protected"
        case officialUninstallerRequired = "official_uninstaller_required"
    }

    public static let empty = BundleProtectionData(
        version: 0,
        source: "",
        updatedAt: "",
        systemCritical: [],
        appleUninstallable: [],
        dataProtected: [],
        officialUninstallerRequired: []
    )
}

/// 匹配器：把 JSON 三个 list 按模式形状分桶预编译，提供 O(1) ~ O(prefixes) 查询。
public final class BundleProtectionMatcher: @unchecked Sendable {
    public let data: BundleProtectionData
    public let loadError: Error?
    public let loadState: BundleProtectionLoadState

    // 三个 Kind 各自的三个桶（exact / prefix / contains）
    private let systemExact: Set<String>
    private let systemPrefix: [String]
    private let systemContains: [String]

    private let appleUninstallableExact: Set<String>
    private let appleUninstallablePrefix: [String]
    private let appleUninstallableContains: [String]

    private let dataExact: Set<String>
    private let dataPrefix: [String]
    private let dataContains: [String]

    private init(data: BundleProtectionData,
                 loadError: Error?,
                 loadState: BundleProtectionLoadState) {
        self.data = data
        self.loadError = loadError
        self.loadState = loadState

        let s = Self.partition(data.systemCritical)
        self.systemExact = s.exact
        self.systemPrefix = s.prefix
        self.systemContains = s.contains

        let a = Self.partition(data.appleUninstallable)
        self.appleUninstallableExact = a.exact
        self.appleUninstallablePrefix = a.prefix
        self.appleUninstallableContains = a.contains

        let d = Self.partition(data.dataProtected)
        self.dataExact = d.exact
        self.dataPrefix = d.prefix
        self.dataContains = d.contains
    }

    /// 构造已成功加载的不可变 matcher。保留 `loadError` 参数兼容已有调用；一旦传入
    /// 错误，状态会结构化为 unavailable，避免“空数据 + 有错误”被能力层当成完整证据。
    public convenience init(data: BundleProtectionData, loadError: Error? = nil) {
        let state = loadError.map {
            BundleProtectionLoadState.unavailable(BundleProtectionLoadFailure.classify($0))
        } ?? .loaded
        self.init(data: data, loadError: loadError, loadState: state)
    }

    /// 显式构造资源不可用的 matcher，用于启动失败路径与依赖注入测试。
    /// 该实例仍可安全调用 `match`（恒不命中），但 `loadState` 会让 destructive
    /// authorization fail closed。
    public static func unavailable(
        failure: BundleProtectionLoadFailure
    ) -> BundleProtectionMatcher {
        unavailable(failure: failure, loadError: nil)
    }

    static func unavailable(
        failure: BundleProtectionLoadFailure,
        loadError: Error?
    ) -> BundleProtectionMatcher {
        BundleProtectionMatcher(
            data: .empty,
            loadError: loadError,
            loadState: .unavailable(failure)
        )
    }

    /// 从 SafetyKit 资源 bundle 加载 protected_bundles.json。
    public static func loadFromBundle() throws -> BundleProtectionMatcher {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "protected_bundles", withExtension: "json") else {
            throw BundleProtectionError.resourceMissing
        }
        let raw = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(BundleProtectionData.self, from: raw)
        return BundleProtectionMatcher(data: decoded)
    }

    /// 给定 bundle ID 返回 Match（命中最高优先级的 Kind）。
    ///
    /// 优先级：systemCritical > dataProtected > appleUninstallable
    /// 理由：apple_uninstallable 的目的是绕开 systemCritical 的 `com.apple.*` 误伤，
    /// 但**只在用户主动卸载时**才需要这层放行；用作 cleanup 评估时，systemCritical
    /// 命中就直接 forbid，apple_uninstallable 不参与降级。
    public func match(bundleID: String) -> BundleProtection.Match? {
        if let p = matchOneKind(bundleID: bundleID,
                                exact: systemExact,
                                prefix: systemPrefix,
                                contains: systemContains) {
            return .init(kind: .systemCritical, pattern: p)
        }
        if let p = matchOneKind(bundleID: bundleID,
                                exact: dataExact,
                                prefix: dataPrefix,
                                contains: dataContains) {
            return .init(kind: .dataProtected, pattern: p)
        }
        if let p = matchOneKind(bundleID: bundleID,
                                exact: appleUninstallableExact,
                                prefix: appleUninstallablePrefix,
                                contains: appleUninstallableContains) {
            return .init(kind: .appleUninstallable, pattern: p)
        }
        return nil
    }

    // MARK: - Private

    private struct Buckets {
        let exact: Set<String>
        let prefix: [String]   // 不含 `*`，匹配规则：bundleID 以 prefix 开头
        let contains: [String] // 含 `*` 中段，按 glob 语义匹配
    }

    /// 按 pattern 形状分桶：
    /// - 无 `*`                              → exact（O(1) Set）
    /// - 仅末尾 `*`（如 `com.1password.*`）  → prefix（保留去掉 `*` 后的串）
    /// - 其他含 `*` 的（如 `*ShadowsocksX-NG*`） → contains（用 NSRegular 转 glob）
    private static func partition(_ patterns: [String]) -> Buckets {
        var exact: Set<String> = []
        var prefix: [String] = []
        var contains: [String] = []
        for raw in patterns {
            if !raw.contains("*") {
                exact.insert(raw)
                continue
            }
            // 末尾 `*` 且唯一一个 `*`
            if raw.hasSuffix("*"), raw.dropLast().firstIndex(of: "*") == nil {
                prefix.append(String(raw.dropLast()))
                continue
            }
            contains.append(raw)
        }
        return Buckets(exact: exact, prefix: prefix, contains: contains)
    }

    private func matchOneKind(bundleID: String,
                              exact: Set<String>,
                              prefix: [String],
                              contains: [String]) -> String? {
        if exact.contains(bundleID) { return bundleID }
        for p in prefix where bundleID.hasPrefix(p) { return p + "*" }
        for p in contains where Self.globMatch(pattern: p, candidate: bundleID) {
            return p
        }
        return nil
    }

    /// 最简 glob：把 pattern 中的 `*` 转成 `.*`，其他字符 regex-escape，全串匹配。
    /// 仅供 contains 桶使用，数量受控（< 100 条），冷启动一次性编译可选。
    static func globMatch(pattern: String, candidate: String) -> Bool {
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*":
                regex.append(".*")
            case ".", "+", "?", "^", "$", "(", ")", "[", "]", "{", "}", "|", "\\":
                regex.append("\\")
                regex.append(ch)
            default:
                regex.append(ch)
            }
        }
        regex.append("$")
        return candidate.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public enum BundleProtectionError: Error, Equatable {
    case resourceMissing
}
