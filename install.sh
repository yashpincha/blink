#!/bin/sh
# Install blink: build the app, add the Claude Code hooks, add the VS Code helper.
# Safe to re-run (that's also how you update).
set -eu
cd "$(dirname "$0")"
APPS="$HOME/Applications"
DATA="$HOME/.claude/blink"
SETTINGS="$HOME/.claude/settings.json"
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

command -v jq >/dev/null || { echo "blink needs jq (macOS 15+ ships it; otherwise: brew install jq)" >&2; exit 1; }

# 1. A local code-signing identity. macOS ties Accessibility and Automation
#    permissions to the app's signature; a stable identity keeps them across
#    rebuilds. It lives only in your login keychain.
if ! security find-identity -p codesigning 2>/dev/null | grep -q '"blink"'; then
  say "Creating a local signing certificate in your login keychain"
  tmp=$(mktemp -d)
  cat > "$tmp/cfg" <<'CFG'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = blink
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name blink \
    -out "$tmp/id.p12" -passout pass:blink
  security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P blink -T /usr/bin/codesign >/dev/null
  rm -rf "$tmp"
  echo "    If macOS asks to let codesign use the 'blink' key, enter your password and choose Always Allow."
fi

# 2. Build and install the app.
say "Building"
./build.sh >/dev/null
pkill -x blink 2>/dev/null || true
mkdir -p "$APPS"
rm -rf "$APPS/blink.app"
cp -R build/blink.app "$APPS/"
echo "    $APPS/blink.app"

# 3. The hook script, and the hooks in Claude Code's settings (backup first).
say "Adding Claude Code hooks"
mkdir -p "$DATA/sessions"
cp hooks/hook.sh "$DATA/hook.sh"
chmod +x "$DATA/hook.sh"
mkdir -p "$(dirname "$SETTINGS")"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-blink"
jq -f scripts/hooks-add.jq "$SETTINGS" > "$SETTINGS.tmp-blink"
mv "$SETTINGS.tmp-blink" "$SETTINGS"
echo "    $SETTINGS (backup: settings.json.bak-blink)"

# 4. The VS Code helper that focuses the exact terminal tab.
if command -v code >/dev/null; then
  say "Installing the VS Code helper extension"
  ./build.sh vsix >/dev/null
  code --install-extension build/blink.vsix --force >/dev/null
fi

# 5. Start it.
open "$APPS/blink.app"
say "Done"
cat <<'MSG'
    - The dot is in your menu bar. If you can't see it (a notch can hide icons),
      quit some menu bar apps, then hold ⌘ and drag the dot next to the clock.
    - Claude Code sessions that are already open need a restart to pick up the hooks.
    - First click on a VS Code session: VS Code asks to allow blink to open a
      link; tick "Don't ask again". First Terminal.app click: allow "control Terminal".
MSG
