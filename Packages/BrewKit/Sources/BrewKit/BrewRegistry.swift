import Foundation

/// BrewKit Step 16-B2 —— 解析 `~/Library/Caches/Homebrew/api/{formula,cask}.jws.json`
/// 的轻量 registry，做"已安装版本 vs 最新版本"的可升级标记。
///
/// 设计来源（[docs/AUDIT_2026_06.md L102](file:///Users/amuxuser/workspace/AmuxAIClean/docs/AUDIT_2026_06.md#L102)）：
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
/// - **解析失败容错**：保留可用条目，并把不可读/损坏以结构化 diagnostic 返回；文件缺失
///   仍是 Homebrew 尚未生成 cache 的正常状态。
public enum BrewRegistrySourceStatus: String, Sendable, Equatable {
    case missing
    case complete
    case partial
    case unavailable
}

public struct BrewRegistry: Sendable {

    /// formula.jws.json 解析结果：name → latest stable version
    public let formulaLatest: [String: String]
    /// cask.jws.json 解析结果：token → latest version
    public let caskLatest: [String: String]
    public let formulaStatus: BrewRegistrySourceStatus
    public let caskStatus: BrewRegistrySourceStatus
    public let diagnostics: [BrewDiagnostic]

    public init(
        formulaLatest: [String: String],
        caskLatest: [String: String],
        formulaStatus: BrewRegistrySourceStatus = .complete,
        caskStatus: BrewRegistrySourceStatus = .complete,
        diagnostics: [BrewDiagnostic] = []
    ) {
        self.formulaLatest = formulaLatest
        self.caskLatest = caskLatest
        self.formulaStatus = formulaStatus
        self.caskStatus = caskStatus
        self.diagnostics = diagnostics
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
        load(cacheDirectory: cacheDirectory, fileReader: .live)
    }

    static func load(
        cacheDirectory: URL?,
        fileReader: BrewFileReader
    ) -> BrewRegistry {
        guard let dir = cacheDirectory else {
            return BrewRegistry(
                formulaLatest: [:],
                caskLatest: [:],
                formulaStatus: .missing,
                caskStatus: .missing
            )
        }
        let formulaPath = dir.appendingPathComponent("formula.jws.json")
        let caskPath = dir.appendingPathComponent("cask.jws.json")
        let formula = parseFormulaResult(at: formulaPath, fileReader: fileReader)
        let cask = parseCaskResult(at: caskPath, fileReader: fileReader)
        return BrewRegistry(
            formulaLatest: formula.values,
            caskLatest: cask.values,
            formulaStatus: formula.status,
            caskStatus: cask.status,
            diagnostics: formula.diagnostics + cask.diagnostics
        )
    }

    // MARK: - Lookup

    public func latestVersion(for name: String, kind: BrewPackageKind) -> String? {
        switch kind {
        case .formula: return formulaLatest[name]
        case .cask:    return caskLatest[name]
        }
    }

    public func status(for kind: BrewPackageKind) -> BrewRegistrySourceStatus {
        switch kind {
        case .formula: return formulaStatus
        case .cask: return caskStatus
        }
    }

    // MARK: - Parsing

    static func parseFormula(at url: URL) -> [String: String] {
        parseFormulaResult(at: url, fileReader: .live).values
    }

    static func parseCask(at url: URL) -> [String: String] {
        parseCaskResult(at: url, fileReader: .live).values
    }

    private struct RegistryParseResult {
        let values: [String: String]
        let diagnostics: [BrewDiagnostic]
        let status: BrewRegistrySourceStatus
    }

    private struct PayloadParseResult {
        let items: [[String: Any]]
        let diagnostics: [BrewDiagnostic]
        let status: BrewRegistrySourceStatus
        let rejectedEntryCount: Int
    }

    private static func parseFormulaResult(
        at url: URL,
        fileReader: BrewFileReader
    ) -> RegistryParseResult {
        let parsed = parsePayload(at: url, source: .formulaRegistry, fileReader: fileReader)
        var out: [String: String] = [:]
        var rejectedEntryCount = parsed.rejectedEntryCount
        for item in parsed.items {
            guard let name = item["name"] as? String,
                  let versions = item["versions"] as? [String: Any],
                  let stable = versions["stable"] as? String else {
                rejectedEntryCount += 1
                continue
            }
            let revision = (item["revision"] as? Int) ?? 0
            out[name] = revision > 0 ? "\(stable)_\(revision)" : stable
        }
        return RegistryParseResult(
            values: out,
            diagnostics: parsed.diagnostics + entryDiagnostic(
                source: .formulaRegistry,
                url: url,
                rejectedEntryCount: rejectedEntryCount
            ),
            status: rejectedEntryCount > 0 ? .partial : parsed.status
        )
    }

    private static func parseCaskResult(
        at url: URL,
        fileReader: BrewFileReader
    ) -> RegistryParseResult {
        let parsed = parsePayload(at: url, source: .caskRegistry, fileReader: fileReader)
        var out: [String: String] = [:]
        var rejectedEntryCount = parsed.rejectedEntryCount
        for item in parsed.items {
            guard let token = item["token"] as? String,
                  let version = item["version"] as? String else {
                rejectedEntryCount += 1
                continue
            }
            out[token] = version
        }
        return RegistryParseResult(
            values: out,
            diagnostics: parsed.diagnostics + entryDiagnostic(
                source: .caskRegistry,
                url: url,
                rejectedEntryCount: rejectedEntryCount
            ),
            status: rejectedEntryCount > 0 ? .partial : parsed.status
        )
    }

    private static func parsePayload(
        at url: URL,
        source: BrewDiagnostic.Source,
        fileReader: BrewFileReader
    ) -> PayloadParseResult {
        let data: Data
        switch readBrewLocalFile(at: url, source: source, reader: fileReader) {
        case .missing:
            return PayloadParseResult(
                items: [],
                diagnostics: [],
                status: .missing,
                rejectedEntryCount: 0
            )
        case .failure(let diagnostic):
            return PayloadParseResult(
                items: [],
                diagnostics: [diagnostic],
                status: .unavailable,
                rejectedEntryCount: 0
            )
        case .contents(let contents):
            data = contents
        }

        let envelope: [String: Any]
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return malformedPayloadResult(source: source, stage: .decodeDocument, url: url)
            }
            envelope = dictionary
        } catch {
            return malformedPayloadResult(
                source: source,
                stage: .decodeDocument,
                url: url,
                error: error
            )
        }
        guard let payloadString = envelope["payload"] as? String,
              let payloadData = payloadString.data(using: .utf8) else {
            return malformedPayloadResult(source: source, stage: .decodePayload, url: url)
        }
        let rawItems: [Any]
        do {
            guard let array = try JSONSerialization.jsonObject(with: payloadData) as? [Any] else {
                return malformedPayloadResult(source: source, stage: .decodePayload, url: url)
            }
            rawItems = array
        } catch {
            return malformedPayloadResult(
                source: source,
                stage: .decodePayload,
                url: url,
                error: error
            )
        }

        let items = rawItems.compactMap { $0 as? [String: Any] }
        let rejectedContainerCount = rawItems.count - items.count
        return PayloadParseResult(
            items: items,
            diagnostics: [],
            status: rejectedContainerCount > 0 ? .partial : .complete,
            rejectedEntryCount: rejectedContainerCount
        )
    }

    private static func malformedPayloadResult(
        source: BrewDiagnostic.Source,
        stage: BrewDiagnostic.Stage,
        url: URL,
        error: Error? = nil
    ) -> PayloadParseResult {
        let nsError = error.map { $0 as NSError }
        return PayloadParseResult(
            items: [],
            diagnostics: [BrewDiagnostic(
                source: source,
                stage: stage,
                reason: .malformed,
                path: url.path,
                errorDomain: nsError?.domain,
                errorCode: nsError?.code
            )],
            status: .unavailable,
            rejectedEntryCount: 0
        )
    }

    private static func entryDiagnostic(
        source: BrewDiagnostic.Source,
        url: URL,
        rejectedEntryCount: Int
    ) -> [BrewDiagnostic] {
        guard rejectedEntryCount > 0 else { return [] }
        return [BrewDiagnostic(
            source: source,
            stage: .decodeEntry,
            reason: .malformed,
            path: url.path,
            rejectedEntryCount: rejectedEntryCount
        )]
    }
}
