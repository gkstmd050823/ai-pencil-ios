import PDFKit
import SwiftUI

/// A line of a document's table of contents.
private struct OutlineEntry: Identifiable {
    let id = UUID()
    let level: Int
    let label: String
    let page: Int?
}

/// Finding one's way about a document: its pages as small pictures, its table of contents, the pages
/// marked to come back to, and a search of its words.
struct NavigatorSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case pages, outline, bookmarks, search

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pages: return "쪽"
            case .outline: return "목차"
            case .bookmarks: return "책갈피"
            case .search: return "검색"
            }
        }
    }

    @ObservedObject var controller: ReaderController
    @Binding var bookmarks: [Int]
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab
    @State private var query: String
    @State private var hits: [SearchHit] = []
    @State private var searchedFor = ""
    @State private var outline: [OutlineEntry] = []
    @FocusState private var typing: Bool

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: 18)]

    init(controller: ReaderController, bookmarks: Binding<[Int]>, tab: Tab = .pages, query: String = "") {
        self.controller = controller
        _bookmarks = bookmarks
        _tab = State(initialValue: tab)
        _query = State(initialValue: query)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("보기", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                Divider()
                switch tab {
                case .pages: pages
                case .outline: contents
                case .bookmarks: marked
                case .search: finder
                }
            }
            .navigationTitle("쪽 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .onAppear {
            if let document = controller.document, let root = document.outlineRoot, outline.isEmpty {
                var list: [OutlineEntry] = []
                Self.flatten(root, level: 0, document: document, into: &list)
                outline = list
            }
            if tab == .search, !query.isEmpty { find() }
        }
    }

    private func go(_ page: Int) {
        controller.go(toPage: page)
        dismiss()
    }

    private static func flatten(_ node: PDFOutline, level: Int, document: PDFDocument, into list: inout [OutlineEntry]) {
        for index in 0..<node.numberOfChildren {
            guard let child = node.child(at: index) else { continue }
            let page = child.destination?.page.map { document.index(for: $0) }
            list.append(OutlineEntry(level: level, label: child.label ?? "", page: page))
            if level < 6 { flatten(child, level: level + 1, document: document, into: &list) }
        }
    }

    // MARK: pages

    private var pages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(0..<controller.pageCount, id: \.self) { index in
                        Button {
                            go(index)
                        } label: {
                            PageThumbnail(
                                document: controller.document, index: index,
                                current: index == controller.pageIndex, marked: bookmarks.contains(index)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(20)
            }
            .onAppear {
                proxy.scrollTo(controller.pageIndex, anchor: .center)
            }
        }
    }

    // MARK: table of contents

    @ViewBuilder
    private var contents: some View {
        if outline.isEmpty {
            empty("list.bullet.indent", "이 문서에는 목차가 없어요", "목차는 PDF에 들어 있을 때만 보여요.")
        } else {
            List(outline) { entry in
                Button {
                    if let page = entry.page { go(page) }
                } label: {
                    HStack {
                        Text(entry.label)
                            .font(entry.level == 0 ? .body.weight(.semibold) : .body)
                            .foregroundStyle(.primary)
                            .padding(.leading, CGFloat(entry.level) * 18)
                        Spacer(minLength: 12)
                        if let page = entry.page {
                            Text("\(page + 1)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(entry.page == nil)
            }
            .listStyle(.plain)
        }
    }

    // MARK: bookmarks

    @ViewBuilder
    private var marked: some View {
        if bookmarks.isEmpty {
            empty("bookmark", "책갈피가 아직 없어요", "문서 화면의 ⋯ 메뉴에서 \"이 쪽에 책갈피\"를 누르면 여기에 모여요.")
        } else {
            List {
                ForEach(bookmarks.sorted(), id: \.self) { page in
                    Button {
                        go(page)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.tint)
                            Text("\(page + 1)쪽")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(firstLine(of: page))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            bookmarks.removeAll { $0 == page }
                        } label: {
                            Label("지우기", systemImage: "bookmark.slash")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func firstLine(of page: Int) -> String {
        let text = controller.document?.page(at: page)?.string ?? ""
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    // MARK: search

    private var finder: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("문서 안에서 찾을 말", text: $query)
                    .focused($typing)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(find)
                if !query.isEmpty {
                    Button {
                        query = ""
                        hits = []
                        searchedFor = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("지우기")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if searchedFor.isEmpty {
                empty("text.magnifyingglass", "문서의 글에서 찾아요", "찾을 말을 넣고 키보드의 검색을 누르세요.")
                    .onAppear { if query.isEmpty { typing = true } }
            } else if hits.isEmpty {
                empty("magnifyingglass", "\"\(searchedFor)\"에 맞는 곳이 없어요", "스캔한 문서처럼 글자 정보가 없는 PDF에서는 찾을 수 없어요.")
            } else {
                List {
                    Section("\(hits.count)곳") {
                        ForEach(hits) { hit in
                            Button {
                                controller.show(hit)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(hit.page + 1)쪽")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tint)
                                        .frame(minWidth: 44, alignment: .leading)
                                    Text(hit.snippet)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func find() {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        typing = false
        hits = controller.search(words)
        searchedFor = words
    }

    private func empty(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A page as a small picture, with its number under it.
struct PageThumbnail: View {
    let document: PDFDocument?
    let index: Int
    let current: Bool
    var marked = false
    @State private var picture: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    if let picture {
                        Image(uiImage: picture)
                            .resizable()
                            .scaledToFit()
                    }
                }
                if marked {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.tint)
                        .padding(.trailing, 8)
                        .offset(y: -2)
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: current ? 2.5 : 1))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            Text("\(index + 1)")
                .font(.caption.weight(current ? .bold : .regular).monospacedDigit())
                .foregroundStyle(current ? Color.accentColor : Color.secondary)
        }
        .task(id: index) {
            guard picture == nil, let page = document?.page(at: index) else { return }
            // Drawn off the main thread: a grid of pages scrolling by asks for many of these at once.
            picture = await Task.detached(priority: .userInitiated) {
                page.thumbnail(of: CGSize(width: 340, height: 480), for: .cropBox)
            }.value
        }
    }
}
