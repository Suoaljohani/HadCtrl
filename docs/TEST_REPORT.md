# Test report

## Database: run locally in this session, 2026-11-23
Command: `sudo -u postgres ./scripts/db-test.sh`
Environment: Ubuntu 24.04 container, PostgreSQL 16.15, with the Supabase platform shim (`supabase/tests/local/00_supabase_shim.sql`: roles `anon`/`authenticated`/`service_role`, `auth.uid()` from JWT claims). The migrations run on an **empty** database every time.

| Suite | Assertions | Result |
|---|---|---|
| 00_fixtures | 1 | pass |
| 05_grants (anon executes nothing; authenticated = documented RPC list; verified to fail without the lockdown migration) | 4 | pass |
| 10_rls_isolation (anon, outsider, director, heads, coordinator, exec viewer, sysadmin, disabled, expired, delegate; direct-write denial) | 43 | pass |
| 30_tasks_rpc (create/idempotency/validation/lifecycle/approve/return/extension/revocation/notifications/audit) | 50 | pass |
| 40_reports_rpc (scheduler idempotency, drafts, submit, return, resubmit, stale approval, waiver, compliance) | 38 | pass |
| 50_measurements_rpc (SQL scoring parity, input rules, approval, freeze, correction after freeze) | 31 | pass |
| 60_dashboard (coverage/verdict, consistency, cross-department and cross-hospital non-leakage) | 13 | pass |
| 70_admin (departments, employees, escalation rules) | 36 | pass |
| 80_definitions (director-only templates, schedules, generation incl. frozen refusal, indicators with §11 rule rejection and atomicity, head submits on a new indicator) | 25 | pass |
| 85_notifications (reading notifications, own-inbox RLS, mark all read, deadline reminders once per deadline) | 11 | pass |
| 87_achievements (draft/submit/return/approve, roles, visibility, history immutability, notifications) | 23 | pass |
| 88_goals (create rules, director lifecycle, completion request/refusal, milestones, visibility, cross-hospital) | 25 | pass |
| 90_concurrency.sh (two sessions, same request_id) | 3 | pass |
| **Total** | **303** | **pass, 0 failures** |

All checks run as the real `authenticated`/`anon` roles with a JWT `sub`, never as `service_role`.

Limits: PostgreSQL 16 locally vs 17 on the hosted project. Storage (`storage.objects`) policies are not covered yet. ## Hosted project after migration 001500 (2026-11-23)
- The MCP apply timed out three times waiting for an approval prompt, so the owner ran `20261123001500_achievements.sql` in the SQL Editor. It is therefore **not listed** in `supabase_migrations.schema_migrations`.
- Verified afterwards: `achievement_reviews` exists with RLS and one policy, SELECT-only for clients; anon executes no public function. The pasted text had Windows line endings; with `chr(13)` removed, every function body is identical to the tested build: fingerprint `508cd108f4650d817cb5c88bf67fd987` over 77 functions, same as local.
- Security advisor: only accepted findings (27 documented RPCs, D-18; leaked-password protection off).

## Hosted project after migration 001400 (2026-11-23)
- Applied `notifications_inbox`. Fingerprint `1d9e71d77657fc93815bde37a58a424a` over 73 functions, identical locally and hosted. Anon executes no public function.

## Hosted project after migration 001300 (2026-11-23)
- Applied `definitions_admin`. Function fingerprint (excluding the local-only test shim `_shim_grant_new_functions`): `812dca3256cd78e6df427f4dcd1ac5c9` over 70 functions, identical locally and hosted.
- Security advisor: no anon findings; `authenticated_security_definer_function_executable` now lists the 23 documented RPCs (accepted, D-18); leaked-password protection still off (owner setting).
- `cron.job`: `hadctrl-daily`, `10 21 * * *`, active.

## Hosted project (HadCtrl, `vffusttzqmerfofqianz`), 2026-11-23
- 11 migrations applied in order (`supabase_migrations.schema_migrations` = 11). Nothing destructive; the project held no data.
- Structure matches the tested database: 38 tables, all with RLS; 40 policies; an md5 fingerprint over every `public`/`private` function body is identical locally and hosted (`f9dde17efc18b737ebb14af6be619fc9`).
- Grants: anon can execute 0 functions and holds 0 table privileges. Authenticated can call exactly the 16 documented RPCs.
- Security advisor: only accepted findings remain (D-18).
- The behavioral test suite was **not** run on the hosted project, because it inserts fixture rows. The fingerprint shows the code is identical to what the suite exercised.

## iOS: GitHub Actions run #11 (commit 0492f7a), 2026-11-23
Environment: `macos-15-arm64` image 20261118.0550, Xcode 26.3 (17C529), Swift 6.2.4, simulator iPhone SE (3rd generation) on iOS 26.2. Unsigned Debug build, `HC_APP_ENV=ui-testing` (labelled mock repositories). The `.xcresult` is uploaded as artifact `HadCtrl-tests-45154877788-1`.

| Suite | Result |
|---|---|
| Swift Testing (10 suites, 42 tests: scoring, aggregation, coverage, number input, calendar, search, routes, configuration, view models, Supabase contracts) | 42/42 pass |
| XCUITest `HadCtrlUITests` (five tabs + demo banner; director approves; director returns with mandatory note; head scope + no self-approval; AX-XL text) | 5/5 pass |
| Built-app secret scan | clean |

Limits:
- Simulator only, on the iOS 26.2 runtime. The deployment target is iOS 17, and no iOS 17 runtime exists on the image, so running on 17 is not yet verified (§31).
- UI tests run against mock repositories. The Supabase client is covered by contract tests on captured server output, not by a live end-to-end run: that needs the publishable key and a bootstrapped director.
- One green run. The UI tests needed several runner-specific fixes (runs #2–#10); watch the next runs for flakiness before treating them as stable.
