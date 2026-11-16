import MetricKit
import PDFKit
import UIKit

/// What went wrong on this iPad, kept on the iPad. The app is built on a server and run in a simulator
/// there, so what happens on a real iPad is seen by no one but its user; this keeps count of the things
/// worth knowing (runs that ended while the app was on screen, warnings that memory was short, what the
/// system reports of crashes) and puts them together as text the user can copy and pass on. Nothing here
/// is ever sent anywhere by the app itself.
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = Diagnostics()

    private let defaults = UserDefaults.standard
    private var started = false
    private var watching: [NSObjectProtocol] = []

    private var notes: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("diagnostics.txt")
    }

    private func count(_ key: String) -> Int { defaults.integer(forKey: key) }

    private func bump(_ key: String) { defaults.set(defaults.integer(forKey: key) + 1, forKey: key) }

    private func stamp(_ date: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.string(from: date)
    }

    private func note(_ line: String) {
        let data = Data(("[\(stamp())] " + line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: notes) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: notes)
        }
    }

    /// Called once, when the app starts.
    func start() {
        guard !started else { return }
        started = true
        // The mark was set while the app was on screen and is taken down whenever it leaves the screen.
        // Still set now, the last run ended on screen: it crashed, was stopped by the system, or was
        // swiped away while in use.
        if defaults.bool(forKey: "diag.onScreen") {
            bump("diag.cutShort")
            note("the run before this one ended while the app was on screen")
        }
        bump("diag.launches")
        defaults.set(true, forKey: "diag.onScreen")
        let center = NotificationCenter.default
        watching.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.defaults.set(false, forKey: "diag.onScreen")
        })
        watching.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.defaults.set(false, forKey: "diag.onScreen")
        })
        watching.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.defaults.set(true, forKey: "diag.onScreen")
        })
        watching.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.bump("diag.memoryWarnings")
            let used = Self.footprint().map { "\($0 / 1_048_576) MB in use" } ?? "use unknown"
            self.note("memory warning, \(used)")
        })
        MXMetricManager.shared.add(self)
    }

    // MARK: what the system reports

    /// Crashes and hangs, as the system hands them over the next time the app runs.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                bump("diag.crashes")
                var line = "crash in version \(crash.metaData.applicationBuildVersion):"
                if let type = crash.exceptionType { line += " exception \(type)" }
                if let code = crash.exceptionCode { line += " code \(code)" }
                if let signal = crash.signal { line += " signal \(signal)" }
                if let reason = crash.terminationReason { line += " (\(reason))" }
                note(line)
                note("  where: " + Self.frames(of: crash.callStackTree))
            }
            for hang in payload.hangDiagnostics ?? [] {
                bump("diag.hangs")
                let seconds = hang.hangDuration.converted(to: .seconds).value
                note(String(format: "hang of %.1f s; where: ", seconds) + Self.frames(of: hang.callStackTree))
            }
        }
    }

    /// How the app's runs ended, counted by the system over a day.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics?.foregroundExitData else { continue }
            var parts: [String] = []
            parts.append("normal \(exits.cumulativeNormalAppExitCount)")
            parts.append("out of memory \(exits.cumulativeMemoryResourceLimitExitCount)")
            parts.append("bad access \(exits.cumulativeBadAccessExitCount)")
            parts.append("abnormal \(exits.cumulativeAbnormalExitCount)")
            parts.append("illegal instruction \(exits.cumulativeIllegalInstructionExitCount)")
            parts.append("watchdog \(exits.cumulativeAppWatchdogExitCount)")
            let span = stamp(payload.timeStampBegin) + " to " + stamp(payload.timeStampEnd)
            note("exits while on screen, " + span + ": " + parts.joined(separator: ", "))
        }
    }

    /// The first frames of the thread a report is about: which library, and how far into it.
    private static func frames(of tree: MXCallStackTree) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]]
        else { return "unknown" }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        var parts: [String] = []
        while let here = frame, parts.count < 24 {
            let name = here["binaryName"] as? String ?? "?"
            let offset = (here["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            parts.append("\(name)+\(offset)")
            frame = (here["subFrames"] as? [[String: Any]])?.first
        }
        return parts.isEmpty ? "unknown" : parts.joined(separator: " > ")
    }

    // MARK: for the settings screen

    /// How many runs ended while the app was on screen, and how many times memory ran short.
    var cutShort: Int { count("diag.cutShort") }
    var memoryWarnings: Int { count("diag.memoryWarnings") }
    var crashes: Int { count("diag.crashes") }

    /// Everything kept, as text to copy.
    var report: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        let device = UIDevice.current
        let screen = UIScreen.main
        let used = Self.footprint().map { "\($0 / 1_048_576) MB in use" } ?? "use unknown"
        var lines: [String] = []
        lines.append("AI Pencil \(version), \(device.systemName) \(device.systemVersion), \(Self.model())")
        lines.append("screen \(Int(screen.bounds.width)) x \(Int(screen.bounds.height)) points, scale \(screen.scale), native \(screen.nativeScale)")
        lines.append("memory: \(used), \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB in the device")
        lines.append("runs \(count("diag.launches")), ended while on screen \(cutShort), memory warnings \(memoryWarnings)")
        lines.append("crashes reported \(crashes), hangs reported \(count("diag.hangs"))")
        lines.append("settings: own pen \(flag("appPen")), own pictures \(flag("sharpPages")), dark paper \(flag("darkPaper")), finger writes \(defaults.bool(forKey: "fingerDraws"))")
        lines.append("")
        if let text = try? String(contentsOf: notes, encoding: .utf8) {
            // The newest notes; a long history is of no more use than its end.
            lines.append(contentsOf: text.split(separator: "\n").suffix(60).map(String.init))
        } else {
            lines.append("(nothing noted yet)")
        }
        return lines.joined(separator: "\n")
    }

    private func flag(_ key: String) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    func clear() {
        for key in ["diag.cutShort", "diag.memoryWarnings", "diag.crashes", "diag.hangs", "diag.launches"] {
            defaults.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: notes)
    }

    /// The kind of device, as the system names it ("iPad13,18").
    private static func model() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    /// The memory the app is charged with, in bytes: the figure the system holds against its limit.
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// Draws the small pictures of a document's pages on a queue of its own, from a copy of the document that
/// nothing else touches. (PDFKit's objects are not made to be shared between threads; the pages on show
/// belong to the main thread.)
final class ThumbnailSource {
    private let queue = DispatchQueue(label: "app.aipencil.thumbnails", qos: .userInitiated)
    private let url: URL
    private var document: PDFDocument?
    private let made = NSCache<NSNumber, UIImage>()

    init(url: URL) {
        self.url = url
    }

    /// The picture of a page, or nil if [stillWanted] says no by the time its turn comes (the page was
    /// scrolled out of the grid while it waited).
    func picture(of index: Int, size: CGSize, stillWanted: @escaping () -> Bool) async -> UIImage? {
        if let kept = made.object(forKey: NSNumber(value: index)) { return kept }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard stillWanted() else {
                    continuation.resume(returning: nil)
                    return
                }
                if self.document == nil {
                    self.document = DocFile.open(self.url, delegate: InkPageMaker.shared)
                }
                let picture = self.document?.page(at: index)?.thumbnail(of: size, for: .cropBox)
                if let picture { self.made.setObject(picture, forKey: NSNumber(value: index)) }
                continuation.resume(returning: picture)
            }
        }
    }
}
