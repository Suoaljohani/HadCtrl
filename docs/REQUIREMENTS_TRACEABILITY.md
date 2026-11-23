# Requirements traceability

Status values: **verified** (an automated test passes and is cited), **implemented** (code exists, no dedicated test yet), **partial**, **planned**. Nothing is marked done just because a view or migration with that name exists (§35).

DB tests: `scripts/db-test.sh` (local Postgres, real `anon`/`authenticated` roles). Swift tests: `HadCtrlTests`, `HadCtrlUITests` (CI macOS job).

## Acceptance matrix (§35)

| ID | Scenario | Status | Evidence |
|---|---|---|---|
| AC-001 | Fresh launch without session | partial | `SessionStore` phases; anon sees nothing: `10_rls_isolation` "anon cannot read …". Real sign-in pending the SDK (D-11). |
| AC-002 | Account without active membership | verified (server + client) | `10_rls_isolation` outsider block; `ViewModelTests.noMembership` |
| AC-003 | Head requests another dept UUID | verified | `10_rls_isolation` "LAB head guessing TRN UUID gets nothing"; `30_tasks_rpc` "head cannot create in another department" |
| AC-004 | Nov → Oct switching | verified (client) | `ViewModelTests.latestPeriodWins` |
| AC-005 | Zero vs null | verified | `IndicatorScoringTests.nullIsNotZero` |
| AC-006 | Zero denominator | verified | `IndicatorScoringTests.zeroDenominator` |
| AC-007 | 90/100 + 1/2 | verified | `AggregationTests.ratioOfSums` |
| AC-008 | Lower is better | verified | `IndicatorScoringTests.lowerIsBetter` |
| AC-009 | 60% coverage | verified | `CoverageTests.insufficient`, `ViewModelTests.dashboardVerdict` |
| AC-010 | Tasks done, indicator not achieved | planned | needs goal evaluation RPC (G5) |
| AC-011 | Double-tap assign | verified (server, incl. real concurrency; client) | `30_tasks_rpc` replay block; `90_concurrency.sh`; `ViewModelTests.idempotentCreate` |
| AC-012 | Concurrent edit | verified | `30_tasks_rpc` "stale expected_version rejected"; `ViewModelTests.lifecycle` |
| AC-013 | Extension request | verified (server) | `30_tasks_rpc` extensions block |
| AC-014 | Submitted ≠ completed | verified | `30_tasks_rpc` "submitted task is not counted as completed"; `ViewModelTests.lifecycle` |
| AC-015 | Submit before due, approve after | verified (client rule) | `HospitalCalendarTests.overdue`; server report RPC planned (G4) |
| AC-016..019 | Report return/approve/schedule/waiver | partial | schema + constraints (`report_instances` unique, frozen revision trigger); RPCs planned (G4) |
| AC-020 | Correction after freeze | partial | `indicator_measurements` revisions, one-approved index, immutable `period_snapshots`; RPCs planned (G5) |
| AC-021 | Other org's file | partial | `can_read_attachment` + typed links; storage policies + prepare/finalize planned (G6) |
| AC-022 | Required evidence upload fails | planned | G6 |
| AC-023 | Session expiry while saving | planned | needs SDK session handling |
| AC-024 | Network drop after RPC | verified (server) | `30_tasks_rpc` "approve replay returns stored result"; client reuses request_id (`TaskDetailViewModel.perform`) |
| AC-025 | Sign out → other account | partial | per-session containers; cache not yet implemented (nothing persisted yet) |
| AC-026 | Notifications permission denied | implemented | in-app notifications are server rows, independent of APNs |
| AC-027 | Deep link to unauthorized record | partial | `AppRoute(url:)` ignores role hints (`RouteTests.deepLink`); detail screens show not-found state |
| AC-028 | Arabic export | planned | G6 |
| AC-029 | Large text + VoiceOver | partial | `HadCtrlUITests.testLargeTextDoesNotHideDecisions`; accessibility labels on metrics; full VoiceOver audit is G6/G7 |
| AC-030 | Reduce Motion/Transparency | implemented | no custom motion or translucency in content layer yet |
| AC-031 | Supabase failure | verified (client) | `ViewModelTests.failureIsVisible`, `productionNeverFallsBack` |
| AC-032 | Revoked member with valid token | verified | `10_rls_isolation` disabled/expired users; `30_tasks_rpc` revoked access block |
| AC-033 | PR workflow has no secrets | implemented | `.github/workflows/ci.yml`: `contents: read`, no secrets, no environment |
| AC-034..036 | IPA verification / install | planned | G7; needs Apple signing inputs |

## Functional requirements (selected)

| ID | Requirement | Status | Where |
|---|---|---|---|
| HC-001 | Native SwiftUI, no WebView | implemented | `HadCtrl/` |
| HC-002 | Supabase is the source of truth; drafts aren't submissions | partial | server RPCs; client SDK pending (D-11) |
| HC-003 | Every operational row carries org/department/period | verified | composite FKs `(organization_id, …)` in all migrations |
| HC-004 | Demo data can't become operational silently | implemented | `AppEnvironment`, `DemoDataBanner`, `organizations.is_demo` |
| HC-040 | Approved numbers trace to definition/version/source | partial | schema (`definition_version_id`, `supersedes_id`, `snapshot_data`) |
| HC-080 | VoiceOver can assign, review and return | partial | identifiers + labels; manual audit pending |
| HC-120 | UUID guessing leaks nothing | verified | D-04; `10_rls_isolation`, `30_tasks_rpc` HC_NOT_FOUND cases |

## Gates (§34)

| Gate | Status |
|---|---|
| G1 project | CI run pending — see `docs/BUILD_REPORT.md` |
| G2 database | local: verified (97 assertions); CI database job pending |
| G3 assignments | server: verified; client: mock-backed, SDK wiring pending |
| G4–G8 | planned |
