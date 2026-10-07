import SwiftUI

/// v2026.09.06: the canvas renders one background-prepared presentation. Compact
/// cells always retain both identifying text lines; grouped area has a permanent
/// full-width action, even when its true proportional area is only a few pixels.
struct StorageTreemapCanvas<Actions: View>: View {
    let presentation: StorageTreemapPresentation
    let isBusy: Bool
    let onViewportChange: (CGSize) -> Void
    let onActivate: (TreeRow) -> Void
    let onShowSmallerItems: () -> Void
    @ViewBuilder let fileActions: (TreeRow) -> Actions
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(presentation.cells) { cell in mapCell(cell) }
                if let group = presentation.smallerItems {
                    groupButton(group)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .onValueChange(of: geometry.size, initial: true) { _, size in onViewportChange(size) }
        }
        .accessibilityIdentifier("normal.analysis.treemap")
    }

    private func mapCell(_ cell: StorageMapRect) -> some View {
        let color = NormalWorkspacePalette.color(cell.item.colorIndex)
        let title = title(for: cell.item)
        let bytes = AppLocalization.byteCount(cell.item.bytes, locale: locale)
        let expanded = cell.rect.width >= 180 && cell.rect.height >= 120
        let fullSummary = StorageTreemapPresentation.fitsSummary(cell.rect)
        let compactGroup = cell.item.row == nil
            && cell.rect.width >= StorageTreemapPresentation.minimumGroupSummarySize.width
            && cell.rect.height >= StorageTreemapPresentation.minimumGroupSummarySize.height
        let canLabel = fullSummary || compactGroup
        let labelTitle = compactGroup && !fullSummary
            ? AppLocalization.format(
                "workspace.storage.group.count %lld", locale: locale,
                arguments: [Int64(cell.item.groupedCount)]) : title
        return Button {
            if let row = cell.item.row { onActivate(row) } else { onShowSmallerItems() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(colorScheme == .dark ? 0.80 : 0.24),
                                color.opacity(colorScheme == .dark ? 0.53 : 0.14)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.23) : color.opacity(0.42),
                        lineWidth: 1)
                if canLabel {
                    VStack(spacing: expanded ? 7 : 4) {
                        if expanded {
                            Image(systemName: symbol(for: cell.item))
                                .font(.system(size: 27, weight: .light))
                        }
                        Text(verbatim: labelTitle)
                            .font(.system(size: expanded ? 19 : 12, weight: .semibold, design: .rounded))
                            .lineLimit(expanded ? 2 : 1).truncationMode(.middle)
                        Text(verbatim: bytes)
                            .font(.system(size: expanded ? 14 : 11, design: .rounded).monospacedDigit())
                            .opacity(0.85).lineLimit(1)
                    }
                    .padding(StorageTreemapPresentation.cellPadding)
                } else if cell.rect.width >= 24, cell.rect.height >= 24 {
                    // Only the aggregate can reach this branch. Its name, count,
                    // size and action remain visible in the adjacent group button.
                    Image(systemName: "ellipsis").font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
            .frame(
                width: max(0, cell.rect.width - StorageTreemapPresentation.cellGap),
                height: max(0, cell.rect.height - StorageTreemapPresentation.cellGap))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .position(x: cell.rect.midX, y: cell.rect.midY)
        .help(Text(verbatim: "\(title) · \(bytes)"))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: bytes))
        .contextMenu {
            if let row = cell.item.row { fileActions(row) }
        }
    }

    private func groupButton(_ group: StorageMapItem) -> some View {
        Button(action: onShowSmallerItems) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(NormalWorkspacePalette.color(group.colorIndex))
                Text(verbatim: title(for: group)).font(.callout.weight(.semibold))
                Text(verbatim: AppLocalization.byteCount(group.bytes, locale: locale))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("workspace.storage.smaller.show", bundle: .module).font(.caption.weight(.medium))
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: StorageTreemapPresentation.groupButtonHeight)
            .background(
                NormalWorkspacePalette.color(group.colorIndex).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(isBusy)
        .accessibilityIdentifier("normal.analysis.smaller-items")
    }

    private func title(for item: StorageMapItem) -> String {
        item.row?.displayTitle(locale: locale)
            ?? AppLocalization.format(
                "workspace.storage.group %lld", locale: locale, arguments: [Int64(item.groupedCount)])
    }

    private func symbol(for item: StorageMapItem) -> String {
        guard let row = item.row else { return "square.grid.2x2" }
        return row.isDirectory ? "folder" : "doc"
    }
}
