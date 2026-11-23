# Setup

## What is already configured
- Supabase project **HadCtrl** (`vffusttzqmerfofqianz`, region ap-southeast-1). URL: `https://vffusttzqmerfofqianz.supabase.co`, set in `Config/Shared.xcconfig`.
- Publishable key `sb_publishable__q7R9…` in `Config/Shared.xcconfig` (supplied and approved by the owner; verified live that it is this project's enabled key and that signed-out calls are refused).
- Brand: hospital logo and Janna LT in `Brand/` (Janna is bundled in the app under the license the owner confirmed).

## Recommended in the Supabase dashboard
- **Authentication → Providers → Email → Leaked password protection**: enable it (flagged by the security advisor). It rejects known-breached passwords when employees replace their temporary one.

## Still needed from the owner

| Input | Where it goes | Blocks |
|---|---|---|
| First director account | Auth → Add user, then `supabase/admin/01_bootstrap_first_director.sql` (RUNBOOK §2) | any real data |
| Real departments (names, codes, heads) | admin SQL or the future admin screen | operational use |
| Apple Team ID, bundle id | GitHub environment `ios-signing` variables `HC_APPLE_TEAM_ID`, `HC_APP_BUNDLE_ID` | G7 IPA |
| Distribution certificate (.p12 + password), provisioning profile, keychain password | `ios-signing` secrets (see `docs/SETUP_INPUTS_AR.md`) | G7 IPA |
| `HC_XCODE_VERSION` | repo variable, after the first green CI run | reproducible builds |

Never paste keys, passwords or certificates into chat or commit them. `scripts/check-no-secrets.sh` runs in CI.

## Local development
- Database: `sudo -u postgres ./scripts/db-test.sh` (needs a local PostgreSQL 16+). It drops and recreates `hadctrl_test` on localhost only.
- iOS (on a Mac): `brew install xcodegen` (2.43.0), then `xcodegen generate`, open `HadCtrl.xcodeproj`, and run the `HadCtrl` scheme. Debug runs in `demo` mode with labelled synthetic data; set `HC_DEMO_USER=head` to see a department head's view. To run against Supabase, set the scheme's `HC_APP_ENV=production` and provide the key in `Config/Local.xcconfig`.
- Swift packages: `scripts/generate-project.sh` installs `Config/Package.resolved`. To change a dependency, edit `project.yml`, resolve on a Mac, and commit the new `Package.resolved` with a DECISIONS entry.
