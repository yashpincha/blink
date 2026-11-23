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
    var background = 0  // Claude stopped, but still waits on this many background tasks
    var transcript = ""  // Claude Code's transcript of the session (from the hook payload)

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
    guard let (f, payload) = splitFile(contents) else { return nil }
    // "agents": Claude finished its turn but still waits on background work
    // (agents, shells, monitors).
    // That's still running, not done.
    let waiting = f.first == "agents"
    guard let state = waiting ? .running : SessionState(rawValue: f.first ?? "") else { return nil }
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
        // Typed prompt: no detail (you know what you asked). Woken without a
        // prompt (a subagent reported back): what Claude last said.
        message = payload["last_assistant_message"] as? String ?? ""
    case .idle:
        break
    }
    var dir = field(6)
    if dir.isEmpty { dir = payload["cwd"] as? String ?? "" }
    var background = 0
    if waiting {
        let tasks = (payload["background_tasks"] as? [[String: Any]] ?? [])
            .filter { backgroundWork[$0["type"] as? String ?? ""] != nil }
        background = max(1, tasks.count)
        message = backgroundNote(tasks)
    }
    return Session(id: id, state: state, pid: pid_t(field(1)) ?? 0, entry: field(2), term: field(3),
                   ssePort: field(4), bundleId: field(5), projectDir: dir,
                   message: snippet(message), since: mtime, background: background,
                   transcript: payload["transcript_path"] as? String ?? "")
}

/// Background work Claude is still waiting on, by Claude Code's type names,
/// with how to say each. Agents, plus shells and monitors it started and is
/// watching: Claude wakes up when they finish, so the session isn't done.
/// Claude Code's own housekeeping (dreams, auto-mode scans) doesn't count.
let backgroundWork: [String: String] = [
    "subagent": "Subagent working", "workflow": "Workflow running", "teammate": "Teammate working",
    "cloud session": "Cloud session running", "shell": "Shell running", "monitor": "Monitor running",
    "MCP task": "MCP task running",
]

/// "Subagent working: Write the paper", "2 subagents working: …",
/// "3 background tasks: …".
func backgroundNote(_ tasks: [[String: Any]]) -> String {
    let what = tasks.compactMap { t -> String? in
        let desc = t["description"] as? String ?? "", cmd = t["command"] as? String ?? ""
        let d = desc.isEmpty ? cmd : desc
        return d.isEmpty ? nil : d
    }
    let types = Set(tasks.map { $0["type"] as? String ?? "" })
    let lead: String
    switch tasks.count {
    case 0: lead = "Working in the background"
    case 1: lead = backgroundWork[tasks[0]["type"] as? String ?? ""] ?? "Working in the background"
    default: lead = types == ["subagent"] ? "\(tasks.count) subagents working" : "\(tasks.count) background tasks"
    }
    return what.isEmpty ? lead : lead + ": " + what.joined(separator: ", ")
}

/// The first prompt of a session (from its `.first` file), shortened.
func parseLabel(_ contents: Data) -> String {
    snippet(typedText(splitFile(contents)?.payload["prompt"] as? String ?? ""), max: 40)
}

/// The part of a prompt you typed: pasted blocks dropped, and nothing at all
/// for messages Claude Code delivers as prompts (a subagent reporting back,
/// task notifications, slash-command output), which start with a tag.
func typedText(_ prompt: String) -> String {
    let t = prompt.replacingOccurrences(of: #"<pasted_content[^>]*>[\s\S]*?</pasted_content[^>]*>"#, with: " ",
                                        options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return t.hasPrefix("<") ? "" : t
}

/// The most telling line of a markdown-ish message, without the markup. Skips
/// headings, code blocks, tables and rules; a short opener like "Done." or
/// "Here's what changed:" borrows the line after it.
func snippet(_ text: String, max: Int = 160) -> String {
    func clean(_ raw: Substring) -> String {
        var line = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        line = line.trimmingCharacters(in: .whitespaces)
        while let c = line.first, "#>*-".contains(c) { line.removeFirst() }
        return line.trimmingCharacters(in: .whitespaces)
    }
    var heading = "", picked: [String] = [], inCode = false
    for raw in text.split(whereSeparator: \.isNewline) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") { inCode.toggle(); continue }
        if inCode || t.hasPrefix("|") || t.allSatisfy({ "-=*_ ".contains($0) }) { continue }
        let line = clean(raw)
        if line.isEmpty { continue }
        if t.hasPrefix("#") { if heading.isEmpty { heading = line }; continue }
        picked.append(line)
        let opener = line.count < 28 && [".", "!", ":"].contains(line.last ?? " ")
        if picked.count == 2 || !opener { break }
    }
    var out = picked.isEmpty ? heading : picked.joined(separator: " ")
    if out.count > max { out = String(out.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" }
    return out
}

func summaryLine(_ sessions: [Session]) -> String {
    func count(_ s: SessionState) -> Int { sessions.filter { $0.state == s }.count }
    var parts: [String] = []
    if count(.done) > 0 { parts.append("\(count(.done)) done") }
    if count(.running) > 0 { parts.append("\(count(.running)) running") }
    if count(.needs) > 0 { parts.append("\(count(.needs)) needs you") }
    return parts.isEmpty ? "No active sessions" : parts.joined(separator: " · ")
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

/// When a session last showed signs of life: the newest timestamped entry in
/// its transcript, or the newest file its subagents or tools wrote (they live
/// in a folder next to it). Only the transcript's tail is read. Untimestamped
/// bookkeeping lines that Claude Code appends to idle sessions don't count.
func lastActivity(transcript path: String) -> Date? {
    guard !path.isEmpty else { return nil }
    var latest: Date?
    if let h = FileHandle(forReadingAtPath: path) {
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let tail: UInt64 = 1 << 20
        try? h.seek(toOffset: size > tail ? size - tail : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        // Inside message text quotes are escaped, so this only matches entry fields.
        if let r = text.range(of: #""timestamp":""#, options: .backwards),
           let end = text[r.upperBound...].firstIndex(of: "\"") {
            let stamp = String(text[r.upperBound..<end])
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            latest = f.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        }
    }
    let side = URL(fileURLWithPath: (path as NSString).deletingPathExtension)
    if let files = FileManager.default.enumerator(at: side, includingPropertiesForKeys: [.contentModificationDateKey]) {
        for case let url as URL in files {
            if let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               m > (latest ?? .distantPast) { latest = m }
        }
    }
    return latest
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
        setIdle(id)
        onChange?([])
    }

    private func setIdle(_ id: String) {
        let url = dir.appendingPathComponent(id + ".state")
        guard var text = try? String(contentsOf: url, encoding: .utf8),
              let end = text.firstIndex(where: { $0 == "\t" || $0 == "\n" }) else { return }
        text.replaceSubrange(text.startIndex..<end, with: SessionState.idle.rawValue)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        sessions[id]?.state = .idle
    }

    /// A turn can die without any hook firing (Esc before Claude replies, a
    /// request lost while the Mac slept), leaving its session "running"
    /// forever. When a session has said nothing for this long, in its
    /// transcript or its subagents', it's idle. Sessions waiting on background
    /// work are left alone: a build can be quiet for hours. Any later event
    /// brings the session back.
    static let stallAfter: TimeInterval = 30 * 60
    private var stallChecked: [String: Date] = [:]

    /// Runs when the panel opens, not on a timer. Returns whether anything changed.
    @discardableResult
    func expireStalled(now: Date = Date()) -> Bool {
        var changed = false
        for s in sessions.values where s.state == .running && s.background == 0
            && now.timeIntervalSince(s.since) >= Self.stallAfter {
            if let t = stallChecked[s.id], now.timeIntervalSince(t) < 5 * 60 { continue }
            stallChecked[s.id] = now
            // No transcript to go on: leave it be rather than guess.
            guard let last = lastActivity(transcript: s.transcript.isEmpty ? findTranscript(s.id) : s.transcript),
                  now.timeIntervalSince(last) >= Self.stallAfter else { continue }
            setIdle(s.id)
            changed = true
        }
        stallChecked = stallChecked.filter { sessions[$0.key]?.state == .running }
        return changed
    }

    /// ~/.claude/projects/<project>/<id>.jsonl, for session files written
    /// before the hook kept the transcript path.
    private func findTranscript(_ id: String) -> String {
        let fm = FileManager.default
        let root = dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("projects")
        for project in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let f = root.appendingPathComponent(project).appendingPathComponent(id + ".jsonl").path
            if fm.fileExists(atPath: f) { return f }
        }
        return ""
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
            guard let tty = ttyPath(s.pid) else { return activate(bundleId: "com.apple.Terminal") }
            terminal.async {  // off the main thread, so the panel never freezes
                if terminalCall("jump", tty) == nil {
                    DispatchQueue.main.async { activate(bundleId: "com.apple.Terminal") }
                }
            }
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

    /// Brings an app forward the way the Dock does (Launch Services), which
    /// works from a background app on macOS 14+, unlike NSRunningApplication.activate.
    static func activate(bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    // MARK: Terminal.app

    /// AppleScript for Terminal, compiled once. `jump` sends one-way messages
    /// (no waiting for Terminal to answer each step) and finds the tab and
    /// window with `whose` filters that Terminal evaluates itself. Measured:
    /// Terminal is in front ~50 ms after the click, versus ~150 ms when the
    /// script waited for a reply to every step.
    private static let terminalSource = """
    on jump(t)
      ignoring application responses
        tell application "Terminal"
          set selected of (every tab of every window whose tty is t) to true
          set miniaturized of (every window whose tty of selected tab is t) to false
          set index of (every window whose tty of selected tab is t) to 1
          activate
        end tell
      end ignoring
      return true
    end jump

    on selectedtty()
      tell application "Terminal" to return tty of selected tab of front window
    end selectedtty

    on ping()
      ignoring application responses
        tell application "Terminal" to count windows
      end ignoring
      return true
    end ping
    """

    /// All AppleScript runs here, one call at a time.
    static let terminal = DispatchQueue(label: "blink.terminal", qos: .userInitiated)
    private static var terminalScript: NSAppleScript?  // these two: only on `terminal`
    private static var terminalAllowed: pid_t = 0
    private static var lastWarm = Date.distantPast     // main thread

    private static func compiledTerminalScript() -> NSAppleScript? {
        dispatchPrecondition(condition: .onQueue(terminal))
        if terminalScript == nil {
            let script = NSAppleScript(source: terminalSource)
            if script?.compileAndReturnError(nil) == true { terminalScript = script }
        }
        return terminalScript
    }

    /// Calls a handler in the Terminal script. Run on `terminal`.
    static func terminalCall(_ handler: String, _ args: String...) -> NSAppleEventDescriptor? {
        guard let script = compiledTerminalScript() else { return nil }
        // 'ascr'/'psbr': "call a handler"; 'snam': its name (OpenScripting's ASRegistry.h).
        let event = NSAppleEventDescriptor(eventClass: 0x6173_6372, eventID: 0x7073_6272, targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: 0x736E_616D)
        let params = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { params.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        event.setParam(params, forKeyword: keyDirectObject)
        var err: NSDictionary?
        let result = script.executeAppleEvent(event, error: &err)
        return err == nil ? result : nil
    }

    /// Keeps the Terminal jump fast. The first contact costs ~0.75 s (loading
    /// AppleScript), and after ~30 s idle Terminal takes ~90 ms to answer
    /// instead of ~5 ms (App Nap, permission re-checks). So this loads
    /// AppleScript when a Terminal session appears, and pokes Terminal with a
    /// no-op whenever the panel opens or you hover it, before you click.
    /// At most every 2 s, and it never triggers a permission prompt.
    static func warmTerminal() {
        guard Date().timeIntervalSince(lastWarm) > 2,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first
        else { return }
        lastWarm = Date()
        let pid = app.processIdentifier
        terminal.async {
            _ = compiledTerminalScript()
            if terminalAllowed != pid {
                let target = NSAppleEventDescriptor(processIdentifier: pid)
                guard let desc = target.aeDesc,
                      AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) == noErr
                else { return }
                terminalAllowed = pid
            }
            _ = terminalCall("ping")
        }
    }

    // MARK: Already looking at it?

    static func isLookingAt(_ s: Session) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        switch s.host {
        case .terminal:
            guard front.bundleIdentifier == "com.apple.Terminal", let tty = ttyPath(s.pid) else { return false }
            return terminal.sync { terminalCall("selectedtty")?.stringValue } == tty
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
    static let pressed = pair(0xEBEBEB, 0x2B2B2B)
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

/// Menu bar images: ○ nothing waiting, ● done, ◐ needs you. A 15 pt circle
/// in an 18 pt icon. Template images, so macOS tints them for the menu bar;
/// drawn once, then cached.
enum DotImage {
    static let size: CGFloat = 18

    private static func make(_ dot: Dot) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let c = NSRect(x: 1.5, y: 1.5, width: 15, height: 15)
            let ring = NSBezierPath(ovalIn: c.insetBy(dx: 0.8, dy: 0.8))
            ring.lineWidth = 1.6
            NSColor.black.set()
            switch dot {
            case .done:
                NSBezierPath(ovalIn: c).fill()
            case .needs:
                ring.stroke()
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: c.minX, y: c.minY, width: c.width / 2, height: c.height).clip()
                NSBezierPath(ovalIn: c).fill()
                NSGraphicsContext.restoreGraphicsState()
            case .empty:
                ring.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    static let empty = make(.empty), done = make(.done(0)), needs = make(.needs)
}

final class GlyphView: NSView {
    private let state: SessionState

    init(_ state: SessionState, pulse: Bool) {
        self.state = state
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if pulse && state == .running && !Motion.reduced {
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

class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Respect System Settings → Accessibility → Display → Reduce motion.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
}

/// A quiet text link ("Clear done") that darkens on hover.
final class TextButton: FirstClickButton {
    var onPress: (() -> Void)?
    private let text: String

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(pressed)
        setAccessibilityLabel(text)
        style(hover: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    private func style(hover: Bool) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: hover ? Palette.text : Palette.secondary,
        ])
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { style(hover: true) }
    override func mouseExited(with event: NSEvent) { style(hover: false) }
}

/// One session: glyph, folder, "done · 4m", and what Claude said.
final class RowView: NSView {
    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    private let session: Session
    private let detailText: String
    private let time: NSTextField
    private var close: FirstClickButton?
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            close?.isHidden = !hovering
            time.isHidden = hovering && close != nil
            if !hovering { pressed = false }
            paint(animated: true)
        }
    }
    private var pressed = false {
        didSet { if pressed != oldValue { paint(animated: true) } }
    }

    /// `lines`: how many lines of Claude's message to show (the card shows 2).
    init(_ s: Session, label: String, now: Date, pulse: Bool, lines: Int = 1) {
        session = s
        detailText = s.message
        time = makeLabel(Self.timeText(s, now), size: 11.5, color: Palette.secondary, digits: true)
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

        if detailText.isEmpty {
            constraints.append(name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8))
        } else {
            let detail = makeLabel(detailText, size: 12, color: Palette.secondary)
            if lines > 1 {
                detail.maximumNumberOfLines = lines
                detail.cell?.wraps = true
                detail.cell?.truncatesLastVisibleLine = true
                detail.lineBreakMode = .byWordWrapping
                detail.preferredMaxLayoutWidth = DropPanel.width - 10 - 30 - 11
            }
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
            b.toolTip = "Dismiss"
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

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        describe(now: now)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func timeText(_ s: Session, _ now: Date) -> String {
        "\(stateWord(s.state)) · \(ago(s.since, now: now))"
    }

    /// Updates "running · 12m" in place (no rebuild, so hover state survives).
    func refresh(now: Date) {
        time.stringValue = Self.timeText(session, now)
        describe(now: now)
    }

    private func describe(now: Date) {
        let when = ago(session.since, now: now)
        var text = "\(session.folder), \(stateWord(session.state))" + (when == "now" ? "" : ", \(when) ago")
        if !detailText.isEmpty { text += ". \(detailText)" }
        setAccessibilityLabel(text)
    }

    @objc private func dismissTapped() { onDismiss?() }

    /// Hover and press tints fade rather than snap.
    private func paint(animated: Bool) {
        guard let layer else { return }
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if pressed { color = Palette.pressed.cgColor } else if hovering { color = Palette.hover.cgColor }
        }
        if animated && !Motion.reduced {
            let a = CABasicAnimation(keyPath: "backgroundColor")
            a.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            a.toValue = color
            a.duration = pressed ? 0.06 : 0.14
            layer.add(a, forKey: "tint")
        }
        layer.backgroundColor = color
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { paint(animated: false) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func inside(_ e: NSEvent) -> Bool { bounds.contains(convert(e.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = inside(event) }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if inside(event) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
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

    /// Swaps in new content and sizes the panel to fit, centered under `anchor`
    /// (the dot) just below the menu bar. Height changes glide while visible.
    func update(_ rows: [NSView], under anchor: NSWindow?, animate: Bool) {
        // Keep the scroll position when the list refreshes under you.
        let scrolled = stack.arrangedSubviews.compactMap { $0 as? ScrollingList }.first?.contentView.bounds.origin.y
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
        }
        stack.layoutSubtreeIfNeeded()
        if let y = scrolled, let list = rows.compactMap({ $0 as? ScrollingList }).first { list.scroll(toY: y) }

        let h = ceil(stack.fittingSize.height)
        var target = NSRect(x: frame.minX, y: frame.maxY - h, width: Self.width, height: h)
        if let anchor, let screen = anchor.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let x = min(max(anchor.frame.midX - Self.width / 2, vf.minX + 8), vf.maxX - Self.width - 8)
            target.origin = NSPoint(x: round(x), y: vf.maxY - 6 - h)
        }
        if animate && isVisible && !Motion.reduced && target.height != frame.height {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = Motion.easeOut
                animator().setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true)
        }
        invalidateShadow()
    }

    func refreshTimes(_ now: Date) {
        func walk(_ v: NSView) {
            if let r = v as? RowView { r.refresh(now: now) } else { v.subviews.forEach(walk) }
        }
        walk(card)
    }
}

private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }  // content starts at the top
}

/// Fades the list into the card's background. Click-through.
private final class FadeView: NSView {
    private let gradient = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        recolor()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { gradient }
    override func viewDidChangeEffectiveAppearance() { recolor() }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = Palette.background.cgColor
            gradient.colors = [bg.copy(alpha: 0) ?? bg, bg]
        }
        gradient.startPoint = CGPoint(x: 0.5, y: 1)  // clear at the top
        gradient.endPoint = CGPoint(x: 0.5, y: 0)    // card color at the bottom
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shows the first `visible` rows; the rest scroll (thin overlay scroller).
final class ScrollingList: NSScrollView {
    init(_ rows: [NSView], width: CGFloat, visible: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none

        let list = FlippedStack()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        for r in rows {
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        documentView = list
        // With more rows than fit, let the next one peek out under a fade.
        let more = rows.count > visible
        let height = rows.prefix(visible).reduce(0) { $0 + ceil($1.fittingSize.height) } + (more ? 14 : 0)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            list.topAnchor.constraint(equalTo: contentView.topAnchor),
            list.widthAnchor.constraint(equalToConstant: width),
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
        if more {
            addSubview(fade, positioned: .below, relativeTo: verticalScroller)  // framed in layout()
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                                   name: NSView.boundsDidChangeNotification, object: contentView)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private let fade = FadeView()

    @objc private func scrolled() {
        guard fade.superview != nil, let doc = documentView, doc.frame.height > 0 else { return }
        fade.isHidden = contentView.bounds.maxY >= doc.frame.height - 1  // at the bottom: no fade
    }

    override func layout() {
        super.layout()
        if fade.superview != nil {  // NSScrollView tiles its subviews itself; place the fade by hand
            let h: CGFloat = 26
            fade.frame = NSRect(x: 0, y: isFlipped ? bounds.height - h : 0, width: bounds.width, height: h)
        }
        scrolled()
    }

    func scroll(toY y: CGFloat) {
        layoutSubtreeIfNeeded()
        let maxY = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
        reflectScrolledClipView(contentView)
    }
}

/// The panel's header: "2 done · 1 running", plus "Clear done" when useful.
private func headerRow(_ text: String, onClear: (() -> Void)?, bottom: CGFloat) -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    let l = makeLabel(text, size: 12, color: Palette.secondary)
    v.addSubview(l)
    var constraints = [
        l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 11),
        l.topAnchor.constraint(equalTo: v.topAnchor, constant: 7),
        l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -bottom),
    ]
    if let onClear {
        let b = TextButton("Clear done")
        b.onPress = onClear
        v.addSubview(b)
        constraints += [
            b.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -11),
            b.firstBaselineAnchor.constraint(equalTo: l.firstBaselineAnchor),
            l.trailingAnchor.constraint(lessThanOrEqualTo: b.leadingAnchor, constant: -8),
        ]
    } else {
        constraints.append(l.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -11))
    }
    NSLayoutConstraint.activate(constraints)
    return v
}

/// A plain message (the first-run hint).
func messageRow(_ title: String, _ detail: String) -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    let t = makeLabel(title, size: 13, weight: .medium, color: Palette.text)
    let d = makeLabel(detail, size: 12, color: Palette.secondary)
    d.maximumNumberOfLines = 3
    d.cell?.wraps = true
    d.lineBreakMode = .byWordWrapping
    d.preferredMaxLayoutWidth = DropPanel.width - 10 - 22
    v.addSubview(t)
    v.addSubview(d)
    NSLayoutConstraint.activate([
        t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 11),
        t.topAnchor.constraint(equalTo: v.topAnchor, constant: 9),
        t.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -11),
        d.leadingAnchor.constraint(equalTo: t.leadingAnchor),
        d.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -11),
        d.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 3),
        d.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -9),
    ])
    return v
}

let firstRunHint = ("blink is running",
                    "Hover the dot to see your Claude Code sessions. Hold ⌘ and drag it to move it.")

/// Rows for the card (`card` = the session ids to show) or, with `card: nil`,
/// the full summary panel.
func panelRows(_ sessions: [String: Session], card: [String]?, now: Date,
               onOpen: @escaping (Session) -> Void, onDismiss: @escaping (Session) -> Void,
               onClearDone: (() -> Void)? = nil, paused: Bool = false) -> [NSView] {
    let all = Array(sessions.values)
    let ordered = panelOrder(all)
    let labels = rowLabels(ordered)
    func row(_ s: Session, pulse: Bool, lines: Int) -> RowView {
        let r = RowView(s, label: labels[s.id] ?? "", now: now, pulse: pulse, lines: lines)
        r.onClick = { onOpen(s) }
        r.onDismiss = { onDismiss(s) }
        return r
    }
    if let card {
        return card.compactMap { sessions[$0] }.map { row($0, pulse: false, lines: 2) }
    }
    let anyDone = ordered.contains { $0.state == .done }
    var rows: [NSView] = [headerRow(summaryLine(all) + (paused ? " · paused" : ""), onClear: anyDone ? onClearDone : nil,
                                    bottom: ordered.isEmpty ? 7 : 3)]
    if !ordered.isEmpty {
        let sessionRows = ordered.prefix(50).map { row($0, pulse: true, lines: 1) }
        rows.append(ScrollingList(sessionRows, width: DropPanel.width - 10, visible: 4))
    }
    return rows
}

/// The three dots on a menu-bar-colored strip: real size (2x pixels) on top,
/// zoomed below. Writes dots-light.png and dots-dark.png.
private func renderDotPreviews(to dir: String) {
    let faces: [(NSImage, String)] = [(DotImage.empty, ""), (DotImage.done, " 2"), (DotImage.needs, "")]
    for (look, bar, ink) in [("light", NSColor(hex: 0xECECEC), NSColor.black), ("dark", NSColor(hex: 0x262626), NSColor.white)] {
        let zoom: CGFloat = 6, scale: CGFloat = 2, gap: CGFloat = 44
        let size = NSSize(width: gap * 4 + 24, height: 44 + DotImage.size * zoom + 24)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        bar.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (i, (img, title)) in faces.enumerated() {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                ink.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let x = 12 + CGFloat(i) * gap
            tinted.draw(in: NSRect(x: x, y: size.height - 13 - DotImage.size, width: DotImage.size, height: DotImage.size))
            NSAttributedString(string: title, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                                                           .foregroundColor: ink])
                .draw(at: NSPoint(x: x + DotImage.size, y: size.height - 13 - DotImage.size + 1))
            let zx = 12 + CGFloat(i) * (DotImage.size * zoom + 0) * 0.0 + CGFloat(i) * gap
            tinted.draw(in: NSRect(x: zx, y: 12, width: DotImage.size * zoom * 0.4, height: DotImage.size * zoom * 0.4))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("dots-\(look).png"))
    }
}

/// Developer aid: `blink --preview <dir>` renders the card, the panel and
/// the first-run hint, light and dark, to PNGs (no screen recording needed).
func renderPreviews(to dir: String) {
    renderDotPreviews(to: dir)
    let now = Date()
    let sample = [
        Session(id: "1", state: .done, projectDir: "/x/proj",
                message: snippet("## Summary\n\nDone.\nThe cosine schedule with warmup beats step decay by 1.8% on val loss, so I made it the default."),
                since: now.addingTimeInterval(-240)),
        Session(id: "2", state: .needs, projectDir: "/x/repo",
                message: "Claude needs your permission to use Bash", since: now.addingTimeInterval(-30)),
        Session(id: "3", state: .running, projectDir: "/x/sim", label: "Run the parameter sweep",
                since: now.addingTimeInterval(-60)),
        Session(id: "4", state: .running, projectDir: "/x/sim",
                message: "Subagent working: Write the proj paper", label: "Plot the phase diagram",
                since: now.addingTimeInterval(-95), background: 1),
        Session(id: "5", state: .done, projectDir: "/x/website", message: "Shipped the new landing page copy.",
                since: now.addingTimeInterval(-3 * 3600)),
    ]
    let sessions = Dictionary(uniqueKeysWithValues: sample.map { ($0.id, $0) })
    let kinds: [(String, () -> [NSView])] = [
        ("card", { panelRows(sessions, card: ["1", "2"], now: now, onOpen: { _ in }, onDismiss: { _ in }) }),
        ("panel", { panelRows(sessions, card: nil, now: now, onOpen: { _ in }, onDismiss: { _ in }, onClearDone: {}) }),
        ("hint", { [messageRow(firstRunHint.0, firstRunHint.1)] }),
    ]
    for (look, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        for (kind, rows) in kinds {
            let panel = DropPanel()
            panel.appearance = NSAppearance(named: name)
            panel.update(rows(), under: nil, animate: false)
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
    private enum Mode { case hidden, card, summary, hint }

    private let store: Store
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = DropPanel()
    private var mode = Mode.hidden
    private var overDot = false
    private var overPanel = false
    private var cardIds: [String] = []
    private var hideWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var ticker: Timer?
    private var mouseMonitor: Any?
    private var clickMonitor: Any?

    /// Pinned by a click: stays open with the dot highlighted, and a click
    /// anywhere else closes it, like a menu. The click watcher exists only
    /// while pinned.
    private var pinned = false {
        didSet {
            guard pinned != oldValue else { return }
            item.button?.highlight(pinned)
            if pinned {
                clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    guard let self, !self.mouseOnDot else { return }  // the dot toggles itself
                    self.pinned = false
                    self.hide()
                }
            } else if let m = clickMonitor {
                NSEvent.removeMonitor(m)
                clickMonitor = nil
            }
        }
    }

    static let cardSeconds = 6.0
    static let maxCardRows = 3
    static let hoverDelay = 0.12  // passing over the dot on the way elsewhere shouldn't flash the panel

    init(store: Store) {
        self.store = store
        super.init()
        item.autosaveName = "blink"
        item.behavior = []
        if let b = item.button {
            b.imagePosition = .imageLeft
            b.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            b.target = self
            b.action = #selector(dotClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // macOS 13–15: the dot lives in our own window, so a tracking area works.
            b.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                             owner: self))
        }
        // macOS 26: Control Center draws menu bar icons and forwards clicks but
        // not hover. Watch mouse movement instead; it's delivered only while the
        // mouse moves, and each event is one rectangle check.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            self.setOverDot(self.mouseOnDot)
        }
        panel.card.onHover = { [weak self] inside in
            guard let self else { return }
            self.overPanel = inside
            if inside { self.warmTerminalIfNeeded() }  // you're about to click
            if !inside { self.scheduleHide(after: self.mode == .summary ? 0.3 : 1.5) }
        }
        store.onChange = { [weak self] fresh in self?.storeChanged(fresh) }
        updateDot()
    }

    private func warmTerminalIfNeeded() {
        if store.sessions.values.contains(where: { $0.host == .terminal && $0.state != .idle }) { Focus.warmTerminal() }
    }

    private var mouseOnDot: Bool { item.button?.window?.frame.contains(NSEvent.mouseLocation) ?? false }
    private var mouseOnPanel: Bool { panel.isVisible && panel.frame.contains(NSEvent.mouseLocation) }

    // MARK: Dot

    private func updateDot() {
        guard let b = item.button else { return }
        let all = Array(store.sessions.values)
        switch dot(for: all) {
        case .empty: b.image = DotImage.empty; b.title = ""
        case .needs: b.image = DotImage.needs; b.title = ""
        case .done(let n): b.image = DotImage.done; b.title = " \(n)"
        }
        b.appearsDisabled = Prefs.paused  // a dimmed dot says "popups paused"
        b.setAccessibilityLabel("blink: " + summaryLine(all) + (Prefs.paused ? ", popups paused" : ""))
    }

    @objc func mouseEntered(with event: NSEvent) { setOverDot(true) }
    @objc func mouseExited(with event: NSEvent) { setOverDot(false) }

    private func setOverDot(_ inside: Bool) {
        guard inside != overDot else { return }
        overDot = inside
        hoverWork?.cancel()
        if inside {
            guard !pinned else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.overDot, !self.pinned else { return }
                self.show(.summary)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (mode == .hidden ? Self.hoverDelay : 0), execute: work)
        } else {
            scheduleHide(after: 0.3)
        }
    }

    @objc private func dotClicked() {
        let e = NSApp.currentEvent
        hoverWork?.cancel()
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
        warmTerminalIfNeeded()
        switch mode {
        case .summary:
            render()
        case .card, .hint, .hidden:
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

    /// First launch only: point at the dot once, so it isn't a mystery.
    func showHint() {
        guard mode == .hidden else { return }
        show(.hint)
        scheduleHide(after: 8)
    }

    private func show(_ m: Mode) {
        hideWork?.cancel()
        warmTerminalIfNeeded()
        if m == .summary { store.expireStalled() }
        let wasHidden = mode == .hidden
        mode = m
        render(animate: !wasHidden)
        if wasHidden {
            let target = panel.frame
            panel.alphaValue = 0
            if !Motion.reduced { panel.setFrameOrigin(NSPoint(x: target.minX, y: target.minY + 6)) }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.reduced ? 0.12 : 0.22
                ctx.timingFunction = Motion.easeOut
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        ticker?.invalidate()
        ticker = nil
        if m == .summary {  // keep "running · 12m" honest while the panel is open
            ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.panel.refreshTimes(Date())
            }
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Trust where the pointer is, not enter/exit bookkeeping: a fast
            // move can skip an exit event.
            guard let self, !self.pinned, !self.mouseOnDot, !self.mouseOnPanel else { return }
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
        overDot = mouseOnDot
        let start = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if !Motion.reduced { panel.animator().setFrame(start.offsetBy(dx: 0, dy: 4), display: true) }
        }, completionHandler: { [weak self] in
            guard let self, self.mode == .hidden else { return }
            self.panel.orderOut(nil)
            self.panel.update([], under: nil, animate: false)  // drop views (and pulse animations) while hidden
        })
    }

    private func render(animate: Bool = true) {
        guard mode != .hidden else { return }
        let rows: [NSView]
        if mode == .hint {
            rows = [messageRow(firstRunHint.0, firstRunHint.1)]
        } else {
            rows = panelRows(store.sessions, card: mode == .card ? cardIds : nil, now: Date(),
                             onOpen: { [weak self] s in self?.open(s) },
                             onDismiss: { [weak self] s in self?.store.dismiss(s.id) },
                             onClearDone: { [weak self] in self?.clearDone() },
                             paused: Prefs.paused)
        }
        panel.update(rows, under: item.button?.window, animate: animate)
    }

    private func open(_ s: Session) {
        if !pinned { hide() }  // the panel goes first, so the click feels instant
        Focus.open(s)
        if s.state == .done { store.dismiss(s.id) }
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
    @objc private func togglePause() {
        Prefs.paused.toggle()
        updateDot()
    }
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
        let first = firstRun()
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/blink/sessions")
        let store = Store(dir: dir)
        controller = Controller(store: store)
        store.start()
        self.store = store
        if first {  // let the status item settle into the menu bar first
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.controller?.showHint() }
        }
    }

    /// Defaults from the spec: launch at login on, and ask once for
    /// Accessibility (used only to read VS Code's front window title).
    private func firstRun() -> Bool {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "setupDone") else { return false }
        d.set(true, forKey: "setupDone")
        Prefs.setLaunchAtLogin(true)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        return true
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
