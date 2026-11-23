# Build report

| Item | Value |
|---|---|
| Build type so far | **Simulator only, unsigned** (`CODE_SIGNING_ALLOWED=NO`). No device archive, no IPA. |
| Runner | GitHub `macos-15`; Xcode = newest stable on the image (printed in the "Select Xcode" step) until `HC_XCODE_VERSION` is pinned |
| Project generation | XcodeGen 2.43.0 from `project.yml` |
| Minimum iOS | 17.0 |
| Swift packages | none yet (supabase-swift is added in the G3 client slice; see D-11) |
| Bundle id | placeholder `invalid.hadctrl.app` |

## CI runs
| Run | Commit | Database job | iOS job |
|---|---|---|---|
| #1 | 9cb1b1e | failed: the `postgres` OS user could not read the workspace (fixed in e251f9e) | project generated, `xcodebuild -list` and shared scheme verified; the build+test step was still running when this report was written |

Update this table from the Actions page after each run. A signed IPA (G7) needs the Apple inputs listed in SETUP.md.
