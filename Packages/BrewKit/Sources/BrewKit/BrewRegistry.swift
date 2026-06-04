import Foundation

/// BrewKit Step 16-B2 —— 解析 `~/Library/Caches/Homebrew/api/{formula,cask}.jws.json`
/// 的轻量 registry，做"已安装版本 vs 最新版本"的可升级标记。
///
/// 设计来源（[docs/AUDIT_2026_06.md L102](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/AUDIT_2026_06.md#L102)）：
/// > 直接读 `~/Library/Caches/Homebrew/api/{cask,formula}.jws.json`，不需要执行 brew 命令。
///
/// **JWS 信封格式**（真机抽样确认）：
/// ```json
/// {"payload": "<escaped-JSON-string>", "signatures": [...]}
/// ```
/// `payload` 是字符串，二次 parse 后是数组：
/// - formula 元素：`{"name": "a2ps", "versions": {"stable": "4.15.8"}, ...}`
/// - cask 元素：`{"token": "0-ad", "version": "0.28.0", ...}`
///
/// 设计原则：
/// - **不执行 brew**：纯 JSON 解析，与 BrewController 同款约束。
/// - **只读 name + version**，其余字段（desc/homepage/url）忽略以减少内存。
/// - **解析失败容错**：返回空 map 而不抛错；调用方按 nil/missing 视作"无更新信息"。
public struct BrewRegistry: Sendable {

    /// formula.jws.json 解析结果：name → latest stable version
    public let formulaLatest: [String: String]
    /// cask.jws.json 解析结果：token → latest version
    public let caskLatest: [String: String]

    public init(formulaLatest: [String: String], caskLatest: [String: String]) {
        self.formulaLatest = formulaLatest
        self.caskLatest = caskLatest
    }

    /// 用户默认 cache 路径下加载：
    /// `~/Library/Caches/Homebrew/api/{formula,cask}.jws.json`
    public static func loadDefault() -> BrewRegistry {
        let cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Homebrew/api", isDirectory: true)
        return load(cacheDirectory: cache)
    }

    /// 从指定 cache 目录加载（测试可注入 fixture 目录）。
    /// cacheDirectory 为 nil 或文件缺失时返回空 registry。
    public static func load(cacheDirectory: URL?) -> BrewRegistry {
        guard let dir = cacheDirectory else {
            return BrewRegistry(formulaLatest: [:], caskLatest: [:])
        }
        let formulaPath = dir.appendingPathComponent("formula.jws.json")
        let caskPath = dir.appendingPathComponent("cask.jws.json")
        let formula = parseFormula(at: formulaPath)
        let cask = parseCask(at: caskPath)
        return BrewRegistry(formulaLatest: formula, caskLatest: cask)
    }

    // MARK: - Lookup

    public func latestVersion(for name: String, kind: BrewPackageKind) -> String? {
        switch kind {
        case .formula: return formulaLatest[name]
        case .cask:    return caskLatest[name]
        }
    }

    // MARK: - Parsing

    static func parseFormula(at url: URL) -> [String: String] {
        let items = parsePayload(at: url)
        var out: [String: String] = [:]
        for item in items {
            guard let name = item["name"] as? String,
                  let versions = item["versions"] as? [String: Any],
                  let stable = versions["stable"] as? String else { continue }
            out[name] = stable
        }
        return out
    }

    static func parseCask(at url: URL) -> [String: String] {
        let items = parsePayload(at: url)
        var out: [String: String] = [:]
        for item in items {
            guard let token = item["token"] as? String,
                  let version = item["version"] as? String else { continue }
            out[token] = version
        }
        return out
    }

    private static func parsePayload(at url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let payloadString = envelope["payload"] as? String,
              let payloadData = payloadString.data(using: .utf8) else {
            return []
        }
        guard let array = try? JSONSerialization.jsonObject(with: payloadData) as? [[String: Any]] else {
            return []
        }
        return array
    }
}
