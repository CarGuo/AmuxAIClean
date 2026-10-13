import Foundation

/// vendor 规则（来自 vendors.yaml）—— 命中后默认 verdict 设为 `.confirm`，UI 不默认勾选。
public struct VendorRule: Sendable, Equatable {
    public let name: String
    public let bundleIDPrefix: String?
    public let appSupportSubdir: String?
    public let cachesPath: String?
    /// 可选规则分类。用于把同一份 vendors.yaml 按能力面切片，例如 common_app_cache。
    public let category: String?
    /// 可选证据来源，供规则审计 / 导出日志展示。
    public let source: String?
    public let note: String?
    /// 显式声明的 path 级规则（DEV_ARTIFACTS_RULES.md §2.x 表格直接对应）。
    /// 命中其中任一条目时，verdict 由该条目而非默认 `.confirm` 决定。
    /// 与 `appSupportSubdir`/`cachesPath` 可同时存在 —— 后两者继续走"vendor 根 confirm /
    /// 子路径继承 base verdict"语义；`paths` 走"path 级 verdict 覆盖"语义。
    public let paths: [PathRule]

    public init(name: String, bundleIDPrefix: String? = nil, appSupportSubdir: String? = nil,
                cachesPath: String? = nil, category: String? = nil, source: String? = nil,
                note: String? = nil,
                paths: [PathRule] = []) {
        self.name = name
        self.bundleIDPrefix = bundleIDPrefix
        self.appSupportSubdir = appSupportSubdir
        self.cachesPath = cachesPath
        self.category = category
        self.source = source
        self.note = note
        self.paths = paths
    }

    /// 给定 home，展开成绝对路径前缀候选列表（用于路径前缀匹配）。
    /// 注意：`paths` 字段单独走 `absolutePathRules(home:)`，**不**混入此列表，
    /// 避免 path 级 verdict 被默认的 vendor-root confirm 覆盖。
    public func absolutePathPrefixes(home: String) -> [String] {
        var out: [String] = []
        if let sub = appSupportSubdir {
            out.append("\(home)/Library/Application Support/\(sub)")
        }
        if let cp = cachesPath {
            out.append(Self.expand(cp, home: home))
        }
        return out
    }

    /// 展开 `paths` 字段为 `(绝对路径, PathRule)` 二元组。
    /// VendorTrie 在建树时把每个二元组当作"带 verdict 覆盖的叶子"插入。
    public func absolutePathRules(home: String) -> [(String, PathRule)] {
        paths.map { (Self.expand($0.path, home: home), $0) }
    }

    static func expand(_ p: String, home: String) -> String {
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        if p == "~" { return home }
        return p
    }
}

/// path 级规则（vendors.yaml 中嵌套于 `paths:` 列表项）。
///
/// YAML 形态：
/// ```yaml
/// vendors:
///   - name: "CocoaPods"
///     paths:
///       - path: "~/Library/Caches/CocoaPods"
///         verdict: "safe"
///         reason: "可重新下载，pod install 自愈"
///         recipe: "rm -rf 或 走 pod cache clean --all"
/// ```
public struct PathRule: Sendable, Equatable {
    public let path: String
    public let verdict: SafetyVerdict
    public let reason: String?
    /// 可选：建议给用户展示的"操作处方"（CLI 命令 / Finder 步骤），仅 UI 引导用，
    /// 工具本身**不**自动执行（与 PITFALLS §0 红线一致）。
    public let recipe: String?

    public init(path: String, verdict: SafetyVerdict,
                reason: String? = nil, recipe: String? = nil) {
        self.path = path
        self.verdict = verdict
        self.reason = reason
        self.recipe = recipe
    }
}

/// 极简 YAML 解析 —— 仅认识 SeedingTool 输出的子集（顶层 `vendors:` 列表）。
/// 不引第三方 YAML 库以保持 SafetyKit 零外部依赖。
public enum RuleLoader {

    public enum LoadError: Error, Equatable {
        case fileNotFound(String)
        case malformed(line: Int, reason: String)
    }

    /// 从 vendors.yaml 文件加载。会**自动剔除**踩 hardForbid 黑名单的恶意规则。
    ///
    /// 过滤策略（DEV_ARTIFACTS_RULES.md §2.7 多重防御）：
    /// - `appSupportSubdir` / `cachesPath` 命中 hardForbid → 整条 vendor 丢弃
    ///   （这两类没有 verdict 字段，无法区分善意/恶意，保守拒绝）
    /// - `paths[i]` 命中 hardForbid 时分两种情况：
    ///   - 该 path 自己声明 `verdict: forbid` → **保留**（这是 yaml 作者主动加的"多重防御"，
    ///     例如 §2.1 显式声明 `~/Library/MobileDevice/Provisioning Profiles` 为 forbid，
    ///     与硬安全网形成重叠保护，UI 还能展示 reason）
    ///   - 该 path 声明 `verdict: safe / confirm` → **整条 vendor 丢弃**
    ///     （恶意作者尝试用 yaml 把硬禁区降级为可删，是攻击向量）
    public static func loadVendors(from url: URL, home: String = NSHomeDirectory(),
                                   engine: SafetyEngine = SafetyEngine())
    throws -> [VendorRule]
    {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            throw LoadError.fileNotFound(url.path)
        }
        let parsed = try parse(text)
        let normalizedHome = SafetyEngine.normalizeHome(home)
        let exactForbiddenRoots = SafetyEngine.userRootForbidden(home: normalizedHome)
        let subtreeForbiddenPaths = SafetyEngine.hardForbidPrefixes
            + SafetyEngine.sensitiveCredentialPrefixes(home: normalizedHome)
            + ["\(normalizedHome)/Library/Application Support/MobileSync/Backup"]
        return parsed.filter { rule in
            for prefix in rule.absolutePathPrefixes(home: normalizedHome) {
                let v = engine.evaluate(path: prefix, home: normalizedHome).0
                if v == .forbid { return false }
            }
            for (abs, pathRule) in rule.absolutePathRules(home: normalizedHome) {
                // glob 规则：取 `*`/`?` 之前的字面量前缀做硬安全网探测。
                // 例如 `~/Library/Keychains/*` 字面量前缀 `~/Library/Keychains/` —— 命中硬禁区。
                // 防御目标：作者意图绕过黄金禁区（声明 safe/confirm 试图删凭证目录下匹配项）。
                // 注意：运行时 evaluateStandardized 已先于 trie/glob 跑硬安全网，
                // 这里的 load-time 过滤是"早失败 + 启动期可见"的补充防御。
                let isGlobRule = PathGlob.isGlob(abs)
                let probe = isGlobRule ? Self.literalPrefix(of: abs) : abs
                if probe.isEmpty {
                    if pathRule.verdict != .forbid { return false }
                    continue
                }
                let v = engine.evaluate(path: probe, home: normalizedHome).0
                if v == .forbid && pathRule.verdict != .forbid {
                    // 恶意尝试：硬禁区路径但作者宣称 safe/confirm —— 整条丢弃
                    return false
                }
                if isGlobRule && pathRule.verdict != .forbid {
                    var pattern = SafetyEngine.stripDataVolumePrefix(abs)
                    while pattern.count > 1 && pattern.hasSuffix("/") {
                        pattern.removeLast()
                    }
                    for root in exactForbiddenRoots {
                        if PathGlob.match(pattern: pattern, path: root) {
                            return false
                        }
                    }
                    for forbidden in subtreeForbiddenPaths {
                        if PathGlob.match(pattern: pattern, path: forbidden)
                            || PathGlob.matchPrefix(pattern: pattern, path: forbidden) {
                            return false
                        }
                    }
                }
            }
            return true
        }
    }

    /// 取 pattern 中第一个 glob 元字符（`*` 或 `?`）之前的字面量前缀。
    /// 用于在装载时做硬安全网探测：若字面量前缀本身已在硬禁区，整条规则视为恶意。
    /// 例：
    /// - `/Users/foo/Library/Keychains/*` → `/Users/foo/Library/Keychains/`
    /// - `/Users/foo/Library/JetBrains/IntelliJIdea*/log` → `/Users/foo/Library/JetBrains/IntelliJIdea`
    static func literalPrefix(of pattern: String) -> String {
        var out = ""
        for ch in pattern {
            if ch == "*" || ch == "?" { break }
            out.append(ch)
        }
        return out
    }

    /// 仅解析（不做 hardForbid 过滤）—— 给单测用。
    public static func parse(_ text: String) throws -> [VendorRule] {
        var rules: [VendorRule] = []
        var current: PartialRule?
        var inVendors = false
        // 嵌套 paths: 解析状态。
        // pathsMode == true 表示目前正处在某个 vendor 的 paths: 子树下，
        // 接下来的 `- path:` / `verdict:` / `reason:` / `recipe:` 都属于该树。
        var pathsMode = false
        var currentPath: PartialPathRule?
        // fix-3：vendor 顶层 key 的 leading 缩进（YAML 习惯：`-` 起 leading=2，紧跟的 key 在 4）。
        // pathsMode 内的 `- path:` 起 leading=6，子键 ≥8。所以遇到非 `- ` 开头且
        // `leading <= vendorTopKeyIndent` 的行必须退出 pathsMode 让上层 vendor 字段
        // 重新被识别 —— 否则 `paths:` 块会"吞掉"后续 note/bundle_id_prefix 等顶层字段。
        let vendorTopKeyIndent = 4

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, raw) in lines.enumerated() {
            let lineNo = idx + 1
            // 先取裸缩进（用于判断 paths 块结束）
            let leading = raw.prefix(while: { $0 == " " }).count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // 跳过空行 / 注释
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // 顶层 vendors: 标记
            if trimmed == "vendors:" {
                inVendors = true
                continue
            }
            guard inVendors else { continue }

            // 列表项起始：以 `- ` 开头
            if trimmed.hasPrefix("- ") {
                // 进入新顶层 vendor 项（缩进为 2，YAML 习惯）—— 关闭可能存在的 paths 块
                if leading <= 2 {
                    if let cp = currentPath {
                        let (built, err) = cp.buildOrError()
                        if let err {
                            throw LoadError.malformed(line: cp.startedAtLine, reason: err)
                        }
                        if let built { current?.paths.append(built) }
                    }
                    currentPath = nil
                    pathsMode = false
                    if let r = current?.build() { rules.append(r) }
                    current = PartialRule()
                    let rest = String(trimmed.dropFirst(2))
                    try apply(line: rest, into: &current!, lineNo: lineNo)
                    continue
                }
                // 嵌套 paths 列表的子项（缩进 >2）
                if pathsMode {
                    if let cp = currentPath {
                        let (built, err) = cp.buildOrError()
                        if let err {
                            throw LoadError.malformed(line: cp.startedAtLine, reason: err)
                        }
                        if let built { current?.paths.append(built) }
                    }
                    var fresh = PartialPathRule()
                    fresh.startedAtLine = lineNo
                    currentPath = fresh
                    let rest = String(trimmed.dropFirst(2))
                    try applyPath(line: rest, into: &currentPath!, lineNo: lineNo)
                    continue
                }
                throw LoadError.malformed(line: lineNo, reason: "unexpected list-item indentation")
            }

            // 非 `- ` 开头：要么是 vendor 顶层 key/value，要么是 paths 项内的 key/value
            guard current != nil else {
                throw LoadError.malformed(line: lineNo, reason: "key appears before list item")
            }

            // fix-3：pathsMode 内若遇到非 `- ` 开头但 leading <= vendorTopKeyIndent，
            // 说明已离开 paths 子树（回到 vendor 顶层字段，如 note/bundle_id_prefix）。
            // 必须先关闭当前 paths 块，再让下面的逻辑作为 vendor 顶层 key/value 处理。
            if pathsMode && leading <= vendorTopKeyIndent {
                if let cp = currentPath {
                    let (built, err) = cp.buildOrError()
                    if let err {
                        throw LoadError.malformed(line: cp.startedAtLine, reason: err)
                    }
                    if let built { current?.paths.append(built) }
                }
                currentPath = nil
                pathsMode = false
                // 落空到下面的 vendor 顶层字段解析路径
            }

            // 检测 `paths:` 块开始（值为空表示后面跟列表）
            if trimmed == "paths:" {
                if let cp = currentPath {
                    let (built, err) = cp.buildOrError()
                    if let err {
                        throw LoadError.malformed(line: cp.startedAtLine, reason: err)
                    }
                    if let built { current?.paths.append(built) }
                }
                currentPath = nil
                pathsMode = true
                continue
            }

            if pathsMode {
                // paths 块内的 key/value（缩进通常为 6）
                guard currentPath != nil else {
                    throw LoadError.malformed(line: lineNo,
                                              reason: "paths sub-key appears before its list item")
                }
                try applyPath(line: trimmed, into: &currentPath!, lineNo: lineNo)
                continue
            }

            try apply(line: trimmed, into: &current!, lineNo: lineNo)
        }
        if let cp = currentPath {
            let (built, err) = cp.buildOrError()
            if let err {
                throw LoadError.malformed(line: cp.startedAtLine, reason: err)
            }
            if let built { current?.paths.append(built) }
        }
        if let r = current?.build() { rules.append(r) }
        return rules
    }

    private static func apply(line: String, into rule: inout PartialRule, lineNo: Int) throws {
        let (key, value) = try splitKeyValue(line: line, lineNo: lineNo)
        switch key {
        case "name": rule.name = value
        case "bundle_id_prefix": rule.bundleIDPrefix = value
        case "app_support_subdir": rule.appSupportSubdir = value
        case "caches_path": rule.cachesPath = value
        case "category": rule.category = value
        case "source": rule.source = value
        case "note": rule.note = value
        default: break // 忽略未知字段（向前兼容）
        }
    }

    private static func applyPath(line: String, into pr: inout PartialPathRule,
                                  lineNo: Int) throws {
        let (key, value) = try splitKeyValue(line: line, lineNo: lineNo)
        switch key {
        case "path": pr.path = value
        case "verdict":
            guard let v = SafetyVerdict.parse(yaml: value) else {
                throw LoadError.malformed(line: lineNo,
                                          reason: "verdict must be safe/confirm/forbid, got \(value)")
            }
            pr.verdict = v
        case "reason": pr.reason = value
        case "recipe": pr.recipe = value
        default: break // 忽略未知字段（向前兼容）
        }
    }

    private static func splitKeyValue(line: String, lineNo: Int) throws -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else {
            throw LoadError.malformed(line: lineNo, reason: "missing ':' separator")
        }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let valuePart = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (key, unquote(valuePart))
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if (s.hasPrefix("\"") && s.hasSuffix("\""))
            || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

private struct PartialRule {
    var name: String?
    var bundleIDPrefix: String?
    var appSupportSubdir: String?
    var cachesPath: String?
    var category: String?
    var source: String?
    var note: String?
    var paths: [PathRule] = []

    func build() -> VendorRule? {
        guard let name, !name.isEmpty else { return nil }
        return VendorRule(
            name: name,
            bundleIDPrefix: bundleIDPrefix,
            appSupportSubdir: appSupportSubdir,
            cachesPath: cachesPath,
            category: category,
            source: source,
            note: note,
            paths: paths
        )
    }
}

private struct PartialPathRule {
    var path: String?
    var verdict: SafetyVerdict?
    var reason: String?
    var recipe: String?
    /// 该 partial 在源文件中第一次被见到的行号，用于抛错时指给作者。
    /// `parse` 在创建 PartialPathRule 时填入；构建失败时一并回传给 LoadError.malformed。
    var startedAtLine: Int = 0

    /// 严格模式：返回构建结果或 nil（仅当**完全未填任何字段**才允许 nil；
    /// 部分填充而无法构建时由调用方抛 `LoadError.malformed`）。
    /// `error` 描述具体丢失的字段，调用方拼成 LoadError reason。
    func buildOrError() -> (rule: PathRule?, error: String?) {
        let hasAny = path != nil || verdict != nil || reason != nil || recipe != nil
        if !hasAny {
            // 一个完全空的 partial（pathsMode 刚翻开但还没遇到 `- path:`），允许跳过
            return (nil, nil)
        }
        guard let path, !path.isEmpty else {
            return (nil, "path-rule missing 'path' field")
        }
        guard let verdict else {
            return (nil, "path-rule missing 'verdict' field (path=\(path))")
        }
        return (PathRule(path: path, verdict: verdict, reason: reason, recipe: recipe), nil)
    }

    /// 旧 API（保 binary compat 同时给 lenient 调用方）：构建失败静默返回 nil。
    /// 新代码请改用 [buildOrError](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift)。
    func build() -> PathRule? {
        guard let path, !path.isEmpty, let verdict else { return nil }
        return PathRule(path: path, verdict: verdict, reason: reason, recipe: recipe)
    }
}

private extension SafetyVerdict {
    /// 容忍前后空白 + 大小写不敏感解析 yaml 中的 verdict 值。
    static func parse(yaml raw: String) -> SafetyVerdict? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "safe": return .safe
        case "confirm": return .confirm
        case "forbid": return .forbid
        default: return nil
        }
    }
}
