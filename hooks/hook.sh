#!/bin/sh
# blink hook: keeps one tiny file per Claude Code session up to date.
# Claude Code runs it in the background (async) on a few lifecycle events.
# The blink app watches the folder and does everything else.
#
#   hook.sh running   UserPromptSubmit                 you sent a prompt
#   hook.sh done      Stop, StopFailure                Claude finished its turn (or, if
#                                                      background agents still work, "agents")
#   hook.sh needs     Notification (permission prompt, question), PreToolUse AskUserQuestion
#   hook.sh tool      PostToolUse                      back to "running" from needs, done or idle:
#                                                      Claude (or a subagent) is using tools, even
#                                                      without a typed prompt (a subagent reported back)
#   hook.sh idle      Notification idle_prompt         clears a stale state after an interrupt
#                                                      (never while agents still work)
#   hook.sh interrupt PostToolUseFailure               you pressed Esc mid-tool: no Stop follows
#   hook.sh end       SessionEnd                       forget the session
#
# File format: one tab-separated metadata line, then the event's JSON payload.

sid=$CLAUDE_CODE_SESSION_ID
[ -n "$sid" ] || exit 0
dir="$HOME/.claude/blink/sessions"
f="$dir/$sid.state"

case $1 in
  end)
    rm -f "$f" "$dir/$sid.first"
    exit 0 ;;
  tool|idle|interrupt)
    # Cheap guard (shell builtins only): most tool calls don't change anything.
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
    # Claude Code lists running background tasks in the Stop payload. If any
    # are agents (not shells or monitors), the session isn't done yet.
    payload=$(cat)
    case $payload in
      *'"type":"subagent"'*|*'"type":"workflow"'*|*'"type":"teammate"'*|*'"type":"cloud session"'*) state=agents ;;
      *) state=done ;;
    esac ;;
  running|needs) state=$1 ;;
  *) exit 0 ;;
esac

# Interactive sessions only (terminal or VS Code); skip `claude -p` and SDK runs.
case $CLAUDE_CODE_ENTRYPOINT in cli|claude-vscode) ;; *) exit 0 ;; esac

[ -d "$dir" ] || mkdir -p "$dir"
tmp="$dir/.$sid.$$"
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$CLAUDE_PID" "$CLAUDE_CODE_ENTRYPOINT" \
    "$TERM_PROGRAM" "$CLAUDE_CODE_SSE_PORT" "$__CFBundleIdentifier" "$CLAUDE_PROJECT_DIR"
  case $1 in
    done) printf '%s\n' "$payload" ;;
    running|needs) cat ;;
    *) tail -n +2 "$f" ;;  # tool, idle, interrupt: keep what Claude last said
  esac
} > "$tmp" && mv -f "$tmp" "$f"

# Remember the first prompt you typed; it labels sessions that share a folder.
# Skip messages Claude Code delivers as prompts (a subagent reporting back,
# task notifications), which start with a tag; a pasted block is still yours.
typed() { # typed <file>: is line 2's prompt something you typed?
  [ -f "$1" ] || return 1
  p=
  { IFS= read -r _; IFS= read -r p; } < "$1"  # the payload has no trailing newline
  case $p in *'"prompt":"<pasted_content'*) return 0 ;; *'"prompt":"<'*) return 1 ;; esac
}
if [ "$1" = running ] && typed "$f" && ! typed "$dir/$sid.first"; then cp "$f" "$dir/$sid.first"; fi
exit 0
