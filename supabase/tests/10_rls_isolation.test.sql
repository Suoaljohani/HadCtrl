-- RLS / grant isolation, tested from the real client roles.
-- AC-001/002/003/021/032, HC-120, §25.

-- anon: no access to anything.
select test.anon();
select test.throws('select count(*) from public.organizations', '42501', 'anon cannot read organizations');
select test.throws('select count(*) from public.tasks', '42501', 'anon cannot read tasks');
select test.throws($$select public.my_context()$$, '42501', 'anon cannot call RPCs');
select test.logout();

-- Outsider (authenticated, no membership) — AC-002.
select test.login('00000000-0000-0000-0000-000000000099');
select test.eq((select count(*) from public.organizations), 0::bigint, 'outsider sees no organizations');
select test.eq((select count(*) from public.departments), 0::bigint, 'outsider sees no departments');
select test.eq((select count(*) from public.tasks), 0::bigint, 'outsider sees no tasks');
select test.eq((select jsonb_array_length(public.my_context() -> 'organizations')), 0, 'outsider context has no organizations');
select test.logout();

-- Director A: whole hospital A, nothing from B.
select test.login('00000000-0000-0000-0000-000000000011');
select test.eq((select count(*) from public.organizations), 1::bigint, 'director A sees only org A');
select test.eq((select count(*) from public.departments), 3::bigint, 'director A sees all A departments (incl. archived)');
select test.eq((select count(*) from public.tasks), 2::bigint, 'director A sees both A tasks');
select test.eq((select count(*) from public.tasks where organization_id = '00000000-0000-0000-0000-0000000000b0'), 0::bigint,
               'director A cannot see org B tasks');
select test.eq((select count(*) from public.reporting_periods), 1::bigint, 'director A sees only A periods');
select test.logout();

-- Head of LAB: own department only — AC-003.
select test.login('00000000-0000-0000-0000-000000000012');
select test.eq((select count(*) from public.departments), 1::bigint, 'LAB head sees only LAB department');
select test.eq((select count(*) from public.departments where id = '00000000-0000-0000-0000-0000000000d2'), 0::bigint,
               'LAB head guessing TRN UUID gets nothing (no name leak)');
select test.eq((select count(*) from public.tasks), 1::bigint, 'LAB head sees only LAB task');
select test.eq((select count(*) from public.tasks where id = '00000000-0000-0000-0000-0000000000c2'), 0::bigint,
               'LAB head guessing TRN task UUID gets nothing');
select test.eq((select count(*) from public.department_memberships where department_id = '00000000-0000-0000-0000-0000000000d2'), 0::bigint,
               'LAB head cannot list TRN memberships');
select test.logout();

-- Coordinator: own department, no other department.
select test.login('00000000-0000-0000-0000-000000000013');
select test.eq((select count(*) from public.tasks), 1::bigint, 'coordinator sees LAB task');
select test.eq((select count(*) from public.departments), 1::bigint, 'coordinator sees only LAB');
select test.logout();

-- Executive viewer: departments yes, operational tasks no.
select test.login('00000000-0000-0000-0000-000000000015');
select test.eq((select count(*) from public.departments), 3::bigint, 'exec viewer sees A departments');
select test.eq((select count(*) from public.tasks), 0::bigint, 'exec viewer does not see operational tasks');
select test.logout();

-- System admin: structure yes, results no automatically.
select test.login('00000000-0000-0000-0000-000000000016');
select test.eq((select count(*) from public.departments), 3::bigint, 'system admin sees department structure');
select test.eq((select count(*) from public.tasks), 0::bigint, 'system admin does not see department tasks');
select test.logout();

-- Disabled profile (active=false) — AC-032: token still "valid", access gone.
select test.login('00000000-0000-0000-0000-000000000017');
select test.eq((select count(*) from public.tasks), 0::bigint, 'disabled user sees no tasks');
select test.eq((select count(*) from public.departments), 0::bigint, 'disabled user sees no departments');
select test.throws($$select public.my_context()$$, 'HC_MEMBERSHIP_INACTIVE', 'disabled user RPC rejected');
select test.logout();

-- Expired membership.
select test.login('00000000-0000-0000-0000-000000000018');
select test.eq((select count(*) from public.departments), 0::bigint, 'expired coordinator sees no departments');
select test.eq((select count(*) from public.organizations), 0::bigint, 'expired coordinator sees no organization');
select test.logout();

-- Delegated reviewer: LAB only, via delegation.
select test.login('00000000-0000-0000-0000-000000000019');
select test.eq((select count(*) from public.tasks), 1::bigint, 'delegate reviewer sees LAB task only');
select test.eq((select count(*) from public.departments), 1::bigint, 'delegate reviewer sees LAB only');
select test.logout();

-- Direct writes are blocked for everyone (writes go through RPCs).
select test.login('00000000-0000-0000-0000-000000000011');
select test.throws($$insert into public.tasks (organization_id, department_id, creator_id, title)
                    values ('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000d1',
                            '00000000-0000-0000-0000-000000000011','direct insert')$$, '42501', 'director cannot INSERT tasks directly');
select test.throws($$update public.tasks set status = 'completed' where id = '00000000-0000-0000-0000-0000000000c1'$$, '42501',
                   'director cannot UPDATE task status directly');
select test.throws($$delete from public.tasks where id = '00000000-0000-0000-0000-0000000000c1'$$, '42501',
                   'director cannot DELETE tasks');
select test.throws($$insert into public.audit_events (organization_id, actor_id, entity_type, entity_id, action)
                    values ('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-000000000012','task',
                            '00000000-0000-0000-0000-0000000000c1','forged')$$, '42501', 'client cannot forge audit events');
select test.throws($$insert into public.organization_memberships (organization_id, user_id, role)
                    values ('00000000-0000-0000-0000-0000000000b0','00000000-0000-0000-0000-000000000011','hospital_director')$$,
                   '42501', 'client cannot grant itself a membership');
select test.throws($$select * from public.idempotency_requests$$, '42501', 'client cannot read idempotency store');
select test.throws($$select * from public.notification_outbox$$, '42501', 'client cannot read notification outbox');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000012');
select test.throws($$update public.profiles set active = true where user_id = '00000000-0000-0000-0000-000000000012'$$, '42501',
                   'user cannot change own active flag');
update public.profiles set display_name = 'رئيس المختبر' where user_id = '00000000-0000-0000-0000-000000000012';
select test.eq((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-000000000012'), 'رئيس المختبر',
               'user can edit own display name');
update public.profiles set display_name = 'hijack' where user_id = '00000000-0000-0000-0000-000000000014';
select test.logout();
select test.ok((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-000000000014') <> 'hijack',
               'user cannot edit another profile');

-- Personal preferences are strictly per user and require membership.
select test.login('00000000-0000-0000-0000-000000000012');
insert into public.personal_preferences (organization_id, pinned_departments)
values ('00000000-0000-0000-0000-0000000000a0', array['00000000-0000-0000-0000-0000000000d1']::uuid[]);
select test.throws($$insert into public.personal_preferences (organization_id, user_id)
                    values ('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-000000000014')$$, '42501',
                   'cannot write preferences for another user');
select test.throws($$insert into public.personal_preferences (organization_id) values ('00000000-0000-0000-0000-0000000000b0')$$,
                   '42501', 'cannot write preferences in a non-member org');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000014');
select test.eq((select count(*) from public.personal_preferences), 0::bigint, 'preferences of others are invisible');
select test.logout();
