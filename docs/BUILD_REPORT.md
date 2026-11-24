# Build report

| Item | Value |
|---|---|
| Build type so far | **Simulator only, unsigned** (`CODE_SIGNING_ALLOWED=NO`). No device archive, no IPA. |
| Runner | GitHub `macos-15-arm64` (image 20261118.0550), Xcode 26.3 (17C529), Swift 6.2.4; simulator iPhone SE (3rd gen), iOS 26.2 |
| Project generation | XcodeGen 2.43.0 from `project.yml` |
| Minimum iOS | 17.0 |
| Swift packages | supabase-swift 2.55.7 + 6 transitive packages, locked by `Config/Package.resolved` (D-22) |
| Bundle id | placeholder `invalid.hadctrl.app` |

## CI runs
| Run | Commit | Database | iOS |
|---|---|---|---|
| #1 | 9cb1b1e | failed: workspace permission (fixed) | cancelled by a later push |
| #2 | 8954872 | pass | build OK; unit 36/36 pass; UI 3/5 (dashboard tile not in accessibility tree: lazy stacks) |
| #5 | 5691919 | pass | build OK; unit 36/36 pass; UI 3/5 (scroll-before-load race; status asserted as staticText) |
| #6 | 0324be8 | pass | packages resolved (2.55.7 + deps); stopped by a CI script bug (bash 3.2 empty array) before compiling G3 |
| #7 | a52fafc | pass | same CI script bug |
| #8 | 33b5dd5 | pass | **G3 with supabase-swift compiles**; locked resolution; unit 42/42 pass (incl. 6 Supabase contract tests); UI 3/5 (container id overrode the badge id; lazy List hid the 2nd action on iPhone SE) |
| #9 | 5b974e2 | pass | build OK; unit 42/42; UI 4/5 (approve flow passes; return flow passes but the badge had scrolled out of the lazy List before the check) |
| #10 | feb050b | pass | build OK; unit 42/42; UI 4/5: return flow passes; approve flow's tile existed but full swipes overshot it under the bars (16 swipes) |
| **#11** | **0492f7a** | **pass** | **pass: project generated from project.yml, `xcodebuild -list` + shared HadCtrl scheme, locked packages, simulator build, unit 42/42, UI 5/5, built-app secret scan clean. G1 gate met (simulator only).** |

Update this table after each run. A signed IPA (G7) needs the Apple inputs listed in SETUP.md.

## Device builds
| Build | Commit | Kind | Result |
|---|---|---|---|
| unsigned #1 | 947a1c4 | **UNSIGNED** Release device build (`generic/platform=iOS`), Xcode 26.3 | `HadCtrl-UNSIGNED-build1-947a1c4.ipa`, SHA-256 `b2d30114b25ea0c320298f865e79848f1bcb258d3c9496c8a8302d86c3ee5336`; artifact digest verified after download. Contents checked: arm64 Mach-O, `iphoneos`, min iOS 17.0, display name قيادة, production backend `vffusttzqmerfofqianz`, publishable key only (the only `sb_secret_` bytes are the guard-prefix constant, not a key), no `_CodeSignature`/profile, Janna LT and app icon present. **Not installable as-is; not a release IPA (§32).** |
| signed | — | Release Testing (Ad Hoc) via `build-ipa.yml` | **Not produced:** needs Apple Developer membership, bundle ID, distribution .p12, Ad Hoc profile with registered UDIDs in the `ios-signing` environment, and the code merged to `main`. |

## Unsigned device build 10 (commit 55ac439), 2026-11-23
- CI run #25 on the same commit: green (database suite; simulator build; 69/69 unit tests in 13 suites; 9/9 UI tests).
- Artifact `HadCtrl-UNSIGNED-build10`, IPA SHA-256 `7eba27a633989682d73f2af186c69acb064edf23ffc043cc00af95e137e7f994` (matches SHA256SUMS.txt).
- Verified after download: no `_CodeSignature` (unsigned), `CFBundleVersion` 10, `HCDefaultAppEnvironment` production, `HCSupabaseURL` https://vffusttzqmerfofqianz.supabase.co, publishable key only; `UIBackgroundModes` fetch + `BGTaskSchedulerPermittedIdentifiers` for the inbox refresh (D-30).
- Includes: reports and indicators screens (G4–G5 client), director definitions, in-app inbox. Must be re-signed by the owner (docs/INSTALL.md).

## Unsigned device build 13 (commit ad4e130), 2026-11-23
- CI run #28 on the same commit: green (database; simulator build; unit and UI tests incl. 5 achievement unit tests and 2 achievement UI tests).
- IPA SHA-256 `7aef57dd700e442826973f1643b2abda8c6d91eb72e0e3b6c3464b400766cd45` (matches SHA256SUMS.txt). Unsigned (no `_CodeSignature`), `CFBundleVersion` 13, production backend, publishable key only.
- Adds achievements (list, detail, director decision, add/edit). Hosted migration 001500 applied by the owner and verified.

## Unsigned device build 16 (commit dbddf27), 2026-11-23
- CI run #31 on the same commit: green (database incl. 88_goals; simulator build; unit tests incl. 7 goal tests; UI tests incl. goal activation and department card).
- IPA SHA-256 `2548bb6d2b86b30289c8900c6173278cae1e77296c4b71a74fe48318a85e346a` (matches SHA256SUMS.txt). Unsigned, `CFBundleVersion` 16, production backend, publishable key only.
- Adds goals (list, detail, new goal, director lifecycle, milestones) and the full department card.

## Unsigned device build 31 (commit b9ca35f), 2026-11-24
- IPA SHA-256 `0c68237e11bc0676a31b2cf0cf857654c6a820032e9def94f59ff5c8f90445e0` (matches SHA256SUMS.txt). Unsigned, `CFBundleVersion` 31, production backend, publishable key only, `NSFaceIDUsageDescription` present, `en.lproj` included. No push entitlement (D-36: only with a push-capable signing profile).
- Adds: role-aware Settings and preferences, Face ID / Touch ID lock, push registration and routing, handwritten signatures on approvals (server side needs migration 001800), English interface, dashboard hero with the hospital photo and scroll motion, director dashboard customization, lifecycle tracks.
- Screens reviewed from CI run #44 (same UI; that run's only failure was a unit-test assertion fixed in 63bf296).

## Unsigned device build 23 (commit ddc0d46), 2026-11-23
- CI run #38 on the same commit: green (database; simulator build; unit tests incl. 2 new dashboard cache tests; all UI tests; screenshot tour in light, dark, head and accessibility-large text, 63 screens).
- IPA SHA-256 `5ecc7fa618c3def6eeb312182b130e477c679894dcfbc4049fb6918e82e74e28` (matches SHA256SUMS.txt). Unsigned, `CFBundleVersion` 23, production backend, publishable key only.
- Professional polish (D-34): motion system, redesigned dashboard, skeleton loading, zoom transitions (iOS 18+), per-period stale-while-revalidate, concurrent reads. Design review fixes from the build 22 screenshots: right-to-left order of mixed lines, unclipped row badges, large-text header.

## Unsigned device build 19 (commit 6023568), 2026-11-23
- CI run #34 on the same commit: green (database incl. 89_attachments; simulator build; unit tests incl. 4 attachment tests; UI tests incl. read-only evidence on an approved achievement).
- IPA SHA-256 `211af336d42f5e7885f560339fde974f0e25551720a918ee4fc9cb80b03fb826` (matches SHA256SUMS.txt). Unsigned, `CFBundleVersion` 19, production backend, publishable key only.
- Adds evidence attachments on tasks, report drafts and achievements.
