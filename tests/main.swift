// Run with ./build.sh test
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL (line \(line)): \(what)") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
let fm = FileManager.default
func file(_ head: String, _ payload: String = "") -> Data { Data((head + "\n" + payload).utf8) }

// MARK: parseSession

let done = parseSession(
    id: "abc",
    contents: file("done\t4242\tcli\tvscode\t29005\tcom.microsoft.VSCode\t/Users/x/proj",
                   ###"{"last_assistant_message":"## Summary\n\n**Fixed** the `flaky` test.\nMore text"}"###),
    mtime: t0)
check(done?.state == .done && done?.host == .vscodeTerminal && done?.folder == "proj", "done session")
check(done?.message == "Fixed the flaky test. More text", "done message: \(done?.message ?? "nil")")

let needs = parseSession(
    id: "n", contents: file("needs\t1\tclaude-vscode\t\t\tcom.microsoft.VSCode\t/p/proj",
                            #"{"message":"Claude needs your permission to use Bash"}"#),
    mtime: t0)
check(needs?.state == .needs && needs?.host == .vscodePanel, "needs from panel")

let question = parseSession(
    id: "q", contents: file("needs\t1\tcli\tApple_Terminal\t\t\t/p/proj",
                            #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?"}]}}"#),
    mtime: t0)
check(question?.message == "Which database?" && question?.host == .terminal, "question message")

let waiting = parseSession(
    id: "w", contents: file("agents\t1\tcli\tvscode\t\t\t/p/proj",
                            #"{"background_tasks":[{"type":"subagent","status":"running"},{"type":"workflow","status":"running"},{"type":"shell","status":"running","command":"npm run dev"},{"type":"dream","status":"running"}]}"#),
    mtime: t0)
check(waiting?.state == .running && waiting?.background == 3, "agents: running, housekeeping not counted")
check(waiting?.message == "3 background tasks: npm run dev", "background note: \(waiting?.message ?? "nil")")
func note(_ json: String) -> String { backgroundNote((try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [[String: Any]]) }
check(note(#"[{"type":"subagent","description":"Draft intro"},{"type":"subagent","description":"Draft methods"}]"#)
      == "2 subagents working: Draft intro, Draft methods", "two subagents")
check(note(#"[{"type":"monitor","command":"tail -f build.log"}]"#) == "Monitor running: tail -f build.log",
      "command when there's no description")

let woken = parseSession(id: "k", contents: file("running\t1\tcli\tvscode\t\t\t/p/aw",
                                                 #"{"last_assistant_message":"A subagent is writing the paper."}"#), mtime: t0)
check(woken?.message == "A subagent is writing the paper.", "woken without a prompt: Claude's last words")
let typedRun = parseSession(id: "r", contents: file("running\t1\tcli\tvscode\t\t\t/p/aw", #"{"prompt":"Fix it"}"#), mtime: t0)
check(typedRun?.message == "", "typed prompt: no detail")
check(parseSession(id: "x", contents: file("bogus\t1"), mtime: t0) == nil, "unknown state rejected")
check(parseSession(id: "c", contents: file("done\t1\tcli\t\t\t\t", #"{"cwd":"/a/b/cwdproj"}"#), mtime: t0)?.folder
      == "cwdproj", "folder falls back to cwd")

check(typedText(#"<agent-message from="a3d5">done</agent-message>"#) == "", "injected message isn't typed")
check(typedText("<pasted_content id=\"1\">\nlots\n</pasted_content id=\"1\">\nsummarize this") == "summarize this",
      "paste dropped, typed kept")

// MARK: snippet

check(snippet("\n\n  - **Done**: all `tests` pass\nsecond") == "Done: all tests pass", "strips markdown")
check(snippet("## Plan\n```swift\nlet x = 1\n```\n| a | b |\n---\nAll good, shipping it now.") == "All good, shipping it now.",
      "skips headings, code, tables, rules")
check(snippet("# Only a heading") == "Only a heading", "heading as a last resort")
check(snippet("Here's what changed:\n- Added retries to the uploader\n- Fixed the timeout") ==
      "Here's what changed: Added retries to the uploader", "opener borrows the next line")
check(snippet(String(repeating: "a", count: 300), max: 10) == "aaaaaaaaa…", "max length")

// MARK: summary, dot, time

func s(_ id: String, _ st: SessionState, _ dir: String = "/p/a", _ t: Date = t0) -> Session {
    Session(id: id, state: st, projectDir: dir, since: t)
}
check(summaryLine([s("1", .done), s("2", .done), s("3", .running), s("4", .needs), s("5", .idle)])
      == "2 done · 1 running · 1 needs you", "summary line")
check(summaryLine([s("1", .idle)]) == "No active sessions", "idle not counted")

check(dot(for: [s("1", .running)]) == .empty, "running only: hollow")
check(dot(for: [s("1", .done), s("2", .done), s("3", .running)]) == .done(2), "done count")
check(dot(for: [s("1", .done), s("2", .needs)]) == .needs, "needs wins")

check(ago(t0, now: t0.addingTimeInterval(4 * 60 + 5)) == "4m", "minutes")
check(ago(t0, now: t0.addingTimeInterval(-10)) == "now", "clock skew")

// MARK: freshAlerts

let t1 = t0.addingTimeInterval(5)
check(freshAlerts(old: [:], new: ["a": s("a", .done)]).map(\.id) == ["a"], "new done session alerts")
check(freshAlerts(old: ["a": s("a", .running)], new: ["a": s("a", .done, "/p/a", t1)]).count == 1, "running → done")
check(freshAlerts(old: ["a": s("a", .done)], new: ["a": s("a", .done)]).isEmpty, "unchanged done: no alert")
check(freshAlerts(old: ["a": s("a", .done)], new: ["a": s("a", .done, "/p/a", t1)]).count == 1, "done again (new turn)")
check(freshAlerts(old: ["a": s("a", .done)], new: ["a": s("a", .idle, "/p/a", t1)]).isEmpty, "dismissed: no alert")
check(freshAlerts(old: [:], new: ["a": s("a", .running)]).isEmpty, "running: no alert")
check(freshAlerts(old: ["a": s("a", .running)], new: ["a": s("a", .needs, "/p/a", t1)]).count == 1, "needs alerts")
check(freshAlerts(old: [:], new: ["a": s("a", .done, "/p/a", t0), "b": s("b", .done, "/p/b", t1)]).map(\.id) == ["b", "a"],
      "newest first")

// MARK: ordering and labels

let order = panelOrder([
    s("r-old", .running, "/p/a", t0), s("r-new", .running, "/p/a", t1),
    s("d-old", .done, "/p/a", t0), s("d-new", .done, "/p/a", t1),
    s("n", .needs), s("i", .idle),
]).map(\.id)
check(order == ["n", "d-new", "d-old", "r-old", "r-new"], "panel order: \(order)")

var a1 = s("1", .done, "/p/repo"); a1.label = "Fix tests"
var a2 = s("2", .running, "/p/repo"); a2.label = "Write docs"
let labels = rowLabels([a1, a2, s("3", .done, "/p/other")])
check(labels["1"] == "Fix tests" && labels["2"] == "Write docs" && labels["3"] == "", "labels only for shared folders")

check(titleShowsFolder("main.py — proj", "proj"), "title match")
check(!titleShowsFolder("main.py — proj-2", "proj"), "no partial title match")

// MARK: vscodeWindowId

do {
    let tmp = fm.temporaryDirectory.appendingPathComponent("blink-test-\(getpid())")
    func log(_ run: String, _ window: String, _ text: String) {
        let d = tmp.appendingPathComponent("\(run)/\(window)/exthost")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: d.appendingPathComponent("exthost.log"))
    }
    log("20261116T043149", "window1", "2026-11-16 [info] Extension host with pid 872 started\n")
    log("20261116T043149", "window7", "2026-11-16 [info] Extension host with pid 874 started\n")
    log("20261031T175749", "window2", "2026-10-31 [info] Extension host with pid 999 started\n")
    check(vscodeWindowId(extHostPid: 874, logsRoot: tmp) == 7, "finds window7")
    check(vscodeWindowId(extHostPid: 87, logsRoot: tmp) == nil, "no prefix match on pid")
    let started = DateFormatter()
    started.locale = Locale(identifier: "en_US_POSIX")
    started.dateFormat = "yyyyMMdd'T'HHmmss"
    check(vscodeWindowId(extHostPid: 999, logsRoot: tmp, notBefore: started.date(from: "20261116T043148")) == nil,
          "ignores logs from older VS Code runs")
    try? fm.removeItem(at: tmp)
}

// MARK: stalled sessions

do {
    let dir = fm.temporaryDirectory.appendingPathComponent("blink-stall-\(getpid())")
    try? fm.removeItem(at: dir)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func transcript(_ name: String, lastEntry: Date) -> String {
        let path = dir.appendingPathComponent(name + ".jsonl").path
        let lines = [
            #"{"type":"user","timestamp":"\#(iso.string(from: lastEntry.addingTimeInterval(-60)))"}"#,
            #"{"type":"api-request","timestamp":"\#(iso.string(from: lastEntry))"}"#,
            // later bookkeeping: no timestamp of its own, and an escaped one inside text
            #"{"type":"session-owner","note":"{\"timestamp\":\"2099-01-01T00:00:00.000Z\"}"}"#,
        ]
        try! (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
    let twoHoursAgo = now.addingTimeInterval(-7200)
    let deadPath = transcript("dead", lastEntry: twoHoursAgo)
    check(lastActivity(transcript: deadPath).map { abs($0.timeIntervalSince(twoHoursAgo)) < 0.01 } == true,
          "last activity = newest timestamped entry")
    let busyPath = transcript("busy", lastEntry: twoHoursAgo)
    let sub = dir.appendingPathComponent("busy/subagents")
    try! fm.createDirectory(at: sub, withIntermediateDirectories: true)
    try! "{}".write(to: sub.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)

    let sessions = dir.appendingPathComponent("sessions")
    try! fm.createDirectory(at: sessions, withIntermediateDirectories: true)
    func write(_ id: String, _ state: String, _ path: String, extra: String = "") {
        let url = sessions.appendingPathComponent("\(id).state")
        try! Data("\(state)\t\(getpid())\tcli\tvscode\t\t\t/p/\(id)\n{\"transcript_path\":\"\(path)\"\(extra)}".utf8).write(to: url)
        try! fm.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: url.path)
    }
    write("dead", "running", deadPath)
    write("busy", "running", busyPath)
    write("fresh", "running", transcript("fresh", lastEntry: now.addingTimeInterval(-60)))
    write("waits", "agents", deadPath, extra: #","background_tasks":[{"type":"shell","status":"running"}]"#)
    write("lost", "running", "")
    let store = Store(dir: sessions)
    store.rescan(initial: true)
    store.expireStalled(now: now)
    store.rescan()
    check(store.sessions["dead"]?.state == .idle, "silent for 2 h: idle, on disk")
    check(store.sessions["busy"]?.state == .running, "subagent still writing: running")
    check(store.sessions["fresh"]?.state == .running, "spoke a minute ago: running")
    check(store.sessions["waits"]?.state == .running, "waiting on background work: left alone")
    check(store.sessions["lost"]?.state == .running, "no transcript: left alone")
    try? fm.removeItem(at: dir)
}

// MARK: Store with the real hook

do {
    let dir = fm.temporaryDirectory.appendingPathComponent("blink-store-\(getpid())")
    try? fm.removeItem(at: dir)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    func write(_ id: String, _ head: String, _ payload: String) {
        try! Data((head + "\n" + payload).utf8).write(to: dir.appendingPathComponent("\(id).state"))
    }
    func hook(_ event: String, _ id: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"mkdir -p "$HOME/.claude/blink" && ln -sfn "$DIR" "$HOME/.claude/blink/sessions" && echo '{}' | sh "$HOOK" "$EV""#]
        p.environment = ["HOME": dir.appendingPathComponent("home").path, "DIR": dir.path,
                         "HOOK": fm.currentDirectoryPath + "/hooks/hook.sh", "EV": event,
                         "CLAUDE_CODE_SESSION_ID": id, "CLAUDE_PID": "\(getpid())",
                         "CLAUDE_CODE_ENTRYPOINT": "cli", "PATH": "/usr/bin:/bin"]
        try! p.run()
        p.waitUntilExit()
    }
    let me = getpid()
    write("one", "done\t\(me)\tcli\tvscode\t\t\t/p/one", #"{"last_assistant_message":"first"}"#)
    write("two", "done\t\(me)\tcli\tvscode\t\t\t/p/two", #"{"last_assistant_message":"second"}"#)
    let store = Store(dir: dir)
    store.rescan(initial: true)

    store.dismiss("one")
    store.rescan()
    check(store.sessions["one"]?.state == .idle && store.sessions["two"]?.state == .done,
          "dismissing one session leaves the other")

    hook("tool", "one")
    store.rescan()
    check(store.sessions["one"]?.state == .running && store.sessions["two"]?.state == .done,
          "woken by a subagent: running; the other untouched")

    hook("done", "one")
    store.dismiss("one")
    hook("running", "one")
    store.rescan()
    check(store.sessions["one"]?.state == .running && dot(for: Array(store.sessions.values)) == .done(1),
          "new prompt: running; dot still shows the other done")
    try? fm.removeItem(at: dir)
}

print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
