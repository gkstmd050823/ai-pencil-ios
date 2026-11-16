import SwiftUI

/// The reading screen with the open documents as tabs along its top: touching a tab shows that document
/// in place of the one on screen, the cross on a tab closes it, and the plus goes back to the shelf to
/// open another.
struct ReaderHost: View {
    /// The document that was opened from the shelf.
    let first: Doc
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    /// The tab on show, when it is not the document opened from the shelf.
    @State private var picked: UUID?

    private var doc: Doc? {
        let id = picked ?? first.id
        return library.docs.first { $0.id == id }
    }

    private var open: [Doc] {
        library.tabs.compactMap { id in library.docs.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(open: open, current: doc?.id, onPick: pick, onClose: close) {
                dismiss()
            }
            if let doc {
                // (Each document gets a reading screen of its own, made afresh when the tab changes.)
                ReaderView(doc: doc)
                    .id(doc.id)
            } else {
                Color(uiColor: .secondarySystemBackground)
            }
        }
        .task {
            library.openTab(first.id)
        }
    }

    private func pick(_ id: UUID) {
        guard id != doc?.id else { return }
        Diagnostics.shared.step("tab changed")
        picked = id
    }

    private func close(_ id: UUID) {
        let before = library.tabs
        let showing = doc?.id
        library.closeTab(id)
        Diagnostics.shared.step("tab closed")
        guard id == showing else { return }
        // The tab on show was closed: the one after it takes its place, or the one before; with none
        // left, back to the shelf.
        if let at = before.firstIndex(of: id) {
            if before.indices.contains(at + 1) {
                picked = before[at + 1]
                return
            }
            if at > 0 {
                picked = before[at - 1]
                return
            }
        }
        dismiss()
    }
}

/// The row of tabs.
private struct TabStrip: View {
    let open: [Doc]
    let current: UUID?
    let onPick: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(open) { doc in
                            tab(doc)
                                .id(doc.id)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onChange(of: current) {
                    if let current { withAnimation { reader.scrollTo(current, anchor: .center) } }
                }
            }
            Button(action: onAdd) {
                HStack(spacing: 4) {
                    Text("탭 추가")
                        .font(.footnote)
                    Image(systemName: "plus")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 36)
            }
            .accessibilityLabel("탭 추가")
        }
        .frame(height: 36)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private func tab(_ doc: Doc) -> some View {
        let selected = doc.id == current
        return HStack(spacing: 2) {
            Button {
                onClose(doc.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected ? Color.primary.opacity(0.7) : Color.secondary)
                    .frame(width: 24, height: 28)
            }
            .accessibilityLabel("\(doc.title) 탭 닫기")
            Button {
                onPick(doc.id)
            } label: {
                Text(doc.title)
                    .font(.footnote.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190)
                    .padding(.trailing, 10)
                    .frame(height: 28)
            }
            .accessibilityLabel("\(doc.title) 탭")
        }
        .padding(.leading, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(selected ? Color.primary : Color.clear)
                .frame(height: 2)
                .padding(.horizontal, 6)
        }
    }
}

/// A grid for the shelf: as many columns as fit, every card as wide as its column, rows as tall as their
/// tallest card. It lays out all its cards at once. (The shelf used the system's grid that makes cards
/// only as they scroll into view; a shelf holds few enough cards not to need that, and this has no
/// cards coming and going while the screen changes size.)
struct ShelfGrid: Layout {
    var minimum: CGFloat = 150
    var maximum: CGFloat = 220
    var spacing: CGFloat = 22
    var rowSpacing: CGFloat = 22

    private func columns(in width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + spacing) / (minimum + spacing)))
        let each = min(maximum, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        return (count, max(each, 10))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let (count, each) = columns(in: width)
        var height: CGFloat = 0
        var index = 0
        while index < subviews.count {
            let end = min(index + count, subviews.count)
            var tall: CGFloat = 0
            for at in index..<end {
                tall = max(tall, subviews[at].sizeThatFits(ProposedViewSize(width: each, height: nil)).height)
            }
            height += tall + (index > 0 ? rowSpacing : 0)
            index = end
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (count, each) = columns(in: bounds.width)
        var y = bounds.minY
        var index = 0
        while index < subviews.count {
            let end = min(index + count, subviews.count)
            var tall: CGFloat = 0
            for at in index..<end {
                tall = max(tall, subviews[at].sizeThatFits(ProposedViewSize(width: each, height: nil)).height)
            }
            for at in index..<end {
                let x = bounds.minX + CGFloat(at - index) * (each + spacing)
                subviews[at].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: each, height: tall))
            }
            y += tall + rowSpacing
            index = end
        }
    }
}
