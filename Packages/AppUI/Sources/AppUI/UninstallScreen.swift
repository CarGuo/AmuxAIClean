import SwiftUI
import Foundation
import SafetyKit

// MARK: - 数据模型

/// 已安装的 .app 条目（一层扫 /Applications）。
public struct InstalledApp: Hashable, Sendable, Identifiable {
    public var id: String { appURL.path }
    public let appURL: URL
    public let metadata: AppMetadata

    public init(appURL: URL, metadata: AppMetadata) {
        self.appURL = appURL
        self.metadata = metadata
    }
}

// MARK: - Store

/// 卸载视图的状态 actor —— 把 IO/扫描搬出主线程，UI 只 await 它。
///
/// 设计要点：
/// - 仅扫一层 `/Applications`（不递归），每条条目附带 `AppMetadata`
/// - 解析失败的 .app（缺少 Info.plist / 缺 CFBundleIdentifier）静默跳过
/// - 候选项委托给已有的 `AppUninstaller.candidates(for:)`，**不重复实现匹配规则**
/// - 孤儿残留独立扫描：`scanOrphans()` 走 [OrphanScanner](OrphanScanner.swift)，反查无主目录
public actor UninstallStore {
    private let applicationsPath: String
    private let uninstaller: AppUninstaller
    private let orphanScanner: OrphanScanner
    private let fileManager: FileManager

    public init(
        applicationsPath: String = "/Applications",
        uninstaller: AppUninstaller = AppUninstaller(),
        orphanScanner: OrphanScanner = OrphanScanner(),
        fileManager: FileManager = .default
    ) {
        self.applicationsPath = applicationsPath
        self.uninstaller = uninstaller
        self.orphanScanner = orphanScanner
        self.fileManager = fileManager
    }

    /// 扫 `/Applications` 一层，仅取 `*.app`，逐个解析 Info.plist。
    public func listInstalledApps() async -> [InstalledApp] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: applicationsPath, isDirectory: &isDir),
              isDir.boolValue,
              let names = try? fileManager.contentsOfDirectory(atPath: applicationsPath)
        else {
            return []
        }

        var out: [InstalledApp] = []
        for name in names where name.hasSuffix(".app") {
            let appURL = URL(fileURLWithPath: applicationsPath).appendingPathComponent(name)
            guard let meta = try? AppMetadata.read(appURL: appURL) else { continue }
            out.append(InstalledApp(appURL: appURL, metadata: meta))
        }
        out.sort { $0.metadata.appName.localizedCaseInsensitiveCompare($1.metadata.appName) == .orderedAscending }
        return out
    }

    /// 给定一个已选 App，返回卸载残留候选项。
    public func selectApp(_ app: InstalledApp) async -> [UninstallCandidate] {
        uninstaller.candidates(for: app.metadata)
    }

    /// 反向扫描三大用户库目录，列出"无主"残留候选。
    public func scanOrphans() async -> [OrphanCandidate] {
        orphanScanner.scan()
    }
}

// MARK: - SwiftUI 屏幕

/// 卸载残留扫描的独立屏幕：左 App 列表 / 右候选项 + 删除按钮。
///
/// 安全契约：
/// - dryRun **默认 true**，按下"删除到废纸篓"先走预览
/// - 实删需要二次确认 sheet 才会调 `dryRun = false`
public struct UninstallScreen: View {
    private let store: UninstallStore
    private let pipeline: any DeletionPipeline

    @State private var apps: [InstalledApp] = []
    @State private var selectedApp: InstalledApp?
    @State private var candidates: [UninstallCandidate] = []
    @State private var checked: Set<String> = []
    @State private var isLoadingApps: Bool = false
    @State private var isLoadingCandidates: Bool = false
    @State private var showRealDeleteConfirm: Bool = false
    @State private var lastResult: String?

    public init(
        store: UninstallStore? = nil,
        pipeline: (any DeletionPipeline)? = nil,
        vendors: [VendorRule] = []
    ) {
        // 若没传 store，用注入的 vendors 现场装一个 AppUninstaller
        if let store {
            self.store = store
        } else {
            let unins = AppUninstaller(vendorRules: vendors)
            self.store = UninstallStore(uninstaller: unins)
        }
        self.pipeline = pipeline ?? TrashPipeline(vendors: vendors)
    }

    public var body: some View {
        // bug2：之前用 HSplitView 是 NSSplitView 桥接，会向外抢宽度预算，导致
        // 嵌在 MainView 的 NavigationSplitView content 栏时，外层 sidebar 被
        // 强制压到几十像素宽，文字截断到只剩首字母。
        // 改成 HStack + Divider + maxWidth=.infinity，让两栏在 content 栏内部
        // 弹性平分，外层 sidebar 不再受到挤压。代价：失去拖拽分栏宽度的能力，
        // 但卸载残留是只读 + 二次确认流程，列宽固定 1:2 已足够。
        HStack(spacing: 0) {
            appsPane
                .frame(minWidth: 240, maxWidth: 360)
            Divider()
            candidatesPane
                .frame(maxWidth: .infinity)
        }
        .task { await reloadApps() }
        .alert("删除结果",
               isPresented: Binding<Bool>(
                get: { lastResult != nil },
                set: { if !$0 { lastResult = nil } }
               )) {
            Button("好") { lastResult = nil }
        } message: {
            Text(lastResult ?? "")
        }
        .sheet(isPresented: $showRealDeleteConfirm) {
            confirmRealDeleteSheet
        }
        // v2：套布局沙箱——把 candidatesPane（卸载残留候选列表）内的长路径
        // ideal width 隔离在沙箱内，禁止反推外层 NavigationSplitView 的列宽。
        .layoutSandbox()
    }

    // MARK: - 左栏

    private var appsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("已安装应用").font(.headline)
                Spacer()
                if isLoadingApps { ProgressView().controlSize(.small) }
                Button {
                    Task { await reloadApps() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(selection: $selectedApp) {
                ForEach(apps) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.metadata.appName)
                            .font(.system(.body, design: .rounded))
                        Text(app.metadata.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(app)
                }
            }
            .listStyle(.inset)
            .onChange(of: selectedApp) { _, new in
                guard let app = new else {
                    candidates = []
                    checked = []
                    return
                }
                Task { await reloadCandidates(for: app) }
            }
        }
    }

    // MARK: - 右栏

    private var candidatesPane: some View {
        VStack(spacing: 0) {
            candidatesHeader
            Divider()
            if selectedApp == nil {
                placeholder("从左侧选择一个 App", icon: "app.dashed")
            } else if isLoadingCandidates {
                placeholder("正在扫描残留…", icon: "hourglass")
            } else if candidates.isEmpty {
                placeholder("未发现残留候选项", icon: "sparkles")
            } else {
                List {
                    ForEach(candidates, id: \.path) { cand in
                        candidateRow(cand)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footerBar
        }
    }

    private var candidatesHeader: some View {
        HStack {
            if let app = selectedApp {
                Text(app.metadata.appName).font(.headline)
                Text(app.metadata.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("候选项").font(.headline)
            }
            Spacer()
            Text("共 \(candidates.count) 项 · \(formattedBytes(totalCheckedBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func candidateRow(_ cand: UninstallCandidate) -> some View {
        let isOn = Binding<Bool>(
            get: { checked.contains(cand.path) },
            set: { newValue in
                if newValue { checked.insert(cand.path) }
                else { checked.remove(cand.path) }
            }
        )
        return HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(cand.path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(reasonLabel(cand.matchReason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedBytes(cand.bytes))
                    .font(.callout.monospacedDigit())
                Text("\(cand.fileCount) 文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var footerBar: some View {
        HStack {
            Button(allChecked ? "全不选" : "全选") {
                toggleAll()
            }
            .disabled(candidates.isEmpty)

            Spacer()

            Text("已选 \(checked.count) 项 · \(formattedBytes(totalCheckedBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                Task { await performDelete(dryRun: true) }
            } label: {
                Label("预览删除", systemImage: "eye")
            }
            .disabled(checked.isEmpty)

            Button(role: .destructive) {
                showRealDeleteConfirm = true
            } label: {
                Label("删除到废纸篓", systemImage: "trash")
            }
            .disabled(checked.isEmpty)
        }
        .padding(16)
    }

    // MARK: - 确认 sheet（实删二次确认）

    private var confirmRealDeleteSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text("确认删除到废纸篓？")
                    .font(.title3.bold())
            }
            Text("将把 \(checked.count) 项（合计 \(formattedBytes(totalCheckedBytes))）移动到废纸篓。\n你仍然可以在 Finder 的废纸篓中撤销。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(checkedPaths, id: \.self) { p in
                        Text(p)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)

            HStack {
                Spacer()
                Button("取消") {
                    showRealDeleteConfirm = false
                }
                Button(role: .destructive) {
                    showRealDeleteConfirm = false
                    Task { await performDelete(dryRun: false) }
                } label: {
                    Text("确认删除")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }

    // MARK: - Helpers

    private var allChecked: Bool {
        !candidates.isEmpty && checked.count == candidates.count
    }

    private var checkedPaths: [String] {
        candidates.map(\.path).filter { checked.contains($0) }
    }

    private var totalCheckedBytes: Int64 {
        candidates.reduce(Int64(0)) { acc, c in
            checked.contains(c.path) ? acc + c.bytes : acc
        }
    }

    private func toggleAll() {
        if allChecked {
            checked.removeAll()
        } else {
            checked = Set(candidates.map(\.path))
        }
    }

    private func reloadApps() async {
        isLoadingApps = true
        let list = await store.listInstalledApps()
        await MainActor.run {
            self.apps = list
            self.isLoadingApps = false
        }
    }

    private func reloadCandidates(for app: InstalledApp) async {
        await MainActor.run {
            self.isLoadingCandidates = true
            self.candidates = []
            self.checked = []
        }
        let list = await store.selectApp(app)
        await MainActor.run {
            self.candidates = list
            self.isLoadingCandidates = false
        }
    }

    /// dryRun 默认 true；实删需走 `showRealDeleteConfirm` 二次确认。
    private func performDelete(dryRun: Bool) async {
        let paths = checkedPaths
        guard !paths.isEmpty else { return }
        // v1.3.zzzz Phase 3-A 对称防御：UninstallScreen 没接 BulkScanner 的
        // permissionDenied 数据源（候选来自 [UninstallStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UninstallStore.swift)
        // 的 NSMetadataQuery + AppCandidate），但 pipeline 是注入进来的、
        // 可能跨视图复用 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
        // 实例。若 MainView 上一轮扫描遗留了 accessDeniedPaths 没清，
        // 切到 UninstallScreen 走 trash 时就会"莫名 accessDenied 拒了某个 ~/Library/.. 路径"。
        // 主动清空一次是 O(1) 锁开销，零误伤。
        pipeline.setAccessDeniedPaths([])
        let (moved, skipped, err) = await pipeline.moveToTrash(paths: paths, dryRun: dryRun)
        let mode = dryRun ? "（预览）" : ""
        await MainActor.run {
            if let err {
                self.lastResult = "失败\(mode)：\(err)\n已处理 \(moved) 项，跳过 \(skipped) 项"
            } else {
                self.lastResult = "已处理 \(moved) 项\(mode)，跳过 \(skipped) 项"
                if !dryRun {
                    self.checked.removeAll()
                    if let app = self.selectedApp {
                        Task { await self.reloadCandidates(for: app) }
                    }
                }
            }
        }
    }

    private func formattedBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func reasonLabel(_ r: MatchReason) -> String {
        switch r {
        case .bundleID(let s): return "bundleID · \(s)"
        case .bundleVendor(let s): return "vendor · \(s)"
        case .appName(let s): return "appName · \(s)"
        case .vendorRule(let s): return "厂商规则 · \(s)"
        }
    }

    @ViewBuilder
    private func placeholder(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
