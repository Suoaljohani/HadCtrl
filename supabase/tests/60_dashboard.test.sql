-- API-01 dashboard_snapshot: permission-filtered, consistent, coverage-aware.
select test.login('00000000-0000-0000-0000-000000000011');
select public.dashboard_snapshot('00000000-0000-0000-0000-0000000000f1') as d \gset
select test.eq((:'d'::jsonb -> 'coverage' ->> 'coverage_pct')::numeric, 100::numeric, 'director: full indicator coverage');
select test.eq(:'d'::jsonb -> 'coverage' ->> 'verdict', 'final', 'frozen period with full coverage is final');
select test.ok(abs((:'d'::jsonb -> 'coverage' ->> 'measured_score')::numeric - 96.8421) < 0.001,
               'measured score uses the approved correction 92/100 vs 95');
select test.eq((:'d'::jsonb -> 'readings' -> 'reports_received' ->> 'denominator')::int, 1, 'waived report excluded from denominator');
select test.eq((:'d'::jsonb -> 'readings' -> 'reports_received' ->> 'waived')::int, 1, 'waived count shown');
select test.eq((:'d'::jsonb -> 'readings' ->> 'awaiting_my_decision')::int,
               (select count(*)::int from jsonb_array_elements(:'d'::jsonb -> 'actions') e where e ->> 'kind' = 'ready_for_approval'),
               'awaiting count equals the listed items (§06)');
select test.ok(jsonb_array_length(:'d'::jsonb -> 'departments') = 2, 'archived department not listed');
select test.logout();

-- Head of TRN sees no LAB indicator, so no verdict and no LAB department.
select test.login('00000000-0000-0000-0000-000000000014');
select public.dashboard_snapshot('00000000-0000-0000-0000-0000000000f1') as h \gset
select test.eq(:'h'::jsonb -> 'coverage' ->> 'verdict', 'insufficient_data', 'no visible indicators → no verdict');
select test.eq((select count(*)::int from jsonb_array_elements(:'h'::jsonb -> 'departments') e where e ->> 'code' = 'LAB'), 0,
               'TRN head dashboard does not leak LAB');
select test.eq((select count(*)::int from jsonb_array_elements(:'h'::jsonb -> 'actions') e
                where e ->> 'department_id' = '00000000-0000-0000-0000-0000000000d1'), 0, 'no LAB actions leak');
select test.logout();

-- Other hospital and outsiders get not-found.
select test.login('00000000-0000-0000-0000-000000000021');
select test.throws($$select public.dashboard_snapshot('00000000-0000-0000-0000-0000000000f1')$$, 'HC_NOT_FOUND',
                   'director B cannot read hospital A dashboard');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000099');
select test.throws($$select public.dashboard_snapshot('00000000-0000-0000-0000-0000000000f1')$$, 'HC_NOT_FOUND', 'outsider gets not found');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000017');
select test.throws($$select public.dashboard_snapshot('00000000-0000-0000-0000-0000000000f1')$$, 'HC_MEMBERSHIP_INACTIVE', 'disabled user rejected');
select test.logout();
