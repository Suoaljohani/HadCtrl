-- Definitions from the app: report templates, schedules, period generation, indicators (D-29).

select test.login('00000000-0000-0000-0000-000000000011');  -- director A
select public.create_report_template('00000000-0000-0000-0000-0000000000a0', 'تقرير الأداء الشهري', 'monthly',
  '[{"key":"summary","label":"الملخص","required":true},{"key":"obstacles","label":"العوائق","required":false},
    {"key":"next_plan","label":"خطة الفترة القادمة","required":true}]', '80000000-0000-0000-0000-000000000001') as t1 \gset
select test.ok((:'t1'::jsonb ->> 'template_id') is not null, 'director creates a report template');
select test.eq((select required_fields from public.report_template_versions where id = (:'t1'::jsonb ->> 'template_version_id')::uuid),
               array['summary', 'next_plan'], 'required fields derived from the field list');
select public.create_report_template('00000000-0000-0000-0000-0000000000a0', 'تقرير الأداء الشهري', 'monthly',
  '[{"key":"summary","label":"الملخص","required":true},{"key":"obstacles","label":"العوائق","required":false},
    {"key":"next_plan","label":"خطة الفترة القادمة","required":true}]', '80000000-0000-0000-0000-000000000001') as t1b \gset
select test.eq(:'t1b'::jsonb ->> 'template_id', :'t1'::jsonb ->> 'template_id', 'template creation is idempotent');
select test.throws($$select public.create_report_template('00000000-0000-0000-0000-0000000000a0','قالب','monthly',
                     '[{"key":"Bad Key","label":"x"}]', gen_random_uuid())$$, 'HC_VALIDATION_FAILED', 'invalid field keys rejected');
select test.throws($$select public.create_report_template('00000000-0000-0000-0000-0000000000a0','قالب مكرر','monthly',
                     '[{"key":"a","label":"أ"},{"key":"a","label":"ب"}]', gen_random_uuid())$$, 'HC_VALIDATION_FAILED', 'duplicate keys rejected');

-- Schedule for RAD-less fixture departments TRN (LAB already has the 40_ schedule).
select public.schedule_report((:'t1'::jsonb ->> 'template_id')::uuid,
  array['00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2']::uuid[], 5,
  '80000000-0000-0000-0000-000000000002') as s1 \gset
select test.eq((:'s1'::jsonb ->> 'scheduled')::int, 2, 'template scheduled for two departments');
select test.throws(format($$select public.schedule_report(%L, array['00000000-0000-0000-0000-0000000000d5']::uuid[], 5, gen_random_uuid())$$,
                          :'t1'::jsonb ->> 'template_id'), 'HC_VALIDATION_FAILED', 'archived department cannot be scheduled');
select test.throws(format($$select public.schedule_report(%L, array['00000000-0000-0000-0000-0000000000d9']::uuid[], 5, gen_random_uuid())$$,
                          :'t1'::jsonb ->> 'template_id'), 'HC_VALIDATION_FAILED', 'other hospital''s department rejected');
select test.throws(format($$select public.schedule_report(%L, array['00000000-0000-0000-0000-0000000000d1']::uuid[], 31, gen_random_uuid())$$,
                          :'t1'::jsonb ->> 'template_id'), 'HC_VALIDATION_FAILED', 'due day must be 1..28');

-- Current month period + generation (idempotent).
select public.ensure_current_period('00000000-0000-0000-0000-0000000000a0') as cp \gset
select public.ensure_current_period('00000000-0000-0000-0000-0000000000a0') as cp2 \gset
select test.eq(:'cp'::jsonb ->> 'period_id', :'cp2'::jsonb ->> 'period_id', 'current period is created once');
-- The current period may already be frozen (fixture month, frozen by 50_); generation there is refused.
select test.ok((select state from public.reporting_periods where id = (:'cp'::jsonb ->> 'period_id')::uuid) in ('open','frozen'),
               'current period exists');
select test.logout();
insert into public.reporting_periods (id, organization_id, type, start_date, end_date, state, frozen_at, frozen_by) values
  ('00000000-0000-0000-0000-0000000000f8', '00000000-0000-0000-0000-0000000000a0', 'monthly', '2099-01-01', '2099-01-31', 'open', null, null),
  ('00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-0000000000a0', 'monthly', '2098-12-01', '2098-12-31', 'frozen',
   now(), '00000000-0000-0000-0000-000000000011');
select test.login('00000000-0000-0000-0000-000000000011');
select test.throws($$select public.generate_reports_for_period('00000000-0000-0000-0000-0000000000f7')$$, 'HC_PERIOD_FROZEN',
                   'no generation into a frozen period');
select public.generate_reports_for_period('00000000-0000-0000-0000-0000000000f8') as g1 \gset
select public.generate_reports_for_period('00000000-0000-0000-0000-0000000000f8') as g2 \gset
select test.ok((:'g1'::jsonb ->> 'created')::int >= 2, 'reports generated for the scheduled departments');
select test.eq((:'g2'::jsonb ->> 'created')::int, 0, 'second generation creates nothing');
select test.logout();

-- Only the director defines obligations and measures.
select test.login('00000000-0000-0000-0000-000000000016');  -- system admin
select test.throws($$select public.create_report_template('00000000-0000-0000-0000-0000000000a0','قالب','monthly',
                     '[{"key":"a","label":"أ"}]', gen_random_uuid())$$, 'HC_FORBIDDEN', 'system admin cannot define report templates');
select test.throws($$select public.create_indicator('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000d1',
                     'X1','مؤشر','count','عدد','higher_is_better','sum','monthly','سجل',gen_random_uuid(), p_target => 5)$$,
                   'HC_FORBIDDEN', 'system admin cannot define indicators');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000012');  -- head LAB
select test.throws($$select public.generate_reports_for_period('00000000-0000-0000-0000-0000000000f1')$$, 'HC_FORBIDDEN',
                   'head cannot trigger report generation');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000021');  -- director B
select test.throws($$select public.ensure_current_period('00000000-0000-0000-0000-0000000000a0')$$, 'HC_NOT_FOUND',
                   'director B cannot touch hospital A');
select test.logout();

-- ---------------------------------------------------------------- indicators
select test.login('00000000-0000-0000-0000-000000000011');
select public.create_indicator('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d2',
  'trn.prog', 'البرامج التدريبية المنفذة', 'count', 'برنامج', 'higher_is_better', 'latest', 'monthly', 'سجل التدريب',
  '80000000-0000-0000-0000-000000000010', p_target => 12) as i1 \gset
select test.eq(:'i1'::jsonb ->> 'code', 'TRN.PROG', 'director defines an indicator (code upper-cased)');
select test.ok((select approved_at is not null from public.indicator_definition_versions
                where id = (:'i1'::jsonb ->> 'definition_version_id')::uuid), 'version 1 is approved by the director');
select test.throws($$select public.create_indicator('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000d2',
                     'BAD1','نسبة بلا مقام','ratio','%','higher_is_better','ratio_of_sums','monthly','سجل',gen_random_uuid(), p_target => 90)$$,
                   'HC_VALIDATION_FAILED', 'ratio without numerator/denominator descriptions rejected (§10)');
select test.throws($$select public.create_indicator('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000d2',
                     'BAD2','هدف صفري','count','عدد','higher_is_better','sum','monthly','سجل',gen_random_uuid(), p_target => 0)$$,
                   'HC_VALIDATION_FAILED', 'target 0 for higher-is-better rejected (§11)');
select test.throws($$select public.create_indicator('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000d2',
                     'TRN.PROG','مكرر','count','عدد','higher_is_better','sum','monthly','سجل',gen_random_uuid(), p_target => 3)$$,
                   'HC_VALIDATION_FAILED', 'duplicate indicator code rejected');
select test.eq((select count(*) from public.indicator_definitions where code like 'BAD%'), 0::bigint,
               'rejected definitions leave nothing behind (atomic)');
select test.logout();

-- The TRN head can now report on the new indicator in the current period.
select test.login('00000000-0000-0000-0000-000000000014');
select public.submit_measurement((:'i1'::jsonb ->> 'definition_version_id')::uuid, '00000000-0000-0000-0000-0000000000f8',
  '80000000-0000-0000-0000-000000000011', p_value => 4) as m1 \gset
select test.eq(:'m1'::jsonb ->> 'status', 'submitted', 'head submits a reading for the new indicator');
select test.logout();
