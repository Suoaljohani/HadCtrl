-- G5 indicators: scoring parity with Swift, submission rules, review,
-- correction after freeze without losing the snapshot (AC-020).

-- Server scoring matches the Swift reference cases (§11).
select test.ok(abs((private.indicator_score('higher_is_better','ratio',95,null,null,true,false,null,90,100)).score - 94.7368) < 0.0001,
               'score parity: 90/100 vs 95 ≈ 94.7368');
select test.ok(abs((private.indicator_score('lower_is_better','duration',10,null,null,true,false,12,null,null)).score - 83.3333) < 0.0001,
               'score parity: 12h vs 10h ≈ 83.3333');
select test.eq((private.indicator_score('higher_is_better','count',95,null,null,true,false,null,null,null)).state, 'not_updated',
               'null value is not_updated, not zero');
select test.eq((private.indicator_score('higher_is_better','ratio',95,null,null,true,false,null,0,0)).state, 'not_computable',
               'zero denominator is not_computable');
select test.eq((private.indicator_score('lower_is_better','count',0,null,null,true,true,0,null,null)).score, 100::numeric, 'zero-event 0 → 100');
select test.eq((private.indicator_score('lower_is_better','count',0,null,null,true,true,1,null,null)).score, 0::numeric, 'zero-event 1 → 0');
select test.eq((private.indicator_score('within_range','count',null,2,4,true,false,4,null,null)).score, 100::numeric, 'range inclusive bound');
select test.eq((private.indicator_score('within_range','count',null,2,4,true,false,5,null,null)).state, 'out_of_range', 'out of range labelled');
select test.eq((private.indicator_score('higher_is_better','count',10,null,null,true,false,15,null,null)).score, 100::numeric, 'cap at 100');

-- Definition constraints (§11).
select test.throws($$insert into public.indicator_definition_versions (organization_id, definition_id, revision, measurement_type, unit,
    direction, aggregation, frequency, data_source, target, valid_from, created_by)
  values ('00000000-0000-0000-0000-0000000000a0', gen_random_uuid(), 1, 'count', 'x', 'higher_is_better', 'sum', 'monthly', 'src', 0,
          '2026-01-01', '00000000-0000-0000-0000-000000000011')$$, '23514', 'target 0 for higher-is-better rejected by constraint');
select test.throws($$insert into public.indicator_definition_versions (organization_id, definition_id, revision, measurement_type, unit,
    direction, aggregation, frequency, data_source, target, valid_from, created_by)
  values ('00000000-0000-0000-0000-0000000000a0', gen_random_uuid(), 1, 'count', 'x', 'higher_is_better', 'ratio_of_sums', 'monthly', 'src', 5,
          '2026-01-01', '00000000-0000-0000-0000-000000000011')$$, '23514', 'ratio_of_sums only for ratio indicators');

-- Fixture: LAB documentation-completeness ratio indicator, approved version 1.
insert into public.indicator_definitions (id, organization_id, department_id, code, title, created_by) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d1',
   'LAB.DOC', 'اكتمال توثيق العينات', '00000000-0000-0000-0000-000000000011');
insert into public.indicator_definition_versions (id, organization_id, definition_id, revision, measurement_type, unit, direction,
  aggregation, frequency, numerator_description, denominator_description, data_source, target, valid_from, approved_by, approved_at, created_by)
values ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000b1', 1,
  'ratio', '%', 'higher_is_better', 'ratio_of_sums', 'monthly', 'عينات موثقة', 'كل العينات', 'سجل المختبر', 95, '2026-01-01',
  '00000000-0000-0000-0000-000000000011', now(), '00000000-0000-0000-0000-000000000011');
update public.indicator_definitions set current_version_id = '00000000-0000-0000-0000-0000000000b2'
 where id = '00000000-0000-0000-0000-0000000000b1';

-- Coordinator cannot submit; head submits; input rules.
select test.login('00000000-0000-0000-0000-000000000013');
select test.throws($$select public.submit_measurement('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000f1',
  gen_random_uuid(), p_numerator => 90, p_denominator => 100)$$, 'HC_FORBIDDEN', 'coordinator cannot submit a measurement');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000012');
select test.throws($$select public.submit_measurement('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000f1',
  gen_random_uuid(), p_value => 90)$$, 'HC_VALIDATION_FAILED', 'ratio indicator requires numerator/denominator');
select test.throws($$select public.submit_measurement('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000f1',
  gen_random_uuid(), p_numerator => 1, p_not_applicable_reason => 'لا ينطبق')$$, 'HC_VALIDATION_FAILED', 'N/A cannot carry values');
select public.submit_measurement('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000f1',
  '60000000-0000-0000-0000-000000000001', p_numerator => 90, p_denominator => 100, p_source_note => 'سجل نوفمبر') as m1 \gset
select (:'m1'::jsonb ->> 'measurement_id') as mid1 \gset
select test.eq(:'m1'::jsonb ->> 'status', 'submitted', 'head submits measurement revision 1');
select test.throws($$select public.submit_measurement('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000f1',
  gen_random_uuid(), p_numerator => 91, p_denominator => 100)$$, 'HC_VALIDATION_FAILED', 'only one open revision at a time');
select test.throws(format($$select public.decide_measurement(%L, 'approved', 1, gen_random_uuid())$$, :'mid1'),
                   'HC_FORBIDDEN', 'head cannot approve own measurement');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000014');
select test.throws($$select public.submit_measurement('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000f1',
  gen_random_uuid(), p_numerator => 1, p_denominator => 1)$$, 'HC_NOT_FOUND', 'other department head cannot submit');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000011');
select public.decide_measurement(:'mid1', 'approved', 1, '60000000-0000-0000-0000-000000000002') as a1 \gset
select test.eq(:'a1'::jsonb ->> 'status', 'approved', 'director approves revision 1');
select version as pv from public.reporting_periods where id = '00000000-0000-0000-0000-0000000000f1' \gset
select public.freeze_period('00000000-0000-0000-0000-0000000000f1', :pv, 'إقفال نوفمبر', '60000000-0000-0000-0000-000000000003') as f1 \gset
select test.eq(:'f1'::jsonb ->> 'state', 'frozen', 'period frozen');
select payload, data_hash as h1 from public.period_snapshots where period_id = '00000000-0000-0000-0000-0000000000f1' \gset
select test.ok((:'payload'::jsonb -> 'measurements' -> 0 ->> 'numerator')::numeric = 90, 'snapshot holds approved 90/100');
select test.throws(format($$select public.freeze_period('00000000-0000-0000-0000-0000000000f1', %s, 'x', gen_random_uuid())$$,
                          (:'f1'::jsonb ->> 'version')), 'HC_PERIOD_FROZEN', 'cannot freeze twice');
select test.logout();

-- After freeze: plain submission rejected; correction with reason allowed (AC-020).
select test.login('00000000-0000-0000-0000-000000000012');
select test.throws($$select public.submit_measurement('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000f1',
  gen_random_uuid(), p_numerator => 92, p_denominator => 100)$$, 'HC_PERIOD_FROZEN', 'frozen period rejects uncorrected submission');
select public.submit_measurement('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000f1',
  '60000000-0000-0000-0000-000000000004', p_numerator => 92, p_denominator => 100,
  p_correction_reason => 'تصحيح عينات لم تُحتسب') as m2 \gset
select (:'m2'::jsonb ->> 'measurement_id') as mid2 \gset
select test.eq((:'m2'::jsonb ->> 'revision')::int, 2, 'correction is revision 2');
select test.eq(:'m2'::jsonb ->> 'supersedes_id', :'mid1', 'correction points to the approved revision');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000011');
select public.decide_measurement(:'mid2', 'approved', 1, '60000000-0000-0000-0000-000000000005') as a2 \gset
select test.eq((select status from public.indicator_measurements where id = :'mid1'), 'superseded', 'old approved becomes superseded');
select test.eq((select status from public.indicator_measurements where id = :'mid2'), 'approved', 'correction approved');
select test.eq((select count(*) from public.indicator_measurements where status = 'approved'), 1::bigint, 'exactly one approved value');
select test.eq((select data_hash from public.period_snapshots where period_id = '00000000-0000-0000-0000-0000000000f1'), :'h1',
               'frozen snapshot unchanged by the correction');
select test.logout();
select test.throws($$update public.period_snapshots set payload = '{}'$$, 'HC_FORBIDDEN', 'snapshots are immutable even for the owner');

-- Exec viewer sees only approved values.
select test.login('00000000-0000-0000-0000-000000000015');
select test.eq((select count(*) from public.indicator_measurements), 1::bigint, 'exec viewer sees only the approved measurement');
select test.logout();
