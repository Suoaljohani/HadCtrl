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
