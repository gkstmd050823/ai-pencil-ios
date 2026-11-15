import SwiftUI

/// One open document: its pages with handwriting on top, and the tool bar floating over them.
struct ReaderView: View {
    let doc: Doc
    @EnvironmentObject private var library: Library
    @AppStorage("fingerDraws") private var fingerDraws = false
    @State private var choice = InkChoice()

    var body: some View {
        PDFInkView(
            url: library.pdfURL(for: doc.id),
            store: DrawingStore(folder: library.folder(for: doc.id)),
            choice: choice,
            fingerDraws: fingerDraws
        )
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
            ToolBar(choice: $choice)
                .padding(.top, 10)
        }
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    fingerDraws.toggle()
                } label: {
                    Label(
                        fingerDraws ? "손가락 필기 끄기" : "손가락 필기 켜기",
                        systemImage: fingerDraws ? "hand.draw.fill" : "hand.draw"
                    )
                }
            }
        }
    }
}

/// The floating tool bar: the tools, then the three colours of the pen or the highlighter.
private struct ToolBar: View {
    @Binding var choice: InkChoice

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InkTool.allCases) { tool in
                Button {
                    choice.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 46, height: 46)
                        .foregroundStyle(choice.tool == tool ? Color.accentColor : Color.secondary)
                        .background(choice.tool == tool ? Color.accentColor.opacity(0.14) : Color.clear, in: Circle())
                }
                .accessibilityLabel(tool.label)
            }
            if choice.tool == .pen || choice.tool == .highlighter {
                Divider()
                    .frame(height: 26)
                    .padding(.horizontal, 6)
                let colors = choice.tool == .pen ? InkChoice.penColors : InkChoice.highlighterColors
                let selected = choice.tool == .pen ? choice.penColor : choice.highlighterColor
                ForEach(colors.indices, id: \.self) { index in
                    Button {
                        if choice.tool == .pen { choice.penColor = index } else { choice.highlighterColor = index }
                    } label: {
                        Circle()
                            .fill(Color(uiColor: colors[index]))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                            .padding(5)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: index == selected ? 2 : 0))
                            .frame(width: 40, height: 46)
                    }
                    .accessibilityLabel("색 \(index + 1)")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
    }
}
