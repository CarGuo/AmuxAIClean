import Foundation
import LogKit
import SwiftUI

/// v1.1 更新检查器：手写 GitHub Releases API 路线（不引入 Sparkle）。
///
/// **为什么不用 Sparkle 2？**
/// - 我们走 ad-hoc 签名（无 Apple Developer Program），Sparkle 2 默认要求 EdDSA 签名 + 公证更新包
/// - 我们没有 appcast.xml 服务器，GitHub Release 的 tag_name 已经是事实上的 SemVer 源
/// - 用户决策：不自动下载 / 不自动安装，只做"提示 + 跳转 Release 页"，避免任何沉默升级风险
///
/// **流程**：
/// 1. 启动时（如果 settings.updateCheckEnabled）调一次 `GET https://api.github.com/repos/CarGuo/GSYCleanMac/releases/latest`
/// 2. 解析 tag_name（形如 `v1.1.0`），与本地 CFBundleShortVersionString 做 SemVer 比较
/// 3. 远端更新且未被"跳过此版本"标记 → MainActor 上设 `availableUpdate`，UI sheet 显示
/// 4. 用户三选一：跳过此版本（写 skippedUpdateTag）/ 稍后提醒（什么都不做）/ 前往下载（NSWorkspace.open html_url）
///
/// **隐私 / 流量承诺**：
/// - 只在启动时打 **一次** API（约 2 KB JSON）
/// - 用户可在设置里关闭（"启动检查更新" toggle，默认 ON）
/// - 不发任何 telemetry / 不带任何 query 参数
public struct ReleaseInfo: Sendable, Equatable {
    public let tagName: String
    public let name: String
    public let htmlURL: URL
    public let body: String
    public let publishedAt: Date?
    /// v1.5.7：Release assets 列表，用于（1）展示给用户已发布的产物（2）拉 `*.sha256` 做完整性提示。
    public let assets: [ReleaseAsset]

    public init(tagName: String, name: String, htmlURL: URL, body: String, publishedAt: Date?, assets: [ReleaseAsset] = []) {
        self.tagName = tagName
        self.name = name
        self.htmlURL = htmlURL
        self.body = body
        self.publishedAt = publishedAt
        self.assets = assets
    }
}

/// v1.5.7：GitHub Release asset 简化模型。
public struct ReleaseAsset: Sendable, Equatable {
    public let name: String
    public let downloadURL: URL
    public let sizeBytes: Int

    public init(name: String, downloadURL: URL, sizeBytes: Int) {
        self.name = name
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
    }
}

/// v2026.07.15：更新检查失败保存稳定事实，不在网络任务结束时固化进程首选语言。
/// Settings 在渲染 `lastResult` 时把当前 App locale 显式传给 `message(locale:)`。
public enum UpdateCheckFailure: Sendable, Equatable {
    case invalidRequestURL(String)
    case httpStatus(Int)
    case invalidReleaseURL
    case invalidResponse
    case requestFailed(domain: String, code: Int)

    public func message(locale: Locale) -> String {
        switch self {
        case .invalidRequestURL(let value):
            return AppLocalization.format(
                "updater.error.url_build_failed %@",
                locale: locale,
                arguments: [value]
            )
        case .httpStatus(let code):
            return AppLocalization.format(
                "updater.error.http_status %lld",
                locale: locale,
                arguments: [Int64(code)]
            )
        case .invalidReleaseURL:
            return AppLocalization.string(
                "updater.error.html_url_parse_failed",
                locale: locale
            )
        case .invalidResponse:
            return AppLocalization.string("updater.error.invalid_response", locale: locale)
        case .requestFailed(let domain, let code):
            return AppLocalization.format(
                "updater.error.request_failed %@ %lld",
                locale: locale,
                arguments: [domain, Int64(code)]
            )
        }
    }
}

public enum UpdateCheckResult: Sendable {
    case upToDate
    case newer(ReleaseInfo)
    /// 用户已主动跳过此版本（仍会上报 release 信息，UI 决定是否再提示）。
    case skippedByUser(ReleaseInfo)
    case failed(UpdateCheckFailure)
}

/// SwiftUI `.sheet(item:)` 需要 Identifiable 包装；ReleaseInfo 是 value type 直接拿 tagName 当 id。
public struct IdentifiedRelease: Identifiable {
    public let release: ReleaseInfo
    public var id: String { release.tagName }
    public init(release: ReleaseInfo) { self.release = release }
}

/// 简易 SemVer 比较（仅取 major/minor/patch 三段，忽略前缀 `v` 和 build/prerelease 后缀）。
public enum SemVer {
    /// 把 "v1.2.3" / "1.2.3-beta" / "1.2" 解析为 (1,2,3) / (1,2,0)。
    /// 解析失败返回 nil，调用方按"无法判断"处理（不弹更新）。
    public static func parse(_ raw: String) -> (Int, Int, Int)? {
        var s = raw
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // 砍掉 -beta / +build 等
        if let idx = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<idx])
        }
        let parts = s.split(separator: ".").map { Int($0) ?? -1 }
        guard !parts.isEmpty, parts.allSatisfy({ $0 >= 0 }) else { return nil }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return (major, minor, patch)
    }

    /// 返回 a < b。
    public static func isOlder(_ a: String, than b: String) -> Bool {
        guard let pa = parse(a), let pb = parse(b) else { return false }
        if pa.0 != pb.0 { return pa.0 < pb.0 }
        if pa.1 != pb.1 { return pa.1 < pb.1 }
        return pa.2 < pb.2
    }
}

private enum UpdateReleaseParsingError: Error {
    case invalidReleaseURL
}

/// MainActor 持有的状态对象，UI 通过 @Bindable 观察。
@MainActor
@Observable
public final class UpdateChecker {
    /// 当前需要展示的可用新版本；nil 表示没有需要提示的更新。
    public var availableUpdate: ReleaseInfo?
    /// 上次检查的结果（设置面板里"立即检查"按钮可看到详情）。
    public var lastResult: UpdateCheckResult?
    /// 是否正在检查中（设置面板按钮 disable 用）。
    public var isChecking: Bool = false

    private let owner: String
    private let repo: String
    private let session: URLSession
    private weak var settings: AppSettings?

    public init(owner: String = "CarGuo", repo: String = "GSYCleanMac",
                session: URLSession? = nil, settings: AppSettings? = nil) {
        self.owner = owner
        self.repo = repo
        // v1.5.7：默认自建 ephemeral session —— 不持久化 cookie / cache / credentials，
        // 防止 GitHub 把同一 host 的其他登录态 cookie 串扰到 update 请求里。
        // - timeoutIntervalForRequest=10s 单包请求超时（避免单个 socket hang 拖死）
        // - timeoutIntervalForResource=30s 整个传输上限（默认 7 天，对 2KB JSON 太宽松）
        // - waitsForConnectivity=false 离线时立即失败而不是排队等到联网（避免 App 退出时还在排队）
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 30
            cfg.waitsForConnectivity = false
            cfg.httpCookieAcceptPolicy = .never
            cfg.httpShouldSetCookies = false
            cfg.allowsCellularAccess = true
            cfg.urlCache = nil
            self.session = URLSession(configuration: cfg)
        }
        self.settings = settings
    }

    /// 启动入口：尊重 settings.updateCheckEnabled，关掉就什么都不做。
    public func checkOnLaunch() {
        guard let s = settings, s.updateCheckEnabled else { return }
        Task { [weak self] in await self?.runCheck(force: false) }
    }

    /// 设置面板"立即检查"按钮入口：忽略 skippedUpdateTag，强制提示。
    public func checkNow() {
        Task { [weak self] in await self?.runCheck(force: true) }
    }

    /// 用户选了"跳过此版本"。
    public func skip(_ release: ReleaseInfo) {
        settings?.skippedUpdateTag = release.tagName
        availableUpdate = nil
    }

    /// 用户选了"稍后提醒"——本次会话内不再弹，下次启动重新判断。
    public func dismissUntilNextLaunch() {
        availableUpdate = nil
    }

    private func runCheck(force: Bool) async {
        if isChecking { return }
        isChecking = true
        defer { isChecking = false }

        let urlStr = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        GSYLog.info(.updater, "runCheck 开始 force=\(force) url=\(urlStr)")
        guard let url = URL(string: urlStr) else {
            GSYLog.error(.updater, "URL 构造失败 url=\(urlStr)")
            lastResult = .failed(.invalidRequestURL(urlStr))
            return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GSYCleanMac/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                GSYLog.warning(.updater, "HTTP 状态码非 200 code=\(code)")
                lastResult = .failed(.httpStatus(code))
                return
            }
            let release = try parseRelease(data)
            // 比对版本
            let local = Self.currentVersion
            if SemVer.isOlder(local, than: release.tagName) {
                if !force, let skipped = settings?.skippedUpdateTag, skipped == release.tagName {
                    GSYLog.info(.updater, "用户已跳过此版本 tag=\(release.tagName)")
                    lastResult = .skippedByUser(release)
                    return
                }
                GSYLog.notice(.updater, "发现新版本 local=\(local) remote=\(release.tagName)")
                availableUpdate = release
                lastResult = .newer(release)
            } else {
                GSYLog.info(.updater, "已是最新版本 local=\(local) remote=\(release.tagName)")
                lastResult = .upToDate
            }
        } catch {
            GSYLog.error(.updater, "runCheck 网络/解析失败 err=\(error.localizedDescription)")
            switch error {
            case UpdateReleaseParsingError.invalidReleaseURL:
                lastResult = .failed(.invalidReleaseURL)
            case is DecodingError:
                lastResult = .failed(.invalidResponse)
            default:
                let nsError = error as NSError
                lastResult = .failed(.requestFailed(
                    domain: nsError.domain,
                    code: nsError.code
                ))
            }
        }
    }

    private func parseRelease(_ data: Data) throws -> ReleaseInfo {
        struct RawRelease: Decodable {
            struct RawAsset: Decodable {
                let name: String
                let browser_download_url: String
                let size: Int
            }
            let tag_name: String
            let name: String?
            let html_url: String
            let body: String?
            let published_at: String?
            let assets: [RawAsset]?
        }
        let raw = try JSONDecoder().decode(RawRelease.self, from: data)
        guard let url = URL(string: raw.html_url) else {
            throw UpdateReleaseParsingError.invalidReleaseURL
        }
        let date: Date? = raw.published_at.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        let assets: [ReleaseAsset] = (raw.assets ?? []).compactMap { a in
            guard let u = URL(string: a.browser_download_url) else { return nil }
            return ReleaseAsset(name: a.name, downloadURL: u, sizeBytes: a.size)
        }
        return ReleaseInfo(
            tagName: raw.tag_name,
            name: raw.name ?? raw.tag_name,
            htmlURL: url,
            body: raw.body ?? "",
            publishedAt: date,
            assets: assets
        )
    }

    /// v1.5.7：从 release assets 里挑出 `*.dmg.sha256` 文件并把内容拉下来。
    ///
    /// 返回一个 `[filename: sha256-hex-lowercase]` 字典，UI 上展示给用户做手动比对。
    /// 这里**不**自动下载主 dmg 然后跑哈希；理由：
    /// - 自动下载需引入 NSSavePanel / 进度条 / 失败重试 / 续传 等大量 UI，超出本次 patch 范畴
    /// - 跳浏览器下载是当前用户决策（避免任何"沉默升级"风险）
    /// - 哪怕 UI 自动比对成功，仍需用户手动把校验后的 .dmg 拖到 Applications，不可省略 GUI 干预
    /// 所以这里只做一件事：**把 GitHub 服务器上的预期 SHA256 拉下来，UI 显式展示给用户**。
    public func fetchExpectedSHA256(for release: ReleaseInfo) async -> [String: String] {
        let sha256Assets = release.assets.filter { $0.name.hasSuffix(".sha256") }
        guard !sha256Assets.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for asset in sha256Assets {
            // 单个 .sha256 文件 < 200 字节，串行下载足够。
            var req = URLRequest(url: asset.downloadURL)
            req.setValue("text/plain", forHTTPHeaderField: "Accept")
            req.setValue("GSYCleanMac/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { continue }
                guard data.count <= 4096,
                      let text = String(data: data, encoding: .utf8) else { continue }
                // shasum 输出格式："<64 hex>  <filename>" —— 取头 64 位 hex
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let firstField = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
                let hex = firstField.lowercased()
                guard hex.count == 64,
                      hex.allSatisfy({ "0123456789abcdef".contains($0) }) else { continue }
                // 关联到对应的原文件名（剥掉 .sha256 后缀）
                let originalName = String(asset.name.dropLast(".sha256".count))
                result[originalName] = hex
            } catch {
                GSYLog.warning(.updater, "fetchExpectedSHA256 拉取失败 asset=\(asset.name) err=\(error.localizedDescription)")
            }
        }
        return result
    }

    /// 当前 App 版本号（从 Info.plist 读 CFBundleShortVersionString）。
    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}

/// 新版本提示 sheet：跳过 / 稍后 / 前往下载。
public struct UpdatePromptView: View {
    /// v2026.07.15：更新弹层可在显示期间随 App 语言切换，格式串不能固化启动语言。
    @Environment(\.locale) private var locale
    @Bindable public var checker: UpdateChecker
    public let release: ReleaseInfo

    /// v1.5.7：从 release assets 拉到的 [filename: sha256-hex] 字典。
    @State private var expectedHashes: [String: String] = [:]
    @State private var hashesLoaded: Bool = false

    public init(checker: UpdateChecker, release: ReleaseInfo) {
        self.checker = checker
        self.release = release
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .resizable().frame(width: 32, height: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.format(
                        "updater.prompt.new_version %@",
                        locale: locale,
                        arguments: [release.tagName]
                    ))
                        .font(.title3).fontWeight(.semibold)
                    Text(AppLocalization.format(
                        "updater.prompt.current_version %@",
                        locale: locale,
                        arguments: [UpdateChecker.currentVersion]
                    ))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            if !release.body.isEmpty {
                ScrollView {
                    Text(release.body)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 240)
            } else {
                Text("updater.prompt.no_notes", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary)
            }
            if hashesLoaded && !expectedHashes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("updater.prompt.sha256_label", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark.seal")
                    }
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(expectedHashes.sorted(by: { $0.key < $1.key }), id: \.key) { name, hex in
                        HStack(alignment: .top, spacing: 6) {
                            Text(name).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(hex).font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button(AppLocalization.string("updater.prompt.button.skip", locale: locale)) {
                    checker.skip(release)
                }
                .controlSize(.regular)
                Spacer()
                Button(AppLocalization.string("updater.prompt.button.later", locale: locale)) {
                    checker.dismissUntilNextLaunch()
                }
                .controlSize(.regular)
                Button(AppLocalization.string("updater.prompt.button.download", locale: locale)) {
                    NSWorkspace.shared.open(release.htmlURL)
                    checker.dismissUntilNextLaunch()
                }
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            // 异步拉 SHA256；失败或没有 .sha256 asset 静默隐藏，不阻塞 UI。
            let h = await checker.fetchExpectedSHA256(for: release)
            expectedHashes = h
            hashesLoaded = true
        }
    }
}
