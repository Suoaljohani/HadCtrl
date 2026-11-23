-- Goals (§09, AC-010): draft → director activation → completion request → director decision; milestones.

select id as trn_prog from public.indicator_definitions where code = 'TRN.PROG' \gset
select id as lab_doc from public.indicator_definitions
 where department_id = '00000000-0000-0000-0000-0000000000d1' order by created_at limit 1 \gset

select test.login('00000000-0000-0000-0000-000000000014');  -- TRN head
select public.create_goal('00000000-0000-0000-0000-0000000000d2', 'تنفيذ ١٢ برنامجًا تدريبيًا', 'count', 'برنامج',
  '2026-01-01', '2026-12-31', '88000000-0000-0000-0000-000000000001',
  p_target => 12, p_plan => '[{"at":"2026-06-30","expected":6},{"at":"2026-11-30","expected":11},{"at":"2026-12-31","expected":12}]',
  p_indicators => format('[{"definition_id":"%s","relation":"measures_outcome"}]', :'trn_prog')::jsonb) as g1 \gset
select test.eq(:'g1'::jsonb ->> 'lifecycle', 'draft', 'a head drafts a goal');
select public.create_goal('00000000-0000-0000-0000-0000000000d2', 'تنفيذ ١٢ برنامجًا تدريبيًا', 'count', 'برنامج',
  '2026-01-01', '2026-12-31', '88000000-0000-0000-0000-000000000001',
  p_target => 12, p_plan => '[{"at":"2026-06-30","expected":6},{"at":"2026-11-30","expected":11},{"at":"2026-12-31","expected":12}]',
  p_indicators => format('[{"definition_id":"%s","relation":"measures_outcome"}]', :'trn_prog')::jsonb) as g1b \gset
select test.eq(:'g1b'::jsonb ->> 'goal_id', :'g1'::jsonb ->> 'goal_id', 'creation is idempotent');
select test.throws($$select public.create_goal('00000000-0000-0000-0000-0000000000d2','هدف بلا قيمة','count','برنامج',
                     '2026-01-01','2026-12-31', gen_random_uuid())$$, 'HC_VALIDATION_FAILED', 'a target is required (no default 100%)');
select test.throws($$select public.create_goal('00000000-0000-0000-0000-0000000000d2','خطة خارج المدة','count','برنامج',
                     '2026-01-01','2026-06-30', gen_random_uuid(), p_target => 5, p_plan => '[{"at":"2026-09-30","expected":5}]')$$,
                   'HC_VALIDATION_FAILED', 'plan points must lie inside the goal window');
select test.throws($$select public.create_goal('00000000-0000-0000-0000-0000000000d2','خطة متناقصة','count','برنامج',
                     '2026-01-01','2026-12-31', gen_random_uuid(), p_target => 5,
                     p_plan => '[{"at":"2026-03-31","expected":4},{"at":"2026-06-30","expected":2}]')$$,
                   'HC_VALIDATION_FAILED', 'plan must not decrease');
select test.throws(format($$select public.create_goal('00000000-0000-0000-0000-0000000000d2','مؤشر قسم آخر','count','عدد',
                     '2026-01-01','2026-12-31', gen_random_uuid(), p_target => 5,
                     p_indicators => '[{"definition_id":"%s","relation":"supports"}]')$$, :'lab_doc'),
                   'HC_VALIDATION_FAILED', 'only indicators of the same department can be linked');
select test.throws(format($$select public.decide_goal(%L, 'activate', %s, gen_random_uuid())$$, :'g1'::jsonb ->> 'goal_id',
                   :'g1'::jsonb ->> 'version'), 'HC_FORBIDDEN', 'a head cannot activate a goal');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000013');  -- LAB coordinator
select test.throws($$select public.create_goal('00000000-0000-0000-0000-0000000000d1','هدف المنسق','count','عدد',
                     '2026-01-01','2026-12-31', gen_random_uuid(), p_target => 3)$$, 'HC_FORBIDDEN', 'a coordinator cannot create goals');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000015');  -- executive viewer
select test.eq((select count(*) from public.goals where id = (:'g1'::jsonb ->> 'goal_id')::uuid), 0::bigint, 'drafts are not visible to viewers');
select test.logout();
select test.eq((select count(*) from public.notifications where recipient_id = '00000000-0000-0000-0000-000000000011'
                  and entity_id = (:'g1'::jsonb ->> 'goal_id')::uuid and event_type = 'decision_needed'), 1::bigint,
               'director asked to review the new goal');

-- Director activates; the head asks to complete; the director refuses (note), then completes.
select test.login('00000000-0000-0000-0000-000000000011');
select test.throws(format($$select public.decide_goal(%L, 'complete', %s, gen_random_uuid())$$, :'g1'::jsonb ->> 'goal_id',
                   :'g1'::jsonb ->> 'version'), 'HC_VALIDATION_FAILED', 'a draft cannot be completed');
select public.decide_goal((:'g1'::jsonb ->> 'goal_id')::uuid, 'activate', (:'g1'::jsonb ->> 'version')::int,
  '88000000-0000-0000-0000-000000000002') as a1 \gset
select test.eq(:'a1'::jsonb ->> 'lifecycle', 'active', 'director activates');
select test.ok((select approved_at is not null from public.goal_versions where id = (:'a1'::jsonb ->> 'current_version_id')::uuid),
               'activation approves the definition version');
select test.logout();
select test.eq((select count(*) from public.notifications where recipient_id = '00000000-0000-0000-0000-000000000014'
                  and event_type = 'goal_decided'), 1::bigint, 'the owner is told about the decision');

select test.login('00000000-0000-0000-0000-000000000014');
select public.request_goal_completion((:'g1'::jsonb ->> 'goal_id')::uuid, (:'a1'::jsonb ->> 'version')::int,
  '88000000-0000-0000-0000-000000000003') as r1 \gset
select test.eq(:'r1'::jsonb ->> 'lifecycle', 'completion_pending', 'completion is only requested by the head');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000011');
select test.throws(format($$select public.decide_goal(%L, 'reject_completion', %s, gen_random_uuid())$$,
                   :'g1'::jsonb ->> 'goal_id', :'r1'::jsonb ->> 'version'), 'HC_VALIDATION_FAILED', 'refusing completion needs a note');
select public.decide_goal((:'g1'::jsonb ->> 'goal_id')::uuid, 'reject_completion', (:'r1'::jsonb ->> 'version')::int,
  '88000000-0000-0000-0000-000000000004', 'المؤشر المعتمد لم يبلغ المستهدف') as d1 \gset
select test.eq(:'d1'::jsonb ->> 'lifecycle', 'active', 'AC-010: back to active when the indicator is not achieved');
select test.throws(format($$select public.decide_goal(%L, 'activate', %s, gen_random_uuid())$$,
                   :'g1'::jsonb ->> 'goal_id', :'r1'::jsonb ->> 'version'), 'HC_VERSION_CONFLICT', 'stale decision rejected');
select test.logout();

-- Milestone goal: weights must total 100; head completes, director approves.
select test.login('00000000-0000-0000-0000-000000000012');  -- LAB head
select test.throws($$select public.create_goal('00000000-0000-0000-0000-0000000000d1','خطة الجودة','milestones','مرحلة',
                     '2026-01-01','2026-12-31', gen_random_uuid(),
                     p_milestones => '[{"title":"إعداد","criterion":"مسودة معتمدة","weight":60},{"title":"تطبيق","criterion":"تقرير التطبيق","weight":30}]')$$,
                   'HC_VALIDATION_FAILED', 'milestone weights must total 100');
select public.create_goal('00000000-0000-0000-0000-0000000000d1', 'خطة الجودة', 'milestones', 'مرحلة',
  '2026-01-01', '2026-12-31', '88000000-0000-0000-0000-000000000010',
  p_milestones => '[{"title":"إعداد","criterion":"مسودة معتمدة","weight":60},{"title":"تطبيق","criterion":"تقرير التطبيق","weight":40}]') as g2 \gset
select test.logout();
select test.login('00000000-0000-0000-0000-000000000011');
select public.decide_goal((:'g2'::jsonb ->> 'goal_id')::uuid, 'activate', (:'g2'::jsonb ->> 'version')::int,
  '88000000-0000-0000-0000-000000000011') as a2 \gset
select test.logout();
select id as ms1 from public.goal_milestones where goal_version_id = (:'a2'::jsonb ->> 'current_version_id')::uuid and ordinal = 1 \gset
select test.login('00000000-0000-0000-0000-000000000012');
select public.set_milestone(:'ms1'::uuid, 'complete', '88000000-0000-0000-0000-000000000012') as c1 \gset
select test.ok((:'c1'::jsonb ->> 'completed_at') is not null, 'the head marks a milestone done');
select test.throws(format($$select public.set_milestone(%L, 'approve', gen_random_uuid())$$, :'ms1'), 'HC_FORBIDDEN',
                   'the department cannot approve its own milestone');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000011');
select public.set_milestone(:'ms1'::uuid, 'approve', '88000000-0000-0000-0000-000000000013') as c2 \gset
select test.eq(:'c2'::jsonb ->> 'approved', 'true', 'director approves the milestone');
select test.eq((select sum(weight) from public.goal_milestones where goal_version_id = (:'a2'::jsonb ->> 'current_version_id')::uuid
                 and approved_by is not null), 60::numeric, 'approved weight counts toward progress');
select public.decide_goal((:'g2'::jsonb ->> 'goal_id')::uuid, 'cancel', (:'c2'::jsonb ->> 'version')::int,
  '88000000-0000-0000-0000-000000000014', 'دُمجت في خطة المستشفى') as x1 \gset
select test.eq(:'x1'::jsonb ->> 'lifecycle', 'cancelled', 'cancellation keeps the goal with its reason');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000021');  -- other hospital
select test.throws(format($$select public.decide_goal(%L, 'cancel', 1, gen_random_uuid(), 'سبب')$$, :'g1'::jsonb ->> 'goal_id'),
                   'HC_NOT_FOUND', 'other hospital cannot see or decide');
select test.logout();
