# HadCtrl API contracts

Implemented contracts are marked **live** (in a migration and covered by tests). The rest are **planned**, with the shape from spec §27.

## Error contract

Every RPC fails with PostgREST `code = "P0001"`, `message = <HC_* code>` and `details = <JSON>`. The client decides retry/sign-in from the code only.

| Code | Meaning | Retry with same request_id? | `details` |
|---|---|---|---|
| HC_AUTH_REQUIRED | no session | after sign-in | — |
| HC_MEMBERSHIP_INACTIVE | profile disabled | no | — |
| HC_FORBIDDEN | caller can see the record but may not do this | no | `{"reason"?}` |
| HC_NOT_FOUND | missing **or not visible** (indistinguishable, HC-120) | no | — |
| HC_VALIDATION_FAILED | input invalid | no (fix input) | `{"fields":{name:reason}}` or `{"transition":...}` |
| HC_VERSION_CONFLICT | expected_version stale | no (reload) | `{"current_version":n}` |
| HC_IDEMPOTENCY_MISMATCH | request_id reused with different payload | no | — |
| HC_PERIOD_FROZEN, HC_ATTACHMENT_INCOMPLETE, HC_RATE_LIMITED, HC_SERVER_ERROR | planned | rate/server: yes | — |

Idempotency: `(actor, operation, request_id)` is a primary key in `idempotency_requests`. A replay with the same payload returns the stored response plus `"replayed": true`. Concurrent duplicates block on the key and then receive the first result (tested by `supabase/tests/90_concurrency.sh`).

## Live

### `my_context() → jsonb`
Memberships the caller holds right now: `{user_id, profile, organizations:[{organization_id, name_ar, timezone, is_demo, roles[], departments:[{department_id, name_ar, code, roles[]}]}]}`. Used to route the app; the client never picks a role.

### API-04 `create_task(p_department_id, p_title, p_request_id, p_assignee_id?, p_due_at?, p_due_date?, p_description?, p_priority?, p_start_at?, p_linked_goal_id?, p_parent_task_id?, p_as_draft?) → jsonb`
- Caller: the hospital director of the department's organization, or an active `department_head` of that department.
- Non-draft tasks need an active member of that department as assignee and a future due date. A date-only `p_due_date` becomes 23:59:59 in the hospital time zone.
- Writes the task, a `task_events` row, an `audit_events` row and a deduplicated `task_assigned` notification in one transaction.
- Returns `{task_id, status, version, assignee_id, due_at, original_due_at, created_at, updated_at, replayed}`.

### API-05 `transition_task(p_task_id, p_expected_version, p_transition, p_request_id, p_note?, p_new_assignee_id?) → jsonb`
| transition | from | who | note |
|---|---|---|---|
| assign | draft | creator (director/head) | — |
| acknowledge | assigned | assignee | — |
| start | assigned, acknowledged, returned | assignee | — |
| block / unblock | acknowledged, in_progress / blocked | assignee or director | block: required |
| submit | assigned, acknowledged, in_progress, returned | assignee | — |
| approve / return | submitted | director, creating head, or `review_tasks` delegate — never the assignee | return: required |
| cancel | any open | director or creating head | required |
| reassign | open, not draft | director or dept head | required; new assignee must be an active dept member |

`first_submitted_at` is set once and kept on resubmission. `original_due_at` never changes.

### API-15 `request_task_extension(p_task_id, p_proposed_due_at, p_reason, p_request_id)` / `decide_task_extension(p_extension_request_id, p_decision, p_request_id, p_note?)`
A request never changes `due_at`; only an approval by the director or creating head (not the requester) does. One pending request per task.

### `mark_notification_read(p_notification_id) → timestamptz`
Own notifications only. Reading completes nothing.

### API-14 `register_device(p_device_id, p_token, p_environment) → uuid`
Binds a token to the caller only. A token that moves to another account is removed from its old binding.

### Reports (G4)
- `generate_report_instances(p_period_id)`: **server-only** (not granted to clients; run from Supabase Cron). Idempotent; returns `{created, skipped_existing}`. Due rules: `day_of_next_period` (clamped) and `end_of_period`, in hospital time.
- `save_report_draft(p_report_id, p_content, p_request_id, p_expected_revision_version?)`: department members. Creates or updates the single open draft revision.
- API-08 `submit_report(p_report_id, p_draft_revision_id, p_expected_version, p_request_id)`: department head (a coordinator needs a `submit_reports` delegation). Checks required fields and required evidence. Sets `first_submitted_at` once.
- API-09 `decide_report(p_report_id, p_revision_id, p_decision, p_expected_version, p_request_id, p_note?)`: director or `approve_reports` delegate who is not a member of that department. The revision must be the latest. Approval freezes `snapshot_data`.
- `waive_report(p_report_id, p_reason, p_expected_version, p_request_id)`: director.
- `report_compliance(p_period_id)`: `security invoker`, counted from rows the caller can read; waived reports are excluded from `required`.

### Definitions from the app (D-29, migration 001300)
All director only (system admin and heads get `HC_FORBIDDEN`; another hospital gets `HC_NOT_FOUND`), idempotent by `p_request_id`, audited.
- `create_report_template(p_organization_id, p_name_ar, p_frequency, p_fields, p_request_id)`: `p_fields` = `[{key, label, required}]`, 1–30 items, keys `^[a-z][a-z0-9_]{0,39}$` and unique (the app sends `f1…fn`). Creates the template and version 1 (`field_schema = {"fields": …}`, `required_fields` derived). Returns `{template_id, template_version_id, name_ar, frequency}`.
- `schedule_report(p_template_id, p_department_ids, p_due_day, p_request_id)`: due on day 1–28 of the next period at 23:59 hospital time, active from the current month. Archived or foreign departments are rejected. Returns `{template_id, scheduled, active_from}`.
- `ensure_current_period(p_organization_id)`: creates the current monthly period (open) if missing. Returns `{period_id}`.
- `generate_reports_for_period(p_period_id)`: runs the scheduler for one period; refused for a frozen period (`HC_PERIOD_FROZEN`). Returns `{created, skipped_existing}`.
- `create_indicator(p_organization_id, p_department_id, p_code, p_title, p_measurement_type, p_unit, p_direction, p_aggregation, p_frequency, p_data_source, p_request_id, p_target?, p_range_min?, p_range_max?, p_numerator_description?, p_denominator_description?, p_weight?, p_zero_event_rule?, p_description?)`: definition and version 1, approved by the director and valid from the current month. Field errors under `fields`; any §11 rule violation (target 0 for higher-is-better, ratio without numerator/denominator descriptions, bad range, zero-event misuse) is `{"fields":{"definition":"inconsistent_rule"}}`. Returns `{definition_id, definition_version_id, code}`.
- Supabase Cron job `hadctrl-daily` (21:10 UTC = 00:10 Riyadh) runs `private.daily_maintenance()`: ensures the current month and generates its reports for every active hospital.

### Client reads (RLS)
`report_instances`, `report_template_versions`, `report_templates`, `report_revisions` (drafts only for the department), `report_reviews`, `indicator_definitions`, `indicator_definition_versions`, `indicator_measurements`. The applicable definition version for a period is the latest approved one whose `valid_from` is on or before the period end. A period's result uses only the approved reading; a submitted one is shown as pending.

### Evidence attachments (§26, API-11, migration 001700)
- Bucket `hadctrl-evidence`: private, 20 MB, PDF/JPEG/PNG/HEIC/CSV/XLSX. Storage policies: INSERT only to a path reserved by `prepare_attachment` for the same user before `upload_expires_at` (1 hour); SELECT only when the linked record is visible to the caller (or their own pending upload); no UPDATE/DELETE for clients.
- `prepare_attachment(p_target_type, p_target_id, p_display_name, p_mime_type, p_size_bytes, p_request_id) → {attachment_id, bucket, object_path, upload_expires_at}`: targets `task` (assignee or department member; open task), `report_revision` (open draft of an editable report; department members), `achievement` (department member; draft/returned). Invisible records → `HC_NOT_FOUND`; not editable → `HC_FORBIDDEN`; type/size/name or > 10 files → `HC_VALIDATION_FAILED`. Path `<organization>/<department>/<attachment id>`.
- Client uploads with `storage.from("hadctrl-evidence").upload(object_path, data:, options: FileOptions(contentType:, upsert: false))`.
- `finalize_attachment(p_attachment_id, p_checksum_sha256, p_request_id)`: uploader only; the stored object's `metadata.size` and `metadata.mimetype` must match the reservation (else `HC_ATTACHMENT_INCOMPLETE`); re-checks that the record is still editable; marks `ready` and links it.
- `remove_attachment(p_attachment_id, p_request_id)`: uploader or department head while the record is editable; unlinks and marks `deleted` (the object is kept for the retention job).
- Reading: `createSignedURL(path:expiresIn: 60)`; the app copies the file into a temporary preview folder that is cleared on sign-out.
- Nightly: expired reservations become `failed`.

### Goals (§09, migration 001600)
- `create_goal(p_department_id, p_title, p_measurement_type, p_unit, p_start_date, p_due_date, p_request_id, p_description?, p_owner_id?, p_priority?, p_baseline?, p_target?, p_plan?, p_plan_is_linear?, p_milestones?, p_indicators?) → {goal_id, lifecycle, version, current_version_id}`: department head or director; draft + version 1. Explicit target > 0, or milestones `[{title, criterion, weight}]` totalling 100; plan `[{at, expected}]` inside the window and non-decreasing; indicator links `[{definition_id, relation: measures_outcome|supports}]` of the same department. A head's draft notifies directors (`decision_needed`).
- `decide_goal(p_goal_id, p_decision, p_expected_version, p_request_id, p_note?)`: director. `activate` (draft → active, approves the version), `return` (stays draft, note), `complete` (completion_pending → completed), `reject_completion` (→ active, note), `cancel` (note; the goal is kept with its reason). Notifies the owner and author (`goal_decided`).
- `request_goal_completion(p_goal_id, p_expected_version, p_request_id, p_note?)`: department head; active → completion_pending; notifies directors.
- `set_milestone(p_milestone_id, p_action, p_request_id)`: `complete` (department head, running goal) or `approve` (director who is not a member). Only approved milestones count.
- Progress (client, `GoalMath`): actual from the measuring indicator's approved readings inside the window, aggregated by its rule (ratio of sums for ratios), or approved milestone weights; expected from the latest plan point (linear only when approved as linear); raw % uncapped, aggregate capped at 100. Tasks never count (AC-010).

### Achievements (§16, migration 001500)
- `save_achievement(p_department_id, p_period_id, p_title, p_request_id, p_achievement_id?, p_expected_version?, p_description?, p_impact_text?, p_beneficiary?, p_linked_task_id?, p_linked_measurement_id?, p_contributor_department_ids?) → {achievement_id, status, version, submitted_at, approved_at}`: any member of the department; creates a draft or edits a draft/returned one (`expected_version` required to edit). Linked task must be a completed task of the department; linked reading an approved one of the department; contributors are other active departments (each counted once). One task per period (`linked_task_id: already_used_in_period`). Frozen period → `HC_PERIOD_FROZEN`.
- `submit_achievement(p_achievement_id, p_expected_version, p_request_id)`: department head; impact required (`impact_text: required`); notifies active directors (`decision_needed`).
- API-10 `decide_achievement(p_achievement_id, p_decision, p_expected_version, p_request_id, p_note?)`: director who is not a member of the department and not the author; `approved | returned | rejected` (note ≥ 3 chars unless approved); writes an immutable `achievement_reviews` row; notifies the author (`achievement_decided`).
- Reads (RLS): `achievements` (drafts: department only; submitted+: also the director; approved: whole hospital), `achievement_contributors`, `achievement_reviews` (same visibility as the achievement).

### Inbox (D-30, migration 001400)
- Read: `notifications` (RLS: `recipient_id = auth.uid()`), newest first, max 100 per page. Columns `id, event_type, entity_type, entity_id, read_at, created_at`. Event types: task_* (assigned, submitted, returned, completed, due_soon, overdue), report_* (due_soon, overdue, returned, approved, submitted), extension_requested/decided, achievement_decided, decision_needed, measurement_submitted/approved/returned (entity_type `indicator`, entity_id = the measurement).
- `mark_notification_read(p_notification_id) → timestamptz` (own rows only, else `HC_NOT_FOUND`); `mark_all_notifications_read() → int` (rows changed).
- Producers: the RPCs above; trigger `indicator_measurements_notify` (submitted → active directors except the submitter; approved/returned → the submitter); `private.deadline_reminders()` from the nightly job (tasks → assignee; reports → the department's active heads; dedupe key includes the deadline date).

### Indicators (G5)
- API-06 `submit_measurement(p_definition_version_id, p_period_id, p_request_id, p_value?, p_numerator?, p_denominator?, p_not_applicable_reason?, p_source_note?, p_correction_reason?)`: department head. Type-checked input. One open revision at a time. Replacing an approved value needs a correction reason. A frozen period accepts only corrections.
- API-07 `decide_measurement(p_measurement_id, p_decision, p_expected_version, p_request_id, p_note?)`: director, not a department member, not the person who entered it. Approval supersedes the previous approved revision.
- API-13 `freeze_period(p_period_id, p_expected_version, p_reason, p_request_id)`: director. Writes an immutable `period_snapshots` row (approved measurements + report states + md5 hash).
- `private.indicator_score(...)`: SQL mirror of `IndicatorScoring.score`; parity is tested.

### Administration (D-25)
- `create_department(p_organization_id, p_code, p_name_ar, p_category, p_request_id, p_name_en?, p_sort_order?)`: director or system admin. The code is upper-cased and must match `^[A-Z0-9][A-Z0-9_-]{0,15}$`, unique per hospital. Idempotent and audited.
- `prepare_employee(p_organization_id, p_email, p_display_name, p_request_id, p_job_title?, p_org_role?, p_department_id?, p_department_role?, p_is_primary?)`: director or system admin. `org_role` ∈ member | executive_viewer | system_admin (system_admin requires a director caller; hospital_director is always refused). At most one active primary head per department. Writes a pending `account_provisioning` row.
- Edge Function **`create-employee`** (POST JSON with the same fields plus `request_id`, user bearer token): returns `{user_id, account_created, temporary_password|null, replayed}`. Errors: `{code: HC_*, details, correlation_id}`. A replay never re-issues a password. An existing Auth user with that email is attached, not recreated.
- Service role only: `provisioning_status`, `find_auth_user_id`, `complete_employee` (profile + `member` org role + optional org/department role, `must_change_password` for new accounts), `fail_provisioning`.
- `mark_password_changed()`: clears the caller's `must_change_password` after `auth.update(password)`. `my_context.profile.must_change_password` drives the forced change screen.
- `list_people(p_organization_id)`: director or system admin; people with org and department roles.

## Planned
API-01 dashboard_snapshot · API-02 list_departments · API-03 get_department_detail · API-10 decide_achievement · API-11 prepare/finalize_attachment · API-12 search_all.

Until these exist, clients read lists through RLS-protected `SELECT`s. Every client-facing table grants SELECT only (plus own preferences and own display name).
