#!/usr/bin/env bash
# Generate HadCtrl.xcodeproj from project.yml and install the committed
# Swift package lock (Config/Package.resolved) so builds use exactly the
# reviewed dependency versions.
set -euo pipefail
xcodegen generate --spec project.yml
lock_dir="HadCtrl.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
if [ -f Config/Package.resolved ]; then
  mkdir -p "$lock_dir"
  cp Config/Package.resolved "$lock_dir/Package.resolved"
  echo "installed Config/Package.resolved"
else
  echo "WARNING: Config/Package.resolved missing; resolution is unlocked (bootstrap run only)" >&2
fi
