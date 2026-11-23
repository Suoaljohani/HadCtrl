# Setup

## What is already configured
- Supabase project **HadCtrl** (`vffusttzqmerfofqianz`, region ap-southeast-1). URL: `https://vffusttzqmerfofqianz.supabase.co`, set in `Config/Shared.xcconfig`.
- Brand: hospital logo and Janna LT in `Brand/` (Janna is bundled in the app under the license the owner confirmed).

## Still needed from the owner

| Input | Where it goes | Blocks |
|---|---|---|
| Supabase **publishable** key (`sb_publishable_…`) | repo variable `HC_SUPABASE_PUBLISHABLE_KEY`, or untracked `Config/Local.xcconfig` | real sign-in in the app (production build shows a config error until then) |
| First director account | Supabase Auth invite, then the bootstrap SQL in RUNBOOK §2 | any real data |
| Real departments (names, codes, heads) | admin SQL or the future admin screen | operational use |
| Apple Team ID, bundle id | GitHub environment `ios-signing` variables `HC_APPLE_TEAM_ID`, `HC_APP_BUNDLE_ID` | G7 IPA |
| Distribution certificate (.p12 + password), provisioning profile, keychain password | `ios-signing` secrets (see `docs/SETUP_INPUTS_AR.md`) | G7 IPA |
| `HC_XCODE_VERSION` | repo variable, after the first green CI run | reproducible builds |

Never paste keys, passwords or certificates into chat or commit them. `scripts/check-no-secrets.sh` runs in CI.

## Local development
- Database: `sudo -u postgres ./scripts/db-test.sh` (needs a local PostgreSQL 16+). It drops and recreates `hadctrl_test` on localhost only.
- iOS (on a Mac): `brew install xcodegen` (2.43.0), then `xcodegen generate`, open `HadCtrl.xcodeproj`, and run the `HadCtrl` scheme. Debug runs in `demo` mode with labelled synthetic data; set `HC_DEMO_USER=head` to see a department head's view.
