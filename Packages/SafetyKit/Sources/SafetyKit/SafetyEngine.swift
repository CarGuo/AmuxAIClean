import Foundation
import LogKit

/// 安全评分结果。
public enum SafetyVerdict: String, Sendable, Codable, Hashable {
    case safe       // 缓存、日志、DerivedData
    case confirm    // 需用户确认
    case forbid     // SIP / 用户文档 / 共享厂商 / 硬编码黑名单
}

/// 拒绝原因（机器可读，便于审计 / 单测断言）。
public enum SafetyRejection: String, Sendable, Equatable {
    case relativePath           // 不是绝对路径
    case dotDotInPath           // 含 .. 段（路径穿越）
    case rootOrAboveHome        // / 或用户家目录本身
    case hardForbidPrefix       // 命中硬编码黑名单
    case userDocumentsRoot      // 用户文档/桌面/下载的根
    case systemVolume           // 系统卷
    case insideAppBundle        // 在 .app 内但不是 Caches
    case sensitiveCredential    // 敏感凭证（SSH / GPG / Cloud / 签名密钥 / 项目级 .git）
    case vendorPathRule         // 命中 vendors.yaml 中显式声明 verdict=forbid 的 path 规则
    case accessDenied           // v1.3.zzzz：扫描期 BulkScanner 标记 permissionDenied / tccProtected，
                                // 上层在 pre-flight 一票否决——这类路径里实质没有数据，"删它"是个伪操作
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
    public init() {}

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

    /// 用户家目录下"根级别"禁删（防止用户拖进整个文件夹被一键带走）。
    public static func userRootForbidden(home: String) -> [String] {
        [
            home,
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Library",
            "\(home)/Library/Mobile Documents", // iCloud Drive 根
            "\(home)/Library/Containers",       // 沙盒容器根
            "\(home)/Library/Group Containers"
        ]
    }

    /// 已知"系统语义就是给清理工具刷的"路径前缀 —— 默认 `safe`，UI 可默认勾选。
    /// 见 PITFALLS §3 / §5.5：必须是**严格匹配的子节点**，不允许整删根本身。
    public static func safeCachePrefixes(home: String) -> [String] {
        let dataPrefix = "/System/Volumes/Data" // firmlink 等价镜像
        let primary = [
            "\(home)/Library/Caches/",
            "\(home)/Library/Logs/",
            "\(home)/Library/Developer/Xcode/DerivedData/",
            "\(home)/Library/Developer/Xcode/Archives/",
            "\(home)/Library/Developer/CoreSimulator/Caches/"
        ]
        // 系统级（任何用户共享的 per-user 临时区）
        let system = [
            "/private/var/folders/",
            "/var/folders/"
        ]
        return primary + primary.map { "\(dataPrefix)\($0)" } + system
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
        // 3. 标准化后再比较
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return evaluateStandardized(standardized: standardized, home: home)
    }

    /// 已 standardize 路径的内部判定。trie 重载会复用这个入口，避免重复 standardize。
    /// 调用者必须保证 `standardized` 已经过 `URL.standardizedFileURL.path`。
    private func evaluateStandardized(standardized: String, home: String) -> (SafetyVerdict, SafetyRejection) {
        // 4. 根目录、`/` 本身
        if standardized == "/" || standardized.isEmpty {
            return (.forbid, .rootOrAboveHome)
        }
        // 5. 硬编码黑名单
        //    M4-P0 修复：旧实现对 `/System/Volumes/Data/` 整体放过 hardForbid，导致 firmlink
        //    等价路径（`/System/Volumes/Data/etc`、`/usr`、`/Applications`、`/Library/Apple`、
        //    `/private/var/db` 等）完全绕过硬禁区。
        //
        //    修复方案：当路径位于 `/System/Volumes/Data/` 下时，**只**用"剥掉数据卷前缀"的
        //    等价路径 (`stripped`) 跑 hardForbid——这样 `/System/Volumes/Data/usr/bin` 会被
        //    `/usr` 前缀命中 forbid，而 `/System/Volumes/Data/private/var/folders/...`（safeCache
        //    镜像项）的 stripped `/private/var/folders/...` 不匹配任何 hardForbid 前缀，
        //    可以继续走到第 8 步升级为 safe。
        //
        //    非 Data 卷路径（普通 standardized）按原逻辑跑 hardForbid。
        let dataVolumePrefix = "/System/Volumes/Data"
        let isDataVolumeChild = standardized.hasPrefix(dataVolumePrefix + "/")
        let pathForHardForbid: String = isDataVolumeChild
            ? String(standardized.dropFirst(dataVolumePrefix.count))
            : standardized
        for prefix in Self.hardForbidPrefixes {
            if pathForHardForbid == prefix || pathForHardForbid.hasPrefix(prefix + "/") {
                return (.forbid, .hardForbidPrefix)
            }
        }
        // 6. 用户根级目录不允许整删
        for forbidden in Self.userRootForbidden(home: home) {
            if standardized == forbidden {
                return (.forbid, .userDocumentsRoot)
            }
        }
        // 7. 不允许触碰其他卷的系统区
        if standardized.hasPrefix("/System/Volumes/")
            && !standardized.hasPrefix("/System/Volumes/Data/") {
            return (.forbid, .systemVolume)
        }
        // 7.1 敏感凭证 / 配置（DEV_ARTIFACTS_RULES §2.7）。
        //     必须放在 safeCache 之前，否则 `~/Library/org.swift.swiftpm/security`
        //     这种"在 ~/Library 下但属于凭证"的路径会被错误升级为 safe。
        //
        //     性能优化：
        //     1) home 前缀短路：非家目录路径直接跳过
        //     2) 第二字符分桶：home 后的第一段要么是 `/.<dotfile>` 要么是 `/Library/...`，
        //        用 standardized[homeLen+1] 单字节判断只跑对应桶（27 → 平均 13 项）
        //     3) 用 hasPrefix(home + suffix) 直接走 String 内核 SIMD 比较，避免 UTF8 索引开销
        if standardized.hasPrefix(home + "/") {
            let homeEndIdx = standardized.index(standardized.startIndex,
                                                offsetBy: home.count + 1)
            // homeEndIdx 指向 home 后第一个字符（已知是 '/' 之后那位）
            let firstChar = standardized[homeEndIdx]
            let bucket: [String]
            if firstChar == "." {
                bucket = Self.dotfileCredentialSuffixes
            } else if firstChar == "L" {
                bucket = Self.libraryCredentialSuffixes
            } else {
                bucket = []
            }
            for suffix in bucket {
                let full = home + suffix
                if standardized == full || standardized.hasPrefix(full + "/") {
                    return (.forbid, .sensitiveCredential)
                }
            }
        }
        // 7.2 文件名后缀禁区（签名容器 / Provisioning）。
        for suffix in Self.hardForbidSuffixes {
            if standardized.hasSuffix(suffix) {
                return (.forbid, .sensitiveCredential)
            }
        }
        // 7.3 路径段禁区（任何 .git 元数据目录都视为源码安全网）。
        for segment in Self.hardForbidPathSegments {
            let middle = "/\(segment)/"
            let tail = "/\(segment)"
            if standardized.contains(middle) || standardized.hasSuffix(tail) {
                return (.forbid, .sensitiveCredential)
            }
        }
        // 7.4 路径子串禁区（review 中危 #4 / #6）。
        // 跨段命中：路径含 `/User/globalStorage/` 或全局工具二进制目录子串即 forbid。
        // 覆盖：
        // - VS Code / Cursor / Trae / Windsurf / Cody 等所有 Code-OSS 衍生编辑器
        //   的 `~/Library/Application Support/<vendor>/User/globalStorage`，
        //   不依赖 vendors.yaml 列举（每加一个新 vendor 都要改 yaml 不可持续）。
        // - Flutter/Dart 全局工具二进制目录（`/.pub-cache/bin/`、`/dart-sdk/bin/`）。
        //   作为 vendors.yaml forbid 规则的 runtime 兜底。
        //
        // 兼容"叶节点自身（无尾斜杠）"：fragment 末尾若为 `/`，同时也允许路径以 `<fragment 去掉尾斜杠>` 结尾命中
        // （否则 `/Users/foo/.pub-cache/bin` 这种刚好是 vendor 根的路径会漏拦，要降级到 vendors.yaml 兜底）。
        for fragment in Self.hardForbidPathContains {
            if standardized.contains(fragment) {
                return (.forbid, .sensitiveCredential)
            }
            if fragment.hasSuffix("/") {
                let trimmed = String(fragment.dropLast())
                if standardized.hasSuffix(trimmed) {
                    return (.forbid, .sensitiveCredential)
                }
            }
        }
        // 8. 已知缓存路径升级为 safe（UI 可默认勾选）
        for safePrefix in Self.safeCachePrefixes(home: home) {
            if standardized.hasPrefix(safePrefix) {
                // 8.1 bundle 保护叠加：safe 路径若属于 data_protected app
                //     （例：~/Library/Caches/com.1password.7/Logs），升级为 confirm。
                if let bm = Self.bundleMatch(standardized: standardized, home: home),
                   bm.kind == .dataProtected {
                    return (.confirm, .bundleDataProtected)
                }
                return (.safe, .ok)
            }
        }

        // 9. bundle 保护兜底：confirm 默认出口前再扫一次。
        //    设计取舍：两类命中都**只升级到 confirm**，不强 forbid。
        //    原因：真正"绝对禁删"的系统区已由 hardForbidPrefixes（/System、/Library/Apple
        //    等）完全拦截。用户家目录下的 `~/Library/Containers/com.apple.*` 是该 app 的
        //    用户数据容器（如 Mail Downloads），强 forbid 会与 vendors.yaml 的 confirm 规则
        //    冲突（RuleLoader 在 load-time 会把 vendor 整条丢弃）。
        //    appleUninstallable 仅供 uninstall 流程使用，cleanup 评估忽略。
        if let bm = Self.bundleMatch(standardized: standardized, home: home) {
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

    /// 从已 standardize 的路径中提取 bundle ID，并查询 [BundleProtection.shared](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/BundleProtection.swift)。
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
    static func bundleMatch(standardized: String, home: String) -> BundleProtection.Match? {
        // 1. 必须是 home/Library/ 子路径 —— 一次 hasPrefix 短路
        let libraryRoot = home + "/Library/"
        guard standardized.hasPrefix(libraryRoot) else { return nil }

        // 2. 找第一段（dir）：libraryRoot 后到下一个 '/'
        let afterRoot = standardized.index(standardized.startIndex, offsetBy: libraryRoot.count)
        guard let slashAfterDir = standardized[afterRoot...].firstIndex(of: "/") else {
            return nil
        }
        let dir = standardized[afterRoot..<slashAfterDir]

        // 3. 找第二段（candidate）：slashAfterDir+1 到下一个 '/' 或字符串尾
        let candidateStart = standardized.index(after: slashAfterDir)
        let candidateEnd = standardized[candidateStart...].firstIndex(of: "/") ?? standardized.endIndex
        var candidate = standardized[candidateStart..<candidateEnd]
        guard !candidate.isEmpty else { return nil }

        // 4. 按 dir 形状剥后缀（.plist / .savedState），无配对的 dir 早退
        let isContainerDir: Bool
        switch dir {
        case "Caches", "Containers", "Group Containers",
             "HTTPStorages", "WebKit":
            isContainerDir = true
        case "Preferences":
            guard candidate.hasSuffix(".plist") else { return nil }
            candidate = candidate.dropLast(".plist".count)
            isContainerDir = false
        case "Saved Application State":
            guard candidate.hasSuffix(".savedState") else { return nil }
            candidate = candidate.dropLast(".savedState".count)
            isContainerDir = false
        default:
            return nil
        }

        // 5. 不含 `.` 的候选段只在 Caches/Containers 下放行（覆盖 Cursor / Claude / Firefox
        //    这类无点 ID），其他 dir 退出避免对随机目录名做 set 查询
        if !candidate.contains(".") && !isContainerDir { return nil }

        return BundleProtection.match(bundleID: String(candidate))
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
        // 2. 只 standardize 一次，复用给 base 判定 + trie 匹配
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let (baseVerdict, rejection) = evaluateStandardized(standardized: standardized, home: home)
        if baseVerdict == .forbid { return (baseVerdict, rejection, nil) }

        guard let hit = VendorTrie.match(standardizedPath: standardized, in: trie) else {
            return (baseVerdict, rejection, nil)
        }
        // path 级 verdict 覆盖（DEV_ARTIFACTS_RULES.md §2.x）：
        // 当 vendor 在 yaml 里显式声明了 `paths: [{path, verdict}]`，那条 path-rule 比
        // vendor 根的默认 `.confirm` 更"具体"，应优先生效。
        // - override.forbid：升级到 forbid（注意 base 的 forbid 已经在上面短路了，
        //   所以这里不会绕过硬安全网；override 仅能在 base==safe/confirm 时生效）
        // - override.safe：即便 base 是 confirm，也按规则作者意图降级到 safe
        // - override.confirm：与默认行为相同，仍走 confirm
        // path-override 沿子树继承，所以 `Pods/Release/**` 这类规则不需要列举每个子文件。
        if let ovr = hit.pathOverride {
            switch ovr.verdict {
            case .forbid:
                return (.forbid, .vendorPathRule, hit.rule)
            case .safe:
                return (.safe, .ok, hit.rule)
            case .confirm:
                return (.confirm, .ok, hit.rule)
            }
        }
        if hit.isExactRoot {
            // 命中 vendor 根 —— 强制 confirm
            return (.confirm, .ok, hit.rule)
        } else {
            // 命中 vendor 子目录 —— 用 baseVerdict（safe / confirm）
            return (baseVerdict, rejection, hit.rule)
        }
    }
}
