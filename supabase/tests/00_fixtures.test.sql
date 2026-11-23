-- Test harness + synthetic fixtures (two hospitals, every role, edge cases).
-- Runs as the database owner; individual tests then switch to the real
-- "authenticated"/"anon" roles with a JWT "sub" claim — never service_role.

create schema if not exists test;
grant usage on schema test to anon, authenticated;

create or replace function test.login(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  execute 'set role authenticated';
end $$;

create or replace function test.anon() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', false);
  execute 'set role anon';
end $$;

create or replace function test.logout() returns void
language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', false);
end $$;

create or replace function test.eq(p_actual anyelement, p_expected anyelement, p_label text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %', p_label, p_expected, p_actual;
  end if;
  raise notice 'ok   %', p_label;
end $$;

create or replace function test.ok(p_cond boolean, p_label text) returns void
language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FAIL %', p_label;
  end if;
  raise notice 'ok   %', p_label;
end $$;

-- Runs p_sql and asserts it raises an error whose message (or SQLSTATE) matches p_expected.
create or replace function test.throws(p_sql text, p_expected text, p_label text) returns void
language plpgsql as $$
declare
  v_msg text; v_state text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    if v_msg = p_expected or v_state = p_expected or v_msg like p_expected then
      raise notice 'ok   % (%)', p_label, v_msg;
      return;
    end if;
    raise exception 'FAIL %: expected error %, got % / %', p_label, p_expected, v_state, v_msg;
  end;
  raise exception 'FAIL %: expected error %, but statement succeeded', p_label, p_expected;
end $$;

grant execute on all functions in schema test to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Fixed identities
-- ---------------------------------------------------------------------------
-- Org A (Alhadithah demo) and Org B (another hospital).
--   ...a0: org A           ...b0: org B
--   ...d1: dept A-LAB      ...d2: dept A-TRN       ...d9: dept B-LAB    ...d5: dept A archived
--   users: 11 dirA, 12 headLab, 13 coordLab, 14 headTrn, 15 execA, 16 sysadminA,
--          17 disabledHead (profile inactive), 18 expiredHead (membership expired),
--          19 delegateReviewer (review_tasks on LAB), 21 dirB, 22 headB, 99 outsider (no membership)
insert into auth.users (id, email) select ('00000000-0000-0000-0000-0000000000' || x)::uuid, 'u' || x || '@test.invalid'
from unnest(array['11','12','13','14','15','16','17','18','19','21','22','99']) x;

insert into public.profiles (user_id, display_name, active)
select ('00000000-0000-0000-0000-0000000000' || x)::uuid, 'user ' || x, x <> '17'
from unnest(array['11','12','13','14','15','16','17','18','19','21','22','99']) x;

insert into public.organizations (id, name_ar, name_en, is_demo) values
  ('00000000-0000-0000-0000-0000000000a0', 'مستشفى الحديثة العام (تجريبي)', 'Alhadithah General Hospital (demo)', true),
  ('00000000-0000-0000-0000-0000000000b0', 'مستشفى آخر (تجريبي)', 'Other Hospital (demo)', true);

insert into public.departments (id, organization_id, code, name_ar, category, archived_at) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a0', 'LAB', 'المختبر', 'medical', null),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a0', 'TRN', 'التدريب', 'administrative', null),
  ('00000000-0000-0000-0000-0000000000d5', '00000000-0000-0000-0000-0000000000a0', 'OLD', 'قسم مؤرشف', 'administrative', now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000000d9', '00000000-0000-0000-0000-0000000000b0', 'LAB', 'مختبر ب', 'medical', null);

insert into public.organization_memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000011', 'hospital_director'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000015', 'executive_viewer'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000016', 'system_admin'),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-000000000021', 'hospital_director');

insert into public.department_memberships (organization_id, department_id, user_id, role, is_primary, valid_from, valid_to) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000012', 'department_head', true, now() - interval '1 year', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000013', 'department_coordinator', false, now() - interval '1 year', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-000000000014', 'department_head', true, now() - interval '1 year', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000017', 'department_coordinator', false, now() - interval '1 year', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-000000000018', 'department_coordinator', false, now() - interval '1 year', now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000d9', '00000000-0000-0000-0000-000000000022', 'department_head', true, now() - interval '1 year', null);

insert into public.delegations (organization_id, grantor_id, grantee_id, scope, department_id, operation, valid_from, valid_to, reason) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000019',
   'department', '00000000-0000-0000-0000-0000000000d1', 'review_tasks', now() - interval '1 day', now() + interval '30 days', 'مراجعة مؤقتة');

insert into public.reporting_periods (id, organization_id, type, start_date, end_date, state) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a0', 'monthly', '2026-11-01', '2026-11-30', 'open'),
  ('00000000-0000-0000-0000-0000000000f9', '00000000-0000-0000-0000-0000000000b0', 'monthly', '2026-11-01', '2026-11-30', 'open');

-- One pre-existing task in each hospital (inserted as owner, bypassing RPCs on purpose).
insert into public.tasks (id, organization_id, department_id, assignee_id, creator_id, title, status, original_due_at, due_at) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d1',
   '00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000011', 'مهمة المختبر', 'assigned', now() + interval '7 days', now() + interval '7 days'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d2',
   '00000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000011', 'مهمة التدريب', 'assigned', now() + interval '7 days', now() + interval '7 days'),
  ('00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000d9',
   '00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000021', 'مهمة مستشفى ب', 'assigned', now() + interval '7 days', now() + interval '7 days');

select test.ok(true, 'fixtures loaded');
