# Implementation status

## What was found at the start (2026-11-23)
- Repository: README only. Apple skills copied into `.claude/skills/` earlier in this session.
- Tools in the cloud session: Linux, PostgreSQL 16, Docker, Node 22, Python 3. **No Xcode, no Swift toolchain** (installing a Linux Swift toolchain was not permitted here). All iOS compilation happens on the GitHub `macos-15` runner.
- Supabase: an empty project named HadCtrl (D-01).
- Apple signing inputs: none supplied.

## Done
- **G2 database:** 11 migrations covering all tables DB-01..DB-30, RLS on every table, SELECT-only client grants, explicit function grants, audit and notification outbox. 183 assertions including a real two-session concurrency test, all from the real client roles; green locally and in CI.
- **G3 server slice:** create, acknowledge, start, block, submit, return, approve, cancel, reassign; extension request and decision; idempotency; version conflicts; revoked-access checks.
- **G1 app (CI-verified project generation; build/test result in BUILD_REPORT):** XcodeGen project, shared HadCtrl scheme, five-tab shell, director dashboard, execution (tasks + achievements), departments, performance, reports, sign-in/access-denied/settings, design tokens with dark mode, Janna LT, app icon, Arabic string catalog with English entries.
- **Domain rules + tests:** scoring for all three directions and the zero-event rule, ratio-of-sums aggregation, latest/sum/weighted mean, coverage verdicts, number parsing, Riyadh deadlines, latest-request gate.
- **G4 server:** report scheduler, drafts, submit/return/approve, waiver, compliance.
- **G5 server:** measurement submit/decide, corrections after freeze, `freeze_period` snapshots, SQL scoring with parity to Swift, `dashboard_snapshot`.
- **Hosted Supabase:** all 11 migrations applied and verified against the tested build (TEST_REPORT, D-17).

## Not done yet (in order)
1. **Fix the failing iOS CI build/test step** (run #2) so G1 is verified.
2. **G3 client (in progress):** supabase-swift 2.55.7 added. Session (sign-in, Keychain, restore, sign-out), dashboard (`dashboard_snapshot`), departments, tasks list/detail/create/transition are wired to Supabase. Contract tests decode real RPC output. Pending: committing `Config/Package.resolved` from the first CI resolve; an end-to-end check against the hosted project, which needs the publishable key and a bootstrapped director.
3. **G4–G5 client:** report and indicator screens wired to their RPCs; schedule `generate_report_instances` with Supabase Cron.
4. **G6:** attachments (Storage policies, prepare/finalize), search, calendar, preferences sync, PDF/CSV export, in-app notification inbox, APNs worker.
5. **G7:** accessibility/VoiceOver audit, performance, deep links.
6. **G8:** signing, IPA export and verification. Blocked on Apple inputs (see SETUP.md).

## Known shortcuts to remove
- `DepartmentDetailView` currently shows only the department's tasks; goals/indicators/reports tabs come with G4/G5.
