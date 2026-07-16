import SwiftUI
import AppKit

/// v1.2 P1-7 启动项查看屏。
///
/// 与 [AppFootprintScreen.swift](AppFootprintScreen.swift) 同源约定：
/// - 这是「**查看**」入口，**不带删除按钮**；右键菜单仅 "在 Finder 中显示" / "拷贝 Label"。
/// - 没有 trash 调用、没有勾选 set、没有清单提交。
/// - 三段分组按 [LaunchAgentScope] 顺序：user → system → daemon。
public struct LaunchAgentScreen: View {
    private let scanner: LaunchAgentScanner

    @State private var items: [LaunchAgentItem] = []
    @State private var selected: LaunchAgentItem?
    @State private var isLoading: Bool = false
    @State private var search: String = ""
    /// v2026.07.15：只保留扫描事实，所有占位、分组和容量在渲染时按当前 locale 投影。
    @Environment(\.locale) private var locale

    public init(scanner: LaunchAgentScanner? = nil) {
        self.scanner = scanner ?? LaunchAgentScanner()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
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
        .task { await reload() }
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
                Task { await reload() }
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
                    "launchagent.footer.total",
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
        return AppLocalization.string("launchagent.empty.no_items", locale: locale)
    }

    private func reload() async {
        isLoading = true
        selected = nil
        let result = await scanner.scanAll()
        items = result
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
        b.formatted(.byteCount(style: .file).locale(locale))
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
