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
    @State private var isLoading: Bool = false
    @State private var progressDone: Int = 0
    @State private var progressTotal: Int = 0
    @State private var search: String = ""

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
        HSplitView {
            leftPane
                .frame(minWidth: 360, idealWidth: 460)
            rightPane
                .frame(minWidth: 320)
        }
        .navigationTitle("应用占用排行榜")
        .task { await reload() }
    }

    // MARK: - 左栏：排行榜

    private var leftPane: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading && items.isEmpty {
                placeholder("正在统计…", systemImage: "hourglass")
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
            Text("已安装应用").font(.headline)
            if !items.isEmpty {
                Text("· \(items.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("搜索 App / bundle id", text: $search)
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
        let maxBytes = max(1, items.first?.totalBytes ?? 1)
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
                    Text(byteString(item.totalBytes))
                        .font(.callout.monospacedDigit())
                    Text("Bundle \(byteString(item.appBundleBytes)) · 数据 \(byteString(item.relatedBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ratioBar(ratio: ratio)
        }
        .padding(.vertical, 4)
    }

    private func ratioBar(ratio: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, ratio)))))
            }
        }
        .frame(height: 4)
    }

    private var footer: some View {
        HStack {
            if isLoading && progressTotal > 0 {
                Text("正在统计 \(progressDone) / \(progressTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !items.isEmpty {
                Text("总计 \(byteString(items.map(\.totalBytes).reduce(0, +)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("只读视图，不会删除任何文件")
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
                detailHeader(item)
                Divider()
                detailList(item)
            } else {
                placeholder("从左侧选择一个应用查看占用细节", systemImage: "sidebar.right")
            }
        }
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
                Text("总占用 \(byteString(item.totalBytes)) · \(item.buckets.count) 项")
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
                        Button("在 Finder 中显示") { revealInFinder(path: b.path) }
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
            Text("\(bucketLabel(b.kind)) · \(b.fileCount) 文件")
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

    private var emptyText: String {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return "没有匹配的应用" }
        return "没有发现任何应用"
    }

    private func reload() async {
        isLoading = true
        progressDone = 0
        progressTotal = 0
        items = []
        selected = nil
        let installed = await store.listInstalledApps()
        apps = installed
        progressTotal = installed.count
        let result = await scanner.scanAll(apps: installed) { done, total in
            Task { @MainActor in
                progressDone = done
                progressTotal = total
            }
        }
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
        case .bundle:      return "App Bundle"
        case .userData:    return "用户数据"
        case .launchAgent: return "启动项 / 厂商共享"
        case .vendorRule:  return "厂商规则"
        }
    }

    @ViewBuilder
    private func contextMenu(for item: AppFootprintItem) -> some View {
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.appURL])
        }
        Button("拷贝 Bundle ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.bundleID, forType: .string)
        }
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
