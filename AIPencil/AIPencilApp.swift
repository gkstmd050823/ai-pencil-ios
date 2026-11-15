import SwiftUI

@main
struct AIPencilApp: App {
    @StateObject private var library = Library()
    /// "system" follows the iPad; "light" and "dark" hold the app to one look.
    @AppStorage("theme") private var theme = "system"

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
        }
    }
}
