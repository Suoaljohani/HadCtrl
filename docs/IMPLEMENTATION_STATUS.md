# Implementation status

## What was found at the start (2026-11-23)
- Repository: README only. Apple skills copied into `.claude/skills/` earlier in this session.
- Tools in the cloud session: Linux, PostgreSQL 16, Docker, Node 22, Python 3. **No Xcode, no Swift toolchain** (installing a Linux Swift toolchain was not permitted here). All iOS compilation happens on the GitHub `macos-15` runner.
- Supabase: an empty project named HadCtrl (D-01).
- Apple signing inputs: none supplied.

## Done
- **G2 database (local):** 7 migrations covering all tables DB-01..DB-30, RLS on every table, SELECT-only client grants, definer RPCs for the task slice, audit and notification outbox. 97 assertions plus a real two-session concurrency test, all from the real client roles.
- **G3 server slice:** create, acknowledge, start, block, submit, return, approve, cancel, reassign; extension request and decision; idempotency; version conflicts; revoked-access checks.
- **G1 app (CI-verified project generation; build/test result in BUILD_REPORT):** XcodeGen project, shared HadCtrl scheme, five-tab shell, director dashboard, execution (tasks + achievements), departments, performance, reports, sign-in/access-denied/settings, design tokens with dark mode, Janna LT, app icon, Arabic string catalog with English entries.
- **Domain rules + tests:** scoring for all three directions and the zero-event rule, ratio-of-sums aggregation, latest/sum/weighted mean, coverage verdicts, number parsing, Riyadh deadlines, latest-request gate.

## Not done yet (in order)
1. **Apply the migrations to the hosted project.** Deferred so the full schema goes up in one reviewed pass.
2. **G3 client:** add supabase-swift (pinned, Package.resolved from CI), Supabase repositories, sign-in, Keychain session.
3. **G4 reports:** scheduler (Supabase Cron), `submit_report`/`decide_report`, waiver, compliance, plus tests AC-015..019.
4. **G5 indicators:** `submit_measurement`/`decide_measurement`, corrections, `freeze_period` + snapshots, server-side scoring, `dashboard_snapshot`.
5. **G6:** attachments (Storage policies, prepare/finalize), search, calendar, preferences sync, PDF/CSV export, in-app notification inbox, APNs worker.
6. **G7:** accessibility/VoiceOver audit, performance, deep links.
7. **G8:** signing, IPA export and verification. Blocked on Apple inputs (see SETUP.md).

## Known shortcuts to remove
- Performance, Reports and Achievements screens request the mock November period id directly. They will follow the dashboard's selected period once periods come from the server.
- `DepartmentDetailView` currently shows only the department's tasks; goals/indicators/reports tabs come with G4/G5.
