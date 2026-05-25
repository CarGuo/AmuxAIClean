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

    public init(tagName: String, name: String, htmlURL: URL, body: String, publishedAt: Date?) {
        self.tagName = tagName
        self.name = name
        self.htmlURL = htmlURL
        self.body = body
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckResult: Sendable {
    case upToDate
    case newer(ReleaseInfo)
    /// 用户已主动跳过此版本（仍会上报 release 信息，UI 决定是否再提示）。
    case skippedByUser(ReleaseInfo)
    case failed(String)
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
                session: URLSession = .shared, settings: AppSettings? = nil) {
        self.owner = owner
        self.repo = repo
        self.session = session
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
            lastResult = .failed("URL 构造失败：\(urlStr)")
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
                lastResult = .failed("HTTP \(code)")
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
            lastResult = .failed("\(error.localizedDescription)")
        }
    }

    private func parseRelease(_ data: Data) throws -> ReleaseInfo {
        struct RawRelease: Decodable {
            let tag_name: String
            let name: String?
            let html_url: String
            let body: String?
            let published_at: String?
        }
        let raw = try JSONDecoder().decode(RawRelease.self, from: data)
        guard let url = URL(string: raw.html_url) else {
            throw NSError(domain: "UpdateChecker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "html_url 解析失败"])
        }
        let date: Date? = raw.published_at.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return ReleaseInfo(
            tagName: raw.tag_name,
            name: raw.name ?? raw.tag_name,
            htmlURL: url,
            body: raw.body ?? "",
            publishedAt: date
        )
    }

    /// 当前 App 版本号（从 Info.plist 读 CFBundleShortVersionString）。
    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}

/// 新版本提示 sheet：跳过 / 稍后 / 前往下载。
public struct UpdatePromptView: View {
    @Bindable public var checker: UpdateChecker
    public let release: ReleaseInfo

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
                    Text("发现新版本：\(release.tagName)")
                        .font(.title3).fontWeight(.semibold)
                    Text("当前版本：\(UpdateChecker.currentVersion)")
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
                Text("没有提供更新说明，请前往 Release 页查看变更。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("跳过此版本") {
                    checker.skip(release)
                }
                .controlSize(.regular)
                Spacer()
                Button("稍后提醒") {
                    checker.dismissUntilNextLaunch()
                }
                .controlSize(.regular)
                Button("前往下载") {
                    NSWorkspace.shared.open(release.htmlURL)
                    checker.dismissUntilNextLaunch()
                }
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
