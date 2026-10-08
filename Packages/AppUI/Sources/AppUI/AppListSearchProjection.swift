import Foundation

/// v2026.10.08: a filtered single-selection list and its detail/action owner must use the
/// same visible identities. Keeping a hidden App selected exposed unrelated uninstall
/// candidates after a no-match search, and also retained stale App Footprint details.
struct AppListSearchProjection<Item: Identifiable> {
    let items: [Item]
    let selection: Item?

    init(
        items: [Item],
        selection: Item?,
        query: String,
        matches: (Item, String) -> Bool
    ) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = term.isEmpty ? items : items.filter { matches($0, term) }
        self.items = visible
        self.selection = selection.flatMap { selected in
            visible.first { $0.id == selected.id }
        }
    }
}
