import SwiftUI

/// Asked whenever a PDF comes in, from the file picker or from another app: a document of its own (and in
/// which folder), or more pages for a document that is open (and where in it).
struct ImportSheet: View {
    let files: IncomingFiles
    /// A new document for each file, in this folder (nil for the shelf itself).
    let onNew: (UUID?) -> Void
    /// The files' pages into this document: after its last page when true, after the page being read otherwise.
    let onAdd: (Doc, Bool) -> Void

    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var folder: UUID?
    @State private var target: UUID?
    @State private var atEnd = false
    @State private var prepared = false

    /// The documents open as tabs, the one on show first.
    private var open: [Doc] {
        let docs = library.tabs.compactMap { id in library.docs.first { $0.id == id } }
        return docs.filter { $0.id == library.showing } + docs.filter { $0.id != library.showing }
    }

    private var names: String {
        let all = files.urls.map { $0.deletingPathExtension().lastPathComponent }
        guard let first = all.first else { return "" }
        return all.count > 1 ? "\(first) 외 \(all.count - 1)개" : first
    }

    private var folders: [Folder] {
        library.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The page being read in the document on show, when that is the one chosen.
    private var pageOnShow: Int? {
        guard let target, target == library.showing else { return nil }
        return library.pageOnShow?()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    mode(false, "새 문서로", files.urls.count > 1 ? "파일마다 문서가 하나씩 생겨요" : "서재에 문서가 하나 생겨요")
                    if !open.isEmpty {
                        mode(true, "열린 문서에 추가", "열려 있는 문서에 쪽으로 들어가요")
                    }
                } header: {
                    Text(names)
                        .textCase(nil)
                }
                if adding {
                    Section("넣을 문서") {
                        ForEach(open) { doc in
                            place(doc.title, symbol: "doc.text", detail: "\(doc.pageCount)쪽", chosen: doc.id == target) {
                                target = doc.id
                            }
                        }
                    }
                    Section {
                        if let page = pageOnShow {
                            Picker("넣을 자리", selection: $atEnd) {
                                Text("\(page + 1)쪽 뒤에").tag(false)
                                Text("맨 끝에").tag(true)
                            }
                            .pickerStyle(.segmented)
                        } else {
                            Text("맨 끝에 들어가요")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("넣을 자리")
                    } footer: {
                        Text("뒤쪽에 써 둔 필기와 AI 표시, 책갈피는 제 쪽을 따라 함께 밀려요.")
                    }
                } else {
                    Section("넣을 폴더") {
                        place("문서 (맨 위)", symbol: "tray", detail: nil, chosen: folder == nil) {
                            folder = nil
                        }
                        ForEach(folders) { item in
                            place(item.name, symbol: "folder", detail: nil, chosen: item.id == folder) {
                                folder = item.id
                            }
                        }
                    }
                }
            }
            .navigationTitle("PDF 가져오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(adding ? "쪽으로 넣기" : "가져오기") {
                        if adding, let doc = open.first(where: { $0.id == target }) {
                            // (Anywhere but in the document on show there is no page being read: the end.)
                            onAdd(doc, pageOnShow == nil ? true : atEnd)
                        } else {
                            onNew(folder)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            folder = library.folders.contains { $0.id == files.folder } ? files.folder : nil
            target = open.first?.id
            adding = files.forDocument && library.showing != nil && target != nil
            Diagnostics.shared.step("asked where \(files.urls.count) files go")
        }
    }

    /// One of the two things that can be done with the files.
    private func mode(_ value: Bool, _ title: String, _ detail: String) -> some View {
        Button {
            adding = value
        } label: {
            HStack(spacing: 12) {
                Image(systemName: adding == value ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(adding == value ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// A folder, or a document, that the files can go to; the one chosen has a tick.
    private func place(_ name: String, symbol: String, detail: String?, chosen: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
