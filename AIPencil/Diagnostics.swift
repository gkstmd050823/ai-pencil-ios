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
    /// Asked for how the page view on screen is put together, when the diagnostics text is made.
    var viewAsked: (() -> String)?
    private var started = false
    private var watching: [NSObjectProtocol] = []
    /// The notes file is written from one queue only: notes come from the main thread, from the system's
    /// reports (which arrive on a thread of their own) and from the thread that watches for a stuck app.
    private let writing = DispatchQueue(label: "app.aipencil.diagnostics", qos: .utility)
    /// The last things the app did, newest last, and when the main thread last answered.
    private let lock = NSLock()
    private var steps: [String] = []
    private var beat = CACurrentMediaTime()
    /// When this run began, and how long it had been going when it was last seen alive.
    private let launched = Date()
    private var alive = 0
    /// The steps of this run, written out as they happen: after a crash they are all that is left of
    /// it, and the next run reads them to say what the app was doing when it went down.
    private var stepsFile: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("steps.txt")
    }
    private var stuckNoted = false

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
        let notes = self.notes
        writing.async {
            if let handle = try? FileHandle(forWritingTo: notes) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: notes)
            }
        }
    }

    /// Something the app just did, in a few words. The last of these are written down when the app is
    /// found stuck, to say what it was in the middle of. Cheap enough to call from anywhere.
    func step(_ what: String) {
        lock.lock()
        steps.append(String(format: "+%.0fs ", Date().timeIntervalSince(launched)) + what)
        if steps.count > 16 { steps.removeFirst(steps.count - 16) }
        lock.unlock()
        keepSteps()
    }

    /// Writes the steps of this run to their file, with how long the run has lasted.
    private func keepSteps() {
        lock.lock()
        let text = "lasted \(alive) s; " + steps.joined(separator: " | ")
        lock.unlock()
        let file = stepsFile
        writing.async { try? text.write(to: file, atomically: false, encoding: .utf8) }
    }

    /// A thread of its own asks the main thread to answer once a second. When it has not answered for
    /// three seconds the app is stuck (what the user sees as a freeze, and what the system ends as a
    /// "watchdog" kill): that, and what the app last did, is noted once per freeze. Nothing is noted while
    /// the app is in the background, where the main thread is not run.
    private func watchForStuck() {
        let me = self
        let thread = Thread {
            var looked = CACurrentMediaTime()
            while true {
                Thread.sleep(forTimeInterval: 1)
                DispatchQueue.main.async {
                    me.lock.lock()
                    me.beat = CACurrentMediaTime()
                    me.stuckNoted = false
                    me.lock.unlock()
                }
                // (How long the run has lasted is written down every five seconds.)
                let lasted = Int(Date().timeIntervalSince(me.launched))
                if lasted / 5 != me.alive / 5 {
                    me.lock.lock()
                    me.alive = lasted
                    me.lock.unlock()
                    me.keepSteps()
                }
                let now = CACurrentMediaTime()
                // (This thread itself held up for longer than its nap: the whole app was, in the
                // background. That is not a freeze, and the count starts again.)
                let held = now - looked > 2.5
                looked = now
                me.lock.lock()
                if held { me.beat = now }
                let silent = now - me.beat
                let fresh = silent > 3 && !me.stuckNoted
                if fresh { me.stuckNoted = true }
                let last = me.steps
                me.lock.unlock()
                if fresh {
                    let text = String(format: "the app did not answer for %.0f s; the last it did: ", silent)
                    me.note(text + last.suffix(8).joined(separator: " | "))
                }
            }
        }
        thread.name = "app.aipencil.stuck"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func setOnScreen(_ value: Bool) {
        lock.lock()
        beat = CACurrentMediaTime()
        lock.unlock()
        defaults.set(value, forKey: "diag.onScreen")
        step(value ? "on screen" : "off screen")
    }

    /// Called once, when the app starts.
    func start() {
        guard !started else { return }
        started = true
        // The mark was set while the app was on screen and is taken down whenever it leaves the screen.
        // Still set now, the last run ended on screen: it crashed, was stopped by the system, or was
        // swiped away while in use.
        let before = (try? String(contentsOf: stepsFile, encoding: .utf8)) ?? "nothing kept of it"
        if defaults.bool(forKey: "diag.onScreen") {
            bump("diag.cutShort")
            note("the run before this one ended while the app was on screen; it " + before)
        }
        bump("diag.launches")
        defaults.set(true, forKey: "diag.onScreen")
        step("started")
        let center = NotificationCenter.default
        watching.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setOnScreen(false)
        })
        watching.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setOnScreen(false)
        })
        watching.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setOnScreen(true)
        })
        watching.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.step("leaving the front")
        })
        watching.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.step("at the front")
        })
        watchForStuck()
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
    ///
    /// The system calls this on a thread of its own. The counts are kept in the app's settings store,
    /// and the screens watch that store: a count written from this thread had them redraw from this
    /// thread, at the same time as the main thread was drawing them. (0.7.1 did that, and its three
    /// reported crashes and freezes all ended inside the code that draws the screens; two of them came
    /// within minutes of a report being handed over.) So the text is put together here and everything
    /// that touches the store is done on the main thread.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var lines: [String] = []
        var crashes = 0, hangs = 0
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                crashes += 1
                var line = "crash in version \(crash.metaData.applicationBuildVersion):"
                if let type = crash.exceptionType { line += " exception \(type)" }
                if let code = crash.exceptionCode { line += " code \(code)" }
                if let signal = crash.signal { line += " signal \(signal)" }
                if let reason = crash.terminationReason { line += " (\(reason))" }
                lines.append(line)
                lines.append("  where: " + Self.frames(of: crash.callStackTree))
            }
            for hang in payload.hangDiagnostics ?? [] {
                hangs += 1
                let seconds = hang.hangDuration.converted(to: .seconds).value
                lines.append(String(format: "hang of %.1f s; where: ", seconds) + Self.frames(of: hang.callStackTree))
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for _ in 0..<crashes { self.bump("diag.crashes") }
            for _ in 0..<hangs { self.bump("diag.hangs") }
            lines.forEach { self.note($0) }
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

    /// The frames of the thread a report is about, innermost first: which library, and how far into it.
    /// All of them, down to where the thread began: the first twenty-four of 0.7.1's reports were all
    /// inside the system and never reached the app's own code. A run of frames that repeats (a function
    /// calling itself down the views) is written once with a count, and every frame of the app's own is
    /// kept, since those are the ones that can be looked up afterwards.
    private static func frames(of tree: MXCallStackTree) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]]
        else { return "unknown" }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        var names: [String] = []
        while let here = frame, names.count < 400 {
            let name = here["binaryName"] as? String ?? "?"
            let offset = (here["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            names.append("\(name)+\(offset)")
            frame = (here["subFrames"] as? [[String: Any]])?.first
        }
        guard !names.isEmpty else { return "unknown" }
        // Runs of one or two frames repeating are folded.
        var parts: [String] = []
        var at = 0
        while at < names.count {
            var folded = false
            for span in [1, 2] where at + 2 * span <= names.count {
                var times = 1
                let first = names[at..<(at + span)]
                while at + (times + 1) * span <= names.count {
                    let from = at + times * span
                    guard names[from..<(from + span)].elementsEqual(first) else { break }
                    times += 1
                }
                if times >= 3 {
                    parts.append("(" + names[at..<(at + span)].joined(separator: " > ") + ") x\(times)")
                    at += times * span
                    folded = true
                    break
                }
            }
            if !folded {
                parts.append(names[at])
                at += 1
            }
        }
        // The innermost thirty, the app's own wherever they are, and the outermost six.
        let own = Bundle.main.executableURL?.lastPathComponent ?? "AIPencil"
        var kept: [String] = []
        for (index, part) in parts.enumerated() {
            if index < 30 || index >= parts.count - 6 || part.contains(own + "+") {
                kept.append(part)
            } else if kept.last != "..." {
                kept.append("...")
            }
        }
        return kept.joined(separator: " > ") + " [\(names.count) frames]"
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
        lines.append("settings: dark paper \(flag("darkPaper")), finger writes \(defaults.bool(forKey: "fingerDraws")), theme \(defaults.string(forKey: "theme") ?? "system")")
        lock.lock()
        let last = steps
        lock.unlock()
        lines.append("last steps: " + last.suffix(16).joined(separator: " | "))
        lines.append("")
        if let seen = viewAsked?(), !seen.isEmpty {
            lines.append("page view as last seen:")
            lines.append(seen)
            lines.append("")
        }
        // (Whatever is still on its way to the file is written first.)
        writing.sync {}
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
        let notes = self.notes
        writing.async { try? FileManager.default.removeItem(at: notes) }
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

/// Measures, for the build server, what writing costs the app: how evenly frames come while a line is
/// being written, how old each touch is by the time the app has dealt with it, and how long the app takes
/// over a line once the pen has lifted. These are the parts of a pen's delay that the app has a hand in;
/// what PencilKit and the screen add on an iPad is not seen from here. A debug build notes the figures in
/// its log; a release build has none of this.
enum Feel {
    #if DEBUG
    private final class Watch: NSObject {
        var link: CADisplayLink?
        var lastFrame: CFTimeInterval = 0
        var gaps: [Double] = []
        var ages: [Double] = []
        var writing = false

        @objc func frame(_ link: CADisplayLink) {
            guard writing else {
                lastFrame = 0
                return
            }
            if lastFrame > 0 { gaps.append((link.timestamp - lastFrame) * 1000) }
            lastFrame = link.timestamp
        }
    }

    private static let watch = Watch()

    private static func middle(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }
    #endif

    /// A line is begun.
    static func begin() {
        #if DEBUG
        if watch.link == nil {
            let link = CADisplayLink(target: watch, selector: #selector(Watch.frame(_:)))
            link.add(to: .main, forMode: .common)
            watch.link = link
        }
        watch.gaps = []
        watch.ages = []
        watch.lastFrame = 0
        watch.writing = true
        #endif
    }

    /// A touch that happened at [time] has been dealt with just now.
    static func dealt(with time: TimeInterval) {
        #if DEBUG
        if watch.writing { watch.ages.append((CACurrentMediaTime() - time) * 1000) }
        #endif
    }

    /// The line is over. (What it was is only put into words in a debug build.)
    static func end(_ what: @autoclosure () -> String) {
        #if DEBUG
        guard watch.writing else { return }
        watch.writing = false
        let gaps = watch.gaps, ages = watch.ages
        guard gaps.count > 3 else { return }
        let late = gaps.filter { $0 > 25 }.count
        DebugLog.write(String(
            format: "feel: %@: %d frames, a frame every %.1f ms (longest %.1f, %d over 25); %d touches dealt with %.1f ms after they happened (longest %.1f)",
            what(), gaps.count, middle(gaps), gaps.max() ?? 0, late, ages.count, middle(ages), ages.max() ?? 0
        ))
        #endif
    }

    /// Notes how long a piece of work on the main thread took.
    static func took(_ what: String, since start: CFTimeInterval, lines: Int) {
        #if DEBUG
        DebugLog.write(String(format: "feel: %@ took %.2f ms on a page of %d lines", what, (CACurrentMediaTime() - start) * 1000, lines))
        #endif
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
