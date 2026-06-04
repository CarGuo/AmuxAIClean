import Foundation

/// BrewKit MVP（Step 16-B）—— 不执行 brew 命令，直接读 Cellar / Caskroom 文件系统结构。
///
/// 设计来源（[docs/AUDIT_2026_06.md L102](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/AUDIT_2026_06.md#L102)）：
/// > 直接读 `Cellar/.../INSTALL_RECEIPT.json` 与 `~/Library/Caches/Homebrew/api/{cask,
/// > formula}.jws.json` 不需要执行 brew 命令。MVP 只做"列出 + 跳详情"。
///
/// 真机实测的目录结构：
/// - Apple Silicon 默认 prefix：`/opt/homebrew`，Intel：`/usr/local`
/// - Formula：`{prefix}/Cellar/{name}/{version}/INSTALL_RECEIPT.json`
///   关键字段：`installed_on_request`（true=显式安装 / false=依赖）、`time`（Unix ts）、
///   `source.versions.stable`、`source.tap`
/// - Cask：`{prefix}/Caskroom/{name}/{version}/`（没有 INSTALL_RECEIPT，目录名即版本）
public enum BrewPackageKind: String, Sendable, Equatable {
    case formula
    case cask
}

public struct BrewPackage: Sendable, Equatable {
    public let name: String
    public let version: String
    public let kind: BrewPackageKind
    public let installedAt: Date?
    /// 仅 formula 有意义；cask 永远 true（用户显式安装 GUI app）。
    public let installedOnRequest: Bool
    public let tap: String?
    /// Cellar/{name}/{version} 或 Caskroom/{name}/{version}
    public let path: URL

    public init(name: String, version: String, kind: BrewPackageKind,
                installedAt: Date?, installedOnRequest: Bool,
                tap: String?, path: URL) {
        self.name = name
        self.version = version
        self.kind = kind
        self.installedAt = installedAt
        self.installedOnRequest = installedOnRequest
        self.tap = tap
        self.path = path
    }
}

/// Step 16-B2 —— 一个本地包 + 它在 BrewRegistry 中的最新版本。
public struct BrewOutdated: Sendable, Equatable {
    public let package: BrewPackage
    public let latestVersion: String

    public init(package: BrewPackage, latestVersion: String) {
        self.package = package
        self.latestVersion = latestVersion
    }
}

public struct BrewController: Sendable {

    /// brew 安装 prefix（一般 /opt/homebrew 或 /usr/local）。
    public let prefix: URL

    public init(prefix: URL) {
        self.prefix = prefix
    }

    /// 标准检测：先看 `/opt/homebrew`，再 `/usr/local`；nil 表示未安装 brew。
    public static func detectDefault() -> BrewController? {
        let fm = FileManager.default
        for p in ["/opt/homebrew", "/usr/local"] {
            let url = URL(fileURLWithPath: p)
            if fm.fileExists(atPath: url.appendingPathComponent("Cellar").path) ||
               fm.fileExists(atPath: url.appendingPathComponent("Caskroom").path) {
                return BrewController(prefix: url)
            }
        }
        return nil
    }

    // MARK: - 公开 API

    public func listFormulae() -> [BrewPackage] {
        let cellar = prefix.appendingPathComponent("Cellar", isDirectory: true)
        return enumeratePackages(at: cellar, kind: .formula)
    }

    public func listCasks() -> [BrewPackage] {
        let casks = prefix.appendingPathComponent("Caskroom", isDirectory: true)
        return enumeratePackages(at: casks, kind: .cask)
    }

    /// 一次性列出全部 formula + cask。
    public func listAll() -> [BrewPackage] {
        return listFormulae() + listCasks()
    }

    /// 用 [BrewRegistry](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit/Sources/BrewKit/BrewRegistry.swift)
    /// 标注每个已安装包的"最新版本"和"是否可升级"。
    ///
    /// 升级判定：installed != latest（字符串严格不等；不做 semver 解析以求稳）。
    /// 同名多 version 时，每个 version 各自比对（与 brew 行为一致）。
    public func outdated(using registry: BrewRegistry) -> [BrewOutdated] {
        let all = listAll()
        return all.compactMap { pkg in
            guard let latest = registry.latestVersion(for: pkg.name, kind: pkg.kind),
                  latest != pkg.version else { return nil }
            return BrewOutdated(package: pkg, latestVersion: latest)
        }
    }

    // MARK: - 内部

    private func enumeratePackages(at root: URL, kind: BrewPackageKind) -> [BrewPackage] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var out: [BrewPackage] = []
        for name in names where !name.hasPrefix(".") {
            let nameDir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: nameDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            // 每个 name 下可能有多个 version 目录，全列出（与 brew list --versions 一致）
            guard let versions = try? fm.contentsOfDirectory(atPath: nameDir.path) else {
                continue
            }
            for version in versions where !version.hasPrefix(".") {
                let verDir = nameDir.appendingPathComponent(version, isDirectory: true)
                var verIsDir: ObjCBool = false
                guard fm.fileExists(atPath: verDir.path, isDirectory: &verIsDir),
                      verIsDir.boolValue else { continue }
                let pkg = build(name: name, version: version, kind: kind, verDir: verDir)
                out.append(pkg)
            }
        }
        return out.sorted { ($0.name, $0.version) < ($1.name, $1.version) }
    }

    private func build(name: String, version: String, kind: BrewPackageKind,
                       verDir: URL) -> BrewPackage {
        let receipt = verDir.appendingPathComponent("INSTALL_RECEIPT.json")
        let info = parseReceipt(at: receipt)
        return BrewPackage(
            name: name,
            version: version,
            kind: kind,
            installedAt: info?.installedAt,
            installedOnRequest: info?.installedOnRequest ?? (kind == .cask),
            tap: info?.tap,
            path: verDir
        )
    }

    private struct ReceiptInfo {
        var installedAt: Date?
        var installedOnRequest: Bool
        var tap: String?
    }

    private func parseReceipt(at url: URL) -> ReceiptInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var info = ReceiptInfo(installedAt: nil, installedOnRequest: false, tap: nil)
        if let time = json["time"] as? TimeInterval {
            info.installedAt = Date(timeIntervalSince1970: time)
        } else if let timeInt = json["time"] as? Int {
            info.installedAt = Date(timeIntervalSince1970: TimeInterval(timeInt))
        }
        info.installedOnRequest = (json["installed_on_request"] as? Bool) ?? false
        if let source = json["source"] as? [String: Any],
           let tap = source["tap"] as? String {
            info.tap = tap
        }
        return info
    }
}
