import SwiftUI
import AppKit

/// v1.0 T4：大文件视图。
///
/// 设计要点（参考 CleanMyMac / Sensei / Pearcleaner 大文件扫描器）：
/// 1. **扁平 Top N 列表**——大文件场景核心是"哪几个最大、最旧"，不需要再下钻；
///    Top N 默认 200（ROADMAP T4），避免一次性渲染数千行卡 UI。
/// 2. **列头点击切排序**——只有 size 与 mtime 两个维度（验收 2 明确）。
///    路径 / 文件名维度不参与排序：大文件页面的决策点是体积与活跃度。
/// 3. **阈值由 AppSettings 提供**——用户在 ⌘, 设置里改 minFileSizeMB，本视图实时反映。
///    若新阈值 < 扫描阈值，提示用户重扫（数据不在内存里就装不出来）。
/// 4. **不显示安全徽章 / 默认勾选**：大文件清理本来就要"用户确认才删"，
///    不能再叫 SafetyEngine 把 ~/Movies/big.mov 标成 .safe。
public struct LargeFilesView: View {
    @ObservedObject var coordinator: ScanCoordinator
    @Bindable var settings: AppSettings

    /// 行内当前选中（用于右侧详情，也作为 .delete 快捷键的锚）。
    @Binding var selection: LargeFileItem?

    /// 移到废纸篓回调；由 MainView 注入，复用主界面的 DeleteSheet 流程。
    let onTrash: ([URL]) -> Void

    /// Top N 截断。默认 200（ROADMAP）。可由调用方覆盖。
    let limit: Int

    /// 当前列表排序键。本地 @State 是为了"列头点击不污染全局 settings.sortKey"——
    /// settings.sortKey 是给清单 / 树视图共用的，大文件视图列只有 size / mtime 两列，
    /// 与之模型不一致。
    @State private var sortKey: LargeFileSortKey = .sizeDesc

    public init(coordinator: ScanCoordinator,
                settings: AppSettings,
                selection: Binding<LargeFileItem?>,
                limit: Int = 200,
                onTrash: @escaping ([URL]) -> Void) {
        self.coordinator = coordinator
        self.settings = settings
        self._selection = selection
        self.limit = limit
        self.onTrash = onTrash
    }

    /// 视图层"实时计算"出的当前列表。
    private var items: [LargeFileItem] {
        coordinator.largeFiles(
            minSizeMB: settings.minFileSizeMB,
            sortKey: sortKey,
            limit: limit
        )
    }

    /// 视图阈值（B）—— 与扫描期阈值对比，判断是否需要提示重扫。
    private var viewThresholdBytes: Int64 {
        Int64(max(0, settings.minFileSizeMB)) * 1024 * 1024
    }

    /// "扫描期采集了 X 条 ≥ 扫描阈值的文件，但视图阈值 < 扫描阈值"——这种情况下
    /// 视图能展示的就只是已采集子集，比 ground truth 偏小，需要重扫。
    private var needsRescanForLowerThreshold: Bool {
        coordinator.largeFileScanThresholdBytes > 0
            && viewThresholdBytes < coordinator.largeFileScanThresholdBytes
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.tint)
            Text("≥ \(settings.minFileSizeMB) MB · Top \(limit)")
                .font(.callout)
            Spacer()
            if needsRescanForLowerThreshold {
                Label("阈值已下调，需重扫才能看到完整列表", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("共 \(items.count) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                columnHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(for: item)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            if coordinator.isScanning {
                Text("正在扫描大文件…")
                    .foregroundStyle(.secondary)
            } else if coordinator.isFinished {
                Text("没有 ≥ \(settings.minFileSizeMB) MB 的文件")
                    .foregroundStyle(.secondary)
                Text("可以在 ⌘, 设置里把阈值调低再重扫")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("点左侧 \"🐘 大文件\" 开始扫描")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Columns

    private var columnHeader: some View {
        HStack(spacing: 10) {
            // 图标占位（与行内对齐）
            Spacer().frame(width: 20)
            Text("名称 / 路径")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            columnButton(title: "大小", column: .size)
                .frame(width: 110, alignment: .trailing)
            columnButton(title: "修改日期", column: .mtime)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.background.secondary)
    }

    private func columnButton(title: String, column: LargeFileSortKey.Column) -> some View {
        Button {
            sortKey = sortKey.toggled(to: column)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.bold())
                if sortKey.column == column {
                    Image(systemName: sortKey.isDescending ? "chevron.down" : "chevron.up")
                        .font(.caption2.bold())
                }
            }
            .foregroundStyle(sortKey.column == column ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("点击切换 \(title) 升 / 降序")
    }

    // MARK: - Row

    private static let mtimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    @ViewBuilder
    private func row(for item: LargeFileItem) -> some View {
        let isSelected = (selection?.path == item.path)
        HStack(spacing: 10) {
            Image(systemName: iconName(for: item))
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((item.path as NSString).deletingLastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                .font(.system(.body, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
            Text(item.modificationDate.map { Self.mtimeFormatter.string(from: $0) } ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = item }
        .help(item.path)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: { Label("在 Finder 中显示", systemImage: "folder") }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(item.path, forType: .string)
            } label: { Label("复制路径", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) {
                onTrash([item.url])
            } label: { Label("移到废纸篓…", systemImage: "trash") }
        }
    }

    /// 极简扩展名 → SF Symbol 映射。覆盖 5 类常见大文件来源：
    /// 视频 / 镜像 / 压缩包 / 安装包 / 文档；其余兜底成 doc。
    private func iconName(for item: LargeFileItem) -> String {
        switch item.fileExtension {
        case "mov", "mp4", "mkv", "avi", "m4v":            return "film"
        case "iso", "dmg", "img":                           return "opticaldisc"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":  return "archivebox"
        case "pkg", "ipa", "app":                            return "shippingbox"
        case "psd", "ai", "sketch", "fig":                   return "photo"
        case "log":                                          return "doc.plaintext"
        default:                                             return "doc"
        }
    }
}
