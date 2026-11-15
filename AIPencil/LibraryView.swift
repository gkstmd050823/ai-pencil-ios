import SwiftUI
import UniformTypeIdentifiers

/// The shelf: every document, and the ways to get more.
struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @State private var path: [Doc] = []
    @State private var importing = false
    @State private var errorText: String?
    @State private var showingSettings = false
    @State private var renaming: Doc?
    @State private var newTitle = ""
    @State private var ranDemo = false

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
                                    Button {
                                        newTitle = doc.title
                                        renaming = doc
                                    } label: {
                                        Label("이름 바꾸기", systemImage: "pencil")
                                    }
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("설정", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            importing = true
                        } label: {
                            Label("PDF 가져오기", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            newNote()
                        } label: {
                            Label("빈 노트 만들기", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Label("추가", systemImage: "plus")
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
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("문서 이름", text: $newTitle)
            Button("취소", role: .cancel) {}
            Button("바꾸기") {
                if let doc = renaming { library.rename(doc, to: newTitle) }
            }
        }
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: runDemoIfAsked)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("읽다가 막히면 동그라미")
                .font(.title2.bold())
            Text("PDF를 가져와 필기하다가, 모르는 부분에 AI 펜으로 동그라미를 치면 바로 설명해 줘요.")
                .multilineTextAlignment(.center)
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
            Button("빈 노트 만들기") { newNote() }
        }
        .padding(36)
    }

    private func newNote() {
        do {
            path = [try library.createNote()]
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// The build server starts the app with these to take pictures without anyone tapping: "-sample" opens
    /// the bundled sample (imported once), "-demoNote" makes a blank notebook and opens it, "-demoImport
    /// name.pdf" opens a file the server put in the app's Documents folder, "-demoSettings" shows the settings.
    private func runDemoIfAsked() {
        guard !ranDemo, path.isEmpty else { return }
        ranDemo = true
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-sample") {
            if let existing = library.docs.first(where: { $0.title == "샘플" }) {
                path = [existing]
            } else if let url = Bundle.main.url(forResource: "Sample", withExtension: "pdf"),
                      let doc = try? library.importPDF(from: url, title: "샘플") {
                path = [doc]
            }
        } else if arguments.contains("-demoNote") {
            newNote()
        } else if let name = UserDefaults.standard.string(forKey: "demoImport") {
            let title = (name as NSString).deletingPathExtension
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let existing = library.docs.first(where: { $0.title == title }) {
                path = [existing]
            } else if let doc = try? library.importPDF(from: documents.appendingPathComponent(name), title: title) {
                path = [doc]
            }
        } else if arguments.contains("-demoSettings") {
            showingSettings = true
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
