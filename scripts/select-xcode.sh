#!/bin/sh
# Selects the named Xcode for CI, or fails with a clear message instead of using whatever is the default.
#   scripts/select-xcode.sh /Applications/Xcode_26.2.app
set -eu
app=${1:?usage: scripts/select-xcode.sh <path to Xcode.app>}
if [ ! -d "$app" ]; then
    echo "::error::$app is not installed on this runner image; update the pinned Xcode in the workflows' XCODE_APP"
    echo "installed:"
    ls -d /Applications/Xcode* || true
    exit 1
fi
sudo xcode-select -s "$app"
xcodebuild -version
