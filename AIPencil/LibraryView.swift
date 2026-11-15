import SwiftUI
import UniformTypeIdentifiers

/// The shelf: every imported PDF, and the way to bring in more.
struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @State private var path: [Doc] = []
    @State private var importing = false
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 22)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.docs.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(library.docs) { doc in
                                NavigationLink(value: doc) {
                                    DocCard(doc: doc)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        library.delete(doc)
                                    } label: {
                                        Label("삭제", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(22)
                    }
                }
            }
            .navigationTitle("문서")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        importing = true
                    } label: {
                        Label("PDF 가져오기", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: Doc.self) { doc in
                ReaderView(doc: doc)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var last: Doc?
                for url in urls {
                    do {
                        last = try library.importPDF(from: url)
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
                // One file opens straight away; several stay on the shelf.
                if urls.count == 1, let doc = last {
                    path = [doc]
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        // A PDF handed over by another app ("open in", share sheet).
        .onOpenURL { url in
            do {
                path = [try library.importPDF(from: url)]
            } catch {
                errorText = error.localizedDescription
            }
        }
        .alert("가져오지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: openSampleIfAsked)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("읽다가 막히면 동그라미")
                .font(.title2.bold())
            Text("PDF를 가져와 애플 펜슬로 필기해 보세요.")
                .foregroundStyle(.secondary)
            Button {
                importing = true
            } label: {
                Label("PDF 가져오기", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(36)
    }

    /// The build server starts the app with "-sample" to take a picture of the reader without anyone tapping:
    /// the bundled sample is imported (once) and opened.
    private func openSampleIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-sample"), path.isEmpty else { return }
        if let existing = library.docs.first(where: { $0.title == "샘플" }) {
            path = [existing]
        } else if let url = Bundle.main.url(forResource: "Sample", withExtension: "pdf"),
                  let doc = try? library.importPDF(from: url, title: "샘플") {
            path = [doc]
        }
    }
}

/// A document on the shelf: its first page standing on the bottom edge of a box, its name beneath.
private struct DocCard: View {
    let doc: Doc
    @EnvironmentObject private var library: Library
    @State private var cover: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                Color.clear
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                }
            }
            .aspectRatio(0.84, contentMode: .fit)

            Text(doc.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text("\(doc.pageCount)쪽")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: doc.id) {
            cover = library.cover(for: doc, width: 360)
        }
    }
}
