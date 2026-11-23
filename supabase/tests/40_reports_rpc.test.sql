-- G4 reports: scheduling idempotency, draft/submit/return/resubmit/approve,
-- stale revision, waiver, compliance. AC-015..AC-019.

-- Fixtures (owner): template, version with required fields, schedule for LAB and TRN.
insert into public.report_templates (id, organization_id, name_ar, frequency, created_by) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000a0', 'التقرير الشهري', 'monthly',
   '00000000-0000-0000-0000-000000000011');
insert into public.report_template_versions (id, organization_id, template_id, revision, field_schema, required_fields, created_by) values
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000e1', 1,
   '{"sections":["summary","obstacles","next_plan"]}', array['summary', 'next_plan'], '00000000-0000-0000-0000-000000000011');
insert into public.report_schedules (organization_id, template_version_id, department_id, recurrence, due_rule, active_from, created_by)
select '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000e2', d, 'monthly',
       '{"kind":"day_of_next_period","day":5,"local_time":"23:59"}', '2026-01-01', '00000000-0000-0000-0000-000000000011'
from unnest(array['00000000-0000-0000-0000-0000000000d1'::uuid, '00000000-0000-0000-0000-0000000000d2'::uuid]) d;

-- AC-018: running the scheduler twice yields one instance per dept/template/period.
select public.generate_report_instances('00000000-0000-0000-0000-0000000000f1') as g1 \gset
select public.generate_report_instances('00000000-0000-0000-0000-0000000000f1') as g2 \gset
select test.eq((:'g1'::jsonb ->> 'created')::int, 2, 'scheduler creates LAB and TRN instances');
select test.eq((:'g2'::jsonb ->> 'created')::int, 0, 'second scheduler run creates nothing');
select test.eq((select count(*) from public.report_instances), 2::bigint, 'exactly two instances exist');
select test.eq((select to_char(due_at at time zone 'Asia/Riyadh', 'YYYY-MM-DD HH24:MI') from public.report_instances
                where department_id = '00000000-0000-0000-0000-0000000000d1'), '2026-12-05 23:59',
               'November report due 5 December 23:59 Riyadh');
select id as rep from public.report_instances where department_id = '00000000-0000-0000-0000-0000000000d1' \gset
select test.throws($$select private.report_due_at('{"kind":"weird"}', p) from public.reporting_periods p limit 1$$,
                   'HC_VALIDATION_FAILED', 'unknown due rule rejected');

-- Clients cannot run the scheduler.
select test.login('00000000-0000-0000-0000-000000000011');
select test.throws($$select public.generate_report_instances('00000000-0000-0000-0000-0000000000f1')$$, '42501',
                   'director cannot call the scheduler directly');
select test.logout();

-- Coordinator drafts but cannot submit.
select test.login('00000000-0000-0000-0000-000000000013');
select public.save_report_draft(:'rep', '{"summary":"ملخص أولي"}', '50000000-0000-0000-0000-000000000001') as d1 \gset
select (:'d1'::jsonb ->> 'revision_id') as rev1 \gset
select test.eq((:'d1'::jsonb ->> 'revision')::int, 1, 'coordinator creates draft revision 1');
select test.throws(format($$select public.submit_report(%L, %L, 1, gen_random_uuid())$$, :'rep', :'rev1'),
                   'HC_FORBIDDEN', 'coordinator cannot submit without delegation');
select test.logout();

-- Director cannot see department drafts.
select test.login('00000000-0000-0000-0000-000000000011');
select test.eq((select count(*) from public.report_revisions), 0::bigint, 'director does not see drafts');
select test.logout();

-- Head: stale draft version is rejected; missing required field blocks submission.
select test.login('00000000-0000-0000-0000-000000000012');
select test.throws(format($$select public.save_report_draft(%L, '{"summary":"x"}', gen_random_uuid(), 99)$$, :'rep'),
                   'HC_VERSION_CONFLICT', 'stale draft version rejected');
select test.throws(format($$select public.submit_report(%L, %L, 1, gen_random_uuid())$$, :'rep', :'rev1'),
                   'HC_VALIDATION_FAILED', 'missing required next_plan blocks submission');
select public.save_report_draft(:'rep', '{"summary":"ملخص","next_plan":"خطة ديسمبر"}', '50000000-0000-0000-0000-000000000002',
                                (:'d1'::jsonb ->> 'revision_version')::int) as d2 \gset
select test.eq(:'d2'::jsonb ->> 'revision_id', :'rev1', 'draft updated in place');
select public.submit_report(:'rep', :'rev1', 1, '50000000-0000-0000-0000-000000000003') as s1 \gset
select test.eq(:'s1'::jsonb ->> 'status', 'submitted', 'head submits');
select (:'s1'::jsonb ->> 'first_submitted_at') as first_sub \gset
-- Submitted content is immutable, even for the owner (direct UPDATE has no grant anyway).
select test.throws(format($$update public.report_revisions set content = '{}' where id = %L$$, :'rev1'), '42501',
                   'client cannot rewrite a submitted revision');
select test.throws(format($$select public.decide_report(%L, %L, 'approved', 2, gen_random_uuid())$$, :'rep', :'rev1'),
                   'HC_FORBIDDEN', 'head cannot approve own department report');
select test.logout();
select test.throws(format($$update public.report_revisions set content = '{}' where id = %L$$, :'rev1'), 'HC_FORBIDDEN',
                   'even the owner role cannot rewrite submitted content (trigger)');

-- Other department sees nothing.
select test.login('00000000-0000-0000-0000-000000000014');
select test.eq((select count(*) from public.report_instances where id = :'rep'::uuid), 0::bigint, 'TRN head cannot see LAB report');
select test.throws(format($$select public.decide_report(%L, %L, 'approved', 2, gen_random_uuid())$$, :'rep', :'rev1'),
                   'HC_NOT_FOUND', 'TRN head cannot act on LAB report');
select test.logout();

-- Director returns with a note (AC-016).
select test.login('00000000-0000-0000-0000-000000000011');
select test.throws(format($$select public.decide_report(%L, %L, 'returned', 2, gen_random_uuid())$$, :'rep', :'rev1'),
                   'HC_VALIDATION_FAILED', 'return requires a note');
select public.decide_report(:'rep', :'rev1', 'returned', 2, '50000000-0000-0000-0000-000000000004', 'أضف العوائق') as r1 \gset
select test.eq(:'r1'::jsonb ->> 'status', 'returned', 'report returned');
select test.logout();

-- Head prepares revision 2 and resubmits; first submission time is preserved.
select test.login('00000000-0000-0000-0000-000000000012');
select public.save_report_draft(:'rep', '{"summary":"ملخص","next_plan":"خطة","obstacles":"نقص كواشف"}',
                                '50000000-0000-0000-0000-000000000005') as d3 \gset
select (:'d3'::jsonb ->> 'revision_id') as rev2 \gset
select test.eq((:'d3'::jsonb ->> 'revision')::int, 2, 'new draft after return is revision 2');
select test.eq((select content ->> 'summary' from public.report_revisions where id = :'rev1'), 'ملخص',
               'returned revision 1 is kept unchanged');
select public.submit_report(:'rep', :'rev2', 3, '50000000-0000-0000-0000-000000000006') as s2 \gset
select test.eq(:'s2'::jsonb ->> 'first_submitted_at', :'first_sub', 'resubmission keeps first_submitted_at (AC-016)');
select test.logout();

-- AC-017: approving the stale revision 1 fails; approving revision 2 works.
select test.login('00000000-0000-0000-0000-000000000011');
select test.throws(format($$select public.decide_report(%L, %L, 'approved', 4, gen_random_uuid())$$, :'rep', :'rev1'),
                   'HC_VERSION_CONFLICT', 'approving a stale revision is a conflict');
select test.eq((select status from public.report_instances where id = :'rep'), 'submitted', 'stale approval changed nothing');
select public.decide_report(:'rep', :'rev2', 'approved', 4, '50000000-0000-0000-0000-000000000007') as a1 \gset
select test.eq(:'a1'::jsonb ->> 'status', 'approved', 'director approves revision 2');
select test.eq((select approved_revision_id from public.report_instances where id = :'rep'), :'rev2'::uuid,
               'approved revision recorded');
select test.ok((select snapshot_data ? 'content' and snapshot_data ? 'measurements' from public.report_revisions where id = :'rev2'),
               'approval snapshot frozen');
select test.eq((select count(*) from public.report_reviews), 2::bigint, 'two review decisions recorded');
select test.throws(format($$select public.waive_report(%L, 'سبب', 5, gen_random_uuid())$$, :'rep'),
                   'HC_VALIDATION_FAILED', 'approved report cannot be waived');

-- AC-019: waive TRN with reason; compliance excludes it from the denominator.
select id as rep_trn, version as rep_trn_v from public.report_instances where department_id = '00000000-0000-0000-0000-0000000000d2' \gset
select test.throws(format($$select public.waive_report(%L, '', %s, gen_random_uuid())$$, :'rep_trn', :'rep_trn_v'),
                   'HC_VALIDATION_FAILED', 'waiver requires a reason');
select public.waive_report(:'rep_trn', 'القسم في إعادة هيكلة', :rep_trn_v, '50000000-0000-0000-0000-000000000008') as w1 \gset
select test.eq(:'w1'::jsonb ->> 'status', 'waived', 'report waived');
select public.report_compliance('00000000-0000-0000-0000-0000000000f1') as comp \gset
select test.eq((:'comp'::jsonb ->> 'required')::int, 1, 'waived report leaves the denominator');
select test.eq((:'comp'::jsonb ->> 'waived')::int, 1, 'waived count is reported');
select test.eq((:'comp'::jsonb ->> 'on_time')::int, 1, 'LAB counted on time by first submission (AC-015)');
select test.logout();

-- AC-015: approval after due date does not make an on-time submission late.
update public.report_instances set due_at = (first_submitted_at + interval '1 minute') where id = :'rep';
select test.login('00000000-0000-0000-0000-000000000011');
select test.eq((public.report_compliance('00000000-0000-0000-0000-0000000000f1') ->> 'on_time')::int, 1,
               'still on time although approved after the due date');
select test.logout();

-- Executive viewer sees approved reports only.
select test.login('00000000-0000-0000-0000-000000000015');
select test.eq((select count(*) from public.report_instances), 1::bigint, 'exec viewer sees only the approved report');
select test.eq((select count(*) from public.report_revisions), 1::bigint, 'exec viewer sees only the approved revision');
select test.logout();
