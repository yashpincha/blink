#!/bin/sh
# blink hook: keeps one tiny file per Claude Code session up to date.
# Claude Code runs it in the background (async) on a few lifecycle events.
# The blink app watches the folder and does everything else.
#
#   hook.sh running   UserPromptSubmit                 you sent a prompt
#   hook.sh done      Stop, StopFailure                Claude finished its turn
#   hook.sh needs     Notification (permission prompt, question), PreToolUse AskUserQuestion
#   hook.sh tool      PostToolUse                      only used to leave "needs"
#   hook.sh idle      Notification idle_prompt         clears a stale state after an interrupt
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
  tool|idle)
    # Cheap guard (shell builtins only): most tool calls don't change anything.
    [ -f "$f" ] || exit 0
    IFS= read -r head < "$f"
    case "$1:$head" in
      tool:needs*) state=running ;;
      idle:running*|idle:needs*) state=idle ;;
      *) exit 0 ;;
    esac ;;
  running|done|needs) state=$1 ;;
  *) exit 0 ;;
esac

# Interactive sessions only (terminal or VS Code); skip `claude -p` and SDK runs.
case $CLAUDE_CODE_ENTRYPOINT in cli|claude-vscode) ;; *) exit 0 ;; esac

[ -d "$dir" ] || mkdir -p "$dir"
tmp="$dir/.$sid.$$"
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$CLAUDE_PID" "$CLAUDE_CODE_ENTRYPOINT" \
    "$TERM_PROGRAM" "$CLAUDE_CODE_SSE_PORT" "$__CFBundleIdentifier" "$CLAUDE_PROJECT_DIR"
  if [ "$1" = "$state" ]; then cat; fi
} > "$tmp" && mv -f "$tmp" "$f"

# Remember the first prompt; it labels sessions that share a folder.
if [ "$1" = running ] && [ ! -f "$dir/$sid.first" ]; then cp "$f" "$dir/$sid.first"; fi
exit 0
