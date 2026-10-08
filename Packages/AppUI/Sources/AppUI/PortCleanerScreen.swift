import SwiftUI

/// v2026.07.15：端口终止确认只保存标题语义或进程原名；结果只保存计数。
/// confirmationDialog/alert 存续期间切换语言时，由当前 View locale 重新投影。
enum PortCleanerKillTitle: Equatable, Sendable {
    case processName(String)
    case selected

    func text(locale: Locale) -> String {
        switch self {
        case .processName(let value): return value
        case .selected:
            return AppLocalization.string("port_cleaner.button.kill_selected", locale: locale)
        }
    }
}

struct PortCleanerKillResultPresentation: Equatable, Sendable {
    let confirmedStopped: Int
    let requestPending: Int
    let notSubmitted: Int
    let failed: Int

    func text(locale: Locale) -> String {
        AppLocalization.format(
            "port_cleaner.kill.result_with_not_submitted",
            locale: locale,
            arguments: [
                Int64(confirmedStopped),
                Int64(requestPending),
                Int64(notSubmitted),
                Int64(failed)
            ]
        )
    }
}

/// v2026.07.16: one revision-owned reload state machine shared by the screen and tests.
/// A failure preserves the last successful entries; cancellation or a late older revision can
/// never clear/replace them. The model stores only typed failure semantics, never raw stderr.
@MainActor
final class PortCleanerReloadModel: ObservableObject {
    typealias Loader = @Sendable () async -> PortCleanerScanOutcome

    @Published private(set) var entries: [PortCleanerEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var failure: PortCleanerScanFailure?

    private let loader: Loader
    private var revision: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func reload() {
        revision &+= 1
        let ownedRevision = revision
        loadTask?.cancel()
        failure = nil
        isLoading = true
        let loader = self.loader
        loadTask = Task { [weak self] in
            let outcome = await loader()
            guard let self,
                  !Task.isCancelled,
                  self.revision == ownedRevision else { return }
            switch outcome {
            case .success(let entries):
                self.entries = entries
                self.failure = nil
            case .failure(let failure):
                self.failure = failure
            case .cancelled:
                break
            }
            self.isLoading = false
            self.loadTask = nil
        }
    }

    func cancel() {
        revision &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    deinit {
        loadTask?.cancel()
    }
}

public struct PortCleanerScreen: View {
    private enum ViewMode: String, CaseIterable, Identifiable {
        case flat
        case grouped

        var id: String { rawValue }
    }

    private struct PendingKill: Equatable {
        let title: PortCleanerKillTitle
        /// v2026.07.16：确认弹窗冻结完整进程身份，不能在用户点击确认后再按 PID 重新
        /// 猜测目标；执行层会用该快照重验 PID reuse、UID、路径和启动时间。
        let identities: [PortCleanerProcessIdentity]
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
        /// v2026.07.18：透明占位只负责列宽，必须冻结高度。`Color.clear` 若只约束宽度，
        /// 会在纵向可伸缩的表头里吞掉 ScrollView 的剩余高度，把列名与首行拉开数百点。
        static let columnPlaceholderHeight: CGFloat = 1
    }

    private let scanner: PortCleanerScanner

    @StateObject private var reloadModel: PortCleanerReloadModel
    @State private var query = ""
    @State private var viewMode: ViewMode = .grouped
    @State private var selectedIDs: Set<String> = []
    @State private var expandedGroups: Set<String> = []
    @State private var isKilling = false
    @State private var pendingKill: PendingKill?
    @State private var showKillConfirm = false
    @State private var resultPresentation: PortCleanerKillResultPresentation?
    @Environment(\.locale) private var locale

    public init(scanner: PortCleanerScanner = PortCleanerScanner()) {
        self.scanner = scanner
        _reloadModel = StateObject(wrappedValue: PortCleanerReloadModel {
            await scanner.listPorts()
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
        .onValueChange(of: reloadModel.entries) { _, latest in
            selectedIDs.formIntersection(Set(latest.filter(\.canRequestTermination).map(\.id)))
            if expandedGroups.isEmpty {
                expandedGroups = Set(PortCleanerGroup.groups(from: latest).prefix(5).map(\.id))
            }
        }
        .onDisappear {
            reloadModel.cancel()
        }
        .confirmationDialog(
            pendingKill?.title.text(locale: locale)
                ?? AppLocalization.string("port_cleaner.confirm.title", locale: locale),
            isPresented: $showKillConfirm,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("port_cleaner.button.kill", locale: locale), role: .destructive) {
                let request = pendingKill
                pendingKill = nil
                Task { await performKill(request) }
            }
            Button(AppLocalization.string("common.button.cancel", locale: locale), role: .cancel) {
                pendingKill = nil
            }
        } message: {
            let count = pendingKill?.identities.count ?? 0
            Text(AppLocalization.format(
                "port_cleaner.confirm.message",
                locale: locale,
                arguments: [Int64(count)]
            ))
        }
        .alert(AppLocalization.string("port_cleaner.result.title", locale: locale),
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
                TextField(AppLocalization.string("port_cleaner.search.placeholder", locale: locale), text: $query)
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
                Text(AppLocalization.format(
                    "port_cleaner.summary",
                    locale: locale,
                    arguments: [
                        Int64(filteredEntries.count),
                        Int64(groupedEntries.count),
                        Int64(Set(filteredEntries.map(\.pid)).count)
                    ]
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    requestKillSelected()
                } label: {
                    Label(AppLocalization.string("port_cleaner.button.kill_selected", locale: locale),
                          systemImage: "xmark.octagon")
                }
                .disabled(selectedFilteredEntries.isEmpty || isKilling)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    private func scanFailureBanner(_ failure: PortCleanerScanFailure) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(verbatim: failure.message(locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(AppLocalization.string("port_cleaner.scan.retry", locale: locale)) {
                startReload()
            }
            .controlSize(.small)
            .disabled(isLoading || isKilling)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.08))
    }

    private func scanFailurePlaceholder(_ failure: PortCleanerScanFailure) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("port_cleaner.scan.error.title", bundle: .module)
                .font(.headline)
            Text(verbatim: failure.message(locale: locale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(AppLocalization.string("port_cleaner.scan.retry", locale: locale)) {
                startReload()
            }
            .disabled(isLoading || isKilling)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var tableHeader: some View {
        HStack(spacing: TableMetrics.columnSpacing) {
            Color.clear
                .frame(width: TableMetrics.disclosureWidth,
                       height: TableMetrics.columnPlaceholderHeight)
            Color.clear
                .frame(width: TableMetrics.checkboxWidth,
                       height: TableMetrics.columnPlaceholderHeight)
            Color.clear
                .frame(width: TableMetrics.iconWidth,
                       height: TableMetrics.columnPlaceholderHeight)
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
                .frame(width: TableMetrics.checkboxWidth,
                       height: TableMetrics.columnPlaceholderHeight)

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

            Text(AppLocalization.format(
                "port_cleaner.group.summary",
                locale: locale,
                arguments: [Int64(group.portCount), Int64(group.pids.count)]
            ))
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
                requestKill(title: .processName(group.title), entries: group.entries)
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
                .frame(width: TableMetrics.disclosureWidth,
                       height: TableMetrics.columnPlaceholderHeight)
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
                requestKill(title: .processName(entry.processName), entries: [entry])
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
        let selectedVisible = selectedFilteredEntries
        return HStack {
            if !selectedVisible.isEmpty {
                Text(AppLocalization.format(
                    "port_cleaner.footer.selected",
                    locale: locale,
                    arguments: [Int64(selectedVisible.count)]
                ))
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

    private var selectedFilteredEntries: [PortCleanerEntry] {
        filteredEntries.filter { selectedIDs.contains($0.id) && $0.canRequestTermination }
    }

    private var groupedEntries: [PortCleanerGroup] {
        PortCleanerGroup.groups(from: filteredEntries)
    }

    private var entries: [PortCleanerEntry] { reloadModel.entries }
    private var isLoading: Bool { reloadModel.isLoading }

    private func startReload() {
        reloadModel.reload()
    }

    private func requestKill(title: PortCleanerKillTitle, entries: [PortCleanerEntry]) {
        let identities = Array(Set(
            entries
                .filter(\.canRequestTermination)
                .compactMap(\.processIdentity)
        )).sorted { $0.pid < $1.pid }
        guard !identities.isEmpty else { return }
        pendingKill = PendingKill(title: title, identities: identities)
        showKillConfirm = true
    }

    private func requestKillSelected() {
        requestKill(
            title: .selected,
            entries: selectedFilteredEntries
        )
    }

    @MainActor
    private func performKill(_ request: PendingKill?) async {
        guard let request else { return }
        isKilling = true
        let results = await scanner.kill(identities: request.identities)
        let confirmedStopped = results.filter(\.success).count
        let requestPending = results.filter(\.requestPending).count
        let notSubmitted = results.filter(\.notSubmitted).count
        let failed = results.count - confirmedStopped - requestPending - notSubmitted
        // v2026.07.16：结果必须区分“已确认退出”和“SIGTERM 已提交但仍在运行”，避免
        // kill(2) 返回 0 后把尚未退出的进程误报为成功结束。
        resultPresentation = PortCleanerKillResultPresentation(
            confirmedStopped: confirmedStopped,
            requestPending: requestPending,
            notSubmitted: notSubmitted,
            failed: failed
        )
        selectedIDs.removeAll()
        isKilling = false
        startReload()
    }
}
