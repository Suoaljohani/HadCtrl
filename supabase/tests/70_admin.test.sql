-- In-app administration: departments and employee provisioning (D-25).

-- ---------------------------------------------------------------- departments
select test.login('00000000-0000-0000-0000-000000000011');  -- director A
select public.create_department('00000000-0000-0000-0000-0000000000a0', 'rad', 'الأشعة', 'medical',
                                '70000000-0000-0000-0000-000000000001') as d1 \gset
select test.eq(:'d1'::jsonb ->> 'code', 'RAD', 'director creates department (code normalised to upper case)');
select public.create_department('00000000-0000-0000-0000-0000000000a0', 'rad', 'الأشعة', 'medical',
                                '70000000-0000-0000-0000-000000000001') as d1b \gset
select test.eq(:'d1b'::jsonb ->> 'department_id', :'d1'::jsonb ->> 'department_id', 'replay returns the same department');
select test.throws($$select public.create_department('00000000-0000-0000-0000-0000000000a0','RAD','أشعة ثانية','medical',gen_random_uuid())$$,
                   'HC_VALIDATION_FAILED', 'duplicate code rejected');
select test.throws($$select public.create_department('00000000-0000-0000-0000-0000000000a0','a b','x','medical',gen_random_uuid())$$,
                   'HC_VALIDATION_FAILED', 'invalid code / name / category rejected');
select test.throws($$select public.create_department('00000000-0000-0000-0000-0000000000b0','XRAY','أشعة','medical',gen_random_uuid())$$,
                   'HC_NOT_FOUND', 'director A cannot create in hospital B');
select test.eq((select count(*) from public.audit_events where entity_type = 'department' and action = 'create'), 1::bigint,
               'department creation audited once');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000016');  -- system admin A
select public.create_department('00000000-0000-0000-0000-0000000000a0', 'PHR', 'الصيدلة', 'medical', gen_random_uuid()) as d2 \gset
select test.eq(:'d2'::jsonb ->> 'code', 'PHR', 'system admin creates department');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000012');  -- head (not an org manager)
select test.throws($$select public.create_department('00000000-0000-0000-0000-0000000000a0','ICU','العناية','medical',gen_random_uuid())$$,
                   'HC_FORBIDDEN', 'department head cannot create departments');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000015');  -- executive viewer
select test.throws($$select public.create_department('00000000-0000-0000-0000-0000000000a0','ICU','العناية','medical',gen_random_uuid())$$,
                   'HC_FORBIDDEN', 'executive viewer cannot create departments');
select test.logout();

-- ---------------------------------------------------------------- prepare_employee
select test.login('00000000-0000-0000-0000-000000000011');
select public.prepare_employee('00000000-0000-0000-0000-0000000000a0', 'New.Head@Test.invalid', 'رئيس الأشعة',
  '70000000-0000-0000-0000-000000000010', p_job_title => 'رئيس قسم',
  p_department_id => (:'d1'::jsonb ->> 'department_id')::uuid, p_department_role => 'department_head', p_is_primary => true) as p1 \gset
select test.eq(:'p1'::jsonb ->> 'status', 'pending', 'director prepares an employee (head of RAD)');
select test.throws($$select public.prepare_employee('00000000-0000-0000-0000-0000000000a0','x@test.invalid','مدير آخر',gen_random_uuid(),
                     p_org_role => 'hospital_director')$$, 'HC_FORBIDDEN', 'director role cannot be granted from the app');
select test.throws($$select public.prepare_employee('00000000-0000-0000-0000-0000000000a0','not-an-email','اسم',gen_random_uuid())$$,
                   'HC_VALIDATION_FAILED', 'invalid email rejected');
select test.throws(format($$select public.prepare_employee('00000000-0000-0000-0000-0000000000a0','y@test.invalid','اسم',gen_random_uuid(),
                     p_department_id => %L)$$, :'d1'::jsonb ->> 'department_id'), 'HC_VALIDATION_FAILED', 'department without role rejected');
select test.throws($$select public.prepare_employee('00000000-0000-0000-0000-0000000000a0','z@test.invalid','اسم',gen_random_uuid(),
                     p_department_id => '00000000-0000-0000-0000-0000000000d9', p_department_role => 'department_head')$$,
                   'HC_VALIDATION_FAILED', 'department from another hospital rejected');
select test.throws($$select public.prepare_employee('00000000-0000-0000-0000-0000000000a0','w@test.invalid','اسم',gen_random_uuid(),
                     p_department_id => '00000000-0000-0000-0000-0000000000d1', p_department_role => 'department_head', p_is_primary => true)$$,
                   'HC_VALIDATION_FAILED', 'second primary head for LAB rejected');
select public.prepare_employee('00000000-0000-0000-0000-0000000000a0', 'sysadmin2@test.invalid', 'مسؤول تقني',
  gen_random_uuid(), p_org_role => 'system_admin') as p_sa \gset
select test.eq(:'p_sa'::jsonb ->> 'status', 'pending', 'director may grant system_admin');
select test.throws($$select * from public.account_provisioning$$, '42501', 'clients cannot read provisioning rows');
select test.throws(format($$select public.complete_employee(%L, '00000000-0000-0000-0000-000000000011', true)$$,
                          :'p1'::jsonb ->> 'provisioning_id'), '42501', 'clients cannot complete provisioning');
select test.throws($$select public.find_auth_user_id('u12@test.invalid')$$, '42501', 'clients cannot look up auth users');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000016');  -- system admin
select test.throws($$select public.prepare_employee('00000000-0000-0000-0000-0000000000a0','sa3@test.invalid','مسؤول',gen_random_uuid(),
                     p_org_role => 'system_admin')$$, 'HC_FORBIDDEN', 'system admin cannot create another system admin');
select public.prepare_employee('00000000-0000-0000-0000-0000000000a0', 'coord.rad@test.invalid', 'منسق الأشعة', gen_random_uuid(),
  p_department_id => (:'d1'::jsonb ->> 'department_id')::uuid, p_department_role => 'department_coordinator') as p2 \gset
select test.eq(:'p2'::jsonb ->> 'status', 'pending', 'system admin prepares a coordinator');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000012');
select test.throws($$select public.prepare_employee('00000000-0000-0000-0000-0000000000a0','q@test.invalid','اسم',gen_random_uuid())$$,
                   'HC_FORBIDDEN', 'department head cannot create accounts');
select test.throws($$select public.list_people('00000000-0000-0000-0000-0000000000a0')$$, 'HC_FORBIDDEN', 'head cannot list people');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000099');
select test.throws($$select public.prepare_employee('00000000-0000-0000-0000-0000000000a0','q@test.invalid','اسم',gen_random_uuid())$$,
                   'HC_NOT_FOUND', 'outsider gets not found');
select test.logout();

-- ---------------------------------------------------------------- Edge Function steps (as service_role)
-- Simulate what create-employee does after creating the Auth user.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000e5', 'new.head@test.invalid');
set role service_role;
select test.eq(public.find_auth_user_id('NEW.HEAD@test.invalid'), '00000000-0000-0000-0000-0000000000e5'::uuid,
               'service role finds the auth user case-insensitively');
select test.throws(format($$select public.complete_employee(%L, '00000000-0000-0000-0000-000000000012', true)$$,
                          :'p1'::jsonb ->> 'provisioning_id'), 'HC_VALIDATION_FAILED', 'completion with a different user is rejected');
select public.complete_employee((:'p1'::jsonb ->> 'provisioning_id')::uuid, '00000000-0000-0000-0000-0000000000e5', true) as c1 \gset
select test.eq(:'c1'::jsonb ->> 'status', 'completed', 'service role completes provisioning');
select public.complete_employee((:'p1'::jsonb ->> 'provisioning_id')::uuid, '00000000-0000-0000-0000-0000000000e5', true) as c1b \gset
select test.eq((:'c1b'::jsonb ->> 'replayed')::boolean, true, 'completion is idempotent');
reset role;
select test.eq((select count(*) from public.department_memberships where user_id = '00000000-0000-0000-0000-0000000000e5'), 1::bigint,
               'exactly one department membership created');
select test.eq((select must_change_password from public.profiles where user_id = '00000000-0000-0000-0000-0000000000e5'), true,
               'new account must change its temporary password');

-- ---------------------------------------------------------------- the new employee
select test.login('00000000-0000-0000-0000-0000000000e5');
select public.my_context() as ctx \gset
select test.eq((:'ctx'::jsonb -> 'profile' ->> 'must_change_password')::boolean, true, 'my_context reports must_change_password');
select test.eq(:'ctx'::jsonb -> 'organizations' -> 0 -> 'departments' -> 0 ->> 'code', 'RAD', 'new head sees their department');
select test.eq((select count(*) from public.departments), 1::bigint, 'new head sees only RAD');
select public.mark_password_changed();
select test.eq((public.my_context() -> 'profile' ->> 'must_change_password')::boolean, false, 'flag cleared after password change');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000011');
select test.ok((select jsonb_array_length(public.list_people('00000000-0000-0000-0000-0000000000a0'))) >= 9,
               'director lists the hospital''s people');
select test.ok(exists (select 1 from jsonb_array_elements(public.list_people('00000000-0000-0000-0000-0000000000a0')) e
                       where e ->> 'user_id' = '00000000-0000-0000-0000-0000000000e5'
                         and e -> 'departments' -> 0 ->> 'role' = 'department_head'),
               'new head listed with role');
select test.logout();
