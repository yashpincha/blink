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
check(done?.message == "Summary", "first line of message: \(done?.message ?? "nil")")
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

check(parseSession(id: "x", contents: file("bogus\t1"), mtime: t0) == nil, "unknown state rejected")
check(parseSession(id: "x", contents: Data(), mtime: t0) == nil, "empty file rejected")

let noDir = parseSession(id: "c", contents: file("done\t1\tcli\t\t\t\t", #"{"cwd":"/a/b/cwdproj"}"#), mtime: t0)
check(noDir?.folder == "cwdproj", "falls back to cwd")

check(parseLabel(file("running\t1", #"{"prompt":"Fix the login redirect bug that happens after OAuth callback"}"#))
      == "Fix the login redirect bug that happens…", "label truncated")

// MARK: snippet

check(snippet("\n\n  - **Done**: all `tests` pass\nsecond") == "Done: all tests pass", "snippet strips markdown")
check(snippet("") == "", "empty snippet")
check(snippet(String(repeating: "a", count: 300), max: 10) == "aaaaaaaaa…", "snippet max")

// MARK: summary, dot, time

func s(_ id: String, _ st: SessionState, _ dir: String = "/p/a", _ t: Date = t0) -> Session {
    Session(id: id, state: st, projectDir: dir, since: t)
}
check(summaryLine([]) == "No sessions", "empty summary")
check(summaryLine([s("1", .done), s("2", .done), s("3", .running), s("4", .needs), s("5", .idle)])
      == "2 done · 1 running · 1 needs you", "summary line")
check(summaryLine([s("1", .idle)]) == "No sessions", "idle not counted")

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
let titles = rowTitles([a1, a2, s("3", .done, "/p/other")])
check(titles["1"] == "repo · Fix tests" && titles["2"] == "repo · Write docs", "shared folder gets labels")
check(titles["3"] == "other", "unique folder: name only")

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

print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
