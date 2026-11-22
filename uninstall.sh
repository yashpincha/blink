#!/bin/sh
# Remove everything install.sh added. Pass --keep-cert to keep the signing certificate.
set -u
cd "$(dirname "$0")"
APP="$HOME/Applications/blink.app"
SETTINGS="$HOME/.claude/settings.json"

pkill -x blink 2>/dev/null
[ -x "$APP/Contents/MacOS/blink" ] && "$APP/Contents/MacOS/blink" --unregister-login
if [ -f "$SETTINGS" ] && command -v jq >/dev/null; then
  cp "$SETTINGS" "$SETTINGS.bak-blink"
  jq -f scripts/hooks-remove.jq "$SETTINGS" > "$SETTINGS.tmp-blink" && mv "$SETTINGS.tmp-blink" "$SETTINGS"
fi
rm -rf "$APP" "$HOME/.claude/blink"
command -v code >/dev/null && code --uninstall-extension yashpincha.blink >/dev/null 2>&1
tccutil reset Accessibility com.yashpincha.blink >/dev/null 2>&1
tccutil reset AppleEvents com.yashpincha.blink >/dev/null 2>&1
defaults delete com.yashpincha.blink >/dev/null 2>&1
[ "${1:-}" = "--keep-cert" ] || security delete-identity -c blink >/dev/null 2>&1
echo "blink removed. Open Claude Code sessions keep their hooks until restarted."
