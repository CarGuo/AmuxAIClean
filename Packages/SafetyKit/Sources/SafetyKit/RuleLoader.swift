import Foundation

/// vendor 规则（来自 vendors.yaml）—— 命中后默认 verdict 设为 `.confirm`，UI 不默认勾选。
public struct VendorRule: Sendable, Equatable {
    public let name: String
    public let bundleIDPrefix: String?
    public let appSupportSubdir: String?
    public let cachesPath: String?
    public let note: String?

    public init(name: String, bundleIDPrefix: String? = nil, appSupportSubdir: String? = nil,
                cachesPath: String? = nil, note: String? = nil) {
        self.name = name
        self.bundleIDPrefix = bundleIDPrefix
        self.appSupportSubdir = appSupportSubdir
        self.cachesPath = cachesPath
        self.note = note
    }

    /// 给定 home，展开成绝对路径前缀候选列表（用于路径前缀匹配）。
    public func absolutePathPrefixes(home: String) -> [String] {
        var out: [String] = []
        if let sub = appSupportSubdir {
            out.append("\(home)/Library/Application Support/\(sub)")
        }
        if let cp = cachesPath {
            out.append(expand(cp, home: home))
        }
        return out
    }

    private func expand(_ p: String, home: String) -> String {
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        if p == "~" { return home }
        return p
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
        // 反向校验：任何规则展开后命中 hardForbid 一律丢弃
        return parsed.filter { rule in
            for prefix in rule.absolutePathPrefixes(home: home) {
                let v = engine.evaluate(path: prefix, home: home).0
                if v == .forbid {
                    return false
                }
            }
            return true
        }
    }

    /// 仅解析（不做 hardForbid 过滤）—— 给单测用。
    public static func parse(_ text: String) throws -> [VendorRule] {
        var rules: [VendorRule] = []
        var current: PartialRule?
        var inVendors = false

        for (idx, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNo = idx + 1
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
                if let r = current?.build() { rules.append(r) }
                current = PartialRule()
                let rest = String(trimmed.dropFirst(2))
                try apply(line: rest, into: &current!, lineNo: lineNo)
            } else {
                guard current != nil else {
                    throw LoadError.malformed(line: lineNo, reason: "key 出现在 list item 前")
                }
                try apply(line: trimmed, into: &current!, lineNo: lineNo)
            }
        }
        if let r = current?.build() { rules.append(r) }
        return rules
    }

    private static func apply(line: String, into rule: inout PartialRule, lineNo: Int) throws {
        guard let colon = line.firstIndex(of: ":") else {
            throw LoadError.malformed(line: lineNo, reason: "未找到 ':'")
        }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let valuePart = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let value = unquote(valuePart)
        switch key {
        case "name": rule.name = value
        case "bundle_id_prefix": rule.bundleIDPrefix = value
        case "app_support_subdir": rule.appSupportSubdir = value
        case "caches_path": rule.cachesPath = value
        case "note": rule.note = value
        default: break // 忽略未知字段（向前兼容）
        }
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
    var note: String?

    func build() -> VendorRule? {
        guard let name, !name.isEmpty else { return nil }
        return VendorRule(
            name: name,
            bundleIDPrefix: bundleIDPrefix,
            appSupportSubdir: appSupportSubdir,
            cachesPath: cachesPath,
            note: note
        )
    }
}
