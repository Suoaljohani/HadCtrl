-- In-app inbox producers (D-30): indicator readings, deadline reminders, mark all read.

-- 80_ left a submitted reading by the TRN head (…14) on TRN.PROG in period f8.
select id as m1, version as m1v from public.indicator_measurements
 where period_id = '00000000-0000-0000-0000-0000000000f8' and status = 'submitted' limit 1 \gset
select test.eq((select count(*) from public.notifications
                where recipient_id = '00000000-0000-0000-0000-000000000011' and event_type = 'measurement_submitted'
                  and entity_id = :'m1'::uuid), 1::bigint, 'director notified of a submitted reading');
select test.eq((select count(*) from public.notifications
                where recipient_id = '00000000-0000-0000-0000-000000000014' and event_type = 'measurement_submitted'), 0::bigint,
               'the person who entered it is not notified of their own submission');

select test.login('00000000-0000-0000-0000-000000000011');
select public.decide_measurement(:'m1'::uuid, 'approved', :m1v, '85000000-0000-0000-0000-000000000001') as d1 \gset
select test.logout();
select test.eq((select count(*) from public.notifications
                where recipient_id = '00000000-0000-0000-0000-000000000014' and event_type = 'measurement_approved'
                  and entity_id = :'m1'::uuid), 1::bigint, 'head notified that the reading was approved');

-- The head reads their own inbox only, and can clear it.
select test.login('00000000-0000-0000-0000-000000000014');
select test.ok((select count(*) from public.notifications) > 0, 'head sees own notifications');
select test.eq((select count(*) from public.notifications where recipient_id <> '00000000-0000-0000-0000-000000000014'),
               0::bigint, 'no one else''s notifications are visible (RLS)');
select public.mark_all_notifications_read() as cleared \gset
select test.ok(:cleared > 0, 'mark all read clears unread items');
select test.eq((select count(*) from public.notifications where read_at is null), 0::bigint, 'inbox fully read');
select test.eq(public.mark_all_notifications_read(), 0, 'second call changes nothing');
select test.logout();

-- Deadline reminders: once per item and deadline.
select private.deadline_reminders('2100-01-01'::timestamptz) as n1 \gset
select count(*) as c1 from public.notifications where event_type in ('task_overdue', 'report_overdue') \gset
select test.ok(:c1 > 0, 'open items past their deadline produce overdue reminders');
select private.deadline_reminders('2100-01-01'::timestamptz) as n2 \gset
select test.eq((select count(*) from public.notifications where event_type in ('task_overdue', 'report_overdue')), :c1::bigint,
               'a second run does not repeat reminders');
select test.ok(not exists (select 1 from public.notifications n join public.tasks t on t.id = n.entity_id
                           where n.event_type = 'task_overdue' and t.status in ('completed', 'cancelled', 'submitted')),
               'finished or submitted tasks get no overdue reminder');
