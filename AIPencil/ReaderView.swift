import SwiftUI

/// One open document: its pages with handwriting on top.
struct ReaderView: View {
    let doc: Doc
    @EnvironmentObject private var library: Library
    @AppStorage("fingerDraws") private var fingerDraws = false

    var body: some View {
        PDFInkView(
            url: library.pdfURL(for: doc.id),
            store: DrawingStore(folder: library.folder(for: doc.id)),
            fingerDraws: fingerDraws
        )
        .ignoresSafeArea(edges: .bottom)
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
