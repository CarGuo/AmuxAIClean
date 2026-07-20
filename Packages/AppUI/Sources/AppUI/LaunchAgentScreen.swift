import SwiftUI
import AppKit
import ServiceManagement

/// v2026.07.18：一次启动项 reload 的唯一发布身份。取消 Task 只是一条信号，
/// 旧轮必须同时失去 revision ownership，才不能在同步 IO 返回后回写新页面。
struct LaunchAgentReloadIdentity: Sendable, Equatable {
    let operationID: UUID
    let revision: UInt64
}

struct LaunchAgentReloadGate: Sendable, Equatable {
    private(set) var current: LaunchAgentReloadIdentity?

    mutating func begin(_ identity: LaunchAgentReloadIdentity) { current = identity }
    mutating func invalidate() { current = nil }

    mutating func finishIfCurrent(
        _ identity: LaunchAgentReloadIdentity,
        taskWasCancelled: Bool
    ) -> Bool? {
        guard current == identity else { return nil }
        current = nil
        return !taskWasCancelled
    }
}

enum LaunchAgentMetricProjection {
    static func isComplete(issues: [LaunchAgentScanIssue]) -> Bool { issues.isEmpty }
}

/// v1.2 P1-7 启动项查看屏。
///
/// 与 [AppFootprintScreen.swift](AppFootprintScreen.swift) 同源约定：
/// - 这是「**查看**」入口，**不带删除按钮**；右键菜单仅 "在 Finder 中显示" / "拷贝 Label"。
/// - 没有 trash 调用、没有勾选 set、没有清单提交。
/// - 三段分组按 [LaunchAgentScope] 顺序：user → system → daemon。
public struct LaunchAgentScreen: View {
    private let scanner: LaunchAgentScanner

    @State private var items: [LaunchAgentItem] = []
    @State private var issues: [LaunchAgentScanIssue] = []
    @State private var selected: LaunchAgentItem?
    @State private var isLoading: Bool = false
    @State private var search: String = ""
    @State private var reloadTask: Task<Void, Never>?
    @State private var reloadRevision: UInt64 = 0
    @State private var reloadGate = LaunchAgentReloadGate()
    /// v2026.07.15：只保留扫描事实，所有占位、分组和容量在渲染时按当前 locale 投影。
    @Environment(\.locale) private var locale

    public init(scanner: LaunchAgentScanner? = nil) {
        self.scanner = scanner ?? LaunchAgentScanner()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scanContractNotices
            Divider()
            if isLoading && items.isEmpty {
                placeholder(AppLocalization.string("launchagent.placeholder.scanning", locale: locale), systemImage: "hourglass")
            } else if filtered.isEmpty {
                placeholder(emptyText, systemImage: "tray")
            } else {
                list
            }
            Divider()
            footer
        }
        .onAppear { startReload() }
        .onDisappear { cancelReloadForDeparture() }
    }

    /// v2026.07.18：覆盖范围与不完整证据属于结果合同，不能藏进日志或空状态。
    private var scanContractNotices: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(AppLocalization.string("launchagent.coverage.classic_only", locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Text(AppLocalization.string("launchagent.coverage.open_settings", locale: locale))
                }
                .buttonStyle(.link)
            }
            if !issues.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(AppLocalization.format(
                        "launchagent.issue.partial %lld",
                        locale: locale,
                        arguments: [issues.count]
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.045))
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack {
            Text("launchagent.header.title", bundle: .module).font(.headline)
            if !items.isEmpty {
                Text("· \(items.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField(AppLocalization.string("launchagent.header.search_placeholder", locale: locale), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                startReload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            if !items.isEmpty {
                let total = items.map(\.fileSize).reduce(Int64(0), +)
                Text(AppLocalization.format(
                    LaunchAgentMetricProjection.isComplete(issues: issues)
                        ? "launchagent.footer.total"
                        : "launchagent.footer.partial",
                    locale: locale,
                    arguments: [items.count, byteString(total)]
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("common.read_only_no_delete", bundle: .module)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - List with sectioning

    private var list: some View {
        List(selection: $selected) {
            ForEach(LaunchAgentScope.allCases, id: \.self) { scope in
                let group = filtered.filter { $0.scope == scope }
                if !group.isEmpty {
                    Section(header: sectionHeader(scope: scope, count: group.count)) {
                        ForEach(group) { item in
                            row(item)
                                .tag(item)
                                .contextMenu { contextMenu(for: item) }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func sectionHeader(scope: LaunchAgentScope, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: scopeIcon(scope))
                .foregroundStyle(scopeTint(scope))
            Text(scope.displayName(locale: locale))
                .font(.caption.bold())
            Text("· \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ item: LaunchAgentItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(item.label)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.runAtLoad {
                    Text("launchagent.badge.run_at_load", bundle: .module)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(byteString(item.fileSize))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(item.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !item.programArguments.isEmpty {
                Text(item.programArguments.joined(separator: " "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: LaunchAgentItem) -> some View {
        Button {
            let url = URL(fileURLWithPath: item.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Text("launchagent.menu.reveal_in_finder", bundle: .module)
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.label, forType: .string)
        } label: {
            Text("launchagent.menu.copy_label", bundle: .module)
        }
    }

    // MARK: - Helpers

    private var filtered: [LaunchAgentItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.label.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }

    private var emptyText: String {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            return AppLocalization.string("launchagent.empty.no_match", locale: locale)
        }
        if !issues.isEmpty {
            return AppLocalization.format(
                "launchagent.issue.empty %lld",
                locale: locale,
                arguments: [issues.count]
            )
        }
        return AppLocalization.string("launchagent.empty.no_items", locale: locale)
    }

    private func startReload() {
        reloadTask?.cancel()
        reloadRevision &+= 1
        let identity = LaunchAgentReloadIdentity(
            operationID: UUID(),
            revision: reloadRevision
        )
        reloadGate.begin(identity)
        isLoading = true
        selected = nil
        let scanner = scanner
        reloadTask = Task {
            let result = await scanner.scanAll()
            let taskWasCancelled = Task.isCancelled
            await MainActor.run {
                guard let shouldPublish = reloadGate.finishIfCurrent(
                    identity,
                    taskWasCancelled: taskWasCancelled
                ) else { return }
                reloadTask = nil
                isLoading = false
                guard shouldPublish else { return }
                items = result.items
                issues = result.issues
            }
        }
    }

    private func cancelReloadForDeparture() {
        // Invalidate before signalling cancellation: synchronous plist/metadata IO may return
        // before observing Task.isCancelled, but it still cannot claim the departed page.
        reloadGate.invalidate()
        reloadTask?.cancel()
        reloadTask = nil
        isLoading = false
    }

    @ViewBuilder
    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func byteString(_ b: Int64) -> String {
        AppLocalization.byteCount(b, locale: locale)
    }

    private func scopeIcon(_ s: LaunchAgentScope) -> String {
        switch s {
        case .user:   return "person.crop.circle"
        case .system: return "macwindow"
        case .daemon: return "gearshape.2"
        }
    }

    private func scopeTint(_ s: LaunchAgentScope) -> Color {
        switch s {
        case .user:   return .blue
        case .system: return .purple
        case .daemon: return .orange
        }
    }
}
