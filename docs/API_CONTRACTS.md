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

## Planned (schema exists, RPC pending)
API-01 dashboard_snapshot · API-02 list_departments · API-03 get_department_detail · API-06 submit_measurement · API-07 decide_measurement · API-08 submit_report · API-09 decide_report · API-10 decide_achievement · API-11 prepare/finalize_attachment · API-12 search_all · API-13 freeze_period.

Until these exist, clients read lists through RLS-protected `SELECT`s. Every client-facing table grants SELECT only (plus own preferences and own display name).
