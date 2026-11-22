# Adds blink's hooks to Claude Code's settings.json. Idempotent: earlier
# blink entries are replaced; everyone else's hooks are left alone.
def cmd($event): {type: "command", command: ("\"$HOME/.claude/blink/hook.sh\" " + $event), async: true};
def ours: any(.hooks[]?; (.command // "") | contains("/.claude/blink/hook.sh"));
def wanted: {
  UserPromptSubmit: [{hooks: [cmd("running")]}],
  Stop:             [{hooks: [cmd("done")]}],
  StopFailure:      [{hooks: [cmd("done")]}],
  Notification:     [{matcher: "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
                      hooks: [cmd("needs")]},
                     {matcher: "idle_prompt", hooks: [cmd("idle")]}],
  PreToolUse:       [{matcher: "AskUserQuestion", hooks: [cmd("needs")]}],
  PostToolUse:      [{hooks: [cmd("tool")]}],
  SessionEnd:       [{hooks: [cmd("end")]}]
};
.hooks = (.hooks // {})
| reduce (wanted | to_entries[]) as $e (.;
    .hooks[$e.key] = (((.hooks[$e.key] // []) | map(select(ours | not))) + $e.value))
