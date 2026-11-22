// blink: a tiny menu bar dot that tells you when Claude Code sessions are done.
//
// Claude Code hooks (hooks/hook.sh) keep one small file per session in
// ~/.claude/blink/sessions. This app watches that folder (no polling),
// shows a dot in the menu bar, drops a card under it when a session is done or
// needs you, and jumps to the session's window or tab when you click it.

import AppKit
import ApplicationServices
import ServiceManagement

// MARK: - Model (pure; covered by tests/main.swift)

enum SessionState: String { case running, done, needs, idle }

enum Host: Equatable { case terminal, vscodeTerminal, vscodePanel, other }

struct Session: Equatable {
    var id: String
    var state: SessionState
    var pid: pid_t = 0
    var entry = ""
    var term = ""
    var ssePort = ""
    var bundleId = ""
    var projectDir = ""
    var message = ""
    var label = ""
    var since = Date()

    var folder: String {
        let name = (projectDir as NSString).lastPathComponent
        return name.isEmpty ? "Claude Code" : name
    }

    var host: Host {
        if entry == "claude-vscode" { return .vscodePanel }
        if term == "vscode" { return .vscodeTerminal }
        if term == "Apple_Terminal" { return .terminal }
        return .other
    }
}

/// Splits a session file into its metadata line and JSON payload.
private func splitFile(_ contents: Data) -> (fields: [String], payload: [String: Any])? {
    guard let text = String(data: contents, encoding: .utf8) else { return nil }
    let head: Substring, body: Substring
    if let nl = text.firstIndex(of: "\n") {
        head = text[..<nl]
        body = text[text.index(after: nl)...]
    } else {
        head = Substring(text)
        body = ""
    }
    let fields = head.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    let payload = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    return (fields, payload)
}

func parseSession(id: String, contents: Data, mtime: Date) -> Session? {
    guard let (f, payload) = splitFile(contents),
          let state = SessionState(rawValue: f.first ?? "") else { return nil }
    func field(_ i: Int) -> String { i < f.count ? f[i] : "" }

    var message = ""
    switch state {
    case .done:
        message = payload["last_assistant_message"] as? String ?? ""
    case .needs:
        if let m = payload["message"] as? String {
            message = m
        } else if let input = payload["tool_input"] as? [String: Any],
                  let questions = input["questions"] as? [[String: Any]],
                  let q = questions.first?["question"] as? String {
            message = q
        }
    case .running:
        message = payload["prompt"] as? String ?? ""
    case .idle:
        break
    }
    var dir = field(6)
    if dir.isEmpty { dir = payload["cwd"] as? String ?? "" }
    return Session(id: id, state: state, pid: pid_t(field(1)) ?? 0, entry: field(2), term: field(3),
                   ssePort: field(4), bundleId: field(5), projectDir: dir,
                   message: snippet(message), since: mtime)
}

/// The first prompt of a session (from its `.first` file), shortened.
func parseLabel(_ contents: Data) -> String {
    snippet(splitFile(contents)?.payload["prompt"] as? String ?? "", max: 40)
}

/// First meaningful line of some markdown-ish text, without the markup.
func snippet(_ text: String, max: Int = 160) -> String {
    for raw in text.split(whereSeparator: \.isNewline) {
        var line = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        line = line.trimmingCharacters(in: .whitespaces)
        while let c = line.first, "#>*-".contains(c) { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.count > max { line = String(line.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" }
        return line
    }
    return ""
}

func summaryLine(_ sessions: [Session]) -> String {
    func count(_ s: SessionState) -> Int { sessions.filter { $0.state == s }.count }
    var parts: [String] = []
    if count(.done) > 0 { parts.append("\(count(.done)) done") }
    if count(.running) > 0 { parts.append("\(count(.running)) running") }
    if count(.needs) > 0 { parts.append("\(count(.needs)) needs you") }
    return parts.isEmpty ? "No sessions" : parts.joined(separator: " · ")
}

func ago(_ date: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func stateWord(_ s: SessionState) -> String {
    switch s {
    case .done: return "done"
    case .running: return "running"
    case .needs: return "needs you"
    case .idle: return ""
    }
}

enum Dot: Equatable { case empty, done(Int), needs }

func dot(for sessions: [Session]) -> Dot {
    if sessions.contains(where: { $0.state == .needs }) { return .needs }
    let done = sessions.filter { $0.state == .done }.count
    return done > 0 ? .done(done) : .empty
}

/// Sessions that just became done or need you. Each one gets a card.
func freshAlerts(old: [String: Session], new: [String: Session]) -> [Session] {
    new.values.filter { s in
        guard s.state == .done || s.state == .needs else { return false }
        guard let o = old[s.id] else { return true }
        return o.state != s.state || o.since != s.since
    }.sorted { $0.since > $1.since }
}

/// Panel order: needs you, then done (newest first), then running (oldest first).
func panelOrder(_ sessions: [Session]) -> [Session] {
    func rank(_ s: SessionState) -> Int { s == .needs ? 0 : s == .done ? 1 : 2 }
    return sessions.filter { $0.state != .idle }.sorted { a, b in
        if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
        return a.state == .running ? a.since < b.since : a.since > b.since
    }
}

/// Sessions that share a folder are told apart by their first prompt. Returns
/// the label to show next to the folder name ("" when the folder is unique).
func rowLabels(_ sessions: [Session]) -> [String: String] {
    var count: [String: Int] = [:]
    for s in sessions { count[s.folder, default: 0] += 1 }
    var labels: [String: String] = [:]
    for s in sessions { labels[s.id] = (count[s.folder] ?? 0) > 1 ? s.label : "" }
    return labels
}

/// VS Code window titles look like "file.py — project". Does this one show `folder`?
func titleShowsFolder(_ title: String, _ folder: String) -> Bool {
    title.components(separatedBy: " — ").contains { $0.trimmingCharacters(in: .whitespaces) == folder }
}

/// VS Code logs "Extension host with pid N started" per window; that maps an
/// extension host process to the `windowId` VS Code accepts on its URLs.
func vscodeWindowId(extHostPid: pid_t, logsRoot: URL, notBefore: Date? = nil) -> Int? {
    let fm = FileManager.default
    guard let runs = try? fm.contentsOfDirectory(atPath: logsRoot.path) else { return nil }
    let needle = Data("Extension host with pid \(extHostPid) started".utf8)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyyMMdd'T'HHmmss"
    for run in runs.sorted(by: >).prefix(6) {
        if let nb = notBefore, let d = fmt.date(from: run), d < nb.addingTimeInterval(-120) { continue }
        let dir = logsRoot.appendingPathComponent(run)
        guard let windows = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
        for w in windows where w.hasPrefix("window") {
            guard let n = Int(w.dropFirst(6)) else { continue }
            let log = dir.appendingPathComponent(w).appendingPathComponent("exthost/exthost.log")
            if let data = try? Data(contentsOf: log, options: .mappedIfSafe), data.range(of: needle) != nil {
                return n
            }
        }
    }
    return nil
}

// MARK: - Processes

private func procInfo(_ pid: pid_t) -> kinfo_proc? {
    guard pid > 0 else { return nil }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
}

func parentPid(_ pid: pid_t) -> pid_t? {
    guard let p = procInfo(pid)?.kp_eproc.e_ppid, p > 1 else { return nil }
    return p
}

func startTime(_ pid: pid_t) -> Date? {
    guard let tv = procInfo(pid)?.kp_proc.p_starttime, tv.tv_sec > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
}

func ttyPath(_ pid: pid_t) -> String? {
    guard let dev = procInfo(pid)?.kp_eproc.e_tdev, dev != -1,
          let name = devname(dev, S_IFCHR) else { return nil }
    let s = String(cString: name)
    return s == "??" ? nil : "/dev/" + s
}

func isAlive(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return true }  // unknown pid: rely on SessionEnd instead
    return kill(pid, 0) == 0 || errno == EPERM
}

func bootTime() -> Date {
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return .distantPast }
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
}

// MARK: - Store: watches the sessions folder

final class Store {
    let dir: URL
    private(set) var sessions: [String: Session] = [:]
    /// Called on the main queue after every change, with the sessions that just
    /// became done or need you.
    var onChange: (([Session]) -> Void)?

    private var parsed: [String: (Date, Session)] = [:]
    private var labels: [String: (Date, String)] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]
    private var scheduled = false
    private let booted = bootTime()

    init(dir: URL) { self.dir = dir }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleRescan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        rescan(initial: true)
    }

    private func scheduleRescan() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.scheduled = false
            self?.rescan(initial: false)
        }
    }

    private func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func rescan(initial: Bool = false) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        var next: [String: Session] = [:]
        var live = Set<String>()
        for name in names where name.hasSuffix(".state") && !name.hasPrefix(".") {
            let id = String(name.dropLast(6))
            let url = dir.appendingPathComponent(name)
            guard let m = mtime(url) else { continue }
            var s: Session
            if let (cachedTime, cached) = parsed[id], cachedTime == m {
                s = cached
            } else {
                guard let data = try? Data(contentsOf: url),
                      let p = parseSession(id: id, contents: data, mtime: m) else { continue }
                parsed[id] = (m, p)
                s = p
            }
            if m < booted || !isAlive(s.pid) {  // crashed or from before a reboot
                removeFiles(id)
                continue
            }
            live.insert(id)
            s.label = label(id)
            next[id] = s
        }
        for name in names where name.hasSuffix(".first") && !live.contains(String(name.dropLast(6))) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        parsed = parsed.filter { live.contains($0.key) }
        labels = labels.filter { live.contains($0.key) }

        let fresh = initial ? [] : freshAlerts(old: sessions, new: next)
        sessions = next
        watchExits()
        onChange?(fresh)
    }

    private func label(_ id: String) -> String {
        let url = dir.appendingPathComponent(id + ".first")
        guard let m = mtime(url) else { return "" }
        if let (t, l) = labels[id], t == m { return l }
        let l = (try? Data(contentsOf: url)).map(parseLabel) ?? ""
        labels[id] = (m, l)
        return l
    }

    /// kqueue tells us when a session's process exits; no polling.
    private func watchExits() {
        let pids = Set(sessions.values.map(\.pid).filter { $0 > 0 })
        for (pid, w) in exitWatchers where !pids.contains(pid) {
            w.cancel()
            exitWatchers[pid] = nil
        }
        for pid in pids where exitWatchers[pid] == nil {
            let w = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            w.setEventHandler { [weak self] in self?.scheduleRescan() }
            w.resume()
            exitWatchers[pid] = w
        }
    }

    private func removeFiles(_ id: String) {
        for ext in ["state", "first"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).\(ext)"))
        }
    }

    /// Clears a done (or needs-you) session from the list. It comes back as
    /// running the next time you send it a prompt.
    func dismiss(_ id: String) {
        let url = dir.appendingPathComponent(id + ".state")
        guard var text = try? String(contentsOf: url, encoding: .utf8),
              let end = text.firstIndex(where: { $0 == "\t" || $0 == "\n" }) else { return }
        text.replaceSubrange(text.startIndex..<end, with: SessionState.idle.rawValue)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        sessions[id]?.state = .idle
        onChange?([])
    }
}

// MARK: - Jumping to a session

enum Focus {
    static let companionURL = "yashpincha.blink/focus"

    private static func editor(_ bundleId: String) -> (scheme: String, logs: String) {
        switch bundleId {
        case "com.microsoft.VSCodeInsiders": return ("vscode-insiders", "Code - Insiders")
        case "com.todesktop.230313mzl4w4u92": return ("cursor", "Cursor")
        default: return ("vscode", "Code")
        }
    }

    private static func logsRoot(_ bundleId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(editor(bundleId).logs)/logs")
    }

    static func open(_ s: Session) {
        switch s.host {
        case .terminal:
            if let tty = ttyPath(s.pid), terminalSelect(tty: tty) { return }
            activate(bundleId: "com.apple.Terminal")
        case .vscodeTerminal:
            vscodeTerminal(s)
        case .vscodePanel:
            vscodePanel(s)
        case .other:
            activate(bundleId: s.bundleId)
        }
    }

    // VS Code terminal: the session's IDE port → the extension host listening on
    // it → that window's id. The companion extension then shows the terminal.
    private static func vscodeTerminal(_ s: Session) {
        let lock = ideLock(port: s.ssePort)
        DispatchQueue.global(qos: .userInitiated).async {
            let extHost = listeningPid(port: s.ssePort)
            let mainPid = lock?.pid ?? extHost.flatMap(parentPid)
            let window = extHost.flatMap {
                vscodeWindowId(extHostPid: $0, logsRoot: logsRoot(s.bundleId), notBefore: mainPid.flatMap(startTime))
            }
            var pids = [s.pid]
            if let p = parentPid(s.pid) { pids.append(p); if let pp = parentPid(p) { pids.append(pp) } }
            let query = pids.map { "pid=\($0)" }.joined(separator: "&")
            let url = "\(editor(s.bundleId).scheme)://\(companionURL)?\(query)"
            DispatchQueue.main.async {
                openEditorURL(url, window: window, folder: lock?.folder ?? s.projectDir, bundleId: s.bundleId)
            }
        }
    }

    // VS Code Claude panel: claude's parent is the window's extension host.
    private static func vscodePanel(_ s: Session) {
        let extHost = parentPid(s.pid)
        let window = extHost.flatMap {
            vscodeWindowId(extHostPid: $0, logsRoot: logsRoot(s.bundleId), notBefore: parentPid($0).flatMap(startTime))
        }
        let url = "\(editor(s.bundleId).scheme)://anthropic.claude-code/open?session=\(s.id)"
        openEditorURL(url, window: window, folder: s.projectDir, bundleId: s.bundleId)
    }

    /// With a window id, VS Code routes the URL to that window and raises it.
    /// Without one, raise the folder's window first so the URL lands there.
    private static func openEditorURL(_ url: String, window: Int?, folder: String, bundleId: String) {
        if let w = window, let u = URL(string: "\(url)&windowId=\(w)") {
            NSWorkspace.shared.open(u)
            return
        }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId.isEmpty ? "com.microsoft.VSCode" : bundleId)
        if let app, !folder.isEmpty {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
    }

    private static func ideLock(port: String) -> (pid: pid_t, folder: String)? {
        guard !port.isEmpty else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ide/\(port).lock")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let folder = (json["workspaceFolders"] as? [String])?.first ?? ""
        return (pid_t(json["pid"] as? Int ?? 0), folder)
    }

    private static func listeningPid(port: String) -> pid_t? {
        guard Int(port) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    static func activate(bundleId: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate()
    }

    // Terminal.app: select the tab whose tty is the session's.
    private static func terminalSelect(tty: String) -> Bool {
        let src = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set miniaturized of w to false
                set selected tab of w to t
                set index of w to 1
                activate
                return true
              end if
            end repeat
          end repeat
        end tell
        return false
        """
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err).booleanValue ?? false
    }

    // MARK: Already looking at it?

    static func isLookingAt(_ s: Session) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        switch s.host {
        case .terminal:
            guard front.bundleIdentifier == "com.apple.Terminal", let tty = ttyPath(s.pid) else { return false }
            var err: NSDictionary?
            let src = #"tell application "Terminal" to return tty of selected tab of front window"#
            return NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue == tty
        case .vscodeTerminal, .vscodePanel:
            guard front.bundleIdentifier == s.bundleId,
                  let title = focusedWindowTitle(front.processIdentifier) else { return false }
            let folder = ideLock(port: s.ssePort)?.folder ?? s.projectDir
            return titleShowsFolder(title, (folder as NSString).lastPathComponent)
        case .other:
            return false
        }
    }

    private static func focusedWindowTitle(_ pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
}

// MARK: - Look: monochrome, Ollama-inspired

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum Palette {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { ap in
            NSColor(hex: ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }
    static let background = pair(0xFFFFFF, 0x161616)
    static let border = pair(0xE5E5E5, 0x2C2C2C)
    static let text = pair(0x0A0A0A, 0xF5F5F5)
    static let secondary = pair(0x737373, 0x9B9B9B)
    static let hover = pair(0xF4F4F4, 0x232323)
}

private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor, digits: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

/// Menu bar images: ○ nothing waiting, ● done, ◐ needs you. Template images,
/// so macOS tints them for the menu bar. Drawn once, then cached.
enum DotImage {
    private static func make(_ kind: Int) -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let c = NSRect(x: 2.5, y: 2.5, width: 9, height: 9)
            let ring = NSBezierPath(ovalIn: c.insetBy(dx: 0.65, dy: 0.65))
            ring.lineWidth = 1.3
            NSColor.black.set()
            switch kind {
            case 1:
                NSBezierPath(ovalIn: c).fill()
            case 2:
                ring.stroke()
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: c.minX, y: c.minY, width: c.width / 2, height: c.height).clip()
                NSBezierPath(ovalIn: c).fill()
                NSGraphicsContext.restoreGraphicsState()
            default:
                ring.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
    static let empty = make(0), done = make(1), needs = make(2)
}

final class GlyphView: NSView {
    private let state: SessionState

    init(_ state: SessionState, pulse: Bool) {
        self.state = state
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if pulse && state == .running {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.3
            a.duration = 1.1
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(a, forKey: "pulse")
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let c = bounds
        let ring = NSBezierPath(ovalIn: c.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        Palette.text.set()
        switch state {
        case .done:
            NSBezierPath(ovalIn: c).fill()
        case .running:
            ring.stroke()
        case .needs:
            ring.stroke()
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: c.minX, y: c.minY, width: c.width / 2, height: c.height).clip()
            NSBezierPath(ovalIn: c).fill()
            NSGraphicsContext.restoreGraphicsState()
        case .idle:
            break
        }
    }
}

final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One session: glyph, title, "done · 4m", and a one-line snippet underneath.
final class RowView: NSView {
    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    private let time: NSTextField
    private var close: FirstClickButton?
    private var hovering = false {
        didSet {
            needsDisplay = true
            close?.isHidden = !hovering
            time.isHidden = hovering && close != nil
        }
    }

    init(_ s: Session, label: String, now: Date, pulse: Bool) {
        time = makeLabel("\(stateWord(s.state)) · \(ago(s.since, now: now))", size: 11.5,
                         color: Palette.secondary, digits: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        let glyph = GlyphView(s.state, pulse: pulse)
        let name = makeLabel(s.folder, size: 13, weight: .medium, color: Palette.text)
        if !label.isEmpty {  // folder in bold, then the first prompt in gray
            let t = NSMutableAttributedString(string: s.folder, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Palette.text])
            t.append(NSAttributedString(string: "  " + label, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.secondary]))
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            t.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: t.length))
            name.attributedStringValue = t
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [glyph, name, time] as [NSView] { addSubview(v) }

        var constraints = [
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            glyph.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 8),
            glyph.heightAnchor.constraint(equalToConstant: 8),
            name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 11),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -10),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ]

        let detailText = s.state == .running ? "" : s.message
        if detailText.isEmpty {
            constraints.append(name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8))
        } else {
            let detail = makeLabel(detailText, size: 12, color: Palette.secondary)
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(detail)
            constraints += [
                detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -11),
                detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
                detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ]
        }

        if s.state == .done || s.state == .needs {
            let b = FirstClickButton()
            b.isBordered = false
            b.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            b.contentTintColor = Palette.secondary
            b.target = self
            b.action = #selector(dismissTapped)
            b.isHidden = true
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            constraints += [
                b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
                b.centerYAnchor.constraint(equalTo: name.centerYAnchor),
                b.widthAnchor.constraint(equalToConstant: 18),
                b.heightAnchor.constraint(equalToConstant: 18),
            ]
            close = b
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func dismissTapped() { onDismiss?() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = hovering ? Palette.hover.cgColor : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

final class CardView: NSView {
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Palette.background.cgColor
        layer?.borderColor = Palette.border.cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The borderless panel under the dot. It never takes focus from your app.
final class DropPanel: NSPanel {
    static let width: CGFloat = 320
    let card = CardView()
    private let stack = NSStackView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Keep project names and Claude's messages out of screen shares.
        sharingType = UserDefaults.standard.bool(forKey: "allowCapture") ? .readOnly : .none

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        contentView = card
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setRows(_ rows: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
        }
        stack.layoutSubtreeIfNeeded()
        var f = frame
        let h = ceil(stack.fittingSize.height)
        f.origin.y += f.height - h  // keep the top edge in place
        f.size = NSSize(width: Self.width, height: h)
        setFrame(f, display: true)
        invalidateShadow()
    }

    /// Centers the panel under the status item, just below the menu bar.
    func place(under button: NSStatusBarButton) {
        guard let item = button.window, let screen = item.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var x = item.frame.midX - frame.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - frame.width - 8)
        setFrameOrigin(NSPoint(x: x, y: vf.maxY - 6 - frame.height))
    }
}

/// Text rows inside the panel: the summary header and "+N more".
private func textRow(_ text: String, top: CGFloat, bottom: CGFloat) -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    let l = makeLabel(text, size: 12, color: Palette.secondary)
    v.addSubview(l)
    NSLayoutConstraint.activate([
        l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 11),
        l.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -11),
        l.topAnchor.constraint(equalTo: v.topAnchor, constant: top),
        l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -bottom),
    ])
    return v
}

/// Rows for the card (`card` = the session ids to show) or, with `card: nil`,
/// the full summary panel.
func panelRows(_ sessions: [String: Session], card: [String]?, now: Date,
               onOpen: @escaping (Session) -> Void, onDismiss: @escaping (Session) -> Void) -> [NSView] {
    let all = Array(sessions.values)
    let ordered = panelOrder(all)
    let labels = rowLabels(ordered)
    func row(_ s: Session, pulse: Bool) -> RowView {
        let r = RowView(s, label: labels[s.id] ?? "", now: now, pulse: pulse)
        r.onClick = { onOpen(s) }
        r.onDismiss = { onDismiss(s) }
        return r
    }
    if let card {
        return card.compactMap { sessions[$0] }.map { row($0, pulse: false) }
    }
    let maxRows = 10
    var rows: [NSView] = [textRow(summaryLine(all), top: 7, bottom: ordered.isEmpty ? 7 : 3)]
    rows += ordered.prefix(maxRows).map { row($0, pulse: true) }
    if ordered.count > maxRows {
        rows.append(textRow("+\(ordered.count - maxRows) more", top: 3, bottom: 6))
    }
    return rows
}

/// Developer aid: `blink --preview <dir>` renders the card and the panel,
/// light and dark, to PNGs (no screen-recording permission needed).
func renderPreviews(to dir: String) {
    let now = Date()
    let sample = [
        Session(id: "1", state: .done, projectDir: "/x/proj",
                message: "Done. The cosine schedule with warmup beats step decay by 1.8% on val loss.",
                since: now.addingTimeInterval(-240)),
        Session(id: "2", state: .needs, projectDir: "/x/repo",
                message: "Claude needs your permission to use Bash", since: now.addingTimeInterval(-30)),
        Session(id: "3", state: .running, projectDir: "/x/sim", label: "Run the parameter sweep",
                since: now.addingTimeInterval(-720)),
        Session(id: "4", state: .running, projectDir: "/x/sim", label: "Plot the phase diagram",
                since: now.addingTimeInterval(-95)),
        Session(id: "5", state: .done, projectDir: "/x/website", message: "Shipped the new landing page copy.",
                since: now.addingTimeInterval(-3 * 3600)),
    ]
    let sessions = Dictionary(uniqueKeysWithValues: sample.map { ($0.id, $0) })
    for (look, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        for (kind, card) in [("card", ["1", "2"] as [String]?), ("panel", nil)] {
            let panel = DropPanel()
            panel.appearance = NSAppearance(named: name)
            panel.setRows(panelRows(sessions, card: card, now: now, onOpen: { _ in }, onDismiss: { _ in }))
            panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            guard let layer = panel.contentView?.layer else { continue }
            let pad: CGFloat = 24, scale: CGFloat = 2
            let size = CGSize(width: panel.frame.width + pad * 2, height: panel.frame.height + pad * 2)
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(look == "dark" ? NSColor(hex: 0x3A3A3C).cgColor : NSColor(hex: 0xD9D9DE).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.translateBy(x: pad, y: pad)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance { layer.render(in: ctx) }
            if let img = ctx.makeImage(),
               let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(kind)-\(look).png"))
            }
            panel.orderOut(nil)
        }
    }
}

// MARK: - Settings

enum Prefs {
    static var paused: Bool {
        get { UserDefaults.standard.bool(forKey: "paused") }
        set { UserDefaults.standard.set(newValue, forKey: "paused") }
    }
    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }
    static func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("blink: launch at login: \(error.localizedDescription)")
        }
    }
}

// MARK: - App

final class Controller: NSObject {
    private enum Mode { case hidden, card, summary }

    private let store: Store
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = DropPanel()
    private var mode = Mode.hidden
    private var pinned = false
    private var overDot = false
    private var overPanel = false
    private var cardIds: [String] = []
    private var hideWork: DispatchWorkItem?
    private var ticker: Timer?

    static let cardSeconds = 6.0
    static let maxCardRows = 3

    init(store: Store) {
        self.store = store
        super.init()
        item.autosaveName = "blink"
        item.behavior = []
        if let b = item.button {
            b.imagePosition = .imageLeft
            b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            b.target = self
            b.action = #selector(dotClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                             owner: self))
        }
        panel.card.onHover = { [weak self] inside in
            guard let self else { return }
            self.overPanel = inside
            if !inside { self.scheduleHide(after: self.mode == .card ? 1.5 : 0.3) }
        }
        store.onChange = { [weak self] fresh in self?.storeChanged(fresh) }
        updateDot()
    }

    // MARK: Dot

    private func updateDot() {
        guard let b = item.button else { return }
        switch dot(for: Array(store.sessions.values)) {
        case .empty: b.image = DotImage.empty; b.title = ""
        case .needs: b.image = DotImage.needs; b.title = ""
        case .done(let n): b.image = DotImage.done; b.title = " \(n)"
        }
        b.setAccessibilityLabel("blink: " + summaryLine(Array(store.sessions.values)))
    }

    @objc func mouseEntered(with event: NSEvent) {
        overDot = true
        if !pinned { show(.summary) }
    }

    @objc func mouseExited(with event: NSEvent) {
        overDot = false
        scheduleHide(after: 0.3)
    }

    @objc private func dotClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if pinned {
            pinned = false
            hide()
        } else {
            pinned = true
            show(.summary)
        }
    }

    // MARK: Store events

    private func storeChanged(_ fresh: [Session]) {
        updateDot()
        switch mode {
        case .summary:
            render()
        case .card, .hidden:
            // Cards only show sessions that still need attention.
            cardIds = cardIds.filter { id in
                guard let s = store.sessions[id] else { return false }
                return s.state == .done || s.state == .needs
            }
            let alerts = Prefs.paused ? [] : fresh.filter { !Focus.isLookingAt($0) }
            if !alerts.isEmpty {
                cardIds = Array((alerts.map(\.id) + cardIds.filter { id in !alerts.contains { $0.id == id } })
                    .prefix(Self.maxCardRows))
                show(.card)
                scheduleHide(after: Self.cardSeconds)
            } else if mode == .card {
                cardIds.isEmpty ? hide() : render()
            }
        }
    }

    // MARK: Panel

    private func show(_ m: Mode) {
        hideWork?.cancel()
        let wasHidden = mode == .hidden
        mode = m
        render()
        guard let b = item.button else { return }
        panel.place(under: b)
        if wasHidden {
            let target = panel.frame
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: target.minX, y: target.minY + 6))
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        ticker?.invalidate()
        ticker = nil
        if m == .summary {  // keep "running · 12m" honest while the panel is open
            ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.render() }
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pinned, !self.overDot, !self.overPanel else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hide() {
        hideWork?.cancel()
        ticker?.invalidate()
        ticker = nil
        guard mode != .hidden else { return }
        mode = .hidden
        cardIds = []
        overPanel = false
        let start = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
            panel.animator().setFrame(start.offsetBy(dx: 0, dy: 6), display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.mode == .hidden else { return }
            self.panel.orderOut(nil)
            self.panel.setRows([])  // drop views (and pulse animations) while hidden
        })
    }

    private func render() {
        guard mode != .hidden else { return }
        panel.setRows(panelRows(store.sessions, card: mode == .card ? cardIds : nil, now: Date(),
                                onOpen: { [weak self] s in self?.open(s) },
                                onDismiss: { [weak self] s in self?.store.dismiss(s.id) }))
        if let b = item.button { panel.place(under: b) }
    }

    private func open(_ s: Session) {
        Focus.open(s)
        if s.state == .done { store.dismiss(s.id) }
        if !pinned { hide() }
    }

    // MARK: Menu

    private func showMenu() {
        pinned = false
        hide()
        let menu = NSMenu()
        menu.addItem(withTitle: summaryLine(Array(store.sessions.values)), action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear done", action: #selector(clearDone), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = store.sessions.values.contains { $0.state == .done }
        let pause = menu.addItem(withTitle: "Pause popups", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = Prefs.paused ? .on : .off
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = Prefs.launchAtLogin ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit blink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func clearDone() {
        for s in store.sessions.values where s.state == .done { store.dismiss(s.id) }
    }
    @objc private func togglePause() { Prefs.paused.toggle() }
    @objc private func toggleLogin() { Prefs.setLaunchAtLogin(!Prefs.launchAtLogin) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store?
    private var controller: Controller?

    func applicationDidFinishLaunching(_ note: Notification) {
        let mine = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != mine }) {
            NSApp.terminate(nil)  // already running
            return
        }
        firstRun()
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/blink/sessions")
        let store = Store(dir: dir)
        controller = Controller(store: store)
        store.start()
        self.store = store
    }

    /// Defaults from the spec: launch at login on, and ask once for
    /// Accessibility (used only to read VS Code's front window title).
    private func firstRun() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "setupDone") else { return }
        d.set(true, forKey: "setupDone")
        Prefs.setLaunchAtLogin(true)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
}

#if !TESTING
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") { print("blink 0.1.0"); return }
        if args.contains("--unregister-login") { try? SMAppService.mainApp.unregister(); return }
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
            _ = NSApplication.shared
            renderPreviews(to: args[i + 1])
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
