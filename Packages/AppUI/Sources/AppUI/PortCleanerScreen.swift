import SwiftUI

public struct PortCleanerScreen: View {
    private enum ViewMode: String, CaseIterable, Identifiable {
        case flat
        case grouped

        var id: String { rawValue }
    }

    private struct PendingKill: Equatable {
        let title: String
        let pids: [Int32]
    }

    private enum TableMetrics {
        static let rowHorizontalPadding: CGFloat = 20
        static let rowVerticalPadding: CGFloat = 6
        static let columnSpacing: CGFloat = 10
        static let disclosureWidth: CGFloat = 18
        static let checkboxWidth: CGFloat = 18
        static let iconWidth: CGFloat = 18
        static let localWidth: CGFloat = 170
        static let protoWidth: CGFloat = 62
        static let pidWidth: CGFloat = 70
        static let userWidth: CGFloat = 90
        static let actionWidth: CGFloat = 90
        static let childTextIndent: CGFloat = 14
    }

    private let scanner: PortCleanerScanner

    @State private var entries: [PortCleanerEntry] = []
    @State private var query = ""
    @State private var viewMode: ViewMode = .grouped
    @State private var selectedIDs: Set<String> = []
    @State private var expandedGroups: Set<String> = []
    @State private var isLoading = false
    @State private var isKilling = false
    @State private var loadTask: Task<Void, Never>?
    @State private var pendingKill: PendingKill?
    @State private var showKillConfirm = false
    @State private var resultMessage: String?

    public init(scanner: PortCleanerScanner = PortCleanerScanner()) {
        self.scanner = scanner
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .task { startReload() }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
        .confirmationDialog(
            pendingKill?.title ?? String(localized: "port_cleaner.confirm.title", bundle: .module),
            isPresented: $showKillConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "port_cleaner.button.kill", bundle: .module), role: .destructive) {
                let request = pendingKill
                pendingKill = nil
                Task { await performKill(request) }
            }
            Button(String(localized: "common.button.cancel", bundle: .module), role: .cancel) {
                pendingKill = nil
            }
        } message: {
            let count = pendingKill?.pids.count ?? 0
            Text(String(format: String(localized: "port_cleaner.confirm.message", bundle: .module), count))
        }
        .alert(String(localized: "port_cleaner.result.title", bundle: .module),
               isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
               )) {
            Button(String(localized: "common.button.ok", bundle: .module)) {
                resultMessage = nil
            }
        } message: {
            Text(resultMessage ?? "")
        }
        .layoutSandbox()
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("port_cleaner.title", bundle: .module)
                        .font(.headline)
                    Text("port_cleaner.subtitle", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $viewMode) {
                    Text("port_cleaner.view.flat", bundle: .module).tag(ViewMode.flat)
                    Text("port_cleaner.view.grouped", bundle: .module).tag(ViewMode.grouped)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                TextField(String(localized: "port_cleaner.search.placeholder", bundle: .module), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                if isLoading || isKilling {
                    ProgressView().controlSize(.small)
                }
                Button {
                    startReload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoading || isKilling)
            }

            HStack {
                Text(String(format: String(localized: "port_cleaner.summary", bundle: .module),
                            filteredEntries.count,
                            groupedEntries.count,
                            Set(filteredEntries.map(\.pid)).count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    requestKillSelected()
                } label: {
                    Label(String(localized: "port_cleaner.button.kill_selected", bundle: .module),
                          systemImage: "xmark.octagon")
                }
                .disabled(selectedIDs.isEmpty || isKilling)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && entries.isEmpty {
            placeholder("port_cleaner.placeholder.scanning", icon: "network")
        } else if filteredEntries.isEmpty {
            placeholder("port_cleaner.placeholder.empty", icon: "tray")
        } else {
            VStack(spacing: 0) {
                tableHeader
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewMode == .flat {
                            ForEach(filteredEntries) { entry in
                                entryRow(entry, textIndent: 0, showSelection: true)
                                Divider()
                            }
                        } else {
                            ForEach(groupedEntries) { group in
                                groupRow(group)
                                if expandedGroups.contains(group.id) {
                                    ForEach(group.entries) { entry in
                                        entryRow(entry, textIndent: TableMetrics.childTextIndent, showSelection: true)
                                        Divider()
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, TableMetrics.rowHorizontalPadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: TableMetrics.columnSpacing) {
            Color.clear
                .frame(width: TableMetrics.disclosureWidth)
            Color.clear
                .frame(width: TableMetrics.checkboxWidth)
            Color.clear
                .frame(width: TableMetrics.iconWidth)
            Text("port_cleaner.column.process", bundle: .module)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("port_cleaner.column.local", bundle: .module)
                .frame(width: TableMetrics.localWidth, alignment: .leading)
            Text("port_cleaner.column.proto", bundle: .module)
                .frame(width: TableMetrics.protoWidth, alignment: .leading)
            Text("port_cleaner.column.pid", bundle: .module)
                .frame(width: TableMetrics.pidWidth, alignment: .leading)
            Text("port_cleaner.column.user", bundle: .module)
                .frame(width: TableMetrics.userWidth, alignment: .leading)
            Text("port_cleaner.column.action", bundle: .module)
                .frame(width: TableMetrics.actionWidth, alignment: .trailing)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, TableMetrics.rowHorizontalPadding)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35))
    }

    private func groupRow(_ group: PortCleanerGroup) -> some View {
        HStack(spacing: TableMetrics.columnSpacing) {
            Button {
                if expandedGroups.contains(group.id) {
                    expandedGroups.remove(group.id)
                } else {
                    expandedGroups.insert(group.id)
                }
            } label: {
                Image(systemName: expandedGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: TableMetrics.disclosureWidth, height: 18)
            }
            .buttonStyle(.plain)

            Color.clear
                .frame(width: TableMetrics.checkboxWidth)

            Image(systemName: "app.connected.to.app.below.fill")
                .foregroundStyle(.tint)
                .frame(width: TableMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .lineLimit(1)
                if let path = group.path {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: String(localized: "port_cleaner.group.summary", bundle: .module),
                        group.portCount,
                        group.pids.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: TableMetrics.localWidth, alignment: .leading)
            Text("-")
                .foregroundStyle(.tertiary)
                .frame(width: TableMetrics.protoWidth, alignment: .leading)
            Text(group.pids.map(String.init).joined(separator: ", "))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TableMetrics.pidWidth, alignment: .leading)
            Text(group.user ?? "-")
                .lineLimit(1)
                .frame(width: TableMetrics.userWidth, alignment: .leading)
            Button(role: .destructive) {
                requestKill(title: group.title, entries: group.entries)
            } label: {
                Image(systemName: "xmark.octagon")
            }
            .buttonStyle(.borderless)
            .help(Text("port_cleaner.button.kill_group", bundle: .module))
            .disabled(isKilling || group.terminablePids.isEmpty)
            .frame(width: TableMetrics.actionWidth, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    private func entryRow(_ entry: PortCleanerEntry, textIndent: CGFloat, showSelection: Bool) -> some View {
        HStack(spacing: TableMetrics.columnSpacing) {
            Color.clear
                .frame(width: TableMetrics.disclosureWidth)
            if showSelection {
                Toggle("", isOn: Binding(
                    get: { selectedIDs.contains(entry.id) },
                    set: { checked in
                        if checked, entry.canRequestTermination {
                            selectedIDs.insert(entry.id)
                        } else {
                            selectedIDs.remove(entry.id)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!entry.canRequestTermination || isKilling)
                .frame(width: TableMetrics.checkboxWidth)
            }

            Image(systemName: "network")
                .foregroundStyle(.tint)
                .frame(width: TableMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.processName)
                    .lineLimit(1)
                if let path = entry.processPath, !path.isEmpty {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.leading, textIndent)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.localEndpoint)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: TableMetrics.localWidth, alignment: .leading)
            Text(entry.proto.rawValue)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: TableMetrics.protoWidth, alignment: .leading)
            Text(String(entry.pid))
                .font(.caption.monospacedDigit())
                .frame(width: TableMetrics.pidWidth, alignment: .leading)
            Text(entry.user ?? "-")
                .lineLimit(1)
                .frame(width: TableMetrics.userWidth, alignment: .leading)
            Button(role: .destructive) {
                requestKill(title: entry.processName, entries: [entry])
            } label: {
                Image(systemName: "xmark.octagon")
            }
            .buttonStyle(.borderless)
            .help(Text("port_cleaner.button.kill_one", bundle: .module))
            .disabled(isKilling || !entry.canRequestTermination)
            .frame(width: TableMetrics.actionWidth, alignment: .trailing)
        }
        .padding(.vertical, TableMetrics.rowVerticalPadding)
    }

    private var footer: some View {
        HStack {
            if !selectedIDs.isEmpty {
                Text(String(format: String(localized: "port_cleaner.footer.selected", bundle: .module), selectedIDs.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("port_cleaner.footer.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func placeholder(_ key: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(key, bundle: .module)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEntries: [PortCleanerEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return entries }
        return entries.filter { entry in
            entry.processName.localizedCaseInsensitiveContains(text)
            || entry.localEndpoint.localizedCaseInsensitiveContains(text)
            || entry.remoteEndpoint.localizedCaseInsensitiveContains(text)
            || String(entry.pid).contains(text)
            || (entry.processPath?.localizedCaseInsensitiveContains(text) ?? false)
            || (entry.user?.localizedCaseInsensitiveContains(text) ?? false)
            || (entry.state?.localizedCaseInsensitiveContains(text) ?? false)
        }
    }

    private var groupedEntries: [PortCleanerGroup] {
        PortCleanerGroup.groups(from: filteredEntries)
    }

    private func startReload() {
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            let latest = await scanner.listPorts()
            guard !Task.isCancelled else { return }
            entries = latest
            selectedIDs.formIntersection(Set(latest.filter(\.canRequestTermination).map(\.id)))
            if expandedGroups.isEmpty {
                expandedGroups = Set(PortCleanerGroup.groups(from: latest).prefix(5).map(\.id))
            }
            isLoading = false
        }
    }

    private func requestKill(title: String, entries: [PortCleanerEntry]) {
        let pids = Array(Set(entries.filter(\.canRequestTermination).map(\.pid))).sorted()
        guard !pids.isEmpty else { return }
        pendingKill = PendingKill(title: title, pids: pids)
        showKillConfirm = true
    }

    private func requestKillSelected() {
        let selectedEntries = entries.filter { selectedIDs.contains($0.id) && $0.canRequestTermination }
        requestKill(
            title: String(localized: "port_cleaner.button.kill_selected", bundle: .module),
            entries: selectedEntries
        )
    }

    @MainActor
    private func performKill(_ request: PendingKill?) async {
        guard let request else { return }
        isKilling = true
        let results = await scanner.kill(pids: request.pids)
        let success = results.filter(\.success).count
        let failed = results.count - success
        resultMessage = String(format: String(localized: "port_cleaner.kill.result", bundle: .module), success, failed)
        selectedIDs.removeAll()
        isKilling = false
        startReload()
    }
}
