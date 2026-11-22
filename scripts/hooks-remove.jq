# Removes blink's hooks from Claude Code's settings.json, and nothing else.
def ours: any(.hooks[]?; (.command // "") | contains("/.claude/blink/hook.sh"));
if .hooks then
  .hooks |= (with_entries(.value |= map(select(ours | not))) | with_entries(select(.value | length > 0)))
  | if (.hooks | length) == 0 then del(.hooks) else . end
else . end
