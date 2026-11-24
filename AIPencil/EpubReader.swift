import SwiftUI
import WebKit

/// An EPUB as it is, beside the PDF made of it: the words flow to fit the screen and can be made larger
/// or smaller. For reading; what is written is written on the PDF's pages.
struct EpubReader: View {
    /// The folder the book was taken apart into.
    let root: URL
    /// What the place in the book is remembered under.
    let key: String

    @Environment(\.dismiss) private var dismiss
    @AppStorage("epubTextSize") private var textSize = 100
    @State private var book: Epub?
    @State private var chapter = 0
    @State private var ready = false

    private var count: Int { book?.chapters.count ?? 0 }

    private var heading: String {
        guard let book, chapter < book.names.count else { return "" }
        return book.names[chapter]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let book, chapter < book.chapters.count {
                    EpubPage(root: root, book: book, chapter: $chapter, textSize: textSize)
                        .ignoresSafeArea(edges: .bottom)
                } else if ready {
                    Text("원본을 열 수 없어요.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        ForEach(0..<count, id: \.self) { index in
                            Button {
                                chapter = index
                            } label: {
                                if index == chapter {
                                    Label(book?.names[index] ?? "", systemImage: "checkmark")
                                } else {
                                    Text(book?.names[index] ?? "")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("차례")
                    Button {
                        textSize = max(70, textSize - 10)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .accessibilityLabel("글자 작게")
                    Button {
                        textSize = min(220, textSize + 10)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .accessibilityLabel("글자 크게")
                    Button {
                        chapter = max(0, chapter - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(chapter <= 0)
                    .accessibilityLabel("앞 장")
                    Button {
                        chapter = min(count - 1, chapter + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(chapter >= count - 1)
                    .accessibilityLabel("다음 장")
                }
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            book = Epub.load(root)
            let kept = UserDefaults.standard.integer(forKey: "epubChapter-" + key)
            chapter = min(max(kept, 0), max(count - 1, 0))
        }
        .onChange(of: chapter) {
            UserDefaults.standard.set(chapter, forKey: "epubChapter-" + key)
        }
    }
}

/// One chapter of the book in a web view.
private struct EpubPage: UIViewRepresentable {
    let root: URL
    let book: Epub
    @Binding var chapter: Int
    let textSize: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // (A book's own scripts are not run.)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.shown != chapter, chapter < book.chapters.count {
            coordinator.shown = chapter
            coordinator.styled = 0
            view.loadFileURL(root.appendingPathComponent(book.chapters[chapter]), allowingReadAccessTo: root)
        } else if coordinator.styled != textSize {
            coordinator.style(view)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EpubPage
        var shown = -1
        var styled = 0

        init(_ parent: EpubPage) {
            self.parent = parent
        }

        func style(_ view: WKWebView) {
            let size = parent.textSize
            styled = size
            let css = "html{-webkit-text-size-adjust:100% !important;font-size:\(size)% !important;}"
                + "body{max-width:42em !important;margin:0 auto !important;padding:28px 32px 96px !important;line-height:1.7;word-break:keep-all;overflow-wrap:break-word;}"
                + "img,svg,video{max-width:100% !important;height:auto !important;}"
                + "pre{white-space:pre-wrap !important;}"
                + "@media (prefers-color-scheme: dark){html,body{background:#1c1c1e !important;color:#e4e4e6 !important;}a{color:#8ab4f8 !important;}}"
            view.evaluateJavaScript(Converter.styling(css)) { _, _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            style(webView)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if !url.isFileURL {
                // A link out of the book is opened in the browser.
                if navigationAction.navigationType == .linkActivated, url.scheme == "http" || url.scheme == "https" {
                    UIApplication.shared.open(url)
                }
                decisionHandler(url.scheme == "about" ? .allow : .cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                // A link to another chapter turns to that chapter.
                let base = parent.root.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                if path.hasPrefix(base + "/") {
                    let relative = String(path.dropFirst(base.count + 1))
                    if let index = parent.book.chapters.firstIndex(of: relative), index != parent.chapter {
                        parent.chapter = index
                        decisionHandler(.cancel)
                        return
                    }
                }
            }
            decisionHandler(.allow)
        }
    }
}
