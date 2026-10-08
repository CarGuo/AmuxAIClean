import Foundation
import LogKit

/// 安全评分结果。
public enum SafetyVerdict: String, Sendable, Codable, Hashable {
    case safe       // 缓存、日志、DerivedData
    case confirm    // 需用户确认
    case forbid     // 不得走普通删除；具体能力边界继续由 SafetyRejection 区分
}

/// 拒绝原因（机器可读，便于审计 / 单测断言）。
public enum SafetyRejection: String, Sendable, Equatable {
    case relativePath           // 不是绝对路径
    case dotDotInPath           // 含 .. 段（路径穿越）
    case rootOrAboveHome        // / 或用户家目录本身
    case outsideUserDeletionScope // 不在当前用户 HOME / 系统返回的当前用户临时目录内
    case preflightCancelled      // 删除预检任务被取消；整批不得继续
    case hardForbidPrefix       // 命中硬编码黑名单
    case userDocumentsRoot      // 用户文档/桌面/下载的根
    case systemVolume           // 系统卷
    case insideAppBundle        // 在 .app 内但不是 Caches
    case sensitiveCredential    // 敏感凭证（SSH / GPG / Cloud / 签名密钥 / 项目级 .git）
    case vendorPathRule         // 命中 vendors.yaml 中显式声明 verdict=forbid 的 path 规则
    case accessDenied           // v1.3.zzzz：扫描期 BulkScanner 标记 permissionDenied / tccProtected，
                                // 上层在 pre-flight 一票否决——这类路径里实质没有数据，"删它"是个伪操作
    case userWhitelisted        // 用户明确标记“永不展示/永不清理”的路径或其祖先/后代
    case batchContainsForbidden // 同批其它路径命中 forbid；按批级原子合同，本路径也不能单独执行
    case bundleSystemCritical   // 命中 protected_bundles.json system_critical（Finder/Dock/Settings 等）
    case bundleDataProtected    // 命中 protected_bundles.json data_protected（1Password/JetBrains/WeChat 等）
    case ok
}

/// 占位实现。完整规则引擎将基于 YAML 规则库驱动，详见 PITFALLS §3 与 PLAN.md。
///
/// **设计原则**（写死的红线）：
/// 1. 只接受**绝对路径**，且必须经过 `URL(fileURLWithPath:).standardizedFileURL` 标准化
/// 2. 任何 `..` 段一律 forbid（防穿越）
/// 3. 用户家目录本身、桌面、文档、下载的**根目录**禁删（只能删它们的*子节点*）
/// 4. 命中黑名单一律 forbid（不留 confirm 余地）
public struct SafetyEngine: Sendable {
    /// Bundle protection matcher 在构造后不可变，可由测试注入“资源不可用”状态；生产默认
    /// 使用 Bundle.module 的共享加载结果。普通 evaluate 仍沿用历史降级语义，只有需要
    /// 铸造 destructive override 的能力层查询 `hasCompleteBundleProtectionEvidence`。
    private let bundleProtectionMatcher: BundleProtectionMatcher
    private let pathSemantics: FileSystemPathSemantics

    public init(bundleProtectionMatcher: BundleProtectionMatcher = BundleProtection.shared) {
        self.bundleProtectionMatcher = bundleProtectionMatcher
        self.pathSemantics = FileSystemPathSemantics()
    }

    init(bundleProtectionMatcher: BundleProtectionMatcher = BundleProtection.shared,
         pathCaseSensitivity: @escaping @Sendable (String) -> Bool?) {
        self.bundleProtectionMatcher = bundleProtectionMatcher
        self.pathSemantics = FileSystemPathSemantics(isCaseSensitive: pathCaseSensitivity)
    }

    public var bundleProtectionLoadState: BundleProtectionLoadState {
        bundleProtectionMatcher.loadState
    }

    /// 只有资源存在且完整解码后，调用方才可以证明某路径没有被 bundle 规则保护。
    public var hasCompleteBundleProtectionEvidence: Bool {
        bundleProtectionLoadState.hasCompleteEvidence
    }

    /// 写死的"绝对禁删"路径前缀（与 PITFALLS §3.5 黑名单一致）。
    /// 注意：所有前缀都是 standardizedFileURL **之后**的形式
    /// （即 `/private/var/db` 会被标准化为 `/var/db`，所以这里写两份覆盖）。
    public static let hardForbidPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin", "/sbin",
        "/Library/Apple",
        "/private/var/db", "/var/db",
        "/private/var/protected", "/var/protected",
        "/private/etc", "/etc",
        "/Volumes/Macintosh HD",
        "/Applications" // 不允许通过本工具删 App，让用户走 Finder
    ]

    /// 用户家目录下的"敏感凭证 / 配置"硬禁区（DEV_ARTIFACTS_RULES §2.7 黄金禁区）。
    /// 命中即 forbid + `.sensitiveCredential`，比 `userRootForbidden` 更细粒度
    /// （后者只拦根本身，前者连子节点也禁）。
    ///
    /// 这些路径删除后会导致：
    /// - 凭证丢失（SSH / GPG / AWS / GitHub CLI / npm token）
    /// - 签名失效（debug.keystore / adbkey / Provisioning Profiles）
    /// - 包管理器认证断裂（`.cargo/config`、`.gradle/init.d`、`.m2/settings*.xml`、
    ///   `.gradle/gradle.properties`、`.kube/config`、`.netrc`、`.npmrc`、`.yarnrc`、`.pypirc`）
    /// - 项目级 git 元数据丢失（`.gitconfig` / `.git-credentials`）
    ///
    /// 注意：`evaluateStandardized` 内部走 `homeRelativeCredentialSuffixes`
    /// 性能优化路径，此函数仅作公开 API 供测试 / 文档使用。
    public static func sensitiveCredentialPrefixes(home: String) -> [String] {
        homeRelativeCredentialSuffixes.map { "\(home)\($0)" }
    }

    /// 凭证禁区的"home 后缀"列表（不含 home 前缀本身）。
    /// 抽出来作为常量数组：避免每次 evaluate 都重建带 home 拼接的数组（GC 热点）。
    /// 与 `sensitiveCredentialPrefixes(home:)` 一一对应。
    static let homeRelativeCredentialSuffixes: [String] =
        dotfileCredentialSuffixes + libraryCredentialSuffixes

    /// `~/.xxx` 类（dotfile）凭证桶，evaluateStandardized 走分桶快速路径时只跑这一桶。
    static let dotfileCredentialSuffixes: [String] = [
        // SSH / GPG / Cloud CLI 凭证
        "/.ssh",
        "/.gnupg",
        "/.aws",
        "/.config/gh",
        "/.netrc",
        "/.npmrc",
        "/.yarnrc",
        "/.yarnrc.yml",
        "/.pypirc",
        "/.gitconfig",
        "/.git-credentials",
        // Android 签名 / adb 授权
        "/.android/debug.keystore",
        "/.android/adbkey",
        "/.android/adbkey.pub",
        // 包管理器全局配置
        "/.gradle/init.d",
        "/.gradle/gradle.properties",
        "/.cargo/config",
        "/.cargo/config.toml",
        "/.cargo/credentials",
        "/.cargo/credentials.toml",
        "/.m2/settings.xml",
        "/.m2/settings-security.xml",
        "/.kube/config"
    ]

    /// `~/Library/...` 类凭证桶。
    static let libraryCredentialSuffixes: [String] = [
        "/Library/Keychains",
        "/Library/Application Support/com.apple.TCC",
        "/Library/MobileDevice/Provisioning Profiles",
        "/Library/org.swift.swiftpm/security",
        // review 中危 #4：Docker Desktop 共享数据卷
        // `~/Library/Group Containers/group.com.docker` 内含：
        //   - desktop-linux/credentials（Docker Hub / Registry credstore）
        //   - desktop.json / docker.sock
        //   - 已运行容器的临时持久化数据（删了等同于 Docker Desktop "Reset to factory defaults"）
        // userRootForbidden 已经拦了 `~/Library/Group Containers` 根本身（exact-match），
        // 但子节点 group.com.docker 是 confirm 级别 —— 不够。这里升级为整个子树 forbid，
        // 让用户走 Docker Desktop 自带的 "clean / purge data" 工具清理（recipe 已在 §2.6 给出）。
        "/Library/Group Containers/group.com.docker"
    ]

    /// 文件名后缀级硬禁区。任意路径以此结尾即 forbid。
    /// 覆盖：Java / Android / iOS 签名容器、移动端 provisioning。
    public static let hardForbidSuffixes: [String] = [
        ".jks",
        ".keystore",
        ".p12",
        ".pfx",
        ".mobileprovision",
        ".provisionprofile"
    ]

    /// 路径段级硬禁区。任意路径包含 `/<segment>/` 或以 `/<segment>` 结尾即 forbid。
    /// 主要为 `.git`：项目级 git 元数据丢了等同于源码丢失（SafetyEngine 不会去探测
    /// bundle 内是否有 .git，直接拦截 `.git` 段最稳）。
    public static let hardForbidPathSegments: [String] = [
        ".git"
    ]

    /// 路径**子串**级硬禁区（跨段命中，区别于 `hardForbidPathSegments` 的单段命中）。
    /// 任意路径以 `/<fragment>/` 出现该子串即 forbid + `.sensitiveCredential`。
    ///
    /// 设计动机（review 中危 #4）：
    /// VS Code / Cursor / Trae / Windsurf / Cody 等基于 Code-OSS 的编辑器都把
    /// 用户登录 token、Copilot 会话、远程会话密钥写在
    /// `~/Library/Application Support/<vendor>/User/globalStorage` 下。
    /// vendor 名千变万化（每出一个新分叉就要在 yaml 里加一行），用 vendor-rule 维护
    /// 不可持续；而 globalStorage 这个段名是 Code-OSS 上游硬编码的，跨 vendor 稳定。
    /// 所以做成路径子串级硬安全网：路径里出现 `/User/globalStorage/` 一律拦。
    ///
    /// 进一步扩展（review 中危 #6）：
    /// 全局工具二进制目录被错删 = 命令行环境瞬间崩坏（yaml 也已显式 forbid，这里是
    /// runtime 兜底，防 yaml 改坏 / 未来动态 root 探测漏判）：
    /// - `/.pub-cache/bin/` —— Flutter / Dart `pub global activate` 安装的工具（删了
    ///   `dart pub global list` 里所有用户级工具失效）
    /// - `/dart-sdk/bin/` —— 手动解压的 Dart SDK 编译器/分析器二进制
    /// 用子串而非单段是因为段名 `dart-sdk` 在文档/项目里也可能复用（不够强语义），
    /// 必须配上 `/bin/` 后缀才足够特征化为"全局工具二进制目录"。
    ///
    /// 与 `hardForbidPathSegments` 的差别：后者匹配单个 `/<seg>/`，这里匹配跨段子串
    /// `/User/globalStorage/`，无法用单段实现。
    public static let hardForbidPathContains: [String] = [
        "/User/globalStorage/",
        "/.pub-cache/bin/",
        "/dart-sdk/bin/"
    ]

    /// Data 卷 firmlink 前缀。
    static let dataVolumePrefix = "/System/Volumes/Data"
    private static let lowerDataVolumePrefix = "/system/volumes/data"

    /// 将 `/System/Volumes/Data/<subpath>` 归一化为 `/<subpath>`，消除 APFS firmlink 镜像路径绕过。
    @inline(__always)
    public static func stripDataVolumePrefix(_ standardized: String) -> String {
        let utf8 = standardized.utf8
        guard utf8.count >= 20 else { return standardized }
        var idx = utf8.startIndex
        guard utf8[idx] == 0x2F /* / */ else { return standardized }
        idx = utf8.index(after: idx)
        let second = utf8[idx]
        guard second == 0x53 /* S */ || second == 0x73 /* s */ else { return standardized }
        if standardized.hasPrefix(dataVolumePrefix + "/") {
            return String(standardized.dropFirst(dataVolumePrefix.count))
        }
        let lower = standardized.lowercased()
        if lower == lowerDataVolumePrefix {
            return "/"
        }
        if lower.hasPrefix(lowerDataVolumePrefix + "/") {
            return String(standardized.dropFirst(dataVolumePrefix.count))
        }
        return standardized
    }

    /// 归一化 home：剥除 `/System/Volumes/Data` 前缀与末尾多余的 `/`。
    static func normalizeHome(_ home: String) -> String {
        var stripped = stripDataVolumePrefix(home)
        while stripped.count > 1 && stripped.hasSuffix("/") {
            stripped.removeLast()
        }
        return stripped
    }

    /// `userRootForbidden(home:)` 对应的家目录相对后缀常量表（热路径零分配）。
    static let userRootForbiddenRelativeSuffixes: [String] = [
        "/Documents",
        "/Desktop",
        "/Downloads",
        "/Pictures",
        "/Movies",
        "/Music",
        "/Library",
        "/Library/Mobile Documents", // iCloud Drive 根
        "/Library/Containers",       // 沙盒容器根
        "/Library/Group Containers"
    ]

    /// `safeCachePrefixes(home:)` 对应的家目录相对前缀常量表（热路径零分配）。
    static let safeCacheRelativePrefixes: [String] = [
        "/Library/Caches/",
        "/Library/Logs/",
        "/Library/Developer/Xcode/DerivedData/",
        "/Library/Developer/Xcode/Archives/",
        "/Library/Developer/CoreSimulator/Caches/"
    ]

    /// 系统级共享 per-user 临时区前缀常量表（热路径零分配）。
    static let systemSafeCachePrefixes: [String] = [
        "/private/var/folders/",
        "/var/folders/"
    ]

    private static let lowerHardForbidPrefixes: [String] =
        hardForbidPrefixes.map { $0.lowercased() }
    private static let lowerDotfileCredentialSuffixes: [String] =
        dotfileCredentialSuffixes.map { $0.lowercased() }
    private static let lowerLibraryCredentialSuffixes: [String] =
        libraryCredentialSuffixes.map { $0.lowercased() }
    private static let lowerHardForbidSuffixes: [String] =
        hardForbidSuffixes.map { $0.lowercased() }
    private static let lowerHardForbidPathSegments: [String] =
        hardForbidPathSegments.map { $0.lowercased() }
    private static let lowerHardForbidPathContains: [String] =
        hardForbidPathContains.map { $0.lowercased() }
    private static let lowerUserRootForbiddenRelativeSuffixes: [String] =
        userRootForbiddenRelativeSuffixes.map { $0.lowercased() }

    /// 用户家目录下"根级别"禁删（防止用户拖进整个文件夹被一键带走）。
    public static func userRootForbidden(home: String) -> [String] {
        [home] + userRootForbiddenRelativeSuffixes.map { "\(home)\($0)" }
    }

    /// 已知"系统语义就是给清理工具刷的"路径前缀 —— 默认 `safe`，UI 可默认勾选。
    /// 见 PITFALLS §3 / §5.5：必须是**严格匹配的子节点**，不允许整删根本身。
    public static func safeCachePrefixes(home: String) -> [String] {
        let primary = safeCacheRelativePrefixes.map { "\(home)\($0)" }
        return primary + primary.map { "\(dataVolumePrefix)\($0)" } + systemSafeCachePrefixes
    }

    /// 严格判定。返回 (verdict, rejection)。
    /// - 任何不确定都向 `forbid` 倾斜，宁可误拒不可误删。
    ///
    /// **GSYLog 埋点（v1.3.zzzz Phase 6）**：所有 forbid 出口在此 wrapper 集中打 debug 级日志，
    /// 调用极频繁（每条候选路径都过一次），用 debug 级避免污染 Console；
    /// Release 默认 .info 阈值不会写盘，开发期 .debug 时可定位"为什么这条被拒了"。
    public func evaluate(path: String, home: String = NSHomeDirectory()) -> (SafetyVerdict, SafetyRejection) {
        let result = evaluateInternal(path: path, home: home)
        if result.0 == .forbid {
            GSYLog.debug(.safety, "forbid path=\(path) reason=\(result.1.rawValue)")
        }
        return result
    }

    private func evaluateInternal(path: String, home: String) -> (SafetyVerdict, SafetyRejection) {
        // 1. 必须绝对路径
        guard path.hasPrefix("/") else {
            return (.forbid, .relativePath)
        }
        // 2. 不能含 ..
        if path.contains("/../") || path.hasSuffix("/..") || path == ".." {
            return (.forbid, .dotDotInPath)
        }
        // 3. 标准化后再比较；若路径中间包含 symlink，再用真实路径做一次更保守判定。
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let base = evaluateStandardized(standardized: standardized, home: home)
        let resolved = Self.resolvedSymlinkPath(forStandardizedPath: standardized)
        guard resolved != standardized else { return base }
        let resolvedResult = evaluateStandardized(standardized: resolved, home: home)
        return Self.moreRestrictive(base, resolvedResult)
    }

    /// 已 standardize 路径的内部判定。trie 重载会复用这个入口，避免重复 standardize。
    /// 调用者必须保证 `standardized` 已经过 `URL.standardizedFileURL.path`。
    private func evaluateStandardized(standardized: String, home: String) -> (SafetyVerdict, SafetyRejection) {
        // 4. 根目录、`/` 本身
        if standardized == "/" || standardized.isEmpty {
            return (.forbid, .rootOrAboveHome)
        }
        // 5. 统一剥除 `/System/Volumes/Data/` firmlink 前缀，确保第 5~9 步全部使用一致的
        //    canonical 路径，防止通过 `/System/Volumes/Data/Users/...` 绕过用户根、凭证或 bundle 保护。
        let canonical = Self.stripDataVolumePrefix(standardized)
        if canonical == "/" || canonical.isEmpty {
            return (.forbid, .rootOrAboveHome)
        }
        let canonicalHome = Self.normalizeHome(home)
        let lowerCanonical = canonical.lowercased()
        let lowerHome = canonicalHome.lowercased()
        for prefix in Self.lowerHardForbidPrefixes {
            if lowerCanonical == prefix || lowerCanonical.hasPrefix(prefix + "/") {
                return (.forbid, .hardForbidPrefix)
            }
        }
        // 6. 用户根级目录不允许整删（零分配：直接基于 canonicalHome 与相对后缀比较）
        if lowerCanonical == lowerHome {
            return (.forbid, .userDocumentsRoot)
        }
        let lowerHomeRelative: String? = lowerCanonical.hasPrefix(lowerHome + "/")
            ? String(lowerCanonical.dropFirst(lowerHome.count))
            : nil
        if let relative = lowerHomeRelative {
            for suffix in Self.lowerUserRootForbiddenRelativeSuffixes {
                if relative == suffix {
                    return (.forbid, .userDocumentsRoot)
                }
            }
        }
        // 7. 不允许触碰其他卷的系统区
        if lowerCanonical.hasPrefix("/system/volumes/")
            && !lowerCanonical.hasPrefix("/system/volumes/data/") {
            return (.forbid, .systemVolume)
        }
        // 7.1 敏感凭证 / 配置（DEV_ARTIFACTS_RULES §2.7）。
        //     必须放在 safeCache 之前，否则 `~/Library/org.swift.swiftpm/security`
        //     这种"在 ~/Library 下但属于凭证"的路径会被错误升级为 safe。
        if let relative = lowerHomeRelative, relative.count > 1 {
            let firstCharIdx = relative.index(after: relative.startIndex)
            let firstChar = relative[firstCharIdx]
            let bucket: [String]
            if firstChar == "." {
                bucket = Self.lowerDotfileCredentialSuffixes
            } else if firstChar == "l" {
                bucket = Self.lowerLibraryCredentialSuffixes
            } else {
                bucket = []
            }
            // v2026.09.06 SR-02: recycling an ancestor also removes the credential below it.
            // Compare both directions with component boundaries. This closes every ancestor
            // of the existing credential rules without adding ad-hoc protected directories or
            // traversing children on the UI/scanning hot path.
            let descendantPrefix = relative + "/"
            for suffix in bucket {
                if relative == suffix || relative.hasPrefix(suffix + "/")
                    || suffix.hasPrefix(descendantPrefix) {
                    return (.forbid, .sensitiveCredential)
                }
            }
        }
        // 7.2 文件名后缀禁区（签名容器 / Provisioning）。
        for suffix in Self.lowerHardForbidSuffixes {
            if lowerCanonical.hasSuffix(suffix) {
                return (.forbid, .sensitiveCredential)
            }
        }
        // 7.3 路径段禁区（任何 .git 元数据目录都视为源码安全网）。
        for segment in Self.lowerHardForbidPathSegments {
            let middle = "/\(segment)/"
            let tail = "/\(segment)"
            if lowerCanonical.contains(middle) || lowerCanonical.hasSuffix(tail) {
                return (.forbid, .sensitiveCredential)
            }
        }
        // 7.4 路径子串禁区（review 中危 #4 / #6）。
        for fragment in Self.lowerHardForbidPathContains {
            if lowerCanonical.contains(fragment) {
                return (.forbid, .sensitiveCredential)
            }
            if fragment.hasSuffix("/") {
                let trimmed = String(fragment.dropLast())
                if lowerCanonical.hasSuffix(trimmed) {
                    return (.forbid, .sensitiveCredential)
                }
            }
        }
        // 8. Positive cache matches honor filesystem case semantics before default selection.
        let isSafeCachePath: Bool
        if lowerHomeRelative != nil {
            isSafeCachePath = Self.safeCacheRelativePrefixes.contains {
                pathSemantics.matchesSafeRule(pattern: canonicalHome + $0, path: canonical)
            }
        } else {
            isSafeCachePath = Self.systemSafeCachePrefixes.contains {
                pathSemantics.matchesSafeRule(pattern: $0, path: canonical)
            }
        }
        if isSafeCachePath {
            // 8.1 bundle 保护叠加：safe 路径若属于 data_protected app
            //     （例：~/Library/Caches/com.1password.7/Logs），升级为 confirm。
            if let bm = bundleMatch(lowerCanonical: lowerCanonical, lowerHome: lowerHome),
               bm.kind == .dataProtected {
                return (.confirm, .bundleDataProtected)
            }
            return (.safe, .ok)
        }

        // 9. bundle 保护兜底：confirm 默认出口前再扫一次。
        if let bm = bundleMatch(lowerCanonical: lowerCanonical, lowerHome: lowerHome) {
            switch bm.kind {
            case .systemCritical:
                return (.confirm, .bundleSystemCritical)
            case .dataProtected:
                return (.confirm, .bundleDataProtected)
            case .appleUninstallable:
                break
            }
        }

        return (.confirm, .ok)
    }

    // MARK: - Bundle Protection 接入（Mole `app_protection_data.sh` 对齐）

    /// 从已 standardize 的路径中提取 bundle ID，并查询构造时注入的
    /// [BundleProtectionMatcher](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/BundleProtection.swift)。
    ///
    /// **设计原则：保守解析，永不误升级**。仅识别下列**确定性**路径模式：
    /// - `~/Library/Caches/<bundleID>[/...]`
    /// - `~/Library/Preferences/<bundleID>.plist`
    /// - `~/Library/Containers/<bundleID>[/...]`
    /// - `~/Library/Group Containers/<bundleID>[/...]`
    /// - `~/Library/HTTPStorages/<bundleID>[/...]`
    /// - `~/Library/WebKit/<bundleID>[/...]`
    /// - `~/Library/Saved Application State/<bundleID>.savedState[/...]`
    ///
    /// **不**尝试读 Info.plist / 反查 LaunchServices —— 那会引入 IO 与权限风险，
    /// 且 evaluate 在 ScanCoordinator 热路径上调用极频繁（5000 path/批次量级）。
    ///
    /// **性能契约（VendorTrieTests 性能基准守护）**：
    /// - 5000 次评估必须 < 200ms（本地）/ 350ms（CI）
    /// - 因此本函数零分配：用 Substring 切片 + Index 步进，不用 split / String(...) 构造
    /// - 非 `~/Library` 路径 1 步 hasPrefix 短路退出
    func bundleMatch(standardized: String, home: String) -> BundleProtection.Match? {
        let lowerCanonical = Self.stripDataVolumePrefix(standardized).lowercased()
        let lowerHome = Self.normalizeHome(home).lowercased()
        return bundleMatch(lowerCanonical: lowerCanonical, lowerHome: lowerHome)
    }

    private func bundleMatch(lowerCanonical: String, lowerHome: String) -> BundleProtection.Match? {
        // 1. 必须是 home/Library/ 子路径 —— 一次 hasPrefix 短路
        let libraryRoot = lowerHome + "/library/"
        guard lowerCanonical.hasPrefix(libraryRoot) else { return nil }

        // 2. 找第一段（dir）：libraryRoot 后到下一个 '/'
        let afterRoot = lowerCanonical.index(lowerCanonical.startIndex, offsetBy: libraryRoot.count)
        guard let slashAfterDir = lowerCanonical[afterRoot...].firstIndex(of: "/") else {
            return nil
        }
        let dir = lowerCanonical[afterRoot..<slashAfterDir]

        // 3. 找第二段（candidate）：slashAfterDir+1 到下一个 '/' 或字符串尾
        let candidateStart = lowerCanonical.index(after: slashAfterDir)
        let candidateEnd = lowerCanonical[candidateStart...].firstIndex(of: "/") ?? lowerCanonical.endIndex
        var candidate = lowerCanonical[candidateStart..<candidateEnd]
        guard !candidate.isEmpty else { return nil }

        // 4. 按 dir 形状剥后缀（.plist / .savedState），无配对的 dir 早退
        let isContainerDir: Bool
        switch dir {
        case "caches", "containers", "group containers",
             "httpstorages", "webkit":
            isContainerDir = true
        case "preferences":
            guard candidate.hasSuffix(".plist") else { return nil }
            candidate = candidate.dropLast(".plist".count)
            isContainerDir = false
        case "saved application state":
            guard candidate.hasSuffix(".savedstate") else { return nil }
            candidate = candidate.dropLast(".savedstate".count)
            isContainerDir = false
        default:
            return nil
        }

        // 5. 不含 `.` 的候选段只在 Caches/Containers 下放行（覆盖 Cursor / Claude / Firefox
        //    这类无点 ID），其他 dir 退出避免对随机目录名做 set 查询
        if !candidate.contains(".") && !isContainerDir { return nil }

        return bundleProtectionMatcher.match(bundleID: String(candidate))
    }

    /// 删除能力层查询“路径是否属于任何 protected_bundles 规则”。
    ///
    /// Vendor path override 不能只看 trie 最终返回的 `.vendorPathRule`：vendor 规则比
    /// base bundle 标记更具体，可能覆盖 `.bundleDataProtected`，而 appleUninstallable
    /// 本身甚至不会升级 verdict。这个只读 API 复用同一套零 IO 路径解析，并同时检查
    /// symlink 最终身份，让删除边界可以明确排除全部三类受保护 bundle。
    public static func isBundleProtected(path: String,
                                         home: String = NSHomeDirectory()) -> Bool {
        SafetyEngine().isPathBundleProtected(path: path, home: home)
    }

    /// 与静态兼容入口语义相同，但使用本 SafetyEngine 注入的 matcher/load state。
    /// 删除能力层必须走这个入口，避免测试或启动失败时查询了另一个全局 matcher。
    public func isPathBundleProtected(path: String,
                                      home: String = NSHomeDirectory()) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if bundleMatch(standardized: standardized, home: home) != nil {
            return true
        }
        let resolved = Self.resolvedSymlinkPath(forStandardizedPath: standardized)
        return resolved != standardized
            && bundleMatch(standardized: resolved, home: home) != nil
    }

    /// 简单语义包装：是否被禁。
    public func isForbidden(path: String, home: String = NSHomeDirectory()) -> Bool {
        evaluate(path: path, home: home).0 == .forbid
    }

    /// 带 vendor 规则的评估（PITFALLS §5.9）。
    /// 命中 vendor 规则的根目录会被强制降到 `.confirm`，UI 不默认勾选 + 显示提示
    /// （即使该路径在 safeCachePrefixes 里也不行 —— 比如 ~/Library/Caches/com.adobe 这种）。
    /// vendor 子目录（即非根目录）依然走 evaluate 原有逻辑。
    ///
    /// 外部 API 保持不变；内部委托给基于 `VendorTrie` 的高性能重载。
    /// 若同一组 vendors 会被反复评估，**强烈建议**外部自行 `VendorTrie.build(...)` 一次后
    /// 调用 `evaluate(path:trie:home:)`，避免每次评估都重建 trie。
    public func evaluate(path: String, vendors: [VendorRule],
                         home: String = NSHomeDirectory()) -> (SafetyVerdict, SafetyRejection, VendorRule?) {
        let trie = VendorTrie.build(vendors: vendors, home: home)
        return evaluate(path: path, trie: trie, home: home)
    }

    /// Trie 版评估：与 `evaluate(path:vendors:home:)` 语义等价，但匹配复杂度从
    /// O(vendors × prefixes) 降到 O(路径深度)。`trie` 由 `VendorTrie.build(...)` 预构建。
    public func evaluate(path: String, trie: VendorTrieNode,
                         home: String = NSHomeDirectory()) -> (SafetyVerdict, SafetyRejection, VendorRule?) {
        let result = evaluateTrieInternal(path: path, trie: trie, home: home)
        if result.0 == .forbid {
            GSYLog.debug(.safety, "forbid(trie) path=\(path) reason=\(result.1.rawValue)")
        }
        return result
    }

    private func evaluateTrieInternal(path: String, trie: VendorTrieNode,
                                      home: String) -> (SafetyVerdict, SafetyRejection, VendorRule?) {
        // 1. 基础前置校验（与 evaluate(path:home:) 前两步一致）
        guard path.hasPrefix("/") else {
            return (.forbid, .relativePath, nil)
        }
        if path.contains("/../") || path.hasSuffix("/..") || path == ".." {
            return (.forbid, .dotDotInPath, nil)
        }
        // 2. 只 standardize 一次，复用给 base 判定 + trie 匹配；若中间 symlink 指向更敏感位置，
        // 先采用更保守的真实路径判定，避免 vendor safe 或 cache safe 覆盖真实禁区。
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let canonical = Self.stripDataVolumePrefix(standardized)
        let (baseVerdict, rejection) = evaluateStandardized(standardized: standardized, home: home)
        if baseVerdict == .forbid { return (baseVerdict, rejection, nil) }
        let resolved = Self.resolvedSymlinkPath(forStandardizedPath: standardized)
        let resolvedCanonical = Self.stripDataVolumePrefix(resolved)
        var effectiveBase = (baseVerdict, rejection)
        var resolvedHit: (rule: VendorRule, isExactRoot: Bool, pathOverride: PathRule?)? = nil
        if resolved != standardized {
            let resolvedBase = evaluateStandardized(standardized: resolved, home: home)
            effectiveBase = Self.moreRestrictive(effectiveBase, resolvedBase)
            if effectiveBase.0 == .forbid {
                return (effectiveBase.0, effectiveBase.1, nil)
            }
            resolvedHit = VendorTrie.match(standardizedPath: resolvedCanonical, in: trie) {
                pathSemantics.matchesSafeRule(pattern: $0, path: resolvedCanonical)
            }
            if let rHit = resolvedHit {
                if rHit.pathOverride?.verdict == .forbid {
                    return (.forbid, .vendorPathRule, rHit.rule)
                }
                if rHit.pathOverride?.verdict == .confirm || (rHit.pathOverride == nil && rHit.isExactRoot) {
                    effectiveBase = Self.moreRestrictive(effectiveBase, (.confirm, .ok))
                }
            }
        }

        let confirmRejection: SafetyRejection = (
            effectiveBase.0 == .confirm && (
                effectiveBase.1 == .bundleSystemCritical || effectiveBase.1 == .bundleDataProtected
            )
        ) ? effectiveBase.1 : .ok

        guard let hit = VendorTrie.match(standardizedPath: canonical, in: trie, acceptSafeRule: {
            pathSemantics.matchesSafeRule(pattern: $0, path: canonical)
        }) else {
            if let rHit = resolvedHit,
               rHit.pathOverride?.verdict == .confirm || (rHit.pathOverride == nil && rHit.isExactRoot) {
                return (.confirm, confirmRejection, rHit.rule)
            }
            return (effectiveBase.0, effectiveBase.1, nil)
        }
        // path 级 verdict 覆盖（DEV_ARTIFACTS_RULES.md §2.x）：
        // 当 vendor 在 yaml 里显式声明了 `paths: [{path, verdict}]`，那条 path-rule 比
        // vendor 根的默认 `.confirm` 更"具体"，应优先生效。
        // - override.forbid：升级到 forbid（注意 base 的 forbid 已经在上面短路了，
        //   所以这里不会绕过硬安全网；override 仅能在 base==safe/confirm 时生效）
        // - override.safe：即便 base 是 confirm，也按规则作者意图降级到 safe（但若路径是
        //   指向外部非 safe 目标的 symlink，则保留 effectiveBase，防止 symlink 降级绕过）
        // - override.confirm：与默认行为相同，仍走 confirm
        // path-override 沿子树继承，所以 `Pods/Release/**` 这类规则不需要列举每个子文件。
        if let ovr = hit.pathOverride {
            switch ovr.verdict {
            case .forbid:
                return (.forbid, .vendorPathRule, hit.rule)
            case .safe:
                if resolved != standardized && effectiveBase.0 != .safe {
                    let resolvedTrieSafe = resolvedHit?.pathOverride?.verdict == .safe
                    if !resolvedTrieSafe {
                        return (effectiveBase.0, confirmRejection, hit.rule)
                    }
                }
                return (.safe, .ok, hit.rule)
            case .confirm:
                return (.confirm, confirmRejection, hit.rule)
            }
        }
        if hit.isExactRoot {
            // 命中 vendor 根 —— 强制 confirm
            return (.confirm, confirmRejection, hit.rule)
        } else {
            // 命中 vendor 子目录 —— 用 effectiveBase（safe / confirm）
            return (effectiveBase.0, effectiveBase.1, hit.rule)
        }
    }

    private static func resolvedSymlinkPath(forStandardizedPath path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func moreRestrictive(
        _ lhs: (SafetyVerdict, SafetyRejection),
        _ rhs: (SafetyVerdict, SafetyRejection)
    ) -> (SafetyVerdict, SafetyRejection) {
        let lhsSeverity = severity(lhs.0)
        let rhsSeverity = severity(rhs.0)
        if rhsSeverity != lhsSeverity {
            return rhsSeverity > lhsSeverity ? rhs : lhs
        }
        if lhs.1 == .ok && rhs.1 != .ok {
            return rhs
        }
        return lhs
    }

    private static func severity(_ verdict: SafetyVerdict) -> Int {
        switch verdict {
        case .safe: return 0
        case .confirm: return 1
        case .forbid: return 2
        }
    }
}
