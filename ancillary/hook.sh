#!/bin/sh
# blink hook: keeps ~/.claude/blink/sessions/<id>.state current. Runs async.
#
#   running    UserPromptSubmit
#   done       Stop, StopFailure ("agents" while background work continues)
#   needs      Notification (permission, question), PreToolUse AskUserQuestion
#   tool       PostToolUse: needs, done or idle → running
#   idle       Notification idle_prompt: running or needs → idle
#   interrupt  PostToolUseFailure: Esc mid-tool → idle
#   end        SessionEnd
#
# File: one tab-separated metadata line, then the event's JSON payload.

sid=$CLAUDE_CODE_SESSION_ID
[ -n "$sid" ] || exit 0
dir="$HOME/.claude/blink/sessions"
f="$dir/$sid.state"

case $1 in
  end)
    rm -f "$f" "$dir/$sid.first"
    exit 0 ;;
  tool|idle|interrupt)
    # Builtins only: this runs on every tool call.
    [ -f "$f" ] || exit 0
    IFS= read -r head < "$f"
    case "$1:$head" in
      tool:needs*|tool:done*|tool:idle*) state=running ;;
      idle:running*|idle:needs*) state=idle ;;
      interrupt:running*|interrupt:needs*)
        # A failed tool only ends the turn when you interrupted it.
        case $(cat) in *'"is_interrupt":true'*) state=idle ;; *) exit 0 ;; esac ;;
      *) exit 0 ;;
    esac ;;
  done)
    # Background work Claude waits on keeps the session running.
    # Claude Code's housekeeping tasks (dream, auto-mode scan) don't count.
    payload=$(cat)
    case $payload in
      *'"type":"subagent"'*|*'"type":"workflow"'*|*'"type":"teammate"'*|*'"type":"cloud session"'*| \
      *'"type":"shell"'*|*'"type":"monitor"'*|*'"type":"MCP task"'*) state=agents ;;
      *) state=done ;;
    esac ;;
  running|needs) state=$1 ;;
  *) exit 0 ;;
esac

# Interactive sessions only; skip `claude -p` and SDK runs.
case $CLAUDE_CODE_ENTRYPOINT in cli|claude-vscode) ;; *) exit 0 ;; esac

[ -d "$dir" ] || mkdir -p "$dir"
tmp="$dir/.$sid.$$"
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$CLAUDE_PID" "$CLAUDE_CODE_ENTRYPOINT" \
    "$TERM_PROGRAM" "$CLAUDE_CODE_SSE_PORT" "$__CFBundleIdentifier" "$CLAUDE_PROJECT_DIR"
  case $1 in
    done) printf '%s\n' "$payload" ;;
    running|needs) cat ;;
    *) tail -n +2 "$f" ;;  # keep the previous payload
  esac
} > "$tmp" && mv -f "$tmp" "$f"

# The first typed prompt labels sessions that share a folder. Tag-prefixed
# prompts are injected by Claude Code; pasted content counts as typed.
typed() {
  [ -f "$1" ] || return 1
  p=
  { IFS= read -r _; IFS= read -r p; } < "$1"  # the payload has no trailing newline
  case $p in *'"prompt":"<pasted_content'*) return 0 ;; *'"prompt":"<'*) return 1 ;; esac
}
if [ "$1" = running ] && typed "$f" && ! typed "$dir/$sid.first"; then cp "$f" "$dir/$sid.first"; fi
exit 0
