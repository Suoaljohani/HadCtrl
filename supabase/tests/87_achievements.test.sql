-- Achievements (§16, API-10): draft → submit → return/approve, roles, history, notifications.

select test.login('00000000-0000-0000-0000-000000000013');  -- LAB coordinator drafts
select public.save_achievement('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000f8',
  'تقليص زمن إصدار النتائج', '87000000-0000-0000-0000-000000000001', p_description => 'إعادة ترتيب مسار العينات') as a1 \gset
select test.eq(:'a1'::jsonb ->> 'status', 'draft', 'a department member creates a draft');
select public.save_achievement('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000f8',
  'تقليص زمن إصدار النتائج', '87000000-0000-0000-0000-000000000001', p_description => 'إعادة ترتيب مسار العينات') as a1b \gset
select test.eq(:'a1b'::jsonb ->> 'achievement_id', :'a1'::jsonb ->> 'achievement_id', 'creation is idempotent');
select test.throws(format($$select public.submit_achievement(%L, 1, gen_random_uuid())$$, :'a1'::jsonb ->> 'achievement_id'),
                   'HC_FORBIDDEN', 'a coordinator cannot submit');
select test.throws($$select public.save_achievement('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000f8',
                     'مرتبط بمهمة مفتوحة', gen_random_uuid(), p_linked_task_id => '00000000-0000-0000-0000-0000000000c1')$$,
                   'HC_VALIDATION_FAILED', 'only a completed task of the department can be linked');
select test.throws($$select public.save_achievement('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000f7',
                     'في فترة مجمدة', gen_random_uuid())$$, 'HC_PERIOD_FROZEN', 'no new achievement in a frozen period');
select test.logout();

-- Drafts stay inside the department.
select test.login('00000000-0000-0000-0000-000000000011');
select test.eq((select count(*) from public.achievements where id = (:'a1'::jsonb ->> 'achievement_id')::uuid), 0::bigint,
               'the director does not see drafts');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000014');
select test.eq((select count(*) from public.achievements where id = (:'a1'::jsonb ->> 'achievement_id')::uuid), 0::bigint,
               'another department does not see drafts');
select test.throws($$select public.save_achievement('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000f8',
                     'ليس قسمي', gen_random_uuid())$$, 'HC_NOT_FOUND', 'a head of another department cannot write here');
select test.logout();

-- The head submits once the impact is stated.
select test.login('00000000-0000-0000-0000-000000000012');
select test.throws(format($$select public.submit_achievement(%L, 1, gen_random_uuid())$$, :'a1'::jsonb ->> 'achievement_id'),
                   'HC_VALIDATION_FAILED', 'impact is required before submission');
select test.throws(format($$select public.save_achievement('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000f8',
                     'تقليص زمن إصدار النتائج', gen_random_uuid(), p_achievement_id => %L, p_expected_version => 9)$$,
                   :'a1'::jsonb ->> 'achievement_id'), 'HC_VERSION_CONFLICT', 'a stale edit is a conflict');
select public.save_achievement('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000f8',
  'تقليص زمن إصدار النتائج', '87000000-0000-0000-0000-000000000002',
  p_achievement_id => (:'a1'::jsonb ->> 'achievement_id')::uuid, p_expected_version => 1,
  p_impact_text => 'من ١٢ إلى ٩ ساعات (قراءة LAB.TAT المعتمدة)',
  p_contributor_department_ids => array['00000000-0000-0000-0000-0000000000d2']::uuid[]) as a2 \gset
select public.submit_achievement((:'a1'::jsonb ->> 'achievement_id')::uuid, (:'a2'::jsonb ->> 'version')::int,
  '87000000-0000-0000-0000-000000000003') as s1 \gset
select test.eq(:'s1'::jsonb ->> 'status', 'submitted', 'head submits');
select test.throws(format($$select public.decide_achievement(%L, 'approved', %s, gen_random_uuid())$$,
                   :'a1'::jsonb ->> 'achievement_id', :'s1'::jsonb ->> 'version'), 'HC_FORBIDDEN',
                   'the department cannot approve its own achievement');
select test.logout();
select test.eq((select count(*) from public.achievement_contributors where achievement_id = (:'a1'::jsonb ->> 'achievement_id')::uuid),
               1::bigint, 'contributing department recorded once');
select test.eq((select count(*) from public.notifications where recipient_id = '00000000-0000-0000-0000-000000000011'
                  and entity_id = (:'a1'::jsonb ->> 'achievement_id')::uuid and event_type = 'decision_needed'), 1::bigint,
               'director notified of the submission');

-- Director returns (note required), department resubmits, director approves.
select test.login('00000000-0000-0000-0000-000000000011');
select test.throws(format($$select public.decide_achievement(%L, 'returned', %s, gen_random_uuid())$$,
                   :'a1'::jsonb ->> 'achievement_id', :'s1'::jsonb ->> 'version'), 'HC_VALIDATION_FAILED', 'return needs a note');
select public.decide_achievement((:'a1'::jsonb ->> 'achievement_id')::uuid, 'returned', (:'s1'::jsonb ->> 'version')::int,
  '87000000-0000-0000-0000-000000000004', 'أرفق مقارنة الفترة السابقة') as d1 \gset
select test.eq(:'d1'::jsonb ->> 'status', 'returned', 'director returns with a note');
select test.logout();
select test.eq((select count(*) from public.notifications where recipient_id = '00000000-0000-0000-0000-000000000013'
                  and event_type = 'achievement_decided'), 1::bigint, 'the author is notified of the decision');

select test.login('00000000-0000-0000-0000-000000000012');
select public.submit_achievement((:'a1'::jsonb ->> 'achievement_id')::uuid, (:'d1'::jsonb ->> 'version')::int,
  '87000000-0000-0000-0000-000000000005') as s2 \gset
select test.logout();
select test.login('00000000-0000-0000-0000-000000000021');  -- other hospital
select test.throws(format($$select public.decide_achievement(%L, 'approved', %s, gen_random_uuid())$$,
                   :'a1'::jsonb ->> 'achievement_id', :'s2'::jsonb ->> 'version'), 'HC_NOT_FOUND', 'other hospital cannot decide');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000011');
select public.decide_achievement((:'a1'::jsonb ->> 'achievement_id')::uuid, 'approved', (:'s2'::jsonb ->> 'version')::int,
  '87000000-0000-0000-0000-000000000006') as d2 \gset
select test.eq(:'d2'::jsonb ->> 'status', 'approved', 'director approves');
select test.eq((select count(*) from public.achievement_reviews where achievement_id = (:'a1'::jsonb ->> 'achievement_id')::uuid),
               2::bigint, 'both decisions kept in the history');
select test.logout();

-- Approved achievements are visible across the hospital; history is immutable.
select test.login('00000000-0000-0000-0000-000000000015');
select test.eq((select status from public.achievements where id = (:'a1'::jsonb ->> 'achievement_id')::uuid), 'approved',
               'executive viewer sees the approved achievement');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000014');
select test.eq((select count(*) from public.achievement_reviews where achievement_id = (:'a1'::jsonb ->> 'achievement_id')::uuid),
               2::bigint, 'another department can read the decisions of an approved achievement');
select test.logout();
select test.throws(format($$update public.achievement_reviews set note = 'x' where achievement_id = %L$$,
                          :'a1'::jsonb ->> 'achievement_id'), '%', 'review history cannot be edited');
