import AppKit
import ScanKit
import SwiftUI

struct StorageAnalysisView: View {
    @ObservedObject var store: StorageAnalysisStore
    let probe: SystemProbeStore
    let onClean: () -> Void
    let onBusyChange: (Bool) -> Void
    @StateObject private var trash: StorageAnalysisTrashStore
    @Environment(\.locale) private var locale
    @State private var selectedFile: TreeRow?

    init(
        store: StorageAnalysisStore, probe: SystemProbeStore, pipeline: any DeletionPipeline,
        undoHistoryStore: UndoHistoryStore, onBusyChange: @escaping (Bool) -> Void,
        onClean: @escaping () -> Void
    ) {
        self.store = store
        self.probe = probe
        self.onClean = onClean
        self.onBusyChange = onBusyChange
        _trash = StateObject(
            wrappedValue: StorageAnalysisTrashStore(
                scanner: store.scanner, pipeline: pipeline, undoHistoryStore: undoHistoryStore))
    }

    var body: some View {
        HStack(spacing: 16) {
            directorySidebar
                .frame(width: 238)
            VStack(alignment: .leading, spacing: 12) {
                header.disabled(trash.isBusy)
                breadcrumbBar.disabled(trash.isBusy)
                mapContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .onAppear { store.activate(locale: locale) }
        .onDisappear {
            store.deactivate()
            trash.deactivate()
            onBusyChange(false)
        }
        .onReceive(trash.$isBusy) { onBusyChange($0) }
        .deletionPreflightNoticeOverlay(trash.notice) { trash.notice = nil }
        .localizedSheet(item: $trash.sheet, onDismiss: trash.dismiss) { sheet in
            switch sheet {
            case .review(let review):
                ToolTrashConfirmationSheet(
                    items: review.prepared.confirmationCandidates,
                    totalBytes: review.prepared.plan.intent.candidates.reduce(0) { $0 + $1.bytes },
                    reviewPlan: review.prepared.plan,
                    onCancel: { trash.cancelReview() },
                    onConfirm: { trash.accept(review, plan: $0) })
            case .executing:
                ProgressView { Text("workspace.delete.moving", bundle: .module) }
                    .padding(40).frame(width: 400, height: 160).interactiveDismissDisabled(true)
            case .result(let completion):
                OperationResultSheet(completion: completion) { trash.cancelReview() }
            }
        }
        .onValueChange(of: locale) { _, new in store.activate(locale: new) }
        .onValueChange(of: store.path) { _, _ in selectedFile = nil }
        .onValueChange(of: store.projection?.rows.map(\.path) ?? []) { _, paths in
            if let selectedPath = selectedFile?.path, !paths.contains(selectedPath) {
                selectedFile = nil
            }
        }
        .onValueChange(of: store.phase) { _, phase in
            if phase == .idle || phase == .scanning || phase == .cancelled || phase == .failed {
                selectedFile = nil
                trash.notice = nil
            }
        }
    }

    private var directorySidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            StorageVolumeSummary(probe: probe)
            Divider().opacity(0.6)
            HStack {
                Text(
                    store.projection?.listScope == .smallerItems
                        ? "workspace.storage.smaller.title" : "workspace.storage.folders", bundle: .module)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if store.projection?.listScope == .smallerItems {
                    Button { store.showAllItems() } label: {
                        Text("workspace.storage.smaller.all", bundle: .module)
                    }
                    .font(.caption).buttonStyle(.borderless)
                    .disabled(trash.isBusy)
                    .accessibilityIdentifier("normal.analysis.all-items")
                }
                if store.isProjecting || store.phase == .loadingDirectory {
                    ProgressView().controlSize(.mini)
                }
            }
            TextField(text: $store.query) {
                Text("workspace.storage.search", bundle: .module)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(store.projection == nil || store.directoryAccessState != .normal || trash.isBusy)
            .accessibilityIdentifier("normal.analysis.search")

            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if let projection = store.projection {
                            ForEach(projection.rows) { row in directoryRow(row) }
                            if projection.rows.count < projection.listedCount {
                                Button {
                                    store.showMore()
                                } label: {
                                    Text(
                                        verbatim: AppLocalization.format(
                                            "workspace.storage.more %lld %lld", locale: locale,
                                            arguments: [
                                                Int64(projection.rows.count), Int64(projection.listedCount),
                                            ]))
                                }
                                .buttonStyle(.borderless).font(.caption).padding(.top, 10)
                            }
                        } else {
                            Text("workspace.storage.list.empty", bundle: .module)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        }
                    }
                    .id("directory-list")
                }
                .onValueChange(of: store.projection?.listScope) { _, _ in
                    reader.scrollTo("directory-list", anchor: .top)
                }
            }
            .frame(maxHeight: .infinity)
            Button(action: onClean) {
                Label {
                    Text("workspace.quick_clean", bundle: .module)
                } icon: {
                    Image(systemName: "sparkles")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trash.isBusy)
            .accessibilityIdentifier("normal.quick-clean")
        }
        .padding(16)
        .smartCareTechSurface(tint: SmartCareMotionPalette.blueColor, cornerRadius: 18, elevated: false)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("workspace.storage.title", bundle: .module)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("workspace.storage.subtitle", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    store.scan(.fullDisk)
                } label: {
                    Text("workspace.storage.scope.disk", bundle: .module)
                }
                Button {
                    store.scan(.makeCustom(url: FileManager.default.homeDirectoryForCurrentUser))
                } label: {
                    Text("workspace.storage.scope.home", bundle: .module)
                }
                Button(action: chooseFolder) {
                    Text("workspace.storage.scope.choose", bundle: .module)
                }
            } label: {
                Label {
                    Text("workspace.storage.scope", bundle: .module)
                } icon: {
                    Image(systemName: "folder")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if store.phase == .scanning || store.phase == .loadingDirectory {
                Button {
                    store.cancel()
                } label: {
                    Label {
                        Text("smart_care.action.stop_scan", bundle: .module)
                    } icon: {
                        Image(systemName: "stop.fill")
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    store.scan()
                } label: {
                    Label {
                        Text(
                            store.phase == .idle ? "workspace.storage.scan" : "workspace.storage.rescan",
                            bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("normal.analysis.scan")
            }
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            Button {
                if store.breadcrumbs.count > 1 {
                    store.navigate(to: store.breadcrumbs[store.breadcrumbs.count - 2])
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(store.breadcrumbs.count < 2)
            .accessibilityLabel(Text("workspace.storage.back", bundle: .module))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.breadcrumbs, id: \.self) { path in
                        Button {
                            store.navigate(to: path)
                        } label: {
                            if path == "/" {
                                Text("workspace.storage.scope.disk", bundle: .module)
                            } else {
                                Text(verbatim: URL(fileURLWithPath: path).lastPathComponent)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(path == store.path ? .primary : .secondary)
                        if path != store.path { Image(systemName: "chevron.right").font(.caption2) }
                    }
                    if store.breadcrumbs.isEmpty {
                        Text("workspace.storage.scope.disk", bundle: .module).foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
            if let projection = store.projection, store.directoryAccessState == .normal {
                Text(verbatim: AppLocalization.byteCount(projection.measuredBytes, locale: locale))
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var mapContent: some View {
        switch store.phase {
        case .idle:
            emptyState(
                icon: "internaldrive", title: "workspace.storage.empty.title",
                detail: "workspace.storage.empty.detail", action: true)
        case .scanning:
            VStack(spacing: 22) {
                ProgressView().controlSize(.large)
                Text("workspace.storage.scanning", bundle: .module).font(.title3.weight(.semibold))
                StorageAnalysisProgress(progress: store.scanner.liveProgress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .smartCareTechSurface(tint: SmartCareMotionPalette.blueColor, cornerRadius: 18, elevated: false)
        case .cancelled:
            emptyState(
                icon: "pause.circle", title: "workspace.storage.cancelled.title",
                detail: "workspace.storage.cancelled.detail", action: true)
        case .failed:
            emptyState(
                icon: "exclamationmark.triangle", title: "workspace.storage.failed.title",
                detail: "workspace.storage.failed.detail", action: true)
        case .ready, .loadingDirectory:
            // v2026.10.07 C4: an unread root has no child rows, just like an empty root. Show
            // its typed access evidence before choosing any empty/zero-allocation presentation.
            if let access = StorageDirectoryAccessPresentation(state: store.directoryAccessState) {
                emptyState(icon: "lock", title: access.titleKey, detail: access.detailKey, action: false)
            } else if let projection = store.projection, !projection.mapItems.isEmpty {
                VStack(spacing: 8) {
                    if projection.incompleteCount > 0 || projection.pendingCount > 0
                        || store.phase == .loadingDirectory
                    {
                        Label {
                            Text(
                                store.phase == .loadingDirectory
                                    ? "workspace.storage.measuring" : "workspace.storage.partial",
                                bundle: .module)
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    StorageTreemapCanvas(
                        presentation: projection.mapPresentation,
                        isBusy: trash.isBusy || store.isProjecting,
                        onViewportChange: store.updateMapViewport,
                        onActivate: activate,
                        onShowSmallerItems: store.showSmallerItems,
                        fileActions: { fileActions($0) })
                }
            } else if store.isProjecting || store.phase == .loadingDirectory {
                ProgressView { Text("workspace.storage.measuring", bundle: .module) }
            } else {
                emptyState(
                    icon: "folder", title: "workspace.storage.no_measured.title",
                    detail: "workspace.storage.no_measured.detail", action: false)
            }
        }
    }

    private func directoryRow(_ row: TreeRow) -> some View {
        let canTrash = !(trash.isBusy || store.isProjecting || store.phase != .ready
            || !row.hasCompleteAccessEvidence || row.isSizePending)
        return HStack(spacing: 8) {
            Button {
                activate(row)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: row.accessState == .normal ? (row.isDirectory ? "folder" : "doc") : "lock")
                        .foregroundStyle(
                            NormalWorkspacePalette.color(StorageDirectoryProjection.colorIndex(for: row.path)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: row.displayTitle(locale: locale)).font(.callout.weight(.medium)).lineLimit(
                            1)
                        Text(
                            verbatim: row.isSizePending
                                ? AppLocalization.string("workspace.storage.pending", locale: locale)
                                : AppLocalization.byteCount(row.bytes, locale: locale)
                        )
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if !row.hasCompleteAccessEvidence {
                            Text("workspace.storage.partial.short", bundle: .module)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if row.isDirectory, row.accessState == .normal {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(trash.isBusy)

            Button {
                trash.prepare(row, snapshotIdentity: store.projectionIdentity)
            } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(canTrash ? Color.red.opacity(0.85) : Color.secondary.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canTrash)
            .help(Text("delete.action.confirm", bundle: .module))
        }
        .padding(.horizontal, 9).padding(.vertical, 10)
        .background(
            Color.primary.opacity(selectedFile?.path == row.path ? 0.08 : 0.025),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contextMenu { fileActions(row) }
    }

    @ViewBuilder private func fileActions(_ row: TreeRow) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
        } label: {
            Text("workspace.storage.finder", bundle: .module)
        }
        if row.isDirectory, row.accessState == .normal, !row.isSizePending {
            Button {
                store.open(row)
            } label: {
                Text("workspace.storage.open", bundle: .module)
            }
        }
        Divider()
        Button(role: .destructive) {
            trash.prepare(row, snapshotIdentity: store.projectionIdentity)
        } label: {
            Text("delete.action.confirm", bundle: .module)
        }
        .disabled(
            trash.isBusy || store.isProjecting || store.phase != .ready
                || !row.hasCompleteAccessEvidence || row.isSizePending)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(SmartCareMotionPalette.tealColor)
            if let selectedFile {
                Text(verbatim: selectedFile.displayTitle(locale: locale)).lineLimit(1)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedFile.path)])
                } label: {
                    Text("workspace.storage.finder", bundle: .module)
                }
                .buttonStyle(.borderless)
            } else {
                Text("workspace.storage.map_hint", bundle: .module).foregroundStyle(.secondary)
                Spacer()
            }
        }.font(.caption).frame(minHeight: 24)
    }

    private func activate(_ row: TreeRow) {
        if row.isDirectory, row.accessState == .normal, !row.isSizePending {
            store.open(row)
        } else {
            selectedFile = row
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        onBusyChange(true)
        panel.begin { response in
            onBusyChange(trash.isBusy)
            if response == .OK, let url = panel.url { store.scan(.makeCustom(url: url)) }
        }
    }

    private func emptyState(icon: String, title: String, detail: String, action: Bool) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(
                    LinearGradient(
                        colors: [SmartCareMotionPalette.blueColor, SmartCareMotionPalette.tealColor],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 120, height: 120)
                .background(Color.accentColor.opacity(0.045), in: Circle())
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1))
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Text(LocalizedStringKey(detail), bundle: .module)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if action {
                Button {
                    store.scan()
                } label: {
                    Label {
                        Text("workspace.storage.scan", bundle: .module)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .smartCareTechSurface(tint: SmartCareMotionPalette.tealColor, cornerRadius: 18, elevated: false)
    }
}

private struct StorageAnalysisProgress: View {
    @ObservedObject var progress: ScanLiveProgressStore
    @Environment(\.locale) private var locale
    var body: some View {
        Text(
            verbatim: AppLocalization.format(
                "workspace.storage.progress %lld %@", locale: locale,
                arguments: [
                    Int64(progress.frame.scannedFileCount),
                    AppLocalization.byteCount(progress.frame.totalBytes, locale: locale),
                ])
        )
        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
    }
}

private struct StorageVolumeSummary: View {
    @ObservedObject var probe: SystemProbeStore
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(
                        RadialGradient(
                            colors: [
                                SmartCareMotionPalette.tealColor.opacity(0.22),
                                Color.accentColor.opacity(0.04),
                            ],
                            center: .topLeading, startRadius: 2, endRadius: 92))
                    Circle().strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
                    Image(systemName: "internaldrive.fill").font(.system(size: 24, weight: .light))
                        .foregroundStyle(SmartCareMotionPalette.blueColor)
                }.frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        verbatim: probe.volumeSnapshot?.volumeName
                            ?? AppLocalization.string("workspace.storage.scope.disk", locale: locale)
                    )
                    .font(.system(.caption, design: .rounded).weight(.semibold)).lineLimit(1)
                    if let snapshot = probe.volumeSnapshot {
                        Text(verbatim: AppLocalization.byteCount(snapshot.totalBytes, locale: locale))
                            .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
            }
            if let snapshot = probe.volumeSnapshot {
                ProgressView(value: Double(snapshot.usedBytes), total: Double(max(1, snapshot.totalBytes)))
                    .tint(SmartCareMotionPalette.tealColor)
                Text(
                    verbatim: AppLocalization.format(
                        "workspace.storage.used %@", locale: locale,
                        arguments: [AppLocalization.byteCount(snapshot.usedBytes, locale: locale)])
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("workspace.metric.unavailable", bundle: .module).font(.caption).foregroundStyle(
                    .secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
