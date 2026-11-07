#!/bin/sh
# Builds the recorder as one optimized native binary (no dependencies).
#
# The installed Command Line Tools ship two modulemaps that both define SwiftBridging
# (usr/include/swift/module.modulemap is a stale 2023 copy of bridging.modulemap), which
# breaks every `import Foundation`. A VFS overlay hides the stale one for this build only;
# no system file is touched. Drop the overlay once the CLT is reinstalled or fixed.
set -e
cd "$(dirname "$0")"
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
OVERLAY=""
if [ -f "$STALE" ] && [ -f "$(dirname "$STALE")/bridging.modulemap" ]; then
  : > .empty.modulemap
  printf '{ "version": 0, "roots": [ { "name": "%s", "type": "file", "external-contents": "%s/.empty.modulemap" } ] }\n' "$STALE" "$PWD" > .vfs.yaml
  OVERLAY="-vfsoverlay .vfs.yaml -Xcc -ivfsoverlay -Xcc .vfs.yaml"
fi
xcrun swiftc -O -swift-version 5 $OVERLAY main.swift -o hex-voice-recorder
echo "built ./hex-voice-recorder"
