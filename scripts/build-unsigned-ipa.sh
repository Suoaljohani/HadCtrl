#!/usr/bin/env bash
# UNSIGNED device build for owner-side re-signing (e.g. Sideloadly / Xcode with
# the owner's own Apple ID). It is NOT installable as-is and is never described
# as a release IPA (spec §32, §36). No signing material is used or needed.
set -euo pipefail
# macOS ships bash 3.2: avoid empty-array expansion under set -u.
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS with Xcode is required.' >&2; exit 2; }
: "${RUNNER_TEMP:?}" "${GITHUB_RUN_NUMBER:?}" "${GITHUB_SHA:?}"
test -f HadCtrl.xcodeproj/project.pbxproj
work="$(mktemp -d "$RUNNER_TEMP/hadctrl-unsigned.XXXXXX")"
out="$RUNNER_TEMP/hadctrl-unsigned"
mkdir -p "$out"
short_sha="${GITHUB_SHA:0:7}"
name="HadCtrl-UNSIGNED-build${GITHUB_RUN_NUMBER}-${short_sha}.ipa"

xcodebuild -resolvePackageDependencies -project HadCtrl.xcodeproj -scheme HadCtrl \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution
xcodebuild archive -project HadCtrl.xcodeproj -scheme HadCtrl -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$work/HadCtrl.xcarchive" \
  -derivedDataPath "$work/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER"

app="$work/HadCtrl.xcarchive/Products/Applications/HadCtrl.app"
test -d "$app"
mkdir -p "$work/pkg/Payload"
cp -R "$app" "$work/pkg/Payload/"
(cd "$work/pkg" && /usr/bin/zip -qry "$out/$name" Payload)

export HC_APP="$app" HC_OUT="$out" HC_NAME="$name"
python3 - <<'PY'
import hashlib, os, plistlib, subprocess, zipfile
from pathlib import Path
app, out, name = Path(os.environ['HC_APP']), Path(os.environ['HC_OUT']), os.environ['HC_NAME']
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info.get('CFBundleExecutable') == 'HadCtrl', 'unexpected executable'
assert info.get('HCDefaultAppEnvironment') == 'production', 'Release build must default to production'
assert info.get('HCSupabaseURL', '').startswith('https://'), 'missing backend URL'
key = info.get('HCSupabasePublishableKey', '')
assert key.startswith('sb_publishable_') and not key.startswith('sb_secret_'), 'client key must be publishable'
assert info.get('DTPlatformName') == 'iphoneos', 'not a device build'
with zipfile.ZipFile(out / name) as z:
    assert 'Payload/HadCtrl.app/HadCtrl' in z.namelist(), 'Payload/HadCtrl.app missing'
signed = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True)
assert signed.returncode != 0, 'expected an unsigned app'
digest = hashlib.sha256((out / name).read_bytes()).hexdigest()
(out / 'SHA256SUMS.txt').write_text(f'{digest}  {name}\n')
(out / 'READ-ME-FIRST.txt').write_text(
    'HadCtrl UNSIGNED device build\n'
    f'Commit: {os.environ["GITHUB_SHA"]}\nBuild: {os.environ["GITHUB_RUN_NUMBER"]}\nSHA-256: {digest}\n'
    f'Bundle id (placeholder): {info.get("CFBundleIdentifier")}\nVersion: {info.get("CFBundleShortVersionString")}\n'
    f'{subprocess.check_output(["xcodebuild", "-version"], text=True).strip()}\n\n'
    'This file is NOT signed and cannot be installed as-is.\n'
    'Re-sign it with your own Apple ID (e.g. Sideloadly) to run it on your own iPhone;\n'
    'see docs/INSTALL.md. Backend: production Supabase project, publishable key only.\n')
print('unsigned IPA built:', name, digest)
PY
