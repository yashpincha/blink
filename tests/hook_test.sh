#!/bin/sh
# End-to-end tests for hooks/hook.sh against a temporary HOME.
set -u
cd "$(dirname "$0")/.."
HOOK="$PWD/hooks/hook.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D="$T/.claude/blink/sessions"
fails=0
ok()   { if eval "$1"; then :; else echo "FAIL: $2"; fails=$((fails+1)); fi; }
run()  { # run <event> <json> [extra env...]
  ev=$1; json=$2; shift 2
  printf '%s' "$json" | env -i HOME="$T" PATH=/usr/bin:/bin CLAUDE_CODE_SESSION_ID=s1 CLAUDE_PID=4242 \
    CLAUDE_CODE_ENTRYPOINT=cli TERM_PROGRAM=vscode CLAUDE_CODE_SSE_PORT=29005 \
    __CFBundleIdentifier=com.microsoft.VSCode CLAUDE_PROJECT_DIR=/p/proj "$@" sh "$HOOK" "$ev"
}
head1() { IFS= read -r l < "$D/s1.state"; printf '%s' "$l"; }

run running '{"prompt":"first prompt"}'
ok '[ "$(head1)" = "running	4242	cli	vscode	29005	com.microsoft.VSCode	/p/proj" ]' "running writes metadata line"
ok 'grep -q "first prompt" "$D/s1.first"' "first prompt saved"
run running '{"prompt":"second prompt"}'
ok 'grep -q "first prompt" "$D/s1.first"' ".first keeps the first prompt"
run end '{}'
run running '{"prompt":"<agent-message from=\"a1\">report</agent-message>"}'
ok '[ ! -f "$D/s1.first" ]' "agent message doesn't become the label"
run running '{"prompt":"<pasted_content id=\"1\">x</pasted_content id=\"1\"> summarize"}'
ok 'grep -q summarize "$D/s1.first"' "pasted prompt is yours: label"
run end '{}'
printf 'running\t1\n{"prompt":"<agent-message from=\\"a\\">x</agent-message>"}\n' > "$D/s1.first"
run running '{"prompt":"first prompt"}'
ok 'grep -q "first prompt" "$D/s1.first"' "a bad label is replaced by the first typed prompt"
run running '{"prompt":"second prompt"}'
ok 'grep -q "first prompt" "$D/s1.first"' "then it sticks"
ok 'grep -q "second prompt" "$D/s1.state"' "state has latest payload"

run tool '{"tool_name":"Bash","tool_response":"BIG"}'
ok 'grep -q "second prompt" "$D/s1.state"' "tool while running: no write"

run needs '{"message":"Claude needs your permission to use Bash"}'
ok 'head1 | grep -q "^needs	"' "needs"
run tool '{"tool_name":"Bash","tool_response":"BIG"}'
ok 'head1 | grep -q "^running	"' "tool after needs: running"
ok '! grep -q BIG "$D/s1.state"' "tool payload not stored"

run done '{"last_assistant_message":"All set."}'
ok 'head1 | grep -q "^done	" && grep -q "All set." "$D/s1.state"' "done with message"
run idle '{"notification_type":"idle_prompt"}'
ok 'head1 | grep -q "^done	"' "idle_prompt keeps done"

run running '{"prompt":"spawn agents"}'
run done '{"last_assistant_message":"Started.","background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}'
ok 'head1 | grep -q "^agents	" && grep -q background_tasks "$D/s1.state"' "Stop with a background subagent: agents"
run idle '{"notification_type":"idle_prompt"}'
ok 'head1 | grep -q "^agents	"' "idle_prompt ignored while agents work"
run done '{"last_assistant_message":"Watching the build.","background_tasks":[{"id":"b1","type":"shell","status":"running"}]}'
ok 'head1 | grep -q "^agents	"' "background shell Claude watches: still running"
run done '{"last_assistant_message":"Tailing logs.","background_tasks":[{"id":"m1","type":"monitor","status":"running"}]}'
ok 'head1 | grep -q "^agents	"' "monitor: still running"
run done '{"last_assistant_message":"Done.","background_tasks":[{"id":"d1","type":"dream","status":"running"}]}'
ok 'head1 | grep -q "^done	"' "Claude Code housekeeping only: done"
run done '{"last_assistant_message":"All agents back.","background_tasks":[]}'
ok 'head1 | grep -q "^done	" && grep -q "All agents back." "$D/s1.state"' "agents finished: done"

run running '{"prompt":"run the tests"}'
run interrupt '{"tool_name":"Bash","error":"exit 1","is_interrupt":false}'
ok 'head1 | grep -q "^running	"' "tool error without interrupt: still running"
run interrupt '{"tool_name":"Bash","error":"Interrupted","is_interrupt":true}'
ok 'head1 | grep -q "^idle	"' "Esc mid-tool: idle"
run done '{"last_assistant_message":"Done."}'
run interrupt '{"tool_name":"Bash","is_interrupt":true}'
ok 'head1 | grep -q "^done	"' "interrupt never touches done"
run tool '{}'
ok 'head1 | grep -q "^running	" && grep -q "Done." "$D/s1.state"' "tool after done (a subagent woke Claude): running, keeps Claude's last words"
run done '{"last_assistant_message":"Finished.","background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}'
run tool '{}'
ok 'head1 | grep -q "^agents	"' "subagent tools keep agents (count survives)"
run done '{"last_assistant_message":"Done."}'
printf 'idle%s' "$(tail -c +5 "$D/s1.state")" > "$D/s1.tmp" && mv "$D/s1.tmp" "$D/s1.state"  # you clicked it away
run tool '{}'
ok 'head1 | grep -q "^running	"' "tool after idle (dismissed, then woken): running"

run running '{"prompt":"third"}'
run idle '{"notification_type":"idle_prompt"}'
ok 'head1 | grep -q "^idle	"' "idle_prompt clears stale running (after an interrupt)"

run running '{"prompt":"x"}' CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ID=s2
ok '[ ! -f "$D/s2.state" ]' "non-interactive sessions ignored"
run done '{}' CLAUDE_CODE_SESSION_ID=
ok '[ "$(ls -A "$D" | wc -l | tr -d " ")" = 2 ]' "no session id: nothing written"
ok '[ -z "$(ls -A "$D" | grep "^\.")" ]' "no temp files left behind"

run end '{"reason":"prompt_input_exit"}'
ok '[ ! -f "$D/s1.state" ] && [ ! -f "$D/s1.first" ]' "end removes files"

[ $fails -eq 0 ] && echo "All hook tests passed." || { echo "$fails hook test(s) failed."; exit 1; }
