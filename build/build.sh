#!/bin/sh
# Build blink.
#   build/build.sh          build build/blink.app (signed with the local "blink" identity if present)
#   build/build.sh test     run the unit tests and the hook tests
#   build/build.sh vsix     package the VS Code companion extension
set -eu
cd "$(dirname "$0")/.."
# Command Line Tools can carry newer SDKs than their compiler understands;
# CommandLineTools/SDKs/MacOSX.sdk is the one that matches. Override with SDK=...
CLT=/Library/Developer/CommandLineTools
if [ -z "${SDK:-}" ]; then
  if [ "$(xcode-select -p 2>/dev/null)" = "$CLT" ] && [ -d "$CLT/SDKs/MacOSX.sdk" ]; then SDK="$CLT/SDKs/MacOSX.sdk"
  else SDK=$(xcrun --show-sdk-path); fi
fi
FLAGS="-sdk $SDK -target $(uname -m)-apple-macos13.0"
# Some CLT updates leave a stray bridging.modulemap that redefines
# SwiftBridging; hide it from this build only.
if [ -f "$CLT/usr/include/swift/bridging.modulemap" ] && [ -f "$CLT/usr/include/swift/module.modulemap" ]; then
  mkdir -p build && : > build/empty.modulemap
  printf '{"version":0,"case-sensitive":"false","roots":[{"type":"file","name":"%s","external-contents":"%s"}]}' \
    "$CLT/usr/include/swift/bridging.modulemap" "$PWD/build/empty.modulemap" > build/overlay.yaml
  FLAGS="$FLAGS -vfsoverlay build/overlay.yaml -Xcc -ivfsoverlay -Xcc build/overlay.yaml"
fi

case "${1:-app}" in
  test)
    mkdir -p build
    # Swift only runs top-level code from a file named main.swift.
    cp ancillary/tests.swift build/main.swift
    swiftc $FLAGS -D TESTING blink.swift build/main.swift -o build/tests
    ./build/tests
    sh ancillary/hook_test.sh
    ;;
  vsix)
    rm -rf build/vsix && mkdir -p build/vsix/extension
    cp ancillary/vscode-package.json build/vsix/extension/package.json
    cp ancillary/vscode-extension.js build/vsix/extension/extension.js
    cp LICENSE build/vsix/extension/
    cp ancillary/vscode.vsixmanifest build/vsix/extension.vsixmanifest
    cp ancillary/vscode-content-types.xml "build/vsix/[Content_Types].xml"
    (cd build/vsix && rm -f ../blink.vsix && zip -qrX ../blink.vsix "[Content_Types].xml" extension.vsixmanifest extension)
    echo "build/blink.vsix"
    ;;
  app)
    APP=build/blink.app
    rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
    cp ancillary/Info.plist "$APP/Contents/Info.plist"
    swiftc $FLAGS -O -wmo -parse-as-library blink.swift -o "$APP/Contents/MacOS/blink"
    if security find-identity -p codesigning 2>/dev/null | grep -q '"blink"'; then
      out=$(codesign --force --sign blink --identifier com.yashpincha.blink "$APP" 2>&1) || { echo "$out" >&2; exit 1; }
    else
      echo "note: no local 'blink' signing identity; signing ad-hoc (permissions reset on rebuild)"
      out=$(codesign --force --sign - --identifier com.yashpincha.blink "$APP" 2>&1) || { echo "$out" >&2; exit 1; }
    fi
    echo "$APP"
    ;;
  *) echo "usage: $0 [app|test|vsix]" >&2; exit 2 ;;
esac
