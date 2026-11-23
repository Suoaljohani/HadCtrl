#!/usr/bin/env bash
# HadCtrl signed IPA (G7/G8). Adapted from templates/scripts/sign-and-export.template.sh:
#  * backend URL/key come from build settings (Config/Shared.xcconfig), optionally
#    overridden by HC_SUPABASE_URL / HC_SUPABASE_PUBLISHABLE_KEY, and are validated;
#  * signing is applied through app-target variables (HC_CODE_SIGN_*), so the
#    Swift package targets are untouched;
#  * bash 3.2 safe empty-array expansion; locked package resolution.
# Release Testing (registered devices) only. No App Store/TestFlight upload.
set -euo pipefail
set +x
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'macOS with Xcode is required.' >&2; exit 2; }
for hc_name in RUNNER_TEMP GITHUB_RUN_NUMBER GITHUB_SHA HC_APP_BUNDLE_ID HC_APPLE_TEAM_ID HC_CERTIFICATE_BASE64 HC_P12_PASSWORD HC_PROVISION_PROFILE_BASE64 HC_KEYCHAIN_PASSWORD; do
  [[ -n "${!hc_name:-}" ]] || { printf 'Required input missing: %s\n' "$hc_name" >&2; exit 2; }
done
test -f HadCtrl.xcodeproj/project.pbxproj
hc_work="$(mktemp -d "$RUNNER_TEMP/hadctrl-sign.XXXXXX")"
hc_delivery="$RUNNER_TEMP/hadctrl-delivery"
[[ ! -e "$hc_delivery" ]] || { printf '%s\n' 'Refusing to overwrite an existing delivery directory.' >&2; exit 2; }
mkdir -p "$hc_delivery"
hc_keychain="$hc_work/hadctrl-signing.keychain-db"
hc_profile_paths=()
hc_original_keychains=()
while IFS= read -r hc_item; do
  hc_original_keychains+=("$hc_item")
done < <(security list-keychains -d user | python3 -c 'import shlex,sys;print("\n".join(shlex.split(sys.stdin.read())))')
hc_cleanup() {
  local hc_exit=$?
  trap - EXIT
  if ((${#hc_original_keychains[@]})); then
    security list-keychains -d user -s "${hc_original_keychains[@]}" >/dev/null 2>&1 || :
  fi
  security delete-keychain "$hc_keychain" >/dev/null 2>&1 || :
  if ((${#hc_profile_paths[@]})); then
    for hc_path in "${hc_profile_paths[@]}"; do rm -f -- "$hc_path"; done
  fi
  if [[ "$hc_work" == "$RUNNER_TEMP"/hadctrl-sign.* ]]; then rm -rf -- "$hc_work"; fi
  exit "$hc_exit"
}
trap hc_cleanup EXIT
export HC_SIGN_WORK="$hc_work"
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['HC_SIGN_WORK'])
for name, target in [('HC_CERTIFICATE_BASE64', 'certificate.p12'), ('HC_PROVISION_PROFILE_BASE64', 'profile.mobileprovision')]:
    encoded = ''.join(os.environ[name].split())
    raw = base64.b64decode(encoded, validate=True)
    if not raw:
        raise SystemExit('Empty signing input.')
    path = root / target
    path.write_bytes(raw)
    path.chmod(0o600)
PY
security cms -D -i "$hc_work/profile.mobileprovision" > "$hc_work/profile.plist"
hc_profile_uuid="$(python3 - <<'PY'
import datetime, os, plistlib, re
from pathlib import Path
p = plistlib.loads((Path(os.environ['HC_SIGN_WORK']) / 'profile.plist').read_bytes())
bundle = os.environ['HC_APP_BUNDLE_ID']
team = os.environ['HC_APPLE_TEAM_ID']
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]+', bundle) or bundle.startswith('com.example'):
    raise SystemExit('A final Bundle ID is required.')
if team not in p.get('TeamIdentifier', []):
    raise SystemExit('Provisioning profile Team ID mismatch.')
entitlements = p.get('Entitlements', {})
prefixes = p.get('ApplicationIdentifierPrefix', [])
if entitlements.get('application-identifier') not in [prefix + '.' + bundle for prefix in prefixes]:
    raise SystemExit('Provisioning profile must explicitly match the Bundle ID.')
if entitlements.get('get-task-allow', False):
    raise SystemExit('Release Testing requires a distribution profile, not a debugging profile.')
if p.get('ProvisionsAllDevices') or not p.get('ProvisionedDevices'):
    raise SystemExit('This template requires an ad hoc profile with registered devices.')
expires = p.get('ExpirationDate')
if not expires:
    raise SystemExit('Profile expiry missing.')
if expires.tzinfo is None:
    expires = expires.replace(tzinfo=datetime.timezone.utc)
if expires <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit('Provisioning profile has expired.')
uuid = p.get('UUID', '')
if not re.fullmatch(r'[A-Fa-f0-9-]{36}', uuid):
    raise SystemExit('Invalid provisioning profile UUID.')
print(uuid)
PY
)"
security create-keychain -p "$HC_KEYCHAIN_PASSWORD" "$hc_keychain"
security set-keychain-settings -lut 21600 "$hc_keychain"
security unlock-keychain -p "$HC_KEYCHAIN_PASSWORD" "$hc_keychain"
security import "$hc_work/certificate.p12" -P "$HC_P12_PASSWORD" -A -t cert -f pkcs12 -k "$hc_keychain" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$HC_KEYCHAIN_PASSWORD" "$hc_keychain" >/dev/null
security list-keychains -d user -s ${hc_original_keychains[@]+"${hc_original_keychains[@]}"} "$hc_keychain"
# Xcode versions use different profile discovery directories; do not overwrite
# an existing profile. Both copies belong to this hosted job and are removed.
for hc_dir in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$hc_dir"
  hc_target="$hc_dir/$hc_profile_uuid.mobileprovision"
  [[ ! -e "$hc_target" ]] || { printf '%s\n' 'An existing profile would be overwritten.' >&2; exit 2; }
  cp "$hc_work/profile.mobileprovision" "$hc_target"
  chmod 600 "$hc_target"
  hc_profile_paths+=("$hc_target")
done
export HC_PROFILE_UUID="$hc_profile_uuid"
# Effective backend settings: committed xcconfig unless overridden by variables.
hc_settings="$(xcodebuild -showBuildSettings -project HadCtrl.xcodeproj -scheme HadCtrl -configuration Release 2>/dev/null)"
export HC_EFFECTIVE_URL="${HC_SUPABASE_URL:-$(awk -F' = ' '/^ *HC_SUPABASE_URL = /{print $2; exit}' <<<"$hc_settings")}"
export HC_EFFECTIVE_KEY="${HC_SUPABASE_PUBLISHABLE_KEY:-$(awk -F' = ' '/^ *HC_SUPABASE_PUBLISHABLE_KEY = /{print $2; exit}' <<<"$hc_settings")}"
python3 - <<'PY'
import base64, json, os, plistlib, urllib.parse
from pathlib import Path
url = os.environ['HC_EFFECTIVE_URL']
key = os.environ['HC_EFFECTIVE_KEY']
parsed = urllib.parse.urlparse(url)
if parsed.scheme != 'https' or not parsed.hostname or parsed.hostname in ('example.supabase.co', 'example.com'):
    raise SystemExit('A real HTTPS Supabase project URL is required.')
if not key or key.startswith('sb_secret_') or key == 'CI_MOCK_ONLY_NOT_A_REAL_KEY':
    raise SystemExit('Only a publishable client key is allowed.')
if key.count('.') == 2:
    try:
        part = key.split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
    except (ValueError, json.JSONDecodeError):
        raise SystemExit('Invalid legacy client key format.')
    if claims.get('role') == 'service_role':
        raise SystemExit('Service role keys must never be embedded in the app.')
options = {
    'method': 'release-testing',
    'destination': 'export',
    'signingStyle': 'manual',
    'teamID': os.environ['HC_APPLE_TEAM_ID'],
    'provisioningProfiles': {os.environ['HC_APP_BUNDLE_ID']: os.environ['HC_PROFILE_UUID']},
    'stripSwiftSymbols': True,
    'manageAppVersionAndBuildNumber': False,
}
(Path(os.environ['HC_SIGN_WORK']) / 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
hc_url_setting="${HC_EFFECTIVE_URL/:\/\//:\/\$()\/}"   # keep the // out of xcconfig comment parsing
xcodebuild -resolvePackageDependencies -project HadCtrl.xcodeproj -scheme HadCtrl \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution
xcodebuild archive -project HadCtrl.xcodeproj -scheme HadCtrl -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$hc_work/HadCtrl.xcarchive" \
  -derivedDataPath "$hc_work/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution \
  HC_APPLE_TEAM_ID="$HC_APPLE_TEAM_ID" HC_APP_BUNDLE_ID="$HC_APP_BUNDLE_ID" \
  HC_CODE_SIGN_STYLE=Manual HC_CODE_SIGN_IDENTITY='Apple Distribution' \
  HC_PROVISIONING_PROFILE="$hc_profile_uuid" CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" \
  HC_SUPABASE_URL="$hc_url_setting" HC_SUPABASE_PUBLISHABLE_KEY="$HC_EFFECTIVE_KEY"
xcodebuild -exportArchive -archivePath "$hc_work/HadCtrl.xcarchive" \
  -exportPath "$hc_work/export" -exportOptionsPlist "$hc_work/ExportOptions.plist"
hc_ipas=("$hc_work"/export/*.ipa)
[[ ${#hc_ipas[@]} -eq 1 && -f "${hc_ipas[0]}" ]] || { printf '%s\n' 'Expected exactly one exported IPA.' >&2; exit 2; }
cp "${hc_ipas[0]}" "$hc_delivery/HadCtrl.ipa"
ditto -x -k "$hc_delivery/HadCtrl.ipa" "$hc_work/verify"
hc_app="$hc_work/verify/Payload/HadCtrl.app"
test -d "$hc_app"
codesign --verify --deep --strict --verbose=2 "$hc_app"
security cms -D -i "$hc_app/embedded.mobileprovision" > "$hc_work/embedded.plist"
codesign -d --entitlements :- "$hc_app" > "$hc_work/app-entitlements.plist" 2> "$hc_work/codesign-display.log"
export HC_DELIVERY_DIR="$hc_delivery"
python3 - <<'PY'
import datetime, hashlib, os, plistlib, subprocess
from pathlib import Path
root = Path(os.environ['HC_SIGN_WORK'])
delivery = Path(os.environ['HC_DELIVERY_DIR'])
app = root / 'verify/Payload/HadCtrl.app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
profile = plistlib.loads((root / 'embedded.plist').read_bytes())
entitlements = plistlib.loads((root / 'app-entitlements.plist').read_bytes())
if info.get('CFBundleIdentifier') != os.environ['HC_APP_BUNDLE_ID']:
    raise SystemExit('Exported Bundle ID mismatch.')
if str(info.get('CFBundleVersion')) != os.environ['GITHUB_RUN_NUMBER']:
    raise SystemExit('Exported build number mismatch.')
if profile.get('UUID') != os.environ['HC_PROFILE_UUID']:
    raise SystemExit('Exported provisioning profile mismatch.')
if entitlements.get('com.apple.developer.team-identifier') != os.environ['HC_APPLE_TEAM_ID']:
    raise SystemExit('Signed app Team ID mismatch.')
if entitlements.get('get-task-allow', False):
    raise SystemExit('Exported app is debuggable; release verification failed.')
if info.get('HCDefaultAppEnvironment') != 'production':
    raise SystemExit('Release IPA must default to the production environment.')
if info.get('HCSupabaseURL') != os.environ['HC_EFFECTIVE_URL'] or info.get('HCSupabasePublishableKey') != os.environ['HC_EFFECTIVE_KEY']:
    raise SystemExit('Backend configuration in the IPA does not match the validated settings.')
digest = hashlib.sha256((delivery / 'HadCtrl.ipa').read_bytes()).hexdigest()
(delivery / 'SHA256SUMS.txt').write_text(digest + '  HadCtrl.ipa\n')
lines = [
    'HadCtrl automated IPA validation',
    'Commit: ' + os.environ['GITHUB_SHA'],
    'Build: ' + os.environ['GITHUB_RUN_NUMBER'],
    'Bundle ID: ' + os.environ['HC_APP_BUNDLE_ID'],
    'Distribution: release-testing; registered devices only',
    'Device installation: NOT VERIFIED by this automated script',
    'Generated UTC: ' + datetime.datetime.now(datetime.timezone.utc).isoformat(),
    subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'SHA-256: ' + digest,
]
(delivery / 'BUILD_REPORT.txt').write_text('\n'.join(lines) + '\n')
PY
test -d "$hc_work/HadCtrl.xcarchive/dSYMs"
ditto -c -k --keepParent "$hc_work/HadCtrl.xcarchive/dSYMs" "$hc_delivery/dSYMs.zip"
for hc_file in HadCtrl.ipa SHA256SUMS.txt BUILD_REPORT.txt dSYMs.zip; do
  test -s "$hc_delivery/$hc_file"
done
printf '%s\n' 'IPA exported and structurally validated. Physical-device installation remains a separate acceptance test.'
