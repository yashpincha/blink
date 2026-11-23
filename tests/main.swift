// Unit tests for blink's pure logic. Run with: ./build.sh test
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL (line \(line)): \(what)") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
func file(_ head: String, _ payload: String = "") -> Data { Data((head + "\n" + payload).utf8) }

// MARK: parseSession

let done = parseSession(
    id: "abc",
    contents: file("done\t4242\tcli\tvscode\t29005\tcom.microsoft.VSCode\t/Users/x/proj",
                   ###"{"session_id":"abc","last_assistant_message":"## Summary\n\n**Fixed** the `flaky` test.\nMore text"}"###),
    mtime: t0)
check(done?.state == .done, "done state")
check(done?.pid == 4242, "pid")
check(done?.host == .vscodeTerminal, "vscode terminal host")
check(done?.ssePort == "29005", "sse port")
check(done?.folder == "proj", "folder name")
check(done?.message == "Fixed the flaky test. More text", "skips heading, joins short opener: \(done?.message ?? "nil")")
check(done?.since == t0, "since = mtime")

let needs = parseSession(
    id: "n", contents: file("needs\t1\tclaude-vscode\t\t\tcom.microsoft.VSCode\t/p/proj",
                            #"{"message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#),
    mtime: t0)
check(needs?.state == .needs && needs?.host == .vscodePanel, "needs from panel")
check(needs?.message == "Claude needs your permission to use Bash", "needs message")

let question = parseSession(
    id: "q", contents: file("needs\t1\tcli\tApple_Terminal\t\t\t/p/proj",
                            #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?"}]}}"#),
    mtime: t0)
check(question?.message == "Which database?" && question?.host == .terminal, "question message")

let tool = parseSession(id: "t", contents: file("running\t9\tcli\tApple_Terminal\t\t\t/p/x"), mtime: t0)
check(tool?.state == .running && tool?.message == "", "metadata-only file")

let waiting = parseSession(
    id: "w", contents: file("agents\t1\tcli\tvscode\t\t\t/p/proj",
                            #"{"last_assistant_message":"Kicked off 2 agents.","background_tasks":[{"id":"a1","type":"subagent","status":"running","agent_type":"Explore"},{"id":"w1","type":"workflow","status":"running"},{"id":"b1","type":"shell","status":"running","command":"npm run dev"}]}"#),
    mtime: t0)
check(waiting?.state == .running && waiting?.background == 3,
      "stopped with a subagent, a workflow and a watched shell: running, 3 tasks")
check(waiting?.message == "3 background tasks: npm run dev", "background note: \(waiting?.message ?? "nil")")
func note(_ json: String) -> String { backgroundNote((try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [[String: Any]]) }
check(note(#"[{"type":"subagent","description":"Draft intro"},{"type":"subagent","description":"Draft methods"}]"#)
      == "2 subagents working: Draft intro, Draft methods", "two subagents")
check(note(#"[{"type":"shell","description":"Watch the docker build","command":"until …"}]"#)
      == "Shell running: Watch the docker build", "one watched shell")
check(note(#"[{"type":"monitor","command":"tail -f build.log"}]"#) == "Monitor running: tail -f build.log", "monitor, command as fallback")
let paper = parseSession(
    id: "p", contents: file("agents\t1\tcli\tvscode\t\t\t/p/aw",
                            #"{"background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"Write the proj paper"}]}"#),
    mtime: t0)
check(paper?.message == "Subagent working: Write the proj paper", "agents note names the task: \(paper?.message ?? "nil")")
let woken = parseSession(id: "k", contents: file("running\t1\tcli\tvscode\t\t\t/p/aw",
                                                 #"{"last_assistant_message":"A subagent is writing the paper."}"#), mtime: t0)
check(woken?.message == "A subagent is writing the paper.", "woken without a prompt: Claude's last words")
let typedRun = parseSession(id: "r", contents: file("running\t1\tcli\tvscode\t\t\t/p/aw", #"{"prompt":"Fix it"}"#), mtime: t0)
check(typedRun?.message == "", "typed prompt: no detail")
check(typedText(#"<agent-message from="a3d5">done</agent-message>"#) == "", "agent message isn't typed")
check(typedText("<pasted_content id=\"1\">\nlots\n</pasted_content id=\"1\">\nsummarize this") == "summarize this", "paste dropped, typed kept")
check(typedText("plain words") == "plain words", "plain prompt")
check(dot(for: [waiting!]) == .empty, "waiting on agents: not done yet")
check(parseSession(id: "x", contents: file("bogus\t1"), mtime: t0) == nil, "unknown state rejected")
check(parseSession(id: "x", contents: Data(), mtime: t0) == nil, "empty file rejected")

let noDir = parseSession(id: "c", contents: file("done\t1\tcli\t\t\t\t", #"{"cwd":"/a/b/cwdproj"}"#), mtime: t0)
check(noDir?.folder == "cwdproj", "falls back to cwd")

check(parseLabel(file("running\t1", #"{"prompt":"Fix the login redirect bug that happens after OAuth callback"}"#))
      == "Fix the login redirect bug that happens…", "label truncated")

// MARK: snippet

check(snippet("\n\n  - **Done**: all `tests` pass\nsecond") == "Done: all tests pass", "snippet strips markdown")
check(snippet("## Plan\n```swift\nlet x = 1\n```\n| a | b |\n---\nAll good, shipping it now.") == "All good, shipping it now.",
      "skips headings, code, tables, rules")
check(snippet("# Only a heading") == "Only a heading", "heading as a last resort")
check(snippet("Here's what changed:\n- Added retries to the uploader\n- Fixed the timeout") ==
      "Here's what changed: Added retries to the uploader", "opener borrows the next line")
check(snippet("This first line is long enough to stand on its own.\nSecond line") ==
      "This first line is long enough to stand on its own.", "long first line stands alone")
check(snippet("") == "", "empty snippet")
check(snippet(String(repeating: "a", count: 300), max: 10) == "aaaaaaaaa…", "snippet max")

// MARK: summary, dot, time

func s(_ id: String, _ st: SessionState, _ dir: String = "/p/a", _ t: Date = t0) -> Session {
    Session(id: id, state: st, projectDir: dir, since: t)
}
check(summaryLine([]) == "No active sessions", "empty summary")
check(summaryLine([s("1", .done), s("2", .done), s("3", .running), s("4", .needs), s("5", .idle)])
      == "2 done · 1 running · 1 needs you", "summary line")
check(summaryLine([s("1", .idle)]) == "No active sessions", "idle not counted")

check(dot(for: []) == .empty, "empty dot")
check(dot(for: [s("1", .running)]) == .empty, "running only → hollow")
check(dot(for: [s("1", .done), s("2", .done), s("3", .running)]) == .done(2), "done count")
check(dot(for: [s("1", .done), s("2", .needs)]) == .needs, "needs wins")

check(ago(t0, now: t0.addingTimeInterval(30)) == "now", "now")
check(ago(t0, now: t0.addingTimeInterval(4 * 60 + 5)) == "4m", "minutes")
check(ago(t0, now: t0.addingTimeInterval(3 * 3600)) == "3h", "hours")
check(ago(t0, now: t0.addingTimeInterval(2 * 86400)) == "2d", "days")
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
let two = freshAlerts(old: [:], new: ["a": s("a", .done, "/p/a", t0), "b": s("b", .done, "/p/b", t1)])
check(two.map(\.id) == ["b", "a"], "newest first")

// MARK: ordering and titles

let order = panelOrder([
    s("r-old", .running, "/p/a", t0), s("r-new", .running, "/p/a", t1),
    s("d-old", .done, "/p/a", t0), s("d-new", .done, "/p/a", t1),
    s("n", .needs), s("i", .idle),
]).map(\.id)
check(order == ["n", "d-new", "d-old", "r-old", "r-new"], "panel order: \(order)")

var a1 = s("1", .done, "/p/repo"); a1.label = "Fix tests"
var a2 = s("2", .running, "/p/repo"); a2.label = "Write docs"
let labels = rowLabels([a1, a2, s("3", .done, "/p/other")])
check(labels["1"] == "Fix tests" && labels["2"] == "Write docs", "shared folder gets labels")
check(labels["3"] == "", "unique folder: no label")

check(titleShowsFolder("main.py — proj", "proj"), "title match")
check(titleShowsFolder("proj", "proj"), "title is folder")
check(!titleShowsFolder("main.py — proj-2", "proj"), "no partial match")

// MARK: vscodeWindowId

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("blink-test-\(getpid())")
let fm = FileManager.default
func log(_ run: String, _ window: String, _ text: String) {
    let d = tmp.appendingPathComponent("\(run)/\(window)/exthost")
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: d.appendingPathComponent("exthost.log"))
}
log("20261116T043149", "window1", "2026-11-16 [info] Extension host with pid 872 started\n")
log("20261116T043149", "window7", "2026-11-16 [info] Extension host with pid 874 started\n")
log("20261031T175749", "window2", "2026-10-31 [info] Extension host with pid 999 started\n")
try! fm.createDirectory(at: tmp.appendingPathComponent("20261122T124257"), withIntermediateDirectories: true)
check(vscodeWindowId(extHostPid: 874, logsRoot: tmp) == 7, "finds window7")
check(vscodeWindowId(extHostPid: 87, logsRoot: tmp) == nil, "no prefix match on pid")
let started = DateFormatter()
started.locale = Locale(identifier: "en_US_POSIX")
started.dateFormat = "yyyyMMdd'T'HHmmss"
check(vscodeWindowId(extHostPid: 999, logsRoot: tmp, notBefore: started.date(from: "20261116T043148")) == nil,
      "ignores logs from older VS Code runs")
check(vscodeWindowId(extHostPid: 999, logsRoot: tmp) == 2, "old run found without cutoff")
try? fm.removeItem(at: tmp)

// MARK: processes

check(parentPid(getpid()) == getppid(), "parentPid")
check(isAlive(getpid()), "self alive")
check(startTime(getpid()) != nil, "start time")

// MARK: Store: opening one done session leaves the others alone

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blink-store-\(getpid())")
    try? fm.removeItem(at: dir)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    func write(_ id: String, _ head: String, _ payload: String = "{}") {
        try! Data((head + "\n" + payload).utf8).write(to: dir.appendingPathComponent("\(id).state"))
    }
    func hook(_ event: String, _ id: String) {  // the real hook script, against this folder
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"mkdir -p "$HOME/.claude/blink" && ln -sfn "$DIR" "$HOME/.claude/blink/sessions" && echo '{}' | sh "$HOOK" "$EV""#]
        let home = dir.appendingPathComponent("home").path
        p.environment = ["HOME": home, "DIR": dir.path, "HOOK": FileManager.default.currentDirectoryPath + "/hooks/hook.sh",
                         "EV": event, "CLAUDE_CODE_SESSION_ID": id, "CLAUDE_PID": "\(getpid())",
                         "CLAUDE_CODE_ENTRYPOINT": "cli", "PATH": "/usr/bin:/bin"]
        try! p.run()
        p.waitUntilExit()
    }
    let me = getpid()
    write("one", "done\t\(me)\tcli\tvscode\t\t\t/p/one", #"{"last_assistant_message":"first"}"#)
    write("two", "done\t\(me)\tcli\tvscode\t\t\t/p/two", #"{"last_assistant_message":"second"}"#)

    let store = Store(dir: dir)
    store.rescan(initial: true)
    check(store.sessions["one"]?.state == .done && store.sessions["two"]?.state == .done, "both done at start")

    store.dismiss("one")  // what clicking session 1 does
    store.rescan()
    check(store.sessions["one"]?.state == .idle, "clicked session leaves the list")
    check(store.sessions["two"]?.state == .done, "the other done session stays")

    hook("idle", "two")  // Claude Code's ~60 s "waiting for your input" reminder
    store.rescan()
    check(store.sessions["two"]?.state == .done, "still done after idle reminders")

    hook("tool", "one")  // a subagent reports back and Claude works on in session 1, no typed prompt
    store.rescan()
    check(store.sessions["one"]?.state == .running && store.sessions["two"]?.state == .done,
          "session 1 woken by a subagent: running; session 2 untouched")
    hook("done", "one")
    store.dismiss("one")

    hook("running", "one")  // you send session 1 a new prompt
    store.rescan()
    check(store.sessions["one"]?.state == .running && store.sessions["two"]?.state == .done,
          "new prompt in session 1 doesn't touch session 2")
    check(dot(for: Array(store.sessions.values)) == .done(1), "dot still shows 1 done")
    try? fm.removeItem(at: dir)
}

print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
