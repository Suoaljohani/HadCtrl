# Test report

## Database: run locally in this session, 2026-11-23
Command: `sudo -u postgres ./scripts/db-test.sh`
Environment: Ubuntu 24.04 container, PostgreSQL 16.15, with the Supabase platform shim (`supabase/tests/local/00_supabase_shim.sql`: roles `anon`/`authenticated`/`service_role`, `auth.uid()` from JWT claims). The migrations run on an **empty** database every time.

| Suite | Assertions | Result |
|---|---|---|
| 00_fixtures | 1 | pass |
| 10_rls_isolation (anon, outsider, director, heads, coordinator, exec viewer, sysadmin, disabled, expired, delegate; direct-write denial) | 43 | pass |
| 30_tasks_rpc (create/idempotency/validation/lifecycle/approve/return/extension/revocation/notifications/audit) | 50 | pass |
| 40_reports_rpc (scheduler idempotency, drafts, submit, return, resubmit, stale approval, waiver, compliance) | 38 | pass |
| 50_measurements_rpc (SQL scoring parity, input rules, approval, freeze, correction after freeze) | 31 | pass |
| 60_dashboard (coverage/verdict, consistency, cross-department and cross-hospital non-leakage) | 13 | pass |
| 90_concurrency.sh (two sessions, same request_id) | 3 | pass |
| **Total** | **179** | **pass, 0 failures** |

All checks run as the real `authenticated`/`anon` roles with a JWT `sub`, never as `service_role`.

Limits: PostgreSQL 16 locally vs 17 on the hosted project. Storage (`storage.objects`) policies are not covered yet. The suite has **not** yet been run against the hosted Supabase project.

## iOS: CI only (no Xcode in this session)
Swift Testing suites: `IndicatorScoringTests`, `AggregationTests`, `CoverageTests`, `NumberInputTests`, `HospitalCalendarTests`, `ArabicSearchTests`, `RouteTests`, `ConfigurationTests`, `ViewModelTests`. XCUITest: `HadCtrlUITests` (5 scenarios, Arabic locale, one at AX-XL text size).

Results come from GitHub Actions `HadCtrl CI` → job "iOS simulator build + tests"; the `.xcresult` is uploaded as an artifact. See BUILD_REPORT.md for run status. Nothing iOS-related is reported as passing unless that job is green.
