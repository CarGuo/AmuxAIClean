import SwiftUI
import BrewKit

/// F-2-4 / 2026-06：Homebrew 包管理屏（sidebar 入口接入）。
///
/// dev 期 MVP（直接读 Cellar / Caskroom，不执行 brew 命令）：
/// - 顶部三个 tab：Installed / Outdated / Cleanup
/// - Installed：列 [BrewController.listAll()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit/Sources/BrewKit/BrewController.swift)
/// - Outdated：需要先加载一次 [BrewRegistry](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit/Sources/BrewKit/BrewRegistry.swift)
///   的 jws cache（用户首次点 Refresh 才下载，离线时跳过）
/// - Cleanup：调 [BrewCleanup.dryRun](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit/Sources/BrewKit/BrewCleanup.swift)
///   只列 stale paths，不真删（dev 期保守，避免误删 bottle）
///
/// brew 未安装时显示空态指引。所有字面量走英文 + 中文注释，不引入新 xcstrings。
public struct BrewScreen: View {
    private let controller: BrewController?
    private let cleanup: BrewCleanup?

    @State private var packages: [BrewPackage] = []
    @State private var outdated: [BrewOutdated] = []
    @State private var cleanupPlan: BrewCleanupPlan?
    @State private var selectedTab: Tab = .installed
    @State private var isLoading: Bool = false
    @State private var lastError: String?

    enum Tab: String, CaseIterable, Identifiable {
        case installed, outdated, cleanup
        var id: String { rawValue }
        var label: String {
            switch self {
            case .installed: return "Installed"
            case .outdated:  return "Outdated"
            case .cleanup:   return "Cleanup"
            }
        }
        var icon: String {
            switch self {
            case .installed: return "shippingbox"
            case .outdated:  return "arrow.up.circle"
            case .cleanup:   return "trash.circle"
            }
        }
    }

    public init(controller: BrewController? = BrewController.detectDefault(),
                cleanup: BrewCleanup? = BrewCleanup.detectDefault()) {
        self.controller = controller
        self.cleanup = cleanup
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if controller == nil {
                notInstalledHint
            } else {
                tabBar
                Divider()
                content
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { reloadInstalled() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Homebrew")
                    .font(.title2.bold())
                if let prefix = controller?.prefix.path {
                    Text("prefix: \(prefix)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(controller == nil || isLoading)
        }
    }

    private var notInstalledHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Homebrew not detected", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("BrewScreen looks for /opt/homebrew (Apple Silicon) or /usr/local (Intel). Install Homebrew first, then reopen this screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private var tabBar: some View {
        Picker("", selection: $selectedTab) {
            ForEach(Tab.allCases) { t in
                Label(t.label, systemImage: t.icon).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: selectedTab) { _, new in
            switch new {
            case .installed: reloadInstalled()
            case .outdated:  reloadOutdated()
            case .cleanup:   reloadCleanup()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let err = lastError {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
        switch selectedTab {
        case .installed: installedSection
        case .outdated:  outdatedSection
        case .cleanup:   cleanupSection
        }
    }

    // MARK: - Installed

    @ViewBuilder
    private var installedSection: some View {
        if packages.isEmpty && !isLoading {
            Text("No formula / cask installed.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(packages.count) packages")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(packages, id: \.path) { pkg in
                            packageRow(pkg)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func packageRow(_ pkg: BrewPackage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pkg.kind == .cask ? "macwindow" : "terminal")
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pkg.name).font(.system(.body, design: .monospaced))
                    Text(pkg.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if pkg.installedOnRequest == false && pkg.kind == .formula {
                        Text("dep").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let tap = pkg.tap {
                    Text(tap).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let date = pkg.installedAt {
                Text(date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
    }

    // MARK: - Outdated

    @ViewBuilder
    private var outdatedSection: some View {
        if outdated.isEmpty && !isLoading {
            // dev 期不下载 jws；用户主动点 Refresh 才尝试。
            Text("Outdated tab needs `BrewRegistry` jws cache. Click Refresh to compute against your local Homebrew api cache (~/Library/Caches/Homebrew/api).")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(outdated.count) upgradable")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(outdated, id: \.package.path) { o in
                            outdatedRow(o)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outdatedRow(_ o: BrewOutdated) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
            Text(o.package.name).font(.system(.body, design: .monospaced))
            Text("\(o.package.version) → \(o.latestVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }

    // MARK: - Cleanup

    @ViewBuilder
    private var cleanupSection: some View {
        if let plan = cleanupPlan {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("\(plan.stalePaths.count) stale · \(byteString(plan.totalBytes))",
                          systemImage: "trash")
                        .font(.subheadline)
                        .foregroundStyle(plan.isEmpty ? Color.secondary : Color.orange)
                    Spacer()
                    Text("dry-run only · manual `brew cleanup` to delete")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.stalePaths, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.05)))
                        }
                    }
                }
            }
        } else if isLoading {
            Text("Computing cleanup plan...")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if cleanup == nil {
            Text("Homebrew cache directory missing (~/Library/Caches/Homebrew).")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            Text("Click Refresh to compute the cleanup plan (dry-run).")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - actions

    private func refresh() {
        switch selectedTab {
        case .installed: reloadInstalled()
        case .outdated:  reloadOutdated()
        case .cleanup:   reloadCleanup()
        }
    }

    private func reloadInstalled() {
        guard let ctl = controller else { return }
        isLoading = true
        lastError = nil
        Task.detached {
            let pkgs = ctl.listAll()
            await MainActor.run {
                packages = pkgs
                isLoading = false
            }
        }
    }

    private func reloadOutdated() {
        guard let ctl = controller else { return }
        isLoading = true
        lastError = nil
        Task.detached {
            // BrewRegistry 用户本地 brew api cache（brew update 一下就有）。
            // 完全离线场景下 registry 是空的，outdated == [] 是合理结果。
            let registry = BrewRegistry.loadDefault()
            let result = ctl.outdated(using: registry)
            await MainActor.run {
                outdated = result
                isLoading = false
            }
        }
    }

    private func reloadCleanup() {
        guard let c = cleanup else {
            cleanupPlan = nil
            return
        }
        isLoading = true
        lastError = nil
        Task.detached {
            let plan = c.dryRun()
            await MainActor.run {
                cleanupPlan = plan
                isLoading = false
            }
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
