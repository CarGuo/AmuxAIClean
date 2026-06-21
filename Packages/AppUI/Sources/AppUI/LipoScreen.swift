import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LipoKit

/// F-2-3 / 2026-06：Lipo 通用二进制瘦身屏（sidebar 入口接入）。
///
/// dev 期 MVP：
/// - 用户输入或拖入一个 .app bundle 路径
/// - 调 [LipoEngine.auditBundle(at:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LipoKit/Sources/LipoKit/LipoEngine.swift)
///   汇总 FAT 候选 + 估算节省字节
/// - dryRun 列表展示给用户；点 Extract 才真写盘
///
/// 与 MaintenanceScreen 同结构：sentinel 旁路、不复用扫描状态栏 / footerBar，
/// 完全自闭环。字面量走英文 + 中文注释，不引入新 xcstrings key（避免给 dev 期增负担）。
public struct LipoScreen: View {
    @State private var bundlePath: String = "/Applications"
    @State private var candidates: [LipoEngine.Candidate] = []
    @State private var isAuditing: Bool = false
    @State private var lastError: String?
    /// 真正在 extract 的候选 path → 避免重复点；完成后从 set 移除。
    @State private var extracting: Set<String> = []
    @State private var extractedSavings: UInt64 = 0

    private let engine: LipoEngine

    public init(engine: LipoEngine = LipoEngine()) {
        self.engine = engine
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            inputBar
            Divider()
            resultsSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("lipo.header.title", bundle: .module)
                .font(.title2.bold())
            Text("lipo.header.subtitle", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(.secondary)
            TextField(String(localized: "lipo.input.placeholder", bundle: .module), text: $bundlePath)
                .textFieldStyle(.roundedBorder)
            Button {
                pickBundle()
            } label: {
                Image(systemName: "folder")
            }
            .help(Text("lipo.input.pick.help", bundle: .module))
            Button {
                runAudit()
            } label: {
                if isAuditing {
                    ProgressView().controlSize(.small)
                } else {
                    Label {
                        Text("lipo.action.audit", bundle: .module)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .disabled(isAuditing || bundlePath.isEmpty)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("lipo.results.title", bundle: .module).font(.headline)
                if !candidates.isEmpty {
                    Text(verbatim: String(format: String(localized: "lipo.results.summary %lld %@", bundle: .module),
                                          candidates.count,
                                          byteString(totalSavings)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if extractedSavings > 0 {
                    Label {
                        Text(verbatim: String(format: String(localized: "lipo.results.reclaimed %@", bundle: .module),
                                              byteString(extractedSavings)))
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                    }
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            }
            if let err = lastError {
                Label {
                    Text(verbatim: err)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if candidates.isEmpty && !isAuditing && lastError == nil {
                Text("lipo.results.empty", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates, id: \.path) { cand in
                            candidateRow(cand)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ cand: LipoEngine.Candidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu")
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: displayPath(cand.path))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(verbatim: archesLabel(cand))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: String(format: String(localized: "lipo.candidate.save %@", bundle: .module),
                                          byteString(cand.savings)))
                        .font(.caption)
                        .foregroundStyle(cand.savings > 0 ? .green : .secondary)
                }
            }
            Spacer()
            if extracting.contains(cand.path) {
                ProgressView().controlSize(.small)
            }
            Button {
                runExtract(cand)
            } label: {
                Text("lipo.action.extract_arm64", bundle: .module)
            }
            .disabled(extracting.contains(cand.path) || cand.targetSlice == nil)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - actions

    private func runAudit() {
        let path = bundlePath
        isAuditing = true
        lastError = nil
        candidates = []
        let engineRef = engine
        Task.detached {
            let result = engineRef.auditBundle(at: path)
            await MainActor.run {
                candidates = result
                isAuditing = false
                if result.isEmpty {
                    lastError = nil
                }
            }
        }
    }

    private func runExtract(_ cand: LipoEngine.Candidate) {
        extracting.insert(cand.path)
        let engineRef = engine
        Task.detached { [cand] in
            do {
                try engineRef.extract(cand)
                await MainActor.run {
                    extracting.remove(cand.path)
                    extractedSavings += cand.savings
                    // 移除已处理候选，避免重复 extract（文件已不再是 FAT）
                    candidates.removeAll { $0.path == cand.path }
                }
            } catch {
                await MainActor.run {
                    extracting.remove(cand.path)
                    lastError = String(format: String(localized: "lipo.error.extract_failed %@ %@", bundle: .module),
                                       cand.path, String(describing: error))
                }
            }
        }
    }

    private func pickBundle() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application, .directory]
        panel.message = String(localized: "lipo.picker.message", bundle: .module)
        if panel.runModal() == .OK, let url = panel.url {
            bundlePath = url.path
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                Task { @MainActor in
                    bundlePath = url.path
                    runAudit()
                }
            }
        }
        return true
    }

    // MARK: - helpers

    private var totalSavings: UInt64 {
        candidates.reduce(0) { $0 + $1.savings }
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func displayPath(_ path: String) -> String {
        // 显示相对 bundle 的尾段；长路径折叠
        let basePath = bundlePath
        if path.hasPrefix(basePath) {
            let tail = String(path.dropFirst(basePath.count))
            return tail.isEmpty ? path : "..." + tail
        }
        return path
    }

    private func archesLabel(_ cand: LipoEngine.Candidate) -> String {
        let names = cand.allArches.map { arch -> String in
            switch arch.cputype {
            case CPUType.arm64:  return "arm64"
            case CPUType.x86_64: return "x86_64"
            default:             return "cpu#\(arch.cputype)"
            }
        }
        return names.joined(separator: " + ")
    }
}
