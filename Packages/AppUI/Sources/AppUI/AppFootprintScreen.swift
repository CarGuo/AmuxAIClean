import SwiftUI
import AppKit
import SafetyKit

/// v1.2 P1-6 应用占用排行榜屏。
///
/// 与 [UninstallScreen.swift](UninstallScreen.swift) 的关系：
/// - UninstallScreen 是「**清理**」入口（带 SafetyEngine 默认勾选 + dryRun + 二次确认）
/// - 本屏是「**查看**」入口（只展示哪些 app 在你磁盘上吃了多少空间，**不带删除按钮**）
///
/// 不破坏既有任何安全契约：
/// - 没有 trash 调用、没有勾选 set、没有清单提交
/// - 右键菜单仅 "在 Finder 中显示"（NSWorkspace.activateFileViewerSelecting，无写入操作）
public struct AppFootprintScreen: View {
    private let store: UninstallStore
    private let scanner: AppFootprintScanner

    @State private var apps: [InstalledApp] = []
    @State private var items: [AppFootprintItem] = []
    @State private var selected: AppFootprintItem?
    @State private var pendingIDs: Set<String> = []
    @State private var isLoading: Bool = false
    @State private var progressDone: Int = 0
    @State private var progressTotal: Int = 0
    @State private var search: String = ""
    @State private var streamTask: Task<Void, Never>? = nil

    public init(
        store: UninstallStore? = nil,
        scanner: AppFootprintScanner? = nil,
        vendors: [VendorRule] = []
    ) {
        let unins = AppUninstaller(vendorRules: vendors)
        self.store = store ?? UninstallStore(uninstaller: unins)
        self.scanner = scanner ?? AppFootprintScanner(uninstaller: unins)
    }

    public var body: some View {
        // v1.3.zz UI 修复：原本用 HSplitView + leftPane/rightPane 各 minWidth=360/320，
        // 嵌进 MainView NavigationSplitView 的 content 列（min:420 ideal:520）后，
        // 内层 minWidth 之和 680 > 外层 ideal 520，把外层 sidebar 都挤掉了一半。
        // 改成普通 HStack：左列表自适应、右详情固定占比。窄屏下整个 NavigationSplitView
        // 仍能正常约束，不会再撑破 sidebar。也去掉 navigationTitle，避免覆盖主窗"GSY 清理管家"。
        HStack(spacing: 0) {
            leftPane
                .frame(minWidth: 240, idealWidth: 320)
                .layoutPriority(1)
            Divider()
            rightPane
                .frame(minWidth: 220)
                .layoutPriority(1)
        }
        .task { await reload() }
        // v2：套布局沙箱——「应用占用排行榜」内 leftPane 表格 + rightPane 分项
        // 都有大量长 bundleID / 应用路径，禁止 ideal width 反推外层。
        .layoutSandbox()
    }

    // MARK: - 左栏：排行榜

    private var leftPane: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading && items.isEmpty {
                placeholder(String(localized: "appfootprint.placeholder.loading", bundle: .module), systemImage: "hourglass")
            } else if filtered.isEmpty {
                placeholder(emptyText, systemImage: "tray")
            } else {
                table
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("appfootprint.header.title", bundle: .module).font(.headline)
            if !items.isEmpty {
                Text("· \(items.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField(String(localized: "appfootprint.header.search_placeholder", bundle: .module), text: $search)
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

    private var table: some View {
        let maxBytes = max(1, items.map(\.totalBytes).max() ?? 1)
        return List(selection: $selected) {
            ForEach(filtered) { item in
                row(item, maxBytes: maxBytes)
                    .tag(item)
                    .contextMenu { contextMenu(for: item) }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func row(_ item: AppFootprintItem, maxBytes: Int64) -> some View {
        let isPending = pendingIDs.contains(item.id)
        let ratio = Double(item.totalBytes) / Double(maxBytes)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                appIcon(for: item.appURL)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.appName)
                        .font(.system(.body, design: .rounded))
                        .lineLimit(1)
                    Text(item.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if isPending {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("appfootprint.row.computing", bundle: .module)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(byteString(item.totalBytes))
                            .font(.callout.monospacedDigit())
                        Text(String(format: String(localized: "appfootprint.row.bundle_data", bundle: .module), byteString(item.appBundleBytes), byteString(item.relatedBytes)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ratioBar(ratio: ratio, isPending: isPending)
        }
        .padding(.vertical, 4)
    }

    private func ratioBar(ratio: Double, isPending: Bool = false) -> some View {
        let clamped = min(1, max(0, ratio))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                if !isPending && clamped > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: max(2, geo.size.width * CGFloat(clamped)))
                }
            }
        }
        .frame(height: 4)
    }

    private var footer: some View {
        HStack {
            if isLoading && progressTotal > 0 {
                Text(String(format: String(localized: "appfootprint.footer.progress", bundle: .module), progressDone, progressTotal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !items.isEmpty {
                Text(String(format: String(localized: "appfootprint.footer.total", bundle: .module), byteString(loadedItems.map(\.totalBytes).reduce(0, +))))
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

    // MARK: - 右栏：详情

    private var rightPane: some View {
        VStack(spacing: 0) {
            if let item = selected {
                if pendingIDs.contains(item.id) {
                    pendingDetail(item)
                } else {
                    detailHeader(item)
                    Divider()
                    detailList(item)
                }
            } else {
                placeholder(String(localized: "appfootprint.placeholder.select_app", bundle: .module), systemImage: "sidebar.right")
            }
        }
    }

    private func pendingDetail(_ item: AppFootprintItem) -> some View {
        VStack(spacing: 12) {
            appIcon(for: item.appURL)
                .frame(width: 42, height: 42)
            Text(item.appName)
                .font(.title3)
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("appfootprint.row.computing", bundle: .module)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailHeader(_ item: AppFootprintItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            appIcon(for: item.appURL)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.appName).font(.title3)
                Text(item.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(format: String(localized: "appfootprint.detail.total_buckets", bundle: .module), byteString(item.totalBytes), item.buckets.count))
                    .font(.callout.monospacedDigit())
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func detailList(_ item: AppFootprintItem) -> some View {
        List {
            ForEach(item.buckets) { b in
                bucketRow(b, total: max(1, item.totalBytes))
                    .contextMenu {
                        Button {
                            revealInFinder(path: b.path)
                        } label: {
                            Text("appfootprint.menu.reveal_in_finder", bundle: .module)
                        }
                    }
            }
        }
        .listStyle(.inset)
    }

    private func bucketRow(_ b: AppFootprintBucket, total: Int64) -> some View {
        let ratio = Double(b.bytes) / Double(total)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: bucketIcon(b.kind))
                    .foregroundStyle(bucketTint(b.kind))
                    .frame(width: 16)
                Text(b.path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Text(byteString(b.bytes))
                    .font(.callout.monospacedDigit())
            }
            ratioBar(ratio: ratio)
            Text(String(format: String(localized: "appfootprint.bucket.kind_count", bundle: .module), bucketLabel(b.kind), b.fileCount))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    private var filtered: [AppFootprintItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.appName.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
    }

    private var loadedItems: [AppFootprintItem] {
        items.filter { !pendingIDs.contains($0.id) }
    }

    private var emptyText: String {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "appfootprint.empty.no_match", bundle: .module)
        }
        return String(localized: "appfootprint.empty.no_apps", bundle: .module)
    }

    private func reload() async {
        // 取消上一次的流式扫描（如果还在跑），避免两批 item 互相覆盖。
        streamTask?.cancel()
        streamTask = nil

        isLoading = true
        progressDone = 0
        progressTotal = 0
        items = []
        selected = nil
        pendingIDs = []
        let installed = await store.listInstalledApps()
        apps = installed
        progressTotal = installed.count
        pendingIDs = Set(installed.map(\.id))
        items = installed.map(placeholderItem(for:))
        selected = items.first

        // docs/AUDIT_2026_06.md §4.1 P3 两阶段加载：
        // 第 1 阶段 = 先显示 /Applications 一层应用清单（每行"统计中"），避免首个大 app
        // 的 bundle snapshot 把页面长时间卡在空态。
        // 第 2 阶段 = stream 边算边替换对应 item + 倒序重排；不额外放大底层 IO 并发。
        let stream = scanner.scanAllStream(apps: installed)
        streamTask = Task { @MainActor in
            for await item in stream {
                if Task.isCancelled { break }
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                } else {
                    items.append(item)
                }
                pendingIDs.remove(item.id)
                sortItemsForDisplay()
                if selected?.id == item.id {
                    selected = item
                }
                progressDone += 1
            }
            // 仅当未被取消时才置 isLoading=false——否则 reload() 二次触发会把
            // 新一轮的 isLoading 立刻误清零。
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    private func placeholderItem(for app: InstalledApp) -> AppFootprintItem {
        AppFootprintItem(
            bundleID: app.metadata.bundleID,
            appName: app.metadata.appName,
            appURL: app.appURL,
            appBundleBytes: 0,
            relatedBytes: 0,
            buckets: [
                AppFootprintBucket(
                    path: app.appURL.path,
                    bytes: 0,
                    fileCount: 0,
                    kind: .bundle
                )
            ]
        )
    }

    private func sortItemsForDisplay() {
        items.sort { lhs, rhs in
            let lhsPending = pendingIDs.contains(lhs.id)
            let rhsPending = pendingIDs.contains(rhs.id)
            if lhsPending != rhsPending {
                return !lhsPending
            }
            if lhs.totalBytes != rhs.totalBytes {
                return lhs.totalBytes > rhs.totalBytes
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
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

    private func appIcon(for url: URL) -> some View {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return Image(nsImage: icon)
            .resizable()
            .interpolation(.medium)
    }

    private func byteString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func bucketIcon(_ k: AppFootprintBucket.Kind) -> String {
        switch k {
        case .bundle:      return "app.fill"
        case .userData:    return "folder"
        case .launchAgent: return "play.square"
        case .vendorRule:  return "building.2"
        }
    }

    private func bucketTint(_ k: AppFootprintBucket.Kind) -> Color {
        switch k {
        case .bundle:      return .accentColor
        case .userData:    return .blue
        case .launchAgent: return .orange
        case .vendorRule:  return .purple
        }
    }

    private func bucketLabel(_ k: AppFootprintBucket.Kind) -> String {
        switch k {
        case .bundle:      return String(localized: "appfootprint.bucket.bundle", bundle: .module)
        case .userData:    return String(localized: "appfootprint.bucket.user_data", bundle: .module)
        case .launchAgent: return String(localized: "appfootprint.bucket.launch_agent", bundle: .module)
        case .vendorRule:  return String(localized: "appfootprint.bucket.vendor_rule", bundle: .module)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: AppFootprintItem) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([item.appURL])
        } label: {
            Text("appfootprint.menu.reveal_in_finder", bundle: .module)
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.bundleID, forType: .string)
        } label: {
            Text("appfootprint.menu.copy_bundle_id", bundle: .module)
        }
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
