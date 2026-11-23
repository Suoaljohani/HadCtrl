-- G3 task slice through the real RPCs: create → acknowledge → start → submit →
-- approve/return, idempotency, versions, authorization, extensions, audit,
-- notifications. AC-011..AC-014, AC-024, AC-032.

-- ---------------------------------------------------------------- create
select test.login('00000000-0000-0000-0000-000000000011');  -- director A

select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d1',
  p_title => 'تحديث إجراءات العينات',
  p_request_id => '10000000-0000-0000-0000-000000000001',
  p_assignee_id => '00000000-0000-0000-0000-000000000012',
  p_due_date => (now() at time zone 'Asia/Riyadh')::date + 10,
  p_priority => 'high') as r1 \gset
select (:'r1'::jsonb ->> 'task_id') as task1 \gset
select test.eq(:'r1'::jsonb ->> 'status', 'assigned', 'create_task returns assigned task');
select test.eq((:'r1'::jsonb ->> 'replayed')::boolean, false, 'first call is not a replay');
select test.eq(to_char((:'r1'::jsonb ->> 'due_at')::timestamptz at time zone 'Asia/Riyadh', 'HH24:MI:SS'), '23:59:59',
               'date-only due resolves to end of day Riyadh time');

-- AC-011 / AC-024: same request_id → same task, no duplicate.
select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d1',
  p_title => 'تحديث إجراءات العينات',
  p_request_id => '10000000-0000-0000-0000-000000000001',
  p_assignee_id => '00000000-0000-0000-0000-000000000012',
  p_due_date => (now() at time zone 'Asia/Riyadh')::date + 10,
  p_priority => 'high') as r1b \gset
select test.eq(:'r1b'::jsonb ->> 'task_id', :'task1', 'replay returns the original task id');
select test.eq((:'r1b'::jsonb ->> 'replayed')::boolean, true, 'replay is flagged');
select test.eq((select count(*) from public.tasks where title = 'تحديث إجراءات العينات'), 1::bigint, 'only one task exists');

-- Same request_id, different payload → mismatch.
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d1', p_title => 'عنوان مختلف',
  p_request_id => '10000000-0000-0000-0000-000000000001',
  p_assignee_id => '00000000-0000-0000-0000-000000000012', p_due_at => now() + interval '3 days')$$,
  'HC_IDEMPOTENCY_MISMATCH', 'reused request_id with different payload is rejected');

-- Validation.
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d1', p_title => 'مهمة لرئيس قسم آخر',
  p_request_id => gen_random_uuid(), p_assignee_id => '00000000-0000-0000-0000-000000000014',
  p_due_at => now() + interval '3 days')$$, 'HC_VALIDATION_FAILED', 'assignee outside department rejected');
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d1', p_title => 'مهمة لموظف معطل',
  p_request_id => gen_random_uuid(), p_assignee_id => '00000000-0000-0000-0000-000000000017',
  p_due_at => now() + interval '3 days')$$, 'HC_VALIDATION_FAILED', 'disabled assignee rejected');
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d2', p_title => 'مهمة لعضوية منتهية',
  p_request_id => gen_random_uuid(), p_assignee_id => '00000000-0000-0000-0000-000000000018',
  p_due_at => now() + interval '3 days')$$, 'HC_VALIDATION_FAILED', 'expired-membership assignee rejected');
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d1', p_title => 'بدون موعد',
  p_request_id => gen_random_uuid(), p_assignee_id => '00000000-0000-0000-0000-000000000012')$$,
  'HC_VALIDATION_FAILED', 'missing due date rejected for assigned task');
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d1', p_title => 'موعد ماض',
  p_request_id => gen_random_uuid(), p_assignee_id => '00000000-0000-0000-0000-000000000012',
  p_due_at => now() - interval '1 hour')$$, 'HC_VALIDATION_FAILED', 'past due date rejected');
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d5', p_title => 'قسم مؤرشف',
  p_request_id => gen_random_uuid(), p_assignee_id => '00000000-0000-0000-0000-000000000012',
  p_due_at => now() + interval '3 days')$$, 'HC_VALIDATION_FAILED', 'archived department rejected');
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d9', p_title => 'مستشفى آخر',
  p_request_id => gen_random_uuid(), p_assignee_id => '00000000-0000-0000-0000-000000000022',
  p_due_at => now() + interval '3 days')$$, 'HC_NOT_FOUND', 'director A cannot create in hospital B (not found, no leak)');

-- Draft: allowed without due/assignee, invisible to others, no notification.
select public.create_task(p_department_id => '00000000-0000-0000-0000-0000000000d1', p_title => 'مسودة تكليف',
  p_request_id => '10000000-0000-0000-0000-000000000002', p_as_draft => true) as rd \gset
select test.eq(:'rd'::jsonb ->> 'status', 'draft', 'draft task created');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000012');  -- head LAB
select test.eq((select count(*) from public.tasks where status = 'draft'), 0::bigint, 'head cannot see director draft');
select test.eq((select count(*) from public.notifications where entity_id = :'task1'::uuid and event_type = 'task_assigned'), 1::bigint,
               'assignee received exactly one assignment notification');
-- Head can create inside own department only.
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d2', p_title => 'خارج قسمي',
  p_request_id => gen_random_uuid(), p_assignee_id => '00000000-0000-0000-0000-000000000014',
  p_due_at => now() + interval '3 days')$$, 'HC_NOT_FOUND', 'head cannot create in another department');
select public.create_task(p_department_id => '00000000-0000-0000-0000-0000000000d1', p_title => 'مهمة للمنسق',
  p_request_id => '10000000-0000-0000-0000-000000000003', p_assignee_id => '00000000-0000-0000-0000-000000000013',
  p_due_at => now() + interval '5 days') as rc \gset
select (:'rc'::jsonb ->> 'task_id') as task_coord \gset
select test.eq(:'rc'::jsonb ->> 'status', 'assigned', 'head can assign to own coordinator');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000013');  -- coordinator
select test.throws($$select public.create_task(
  p_department_id => '00000000-0000-0000-0000-0000000000d1', p_title => 'منسق يسند',
  p_request_id => gen_random_uuid(), p_assignee_id => '00000000-0000-0000-0000-000000000012',
  p_due_at => now() + interval '3 days')$$, 'HC_FORBIDDEN', 'coordinator cannot create assignments');
select test.logout();

-- ---------------------------------------------------------------- lifecycle
select test.login('00000000-0000-0000-0000-000000000014');  -- head TRN, not involved
select test.throws(format($$select public.transition_task(%L, 1, 'acknowledge', gen_random_uuid())$$, :'task1'),
                   'HC_NOT_FOUND', 'unrelated head cannot touch the task (not found)');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000011');  -- director
select test.throws(format($$select public.transition_task(%L, 1, 'acknowledge', gen_random_uuid())$$, :'task1'),
                   'HC_FORBIDDEN', 'director cannot acknowledge on behalf of assignee');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000012');  -- assignee
select public.transition_task(:'task1', 1, 'acknowledge', '20000000-0000-0000-0000-000000000001') as t1 \gset
select test.eq(:'t1'::jsonb ->> 'status', 'acknowledged', 'assignee acknowledges');
select test.eq((:'t1'::jsonb ->> 'version')::int, 2, 'version increments');
-- AC-012: stale version is rejected and reports current version.
select test.throws(format($$select public.transition_task(%L, 1, 'start', gen_random_uuid())$$, :'task1'),
                   'HC_VERSION_CONFLICT', 'stale expected_version rejected');
select public.transition_task(:'task1', 2, 'start', '20000000-0000-0000-0000-000000000002') as t2 \gset
select test.throws(format($$select public.transition_task(%L, 3, 'block', gen_random_uuid())$$, :'task1'),
                   'HC_VALIDATION_FAILED', 'block requires a reason');
select public.transition_task(:'task1', 3, 'submit', '20000000-0000-0000-0000-000000000003') as t3 \gset
select test.eq(:'t3'::jsonb ->> 'status', 'submitted', 'assignee submits');
select test.throws(format($$select public.transition_task(%L, 4, 'approve', gen_random_uuid())$$, :'task1'),
                   'HC_FORBIDDEN', 'assignee cannot approve own submission');
select test.logout();

-- AC-014: submitted is not completed.
select test.login('00000000-0000-0000-0000-000000000011');
select test.eq((select status from public.tasks where id = :'task1'), 'submitted', 'submitted task is not counted as completed');
select test.ok((select first_submitted_at is not null and completed_at is null from public.tasks where id = :'task1'),
               'first_submitted_at recorded, completed_at empty');
select test.throws(format($$select public.transition_task(%L, 4, 'return', gen_random_uuid())$$, :'task1'),
                   'HC_VALIDATION_FAILED', 'return requires a note');
select public.transition_task(:'task1', 4, 'return', '20000000-0000-0000-0000-000000000004', 'أرفق محضر الاجتماع') as t4 \gset
select test.eq(:'t4'::jsonb ->> 'status', 'returned', 'director returns with a note');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000012');
select (first_submitted_at) as first_sub from public.tasks where id = :'task1' \gset
select public.transition_task(:'task1', 5, 'submit', '20000000-0000-0000-0000-000000000005') as t5 \gset
select test.eq((select first_submitted_at from public.tasks where id = :'task1'), :'first_sub'::timestamptz,
               'resubmission keeps first_submitted_at');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000011');
select public.transition_task(:'task1', 6, 'approve', '20000000-0000-0000-0000-000000000006') as t6 \gset
select test.eq(:'t6'::jsonb ->> 'status', 'completed', 'director approves');
-- Replaying the approve after a "network drop" returns the stored result (AC-024).
select public.transition_task(:'task1', 6, 'approve', '20000000-0000-0000-0000-000000000006') as t6b \gset
select test.eq((:'t6b'::jsonb ->> 'replayed')::boolean, true, 'approve replay returns stored result');
select test.eq((select count(*) from public.task_events where task_id = :'task1' and event = 'approve'), 1::bigint,
               'approve recorded exactly once');
select test.throws(format($$select public.transition_task(%L, 7, 'cancel', gen_random_uuid(), 'سبب')$$, :'task1'),
                   'HC_VALIDATION_FAILED', 'completed task cannot be cancelled');

-- Audit trail is complete and server-attributed.
select test.eq((select count(*) from public.audit_events where entity_id = :'task1'::uuid), 7::bigint,
               'audit has create + 6 transitions');
select test.eq((select count(distinct actor_id) from public.audit_events where entity_id = :'task1'::uuid), 2::bigint,
               'audit actors are the real callers');
select test.logout();

-- Assignee sees returned + completed notifications; director sees submitted.
select test.login('00000000-0000-0000-0000-000000000012');
select test.eq((select count(*) from public.notifications where entity_id = :'task1'::uuid), 3::bigint,
               'assignee notifications: assigned, returned, completed');
select test.eq((select count(*) from public.audit_events where entity_id = :'task1'::uuid), 4::bigint,
               'non-director sees only own audit rows (ack, start, submit, resubmit)');
select test.logout();

-- Delegated reviewer can approve within delegation scope.
select test.login('00000000-0000-0000-0000-000000000013');
select public.transition_task(:'task_coord', 1, 'submit', '20000000-0000-0000-0000-000000000010') as c1 \gset
select test.logout();
select test.login('00000000-0000-0000-0000-000000000019');
select public.transition_task(:'task_coord', 2, 'approve', '20000000-0000-0000-0000-000000000011') as c2 \gset
select test.eq(:'c2'::jsonb ->> 'status', 'completed', 'delegated reviewer approves within scope');
select test.logout();

-- ---------------------------------------------------------------- extensions (AC-013)
select test.login('00000000-0000-0000-0000-000000000014');  -- head TRN, assignee of c2
select due_at as c2_due from public.tasks where id = '00000000-0000-0000-0000-0000000000c2' \gset
select public.request_task_extension('00000000-0000-0000-0000-0000000000c2', :'c2_due'::timestamptz + interval '5 days',
                                     'انتظار توريد مواد', '30000000-0000-0000-0000-000000000001') as e1 \gset
select test.eq((select due_at from public.tasks where id = '00000000-0000-0000-0000-0000000000c2'), :'c2_due'::timestamptz,
               'extension request does not change the due date');
select test.throws(format($$select public.decide_task_extension(%L, 'approved', gen_random_uuid())$$, :'e1'::jsonb ->> 'extension_request_id'),
                   'HC_FORBIDDEN', 'requester cannot decide own extension');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000011');
select public.decide_task_extension((:'e1'::jsonb ->> 'extension_request_id')::uuid, 'approved', '30000000-0000-0000-0000-000000000002') as e2 \gset
select test.eq((select due_at from public.tasks where id = '00000000-0000-0000-0000-0000000000c2'), :'c2_due'::timestamptz + interval '5 days',
               'approved extension moves due_at');
select test.ok((select original_due_at < due_at from public.tasks where id = '00000000-0000-0000-0000-0000000000c2'),
               'original_due_at preserved after extension');
select test.logout();

-- ---------------------------------------------------------------- revoked access (AC-032)
-- Deactivate the TRN head's membership while their "token" is unchanged.
update public.department_memberships set active = false
 where user_id = '00000000-0000-0000-0000-000000000014' and department_id = '00000000-0000-0000-0000-0000000000d2';
select test.login('00000000-0000-0000-0000-000000000014');
select test.eq((select count(*) from public.departments), 0::bigint, 'revoked head no longer sees the department');
select test.throws($$select public.transition_task('00000000-0000-0000-0000-0000000000c2', 2, 'start', gen_random_uuid())$$,
                   'HC_NOT_FOUND', 'revoked head cannot act on own assigned task');
select test.logout();
update public.department_memberships set active = true
 where user_id = '00000000-0000-0000-0000-000000000014' and department_id = '00000000-0000-0000-0000-0000000000d2';

-- Notification read does not complete anything; cannot read others'.
select test.login('00000000-0000-0000-0000-000000000012');
select id as n1 from public.notifications order by created_at limit 1 \gset
select public.mark_notification_read(:'n1') is not null as marked \gset
select test.eq(:'marked'::boolean, true, 'recipient marks notification read');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000011');
select test.throws(format($$select public.mark_notification_read(%L)$$, :'n1'), 'HC_NOT_FOUND',
                   'cannot mark another user''s notification');
select test.logout();
