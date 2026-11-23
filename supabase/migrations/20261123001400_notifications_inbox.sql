-- In-app notification inbox (D-28, D-30; spec §18). No APNs: the app reads
-- `notifications` (RLS: own rows only) and polls. This migration adds the
-- missing producers and a bulk read action. Never deletes rows.

-- 1. Indicator readings become notification events (entity = the measurement).
alter table public.notifications drop constraint notifications_event_type_check;
alter table public.notifications add constraint notifications_event_type_check check (event_type in (
  'task_assigned', 'task_submitted', 'task_returned', 'task_completed', 'task_due_soon', 'task_overdue',
  'report_due_soon', 'report_overdue', 'report_returned', 'report_approved', 'report_submitted',
  'extension_requested', 'extension_decided', 'achievement_decided', 'decision_needed',
  'measurement_submitted', 'measurement_approved', 'measurement_returned'));

-- Submitted → every active director (except the person who entered it);
-- approved/returned → the person who entered it. Runs in the same transaction
-- as the RPC that changed the row, so a rolled-back change notifies nobody.
create or replace function private.measurement_notify()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if new.status = 'submitted' and (tg_op = 'INSERT' or old.status is distinct from 'submitted') then
    for r in select m.user_id from public.organization_memberships m
             where m.organization_id = new.organization_id and m.role = 'hospital_director' and m.active
               and m.user_id <> new.entered_by loop
      perform private.notify(new.organization_id, r.user_id, 'measurement_submitted',
                             'measurement_submitted:' || new.id, 'indicator', new.id);
    end loop;
  elsif tg_op = 'UPDATE' and old.status = 'submitted' and new.status in ('approved', 'returned') then
    perform private.notify(new.organization_id, new.entered_by, 'measurement_' || new.status,
                           'measurement_' || new.status || ':' || new.id, 'indicator', new.id);
  end if;
  return null;
end;
$$;
create trigger indicator_measurements_notify after insert or update of status on public.indicator_measurements
  for each row execute function private.measurement_notify();

-- 2. Mark the caller's whole inbox read.
create or replace function public.mark_all_notifications_read()
returns int language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := private.require_actor();
  v_count int;
begin
  update public.notifications set read_at = now() where recipient_id = v_actor and read_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- 3. Due-soon (≤ 3 days) and overdue reminders, once per item and deadline.
-- Tasks: the assignee. Reports: the department's active heads.
create or replace function private.deadline_reminders(p_now timestamptz default now())
returns int language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  for r in select t.id, t.organization_id, t.assignee_id, t.due_at, (t.due_at < p_now) as overdue
             from public.tasks t
            where t.assignee_id is not null and t.due_at is not null
              and t.status in ('assigned', 'acknowledged', 'in_progress', 'blocked', 'returned')
              and t.due_at < p_now + interval '3 days' loop
    perform private.notify(r.organization_id, r.assignee_id,
      case when r.overdue then 'task_overdue' else 'task_due_soon' end,
      case when r.overdue then 'task_overdue:' else 'task_due_soon:' end || r.id || ':' || r.due_at::date,
      'task', r.id);
    v_n := v_n + 1;
  end loop;
  for r in select ri.id, ri.organization_id, ri.department_id, ri.due_at, (ri.due_at < p_now) as overdue
             from public.report_instances ri
            where ri.status in ('not_submitted', 'returned') and ri.due_at < p_now + interval '3 days' loop
    perform private.notify(r.organization_id, m.user_id,
      case when r.overdue then 'report_overdue' else 'report_due_soon' end,
      case when r.overdue then 'report_overdue:' else 'report_due_soon:' end || r.id || ':' || r.due_at::date,
      'report', r.id)
      from public.department_memberships m
     where m.department_id = r.department_id and m.role = 'department_head' and m.active;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace function private.daily_maintenance()
returns void language plpgsql security definer set search_path = '' as $$
declare r record; v_period uuid;
begin
  for r in select id, timezone from public.organizations where active loop
    v_period := private.ensure_month_period(r.id, r.timezone);
    perform public.generate_report_instances(v_period);
  end loop;
  perform private.deadline_reminders();
end;
$$;

-- Grants
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;
revoke execute on function private.measurement_notify(), private.deadline_reminders(timestamptz), private.daily_maintenance()
  from authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;
