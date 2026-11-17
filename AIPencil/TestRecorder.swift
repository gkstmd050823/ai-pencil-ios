import SwiftUI
import UIKit

/// The notes of a test, to hand to whoever is looking for a fault: what the app did while the test ran, each
/// thing with the moment it happened.
///
/// The app is not tried out on the build server any more (that took an hour a build); it is tried out by the
/// person who uses it, on the iPad, who films the screen with the iPad's own screen recording. What goes
/// wrong there is mostly a matter of moments (a line that blinks, a tool taken up a moment late), and the
/// film shows what was seen while these notes say what the app was doing at that moment. The two are set
/// side by side by the mark this puts at the top of the screen: the moment it appears in the film is the
/// notes' nought, and every line also has the time of day.
///
/// Nothing is sent anywhere: when the notes are ended they are handed to the system's share sheet as a text
/// file, and where it goes from there is the user's choice. Nothing of a document's contents is noted.
final class TestRecorder: ObservableObject {
    static let shared = TestRecorder()

    @Published private(set) var recording = false

    /// Read from wherever something is noted; true while notes are being taken.
    private(set) var isOn = false
    private let lock = NSLock()
    private var lines: [String] = []
    private var began: CFTimeInterval = 0
    private var startedAt = Date()
    private let clock: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm:ss.SSS"
        return format
    }()

    /// Something the app did, noted with its moment while notes are being taken. Cheap to call when none are.
    func note(_ line: String) {
        guard isOn else { return }
        let stamp = String(format: "[%8.3f ", CACurrentMediaTime() - began)
        lock.lock()
        // (An hour of busy notes at most; past that the oldest go.)
        if lines.count > 40_000 { lines.removeFirst(10_000) }
        lines.append(stamp + clock.string(from: Date()) + "] " + line)
        lock.unlock()
    }

    func start() {
        guard !recording else { return }
        lock.lock()
        lines = []
        lock.unlock()
        began = CACurrentMediaTime()
        startedAt = Date()
        isOn = true
        recording = true
        note("notes begin (the mark at the top of the screen appears now)")
        Diagnostics.shared.step("test notes begin")
    }

    /// Ends the notes, writes them to a file and offers it to be shared.
    func stop() {
        guard recording else { return }
        note("notes end")
        let lasted = CACurrentMediaTime() - began
        isOn = false
        recording = false
        lock.lock()
        let timeline = lines
        lines = []
        lock.unlock()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("test-notes", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("aipencil-test-" + format.string(from: startedAt) + ".txt")
        var text = "AI Pencil test notes, begun \(startedAt), \(String(format: "%.1f", lasted)) s long\n"
        text += "Each line: [seconds since the mark appeared, time of day] what the app did.\n"
        text += "\n---- timeline ----\n" + timeline.joined(separator: "\n")
        text += "\n\n---- diagnostics when the notes ended ----\n" + Diagnostics.shared.report + "\n"
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        Self.share([file])
    }

    /// The view controller on top of everything this app shows.
    private static func top() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first { $0.isKeyWindow } ?? windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private static func share(_ items: [Any]) {
        guard let from = top() else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // (On an iPad the sheet is a popover and has to be told where it comes from.)
        sheet.popoverPresentationController?.sourceView = from.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: from.view.bounds.midX, y: 60, width: 1, height: 1)
        sheet.popoverPresentationController?.permittedArrowDirections = [.up]
        from.present(sheet, animated: true)
    }
}

/// Shown at the top of the screen while a test's notes are being taken: a touch ends them and brings up
/// the sheet to share the file.
struct RecordingPill: View {
    @ObservedObject private var recorder = TestRecorder.shared

    var body: some View {
        if recorder.recording {
            Button {
                recorder.stop()
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                    Text("기록 중 · 눌러서 끝내기")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.78), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityLabel("테스트 기록 끝내기")
        }
    }
}
