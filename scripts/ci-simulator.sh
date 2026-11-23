#!/usr/bin/env bash
# Build + test HadCtrl on the newest available iPhone simulator (unsigned).
# Mock repositories only (HC_APP_ENV=ui-testing via the scheme). No secrets.
set -euo pipefail
# Note: macOS ships bash 3.2; empty arrays are expanded with ${a[@]+"${a[@]}"} under set -u.
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS with Xcode is required.' >&2; exit 2; }
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
test -f HadCtrl.xcodeproj/project.pbxproj

devices="$RUNNER_TEMP/hadctrl-simulators.json"
xcrun simctl list devices available --json > "$devices"
sim_id="$(python3 - "$devices" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
cands = []
for runtime, devs in data.get('devices', {}).items():
    if '.iOS-' not in runtime:
        continue
    version = tuple(int(p) for p in runtime.split('.iOS-')[1].split('-'))
    for d in devs:
        if d.get('isAvailable') and d.get('name', '').startswith('iPhone'):
            cands.append((version, d['name'], d['udid']))
if not cands:
    raise SystemExit('No available iPhone simulator.')
best = sorted(cands, reverse=True)[0]
print(best[2])
print(f"selected simulator: {best[1]} iOS {'.'.join(map(str, best[0]))}", file=sys.stderr)
PY
)"
xcrun simctl boot "$sim_id" 2>/dev/null || true
xcrun simctl bootstatus "$sim_id" -b

lock="HadCtrl.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ -f Config/Package.resolved ]; then
  # Locked: fail instead of silently picking different versions.
  xcodebuild -resolvePackageDependencies -project HadCtrl.xcodeproj -scheme HadCtrl \
    -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution
  locked_flags=(-onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution)
else
  xcodebuild -resolvePackageDependencies -project HadCtrl.xcodeproj -scheme HadCtrl
  locked_flags=()
fi
mkdir -p "$RUNNER_TEMP/swiftpm"
cp "$lock" "$RUNNER_TEMP/swiftpm/Package.resolved"
echo "----- Package.resolved -----"; cat "$lock"; echo "----------------------------"
xcodebuild test -project HadCtrl.xcodeproj -scheme HadCtrl \
  -configuration Debug -destination "platform=iOS Simulator,id=$sim_id" \
  -derivedDataPath "$RUNNER_TEMP/HadCtrlDerivedData" \
  -resultBundlePath "$RUNNER_TEMP/HadCtrlTests.xcresult" \
  ${locked_flags[@]+"${locked_flags[@]}"} \
  CODE_SIGNING_ALLOWED=NO
