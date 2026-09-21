import SwiftUI
import AppKit

typealias DartRadarReloadModel = SnapshotRefreshModel<DartProcessEntry, ProcessSnapshotFailure>

public struct DartRadarScreen: View {
    private struct PendingKill: Equatable {
        let identities: [ProcessIdentity]
        let summary: String
    }

    private enum Metrics {
        static let cardPadding: CGFloat = 12
        static let columnSpacing: CGFloat = 12
        static let resourceWidth: CGFloat = 140
        static let pidWidth: CGFloat = 70
        static let actionWidth: CGFloat = 36
        static let autoRefreshInterval: UInt64 = 3
    }

    private let scanner: DartRadarScanner

    @StateObject private var reloadModel: DartRadarReloadModel
    @State private var query = ""
    @State private var selectedIDs: Set<String> = []
    @State private var collapsedGroups: Set<String> = []
    @State private var autoRefresh = true
    @State private var isKilling = false
    @State private var pendingKill: PendingKill?
    @State private var showKillConfirm = false
    @State private var resultPresentation: ProcessKillResultSummary?
    @Environment(\.locale) private var locale

    public init(scanner: DartRadarScanner = DartRadarScanner()) {
        self.scanner = scanner
        _reloadModel = StateObject(wrappedValue: DartRadarReloadModel {
            await scanner.scan()
        })
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
        .task(id: autoRefresh) {
            // 自动刷新只在开关开启时循环；离开页面或关闭开关后任务取消，旧结果由
            // revision 版本号拦截，不会覆盖新一轮界面。
            while autoRefresh, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Metrics.autoRefreshInterval * 1_000_000_000)
                if !isKilling { startReload() }
            }
        }
        .onValueChange(of: reloadModel.entries) { _, latest in
            selectedIDs.formIntersection(Set(latest.filter(\.canTerminate).map(\.id)))
            collapseStaleGroups(against: latest)
        }
        .onDisappear { reloadModel.cancel() }
        .confirmationDialog(
            AppLocalization.string("dart_radar.confirm.title", locale: locale),
            isPresented: $showKillConfirm,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("dart_radar.button.kill", locale: locale), role: .destructive) {
                let request = pendingKill
                pendingKill = nil
                Task { await performKill(request) }
            }
            Button(AppLocalization.string("common.button.cancel", locale: locale), role: .cancel) {
                pendingKill = nil
            }
        } message: {
            Text(pendingKill?.summary ?? "")
        }
        .alert(AppLocalization.string("dart_radar.result.title", locale: locale),
               isPresented: Binding(
                get: { resultPresentation != nil },
                set: { if !$0 { resultPresentation = nil } }
               )) {
            Button(AppLocalization.string("common.button.ok", locale: locale)) {
                resultPresentation = nil
            }
        } message: {
            Text(resultPresentation?.text(locale: locale) ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("dart_radar.title", bundle: .module)
                        .font(.headline)
                    Text("dart_radar.subtitle", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: $autoRefresh) {
                    Text("dart_radar.auto_refresh", bundle: .module)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                TextField(AppLocalization.string("dart_radar.search.placeholder", locale: locale),
                          text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
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

            statsStrip

            HStack {
                Button(role: .destructive) {
                    requestKillSelected()
                } label: {
                    Label(AppLocalization.string("dart_radar.button.kill_selected", locale: locale),
                          systemImage: "xmark.octagon")
                }
                .disabled(selectedIDs.isEmpty || isKilling)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statsStrip: some View {
        HStack(spacing: 10) {
            statChip(
                value: String(visibleEntries.count),
                label: AppLocalization.string("dart_radar.stat.processes", locale: locale),
                symbol: "waveform.path.ecg"
            )
            statChip(
                value: String(projectCount),
                label: AppLocalization.string("dart_radar.stat.projects", locale: locale),
                symbol: "folder.fill"
            )
            statChip(
                value: String(format: "%.1f%%", totalCPU),
                label: AppLocalization.string("dart_radar.stat.cpu", locale: locale),
                symbol: "cpu"
            )
            statChip(
                value: AppLocalization.byteCount(totalMemory, locale: locale),
                label: AppLocalization.string("dart_radar.stat.memory", locale: locale),
                symbol: "memorychip"
            )
            Spacer()
        }
    }

    private func statChip(value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.callout.bold().monospacedDigit())
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var content: some View {
        if let failure = reloadModel.failure, entries.isEmpty {
            scanFailurePlaceholder(failure)
        } else {
            VStack(spacing: 0) {
                if let failure = reloadModel.failure {
                    scanFailureBanner(failure)
                }
                contentSnapshot
            }
        }
    }

    @ViewBuilder
    private var contentSnapshot: some View {
        if isLoading && entries.isEmpty {
            placeholder("dart_radar.placeholder.scanning", icon: "radar")
        } else if groups.isEmpty {
            placeholder("dart_radar.placeholder.empty", icon: "checkmark.circle")
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(groups) { group in
                        projectSection(group)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func projectSection(_ group: DartProjectGroup) -> some View {
        VStack(spacing: 0) {
            groupHeader(group)
            if !collapsedGroups.contains(group.id) {
                Divider().padding(.leading, 12)
                VStack(spacing: 6) {
                    ForEach(group.entries) { entry in
                        processRow(entry)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func groupHeader(_ group: DartProjectGroup) -> some View {
        HStack(spacing: 10) {
            Button {
                toggleCollapsed(group.id)
            } label: {
                Image(systemName: collapsedGroups.contains(group.id)
                      ? "chevron.right" : "chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)

            Image(systemName: group.isUnassigned ? "questionmark.folder" : "folder.fill")
                .foregroundStyle(.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(groupTitle(group))
                    .font(.callout.bold())
                    .lineLimit(1)
                if let path = group.path {
                    Text(path)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text(groupSummary(group))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            if let path = group.path {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help(Text("dart_radar.button.reveal_project", bundle: .module))

                Button(role: .destructive) {
                    requestKill(entries: group.entries)
                } label: {
                    Image(systemName: "xmark.octagon")
                }
                .buttonStyle(.borderless)
                .help(Text("dart_radar.button.kill_project", bundle: .module))
                .disabled(isKilling || !group.entries.contains(where: \.canTerminate))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { toggleCollapsed(group.id) }
    }

    private func processRow(_ entry: DartProcessEntry) -> some View {
        HStack(spacing: Metrics.columnSpacing) {
            Toggle("", isOn: Binding(
                get: { selectedIDs.contains(entry.id) },
                set: { checked in
                    if checked, entry.canTerminate {
                        selectedIDs.insert(entry.id)
                    } else {
                        selectedIDs.remove(entry.id)
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!entry.canTerminate || isKilling)

            Image(systemName: entry.role.symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(entry.role.titleKey), bundle: .module)
                    .font(.caption.bold())
                Text(entry.launcher.title(locale: locale))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)

            Text(entry.parentName ?? entry.executablePath)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f%%", entry.cpuPercent))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(entry.cpuPercent >= 50 ? .red : .primary)
                Text(AppLocalization.byteCount(entry.memoryBytes, locale: locale))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: Metrics.resourceWidth, alignment: .trailing)

            Text(String(entry.pid))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Metrics.pidWidth)

            Button(role: .destructive) {
                requestKill(entries: [entry])
            } label: {
                Image(systemName: "xmark.octagon")
            }
            .buttonStyle(.borderless)
            .help(Text("dart_radar.button.kill_one", bundle: .module))
            .disabled(isKilling || !entry.canTerminate)
            .frame(width: Metrics.actionWidth)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
    }

    private var footer: some View {
        HStack {
            if !selectedIDs.isEmpty {
                Text(AppLocalization.format(
                    "dart_radar.footer.selected",
                    locale: locale,
                    arguments: [Int64(selectedIDs.count)]
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("dart_radar.footer.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func scanFailureBanner(_ failure: ProcessSnapshotFailure) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(verbatim: failure.message(locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(AppLocalization.string("dart_radar.scan.retry", locale: locale)) {
                startReload()
            }
            .controlSize(.small)
            .disabled(isLoading || isKilling)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.08))
    }

    private func scanFailurePlaceholder(_ failure: ProcessSnapshotFailure) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("dart_radar.scan.error.title", bundle: .module)
                .font(.headline)
            Text(verbatim: failure.message(locale: locale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(AppLocalization.string("dart_radar.scan.retry", locale: locale)) {
                startReload()
            }
            .disabled(isLoading || isKilling)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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

    private func groupTitle(_ group: DartProjectGroup) -> String {
        group.isUnassigned
            ? AppLocalization.string("dart_radar.group.unassigned", locale: locale)
            : group.title
    }

    private func groupSummary(_ group: DartProjectGroup) -> String {
        let count = AppLocalization.format(
            "dart_radar.group.process_count",
            locale: locale,
            arguments: [Int64(group.entries.count)]
        )
        let cpu = String(format: "%.1f%%", group.cpuTotal)
        let memory = AppLocalization.byteCount(group.memoryTotal, locale: locale)
        return "\(count) · \(cpu) · \(memory)"
    }

    private func toggleCollapsed(_ id: String) {
        if collapsedGroups.contains(id) {
            collapsedGroups.remove(id)
        } else {
            collapsedGroups.insert(id)
        }
    }

    private func collapseStaleGroups(against latest: [DartProcessEntry]) {
        let liveIDs = Set(latest.compactMap(\.projectPath))
        let unassignedExists = latest.contains { $0.projectPath == nil }
        collapsedGroups = collapsedGroups.filter { id in
            if id == DartProjectGrouper.unassignedID { return unassignedExists }
            return liveIDs.contains(id)
        }
    }

    private var visibleEntries: [DartProcessEntry] {
        Array(groups.flatMap(\.entries))
    }

    private var groups: [DartProjectGroup] {
        DartProjectGrouper.groups(from: filteredEntries)
    }

    private var filteredEntries: [DartProcessEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return entries }
        return entries.filter { entry in
            entry.role.titleKey.localizedCaseInsensitiveContains(text)
            || (entry.projectName?.localizedCaseInsensitiveContains(text) ?? false)
            || (entry.projectPath?.localizedCaseInsensitiveContains(text) ?? false)
            || (entry.workingDirectory?.localizedCaseInsensitiveContains(text) ?? false)
            || entry.launcher.title(locale: locale).localizedCaseInsensitiveContains(text)
            || String(entry.pid).contains(text)
            || (entry.parentName?.localizedCaseInsensitiveContains(text) ?? false)
        }
    }

    private var projectCount: Int {
        Set(visibleEntries.compactMap(\.projectPath)).count
    }

    private var totalCPU: Double {
        visibleEntries.reduce(0) { $0 + $1.cpuPercent }
    }

    private var totalMemory: Int64 {
        visibleEntries.reduce(0) { $0 + $1.memoryBytes }
    }

    private var entries: [DartProcessEntry] { reloadModel.entries }
    private var isLoading: Bool { reloadModel.isLoading }

    private func startReload() {
        reloadModel.reload()
    }

    private func requestKillSelected() {
        let selectedEntries = entries.filter { selectedIDs.contains($0.id) && $0.canTerminate }
        requestKill(entries: selectedEntries)
    }

    private func requestKill(entries targetEntries: [DartProcessEntry]) {
        let killable = targetEntries.filter(\.canTerminate)
        let unique = Array(Set(killable.map(\.identity))).sorted { $0.pid < $1.pid }
        guard !unique.isEmpty else { return }
        let projectHint = killable.compactMap(\.projectName).first
            ?? unique.first!.executablePath
        let summary = AppLocalization.format(
            "dart_radar.confirm.message",
            locale: locale,
            arguments: [Int64(unique.count), projectHint]
        )
        pendingKill = PendingKill(identities: unique, summary: summary)
        showKillConfirm = true
    }

    @MainActor
    private func performKill(_ request: PendingKill?) async {
        guard let request else { return }
        isKilling = true
        let results = await scanner.kill(identities: request.identities)
        resultPresentation = ProcessKillResultSummary.summarize(results)
        selectedIDs.removeAll()
        isKilling = false
        startReload()
    }
}
