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
    /// 当前 version 目录占用的近似字节数，用于 UI 展示。
    public let sizeBytes: Int64

    public init(name: String, version: String, kind: BrewPackageKind,
                installedAt: Date?, installedOnRequest: Bool,
                tap: String?, path: URL, sizeBytes: Int64 = 0) {
        self.name = name
        self.version = version
        self.kind = kind
        self.installedAt = installedAt
        self.installedOnRequest = installedOnRequest
        self.tap = tap
        self.path = path
        self.sizeBytes = sizeBytes
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

/// Injectable, Sendable facts for the package-size traversal. Foundation dictionaries never cross
/// this boundary, and tests can make one exact subtree enumeration/metadata failure deterministic.
struct BrewPackageSizeEntryFacts: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case regularFile
        case directory
        case symbolicLink
        case other
    }

    let kind: Kind
    let allocatedBytes: Int64?
}

struct BrewPackageSizeFileSystem: Sendable {
    let contentsOfDirectory: @Sendable (URL) throws -> [String]
    let entryFacts: @Sendable (URL) throws -> BrewPackageSizeEntryFacts

    static let live = BrewPackageSizeFileSystem(
        contentsOfDirectory: { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        },
        entryFacts: { url in
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
            ]
            let values = try url.resourceValues(forKeys: keys)
            let kind: BrewPackageSizeEntryFacts.Kind
            if values.isSymbolicLink == true {
                kind = .symbolicLink
            } else if values.isRegularFile == true {
                kind = .regularFile
            } else if values.isDirectory == true {
                kind = .directory
            } else {
                kind = .other
            }
            return BrewPackageSizeEntryFacts(
                kind: kind,
                allocatedBytes: values.totalFileAllocatedSize
                    .map(Int64.init)
                    ?? values.fileAllocatedSize.map(Int64.init)
            )
        }
    )
}

private struct BrewPackageSizeEvidence {
    let bytes: Int64
    let diagnostics: [BrewDiagnostic]
}

public struct BrewController: Sendable {

    /// brew 安装 prefix（一般 /opt/homebrew 或 /usr/local）。
    public let prefix: URL
    private let fileReader: BrewFileReader
    private let packageSizeFileSystem: BrewPackageSizeFileSystem

    public init(prefix: URL) {
        self.prefix = prefix
        self.fileReader = .live
        self.packageSizeFileSystem = .live
    }

    init(
        prefix: URL,
        fileReader: BrewFileReader,
        packageSizeFileSystem: BrewPackageSizeFileSystem = .live
    ) {
        self.prefix = prefix
        self.fileReader = fileReader
        self.packageSizeFileSystem = packageSizeFileSystem
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
        listFormulaeWithDiagnostics().packages
    }

    public func listFormulaeWithDiagnostics() -> BrewPackageListResult {
        let cellar = prefix.appendingPathComponent("Cellar", isDirectory: true)
        return enumeratePackages(at: cellar, kind: .formula)
    }

    public func listCasks() -> [BrewPackage] {
        listCasksWithDiagnostics().packages
    }

    public func listCasksWithDiagnostics() -> BrewPackageListResult {
        let casks = prefix.appendingPathComponent("Caskroom", isDirectory: true)
        return enumeratePackages(at: casks, kind: .cask)
    }

    /// 一次性列出全部 formula + cask。
    public func listAll() -> [BrewPackage] {
        listAllWithDiagnostics().packages
    }

    public func listAllWithDiagnostics() -> BrewPackageListResult {
        let formulae = listFormulaeWithDiagnostics()
        let casks = listCasksWithDiagnostics()
        let packages = formulae.packages + casks.packages
        return BrewPackageListResult(
            packages: packages,
            diagnostics: formulae.diagnostics + casks.diagnostics,
            status: BrewEvidenceStatus.combining(
                [formulae.status, casks.status],
                hasValues: !packages.isEmpty
            )
        )
    }

    /// 用 [BrewRegistry](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit/Sources/BrewKit/BrewRegistry.swift)
    /// 标注每个已安装包的"最新版本"和"是否可升级"。
    ///
    /// 升级判定：installed != latest（字符串严格不等；不做 semver 解析以求稳）。
    /// 同名多 version 时，每个 version 各自比对（与 brew 行为一致）。
    public func outdated(using registry: BrewRegistry) -> [BrewOutdated] {
        outdated(installedPackages: listAll(), using: registry)
    }

    public func outdated(
        installedPackages: [BrewPackage],
        using registry: BrewRegistry
    ) -> [BrewOutdated] {
        installedPackages.compactMap { pkg in
            guard let latest = registry.latestVersion(for: pkg.name, kind: pkg.kind),
                  latest != pkg.version else { return nil }
            return BrewOutdated(package: pkg, latestVersion: latest)
        }
    }

    // MARK: - 内部

    private func enumeratePackages(
        at root: URL,
        kind: BrewPackageKind
    ) -> BrewPackageListResult {
        let fm = FileManager.default
        let source: BrewDiagnostic.Source = kind == .formula
            ? .formulaInstallations
            : .caskInstallations
        let names: [String]
        do {
            names = try fileReader.contentsOfDirectory(root)
        } catch {
            guard let diagnostic = brewLocalFileFailureDiagnostic(
                error,
                source: source,
                stage: .enumerateRoot,
                path: root.path
            ) else {
                // v2026.07.18 P2: Cellar/Caskroom are optional independent roots. ENOENT is a
                // trustworthy absence, not the same terminal state as a denied enumeration.
                return BrewPackageListResult(packages: [], status: .missing)
            }
            return BrewPackageListResult(
                packages: [],
                diagnostics: [diagnostic],
                status: .unavailable
            )
        }
        var out: [BrewPackage] = []
        var diagnostics: [BrewDiagnostic] = []
        for name in names where !name.hasPrefix(".") {
            let nameDir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: nameDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            // 每个 name 下可能有多个 version 目录，全列出（与 brew list --versions 一致）
            let versions: [String]
            do {
                versions = try fileReader.contentsOfDirectory(nameDir)
            } catch {
                if let diagnostic = brewLocalFileFailureDiagnostic(
                    error,
                    source: source,
                    stage: .enumerateVersions,
                    path: nameDir.path
                ) {
                    diagnostics.append(diagnostic)
                }
                continue
            }
            for version in versions where !version.hasPrefix(".") {
                let verDir = nameDir.appendingPathComponent(version, isDirectory: true)
                var verIsDir: ObjCBool = false
                guard fm.fileExists(atPath: verDir.path, isDirectory: &verIsDir),
                      verIsDir.boolValue else { continue }
                let built = build(
                    name: name,
                    version: version,
                    kind: kind,
                    verDir: verDir,
                    diagnosticSource: source
                )
                out.append(built.package)
                diagnostics.append(contentsOf: built.diagnostics)
            }
        }
        return BrewPackageListResult(
            packages: out.sorted { ($0.name, $0.version) < ($1.name, $1.version) },
            diagnostics: diagnostics,
            status: diagnostics.isEmpty ? .complete : .partial
        )
    }

    private func build(
        name: String,
        version: String,
        kind: BrewPackageKind,
        verDir: URL,
        diagnosticSource: BrewDiagnostic.Source
    ) -> (package: BrewPackage, diagnostics: [BrewDiagnostic]) {
        let receipt = verDir.appendingPathComponent("INSTALL_RECEIPT.json")
        let parsed = parseReceipt(at: receipt)
        let size = directoryAllocatedSize(at: verDir, source: diagnosticSource)
        let package = BrewPackage(
            name: name,
            version: version,
            kind: kind,
            installedAt: parsed.info?.installedAt,
            installedOnRequest: parsed.info?.installedOnRequest ?? (kind == .cask),
            tap: parsed.info?.tap,
            path: verDir,
            sizeBytes: size.bytes
        )
        return (package, parsed.diagnostics + size.diagnostics)
    }

    /// v2026.07.18: bytes and completeness are produced by one traversal. The former implementation
    /// used `errorHandler: nil` plus `try?`, turning an unreadable subtree into authoritative 0 B.
    /// Every enumeration/metadata gap now leaves a typed diagnostic and makes the package list
    /// partial while preserving the trustworthy lower-bound bytes already measured.
    private func directoryAllocatedSize(
        at url: URL,
        source: BrewDiagnostic.Source
    ) -> BrewPackageSizeEvidence {
        var pending = [url]
        var total: Int64 = 0
        var diagnostics: [BrewDiagnostic] = []
        while let directory = pending.popLast() {
            if Task.isCancelled {
                diagnostics.append(BrewDiagnostic(
                    source: source,
                    stage: .enumeratePackageSize,
                    reason: .cancelled,
                    path: directory.path
                ))
                break
            }
            let names: [String]
            do {
                names = try packageSizeFileSystem.contentsOfDirectory(directory).sorted()
            } catch {
                diagnostics.append(packageSizeDiagnostic(
                    error,
                    source: source,
                    stage: .enumeratePackageSize,
                    path: directory.path
                ))
                continue
            }

            for name in names where !name.hasPrefix(".") {
                if Task.isCancelled {
                    diagnostics.append(BrewDiagnostic(
                        source: source,
                        stage: .inspectPackageSize,
                        reason: .cancelled,
                        path: directory.path
                    ))
                    return BrewPackageSizeEvidence(bytes: total, diagnostics: diagnostics)
                }
                let child = directory.appendingPathComponent(name)
                let facts: BrewPackageSizeEntryFacts
                do {
                    facts = try packageSizeFileSystem.entryFacts(child)
                } catch {
                    diagnostics.append(packageSizeDiagnostic(
                        error,
                        source: source,
                        stage: .inspectPackageSize,
                        path: child.path
                    ))
                    continue
                }
                switch facts.kind {
                case .directory:
                    pending.append(child)
                case .regularFile:
                    guard let bytes = facts.allocatedBytes, bytes >= 0 else {
                        diagnostics.append(BrewDiagnostic(
                            source: source,
                            stage: .inspectPackageSize,
                            reason: .missingMetadata,
                            path: child.path
                        ))
                        continue
                    }
                    let next = total.addingReportingOverflow(bytes)
                    guard !next.overflow else {
                        diagnostics.append(BrewDiagnostic(
                            source: source,
                            stage: .inspectPackageSize,
                            reason: .tooLarge,
                            path: child.path
                        ))
                        continue
                    }
                    total = next.partialValue
                case .symbolicLink, .other:
                    continue
                }
            }
        }
        return BrewPackageSizeEvidence(bytes: total, diagnostics: diagnostics)
    }

    private func packageSizeDiagnostic(
        _ error: Error,
        source: BrewDiagnostic.Source,
        stage: BrewDiagnostic.Stage,
        path: String
    ) -> BrewDiagnostic {
        if BrewFileErrorClassifier.isMissing(error) {
            return BrewDiagnostic(source: source, stage: stage, reason: .changed, path: path)
        }
        return brewLocalFileFailureDiagnostic(
            error,
            source: source,
            stage: stage,
            path: path
        ) ?? BrewDiagnostic(source: source, stage: stage, reason: .unreadable, path: path)
    }

    private struct ReceiptInfo {
        var installedAt: Date?
        var installedOnRequest: Bool
        var tap: String?
    }

    private func parseReceipt(
        at url: URL
    ) -> (info: ReceiptInfo?, diagnostics: [BrewDiagnostic]) {
        let data: Data
        switch readBrewLocalFile(at: url, source: .installReceipt, reader: fileReader) {
        case .missing:
            return (nil, [])
        case .failure(let diagnostic):
            return (nil, [diagnostic])
        case .contents(let contents):
            data = contents
        }

        let json: [String: Any]
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, [BrewDiagnostic(
                    source: .installReceipt,
                    stage: .decodeDocument,
                    reason: .malformed,
                    path: url.path
                )])
            }
            json = dictionary
        } catch {
            let nsError = error as NSError
            return (nil, [BrewDiagnostic(
                source: .installReceipt,
                stage: .decodeDocument,
                reason: .malformed,
                path: url.path,
                errorDomain: nsError.domain,
                errorCode: nsError.code
            )])
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
        return (info, [])
    }
}
