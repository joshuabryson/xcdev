#!/bin/sh
# Builds MacProbeApp.app into $1 with swiftc; --sandbox signs it with the App Sandbox entitlement.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$1"; shift
app="$out/MacProbeApp.app"
mkdir -p "$app/Contents/MacOS"
swiftc -parse-as-library -swift-version 5 -O -o "$app/Contents/MacOS/MacProbeApp" "$here/main.swift"
cp "$here/Info.plist" "$app/Contents/Info.plist"
if [ "${1:-}" = "--sandbox" ]; then
    ent=$(mktemp)
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>\n' > "$ent"
    codesign --force --sign - --entitlements "$ent" "$app"
    rm -f "$ent"
else
    codesign --force --sign - "$app"
fi
echo "$app"
