-- Global search (§17, API-19): normalization, categories, visibility before return, hospital isolation.

select test.login('00000000-0000-0000-0000-000000000011');  -- director, hospital A
select public.search_records('مهمه') as r1 \gset
select test.ok(jsonb_array_length(:'r1'::jsonb -> 'tasks') >= 2, 'ة/ه normalized: "مهمه" finds "مهمة" tasks');
select test.eq((select count(*) from jsonb_array_elements(:'r1'::jsonb -> 'tasks') e
                where e ->> 'title' = 'مهمة مستشفى ب'), 0::bigint, 'never returns another hospital''s task');
select public.search_records('lab') as r2 \gset
select test.eq((select count(*) from jsonb_array_elements(:'r2'::jsonb -> 'departments') e), 1::bigint,
               'department code match is case-insensitive and stays inside the hospital');
select public.search_records('المختبر') as r3 \gset
select test.eq((:'r3'::jsonb -> 'departments' -> 0 ->> 'title'), 'المختبر', 'original spelling returned for display');
select test.throws($$select public.search_records('م')$$, 'HC_VALIDATION_FAILED', 'one character is too short');
select test.eq((select count(*) from jsonb_array_elements((public.search_records('%%')) -> 'tasks')), 0::bigint,
               'LIKE wildcards are literal');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000014');  -- TRN head
select public.search_records('مهمة') as r4 \gset
select test.eq((select count(*) from jsonb_array_elements(:'r4'::jsonb -> 'tasks') e where e ->> 'title' = 'مهمة المختبر'), 0::bigint,
               'a head does not find another department''s task');
select test.ok((select count(*) from jsonb_array_elements(:'r4'::jsonb -> 'tasks') e where e ->> 'title' = 'مهمة التدريب') = 1,
               'but finds their own');
select test.logout();

select test.throws($$select public.search_records('مهمة')$$, 'HC_AUTH_REQUIRED', 'anonymous callers get nothing');
