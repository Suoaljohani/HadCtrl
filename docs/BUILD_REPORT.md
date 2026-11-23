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

Update this table after each run. A signed IPA (G7) needs the Apple inputs listed in SETUP.md.
