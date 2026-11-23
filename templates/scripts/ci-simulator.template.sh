#!/usr/bin/env bash
# TEMPLATE: project must load HC_APP_ENV=ui-testing and inject mock repositories
# for deterministic UI tests. Real backend integration has its own test job.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'macOS with Xcode is required.' >&2; exit 2; }
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
test -f HadCtrl.xcodeproj/project.pbxproj
hc_devices_json="$RUNNER_TEMP/hadctrl-simulators.json"
xcrun simctl list devices available --json > "$hc_devices_json"
hc_simulator_id="$(python3 - "$hc_devices_json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)
candidates = []
for runtime, devices in data.get('devices', {}).items():
    if '.iOS-' not in runtime:
        continue
    version = tuple(int(part) for part in runtime.split('.iOS-')[1].split('-'))
    for device in devices:
        if device.get('isAvailable') and device.get('name', '').startswith('iPhone'):
            candidates.append((version, device['name'], device['udid']))
if not candidates:
    raise SystemExit('No available iPhone simulator. Install a runtime or change runner.')
print(sorted(candidates, reverse=True)[0][2])
PY
)"
hc_simulator_state="$(python3 - "$hc_devices_json" "$hc_simulator_id" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)
for devices in data.get('devices', {}).values():
    for device in devices:
        if device.get('udid') == sys.argv[2]:
            print(device['state'])
            raise SystemExit(0)
raise SystemExit('Selected simulator disappeared.')
PY
)"
if [[ "$hc_simulator_state" != Booted ]]; then
  xcrun simctl boot "$hc_simulator_id"
fi
xcrun simctl bootstatus "$hc_simulator_id" -b
# Supply the agreed resource format; it must be part of the generated project.
mkdir -p Config
python3 - <<'PY'
import plistlib
from pathlib import Path
config = {
    'APP_ENV': 'ui-testing',
    'SUPABASE_URL': 'https://example.supabase.co',
    'SUPABASE_PUBLISHABLE_KEY': 'CI_MOCK_ONLY_NOT_A_REAL_KEY',
}
Path('Config/AppConfig.plist').write_bytes(plistlib.dumps(config))
PY
xcodebuild -resolvePackageDependencies -project HadCtrl.xcodeproj -scheme HadCtrl
xcodebuild test -project HadCtrl.xcodeproj -scheme HadCtrl \
  -configuration Debug -destination "platform=iOS Simulator,id=$hc_simulator_id" \
  -derivedDataPath "$RUNNER_TEMP/HadCtrlDerivedData" \
  -resultBundlePath "$RUNNER_TEMP/HadCtrlTests.xcresult" \
  CODE_SIGNING_ALLOWED=NO
