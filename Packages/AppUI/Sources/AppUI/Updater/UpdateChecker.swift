import Combine
import Foundation
import LogKit
import SwiftUI

/// v1.1 更新检查器：手写 GitHub Releases API 路线（不引入 Sparkle）。
///
/// **为什么不用 Sparkle 2？**
/// - v2026.07.18 真实发行边界是 Developer ID + 公证 DMG，但产品没有 appcast 或自动安装合同；
/// - GitHub Release 的 tag_name 是当前显式版本源；
/// - 客户端只做“提示 + 跳转已验证 Release 页”，不自动下载或安装，避免静默升级能力扩张。
///
/// **流程**：
/// 1. 启动时（如果 settings.updateCheckEnabled）调一次 `GET https://api.github.com/repos/CarGuo/GSYCleanMac/releases/latest`
/// 2. 解析 tag_name（形如 `v1.1.0`），与本地 CFBundleShortVersionString 做 SemVer 比较
/// 3. 远端更新且未被"跳过此版本"标记 → MainActor 上设 `availableUpdate`，UI sheet 显示
/// 4. 用户三选一：跳过此版本（写 skippedUpdateTag）/ 稍后提醒（什么都不做）/ 前往下载（NSWorkspace.open html_url）
///
/// **隐私 / 流量合同**：
/// - 每个 App 进程最多自动检查一次（约 2 KB JSON），重建主窗口不重试
/// - 用户可在设置里关闭（"启动检查更新" toggle，默认 ON）
/// - 不发任何 telemetry / 不带任何 query 参数
/// - v2026.07.18 起不再自动请求 Release asset：GitHub 官方只承诺 asset
///   下载可返回 200/302，未对 302 最终 host 给出可稳定验证的仓库归属合同。
///   在不能证明重定向边界时，优先取消该请求，不使用推测的 CDN allowlist。
public struct ReleaseInfo: Sendable, Equatable {
    public let tagName: String
    public let name: String
    public let htmlURL: URL
    public let body: String
    public let publishedAt: Date?
    /// v2026.07.18：只保留经仓库归属验证的 Release asset 元数据。
    /// 不会由 App 自动请求 `downloadURL`，避免未受证明的 302 落点扩大网络边界。
    public let assets: [ReleaseAsset]

    /// v2026.07.18：构造器保持 internal，防止 AppUI 外部绕过 parser 伪造任意
    /// `htmlURL` 再交给 `NSWorkspace.open`。对外只暴露已验证完成的不可变值。
    init(tagName: String, name: String, htmlURL: URL, body: String, publishedAt: Date?, assets: [ReleaseAsset] = []) {
        self.tagName = tagName
        self.name = name
        self.htmlURL = htmlURL
        self.body = body
        self.publishedAt = publishedAt
        self.assets = assets
    }
}

/// v2026.07.18：GitHub Release asset 简化模型。`downloadURL` 已经验证为
/// `https://github.com/<owner>/<repo>/releases/download/<tag>/<name>`，
/// 但仅作为 Release 元数据，不构成自动跟随其重定向的授权。
public struct ReleaseAsset: Sendable, Equatable {
    public let name: String
    public let downloadURL: URL
    public let sizeBytes: Int

    /// 同 ReleaseInfo，禁止外部伪造跨仓库 asset URL。
    init(name: String, downloadURL: URL, sizeBytes: Int) {
        self.name = name
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
    }
}

/// v2026.07.18：校验文件自动拉取策略是类型化的产品/安全合同，
/// 避免以后在 View 里因“想显示 hash”就重新打开任意 asset redirect。
public enum AutomaticChecksumFetchPolicy: Sendable, Equatable {
    /// GitHub 文档允许 asset API/browser URL 返回 302，但不承诺稳定的
    /// 最终 origin 集合；因此 App 不自动拉取 checksum asset。
    case disabledBecauseRedirectDestinationIsUnverifiable
}

/// v2026.07.15：更新检查失败保存稳定事实，不在网络任务结束时固化进程首选语言。
/// Settings 在渲染 `lastResult` 时把当前 App locale 显式传给 `message(locale:)`。
public enum UpdateCheckFailure: Sendable, Equatable {
    case invalidRequestURL(String)
    case httpStatus(Int)
    case invalidReleaseURL
    /// API 重定向、最终响应 URL 偏离固定 endpoint，或 Release/asset URL
    /// 不属于配置的 GitHub 仓库。该事实与 JSON 语法错误分开保存。
    case untrustedResponseSource
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
        case .untrustedResponseSource:
            // 用户只需知道返回不可信；host/path 细节仅进入脱敏日志。
            return AppLocalization.string("updater.error.invalid_response", locale: locale)
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
    case untrustedResponseSource
}

/// v2026.07.18：更新请求的唯一 URL 信任边界。
///
/// 不依赖字符串 prefix：先拒绝 userinfo/port/query/fragment，再按解码后的
/// path component 精确匹配 owner/repo/tag/name，避免子域、编码斜杠和前缀仓库混淆。
struct UpdateRepositoryNetworkBoundary: Sendable {
    let owner: String
    let repo: String

    init?(owner: String, repo: String) {
        guard Self.isOwner(owner), Self.isRepository(repo) else { return nil }
        self.owner = owner
        self.repo = repo
    }

    var latestReleaseAPIURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/releases/latest"
        // owner/repo 在 init 已经收窄到 ASCII path component，构造必定成功。
        return components.url!
    }

    func ownsLatestReleaseAPIURL(_ url: URL) -> Bool {
        guard let components = trustedHTTPSComponents(url, host: "api.github.com") else {
            return false
        }
        return decodedPathComponents(components) == [
            "repos", owner, repo, "releases", "latest",
        ]
    }

    func ownsReleasePageURL(_ url: URL, tag: String) -> Bool {
        guard Self.isReleaseTag(tag),
              let components = trustedHTTPSComponents(url, host: "github.com") else {
            return false
        }
        let path = decodedPathComponents(components)
        guard path.count == 5 else { return false }
        return path[0].caseInsensitiveCompare(owner) == .orderedSame
            && path[1].caseInsensitiveCompare(repo) == .orderedSame
            && path[2] == "releases"
            && path[3] == "tag"
            && path[4] == tag
    }

    func ownsReleaseAssetURL(_ url: URL, tag: String, assetName: String) -> Bool {
        guard Self.isReleaseTag(tag), Self.isAssetName(assetName),
              let components = trustedHTTPSComponents(url, host: "github.com") else {
            return false
        }
        let path = decodedPathComponents(components)
        guard path.count == 6 else { return false }
        return path[0].caseInsensitiveCompare(owner) == .orderedSame
            && path[1].caseInsensitiveCompare(repo) == .orderedSame
            && path[2] == "releases"
            && path[3] == "download"
            && path[4] == tag
            && path[5] == assetName
    }

    private func trustedHTTPSComponents(_ url: URL, host: String) -> URLComponents? {
        guard !url.isFileURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == host,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        return components
    }

    private func decodedPathComponents(_ components: URLComponents) -> [String] {
        guard let url = components.url else { return [] }
        var path = url.pathComponents
        if path.first == "/" { path.removeFirst() }
        return path
    }

    private static func isOwner(_ value: String) -> Bool {
        guard (1...39).contains(value.utf8.count),
              value.first != "-", value.last != "-" else { return false }
        return value.unicodeScalars.allSatisfy {
            isASCIIAlphanumeric($0) || $0 == "-"
        }
    }

    private static func isRepository(_ value: String) -> Bool {
        guard (1...100).contains(value.utf8.count), value != ".", value != ".." else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            isASCIIAlphanumeric($0) || "._-".unicodeScalars.contains($0)
        }
    }

    private static func isReleaseTag(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 100,
              value != ".", value != "..", !value.contains("/") else { return false }
        return value.unicodeScalars.allSatisfy {
            isASCIIAlphanumeric($0) || ".+_-".unicodeScalars.contains($0)
        }
    }

    private static func isAssetName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255,
              value != ".", value != "..",
              !value.contains("/"), !value.contains("\\") else { return false }
        return !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }
}

/// v2026.07.18：ephemeral session 的 redirect/auth 闸门。更新 API 只有一个
/// 固定 endpoint，而 checksum 自动拉取已关闭，因此任何 HTTP redirect
/// 都没有业务必要；返回 nil 同时防止 header/body 被 URLSession 复用到新 origin。
enum UpdateRedirectPolicy {
    static func requestAfterRedirect(_ request: URLRequest) -> URLRequest? {
        nil
    }
}

final class UpdateSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(UpdateRedirectPolicy.requestAfterRedirect(request))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// v2026.07.18：生产与 URLProtocol 测试共用同一个 session 工厂。
/// 测试只替换底层 protocol class，不复制或放宽网络策略。
@MainActor
enum UpdateSessionFactory {
    static func configuration(protocolClasses: [AnyClass]?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.allowsCellularAccess = true
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    static func makeSession(protocolClasses: [AnyClass]?) -> URLSession {
        URLSession(
            configuration: configuration(protocolClasses: protocolClasses),
            delegate: UpdateSessionDelegate(),
            delegateQueue: nil
        )
    }
}

/// MainActor 持有的状态对象。v2026.07.16 起通过 Combine 发布用户可见检查状态，
/// 网络 session、仓库标识和 settings 引用不参与发布，以兼容 macOS 13.5。
@MainActor
public final class UpdateChecker: ObservableObject {
    public static let automaticChecksumFetchPolicy: AutomaticChecksumFetchPolicy =
        .disabledBecauseRedirectDestinationIsUnverifiable

    /// 当前需要展示的可用新版本；nil 表示没有需要提示的更新。
    @Published public var availableUpdate: ReleaseInfo?
    /// 上次检查的结果（设置面板里"立即检查"按钮可看到详情）。
    @Published public var lastResult: UpdateCheckResult?
    /// 是否正在检查中（设置面板按钮 disable 用）。
    @Published public var isChecking: Bool = false

    private let owner: String
    private let repo: String
    private let networkBoundary: UpdateRepositoryNetworkBoundary?
    private let session: URLSession
    private weak var settings: AppSettings?
    /// WindowGroup 的 `.task` 会在主窗口重建时再次执行。该 latch 属于
    /// UpdateChecker 进程级实例，把“启动检查”收敛为每进程最多一轮。
    private var hasStartedAutomaticCheck = false

    public convenience init(
        owner: String = "CarGuo",
        repo: String = "GSYCleanMac",
        settings: AppSettings? = nil
    ) {
        self.init(owner: owner, repo: repo, protocolClasses: nil, settings: settings)
    }

    /// v2026.07.18：仅供 `@testable AppUI` 的 URLProtocol 确定性测试入口。
    /// 测试只能注入 protocol class，不能替换整个 URLSession；因此依然经过
    /// 与生产一致的 ephemeral/cookie/cache/credential/redirect 策略。
    init(
        owner: String = "CarGuo",
        repo: String = "GSYCleanMac",
        protocolClasses: [AnyClass]?,
        settings: AppSettings? = nil
    ) {
        self.owner = owner
        self.repo = repo
        self.networkBoundary = UpdateRepositoryNetworkBoundary(owner: owner, repo: repo)
        // v2026.07.18：始终自建 ephemeral session，不再接受可绕过策略的
        // public URLSession 注入。不持久化 cookie / cache / credentials，
        // 防止 GitHub 把同一 host 的其他登录态 cookie 串扰到 update 请求里。
        // - timeoutIntervalForRequest=10s 单包请求超时（避免单个 socket hang 拖死）
        // - timeoutIntervalForResource=30s 整个传输上限（默认 7 天，对 2KB JSON 太宽松）
        // - waitsForConnectivity=false 离线时立即失败而不是排队等到联网（避免 App 退出时还在排队）
        self.session = UpdateSessionFactory.makeSession(protocolClasses: protocolClasses)
        self.settings = settings
    }

    /// 启动入口：尊重 settings.updateCheckEnabled，关掉就什么都不做。
    public func checkOnLaunch() {
        guard let s = settings, s.updateCheckEnabled else { return }
        guard !hasStartedAutomaticCheck else {
            GSYLog.debug(.updater, "checkOnLaunch 跳过：本进程已发起过自动检查")
            return
        }
        hasStartedAutomaticCheck = true
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

        let configuredRoute = "\(owner)/\(repo)"
        guard let networkBoundary else {
            GSYLog.error(.updater, "更新仓库路由非法 route=\(configuredRoute)")
            lastResult = .failed(.invalidRequestURL(configuredRoute))
            return
        }
        let url = networkBoundary.latestReleaseAPIURL
        GSYLog.info(.updater, "runCheck 开始 force=\(force) url=\(url.absoluteString)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.httpBody = nil
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpShouldHandleCookies = false
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GSYCleanMac/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                lastResult = .failed(.invalidResponse)
                return
            }
            guard let responseURL = http.url,
                  networkBoundary.ownsLatestReleaseAPIURL(responseURL),
                  !(300...399).contains(http.statusCode) else {
                GSYLog.warning(.updater, "拒绝更新响应来源 code=\(http.statusCode)")
                lastResult = .failed(.untrustedResponseSource)
                return
            }
            guard http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                GSYLog.warning(.updater, "HTTP 状态码非 200 code=\(code)")
                lastResult = .failed(.httpStatus(code))
                return
            }
            let release = try parseRelease(data, boundary: networkBoundary)
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
            case UpdateReleaseParsingError.untrustedResponseSource:
                lastResult = .failed(.untrustedResponseSource)
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

    private func parseRelease(
        _ data: Data,
        boundary: UpdateRepositoryNetworkBoundary
    ) throws -> ReleaseInfo {
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
        guard boundary.ownsReleasePageURL(url, tag: raw.tag_name) else {
            throw UpdateReleaseParsingError.untrustedResponseSource
        }
        let date: Date? = raw.published_at.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        let assets: [ReleaseAsset] = try (raw.assets ?? []).map { a in
            guard a.size >= 0, let u = URL(string: a.browser_download_url) else {
                throw UpdateReleaseParsingError.invalidReleaseURL
            }
            guard boundary.ownsReleaseAssetURL(
                u,
                tag: raw.tag_name,
                assetName: a.name
            ) else {
                throw UpdateReleaseParsingError.untrustedResponseSource
            }
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

    /// 当前 App 版本号（从 Info.plist 读 CFBundleShortVersionString）。
    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}

/// 新版本提示 sheet：跳过 / 稍后 / 前往下载。
public struct UpdatePromptView: View {
    /// v2026.07.15：更新弹层可在显示期间随 App 语言切换，格式串不能固化启动语言。
    @Environment(\.locale) private var locale
    @ObservedObject public var checker: UpdateChecker
    public let release: ReleaseInfo

    public init(checker: UpdateChecker, release: ReleaseInfo) {
        self._checker = ObservedObject(wrappedValue: checker)
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
    }
}
