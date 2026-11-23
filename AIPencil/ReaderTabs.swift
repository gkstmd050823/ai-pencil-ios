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
        // The tabs are handed to the reading screen, which puts them in the one bar at its top beside its
        // own buttons. (The system's bar, with the title the tab already says, is not shown.)
        let strip = TabStrip(open: open, current: doc?.id, onPick: pick, onClose: close) {
            dismiss()
        }
        VStack(spacing: 0) {
            if let doc {
                // (Each document gets a reading screen of its own, made afresh when the tab changes.)
                ReaderView(doc: doc, lead: AnyView(strip))
                    .id(doc.id)
            } else {
                strip
                    .background(Tone.bar.ignoresSafeArea(edges: .top))
                Color(uiColor: .secondarySystemBackground)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
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

/// The bar along the top of the reading screen: the way back to the shelf, the open documents as tabs,
/// and a plus for opening another. The tab of the document on show stands up from the bar in the colour
/// of what is under it, with how many pages it has; the others lie flat with a line between them.
/// (Until 0.14.13 the tabs were a row of small words, 36 points tall, under the system's own bar with the
/// title in it: three dark bands in all, the tabs "narrow and hard to tell apart".)
struct TabStrip: View {
    let open: [Doc]
    let current: UUID?
    let onPick: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onAdd) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("서재로")
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(open) { doc in
                            tab(doc)
                                .id(doc.id)
                        }
                    }
                    .frame(height: 50, alignment: .bottom)
                }
                .onChange(of: current) {
                    if let current { withAnimation { reader.scrollTo(current, anchor: .center) } }
                }
            }
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("탭 추가")
        }
        .foregroundStyle(.primary)
        .frame(height: 50)
    }

    private func tab(_ doc: Doc) -> some View {
        let selected = doc.id == current
        return HStack(spacing: 6) {
            Button {
                onPick(doc.id)
            } label: {
                HStack(spacing: 8) {
                    Text(doc.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if selected {
                        Text("\(doc.pageCount)쪽")
                            .font(.system(size: 11))
                            .opacity(0.6)
                    }
                }
                .frame(minWidth: 70, maxWidth: 200, alignment: .leading)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(doc.title) 탭")
            Button {
                onClose(doc.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.55)
                    .frame(width: 30, height: 42)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(doc.title) 탭 닫기")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background(
            selected ? Tone.tabOn : Color.clear,
            in: UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 11, style: .continuous)
        )
        .overlay(alignment: .trailing) {
            // (A line between two tabs that lie flat.)
            Rectangle()
                .fill(selected ? Color.clear : Color.primary.opacity(0.16))
                .frame(width: 1, height: 22)
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
