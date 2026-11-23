-- Evidence attachments (§26, API-11): reservation, Storage policies, verification, visibility, limits.

select test.login('00000000-0000-0000-0000-000000000013');  -- LAB coordinator
select public.save_achievement('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000f8',
  'شاهد على أتمتة التقارير', '89000000-0000-0000-0000-000000000001', p_impact_text => 'توفير ٤ ساعات أسبوعيًا') as ach \gset
select (:'ach'::jsonb ->> 'achievement_id') as ach_id \gset
select public.prepare_attachment('achievement', :'ach_id'::uuid, 'محضر الاجتماع.pdf', 'application/pdf', 1000,
  '89000000-0000-0000-0000-000000000002') as p1 \gset
select test.ok((:'p1'::jsonb ->> 'object_path') like '00000000-0000-0000-0000-0000000000a0/00000000-0000-0000-0000-0000000000d1/%',
               'server-made path: organization/department/attachment');
select test.throws(format($$select public.prepare_attachment('achievement', %L, 'برنامج.exe', 'application/x-msdownload', 10, gen_random_uuid())$$, :'ach_id'),
                   'HC_VALIDATION_FAILED', 'executables are not accepted');
select test.throws(format($$select public.prepare_attachment('achievement', %L, 'كبير.pdf', 'application/pdf', 31457280, gen_random_uuid())$$, :'ach_id'),
                   'HC_VALIDATION_FAILED', 'over 20 MB rejected');
select test.throws(format($$select public.prepare_attachment('achievement', %L, '../etc/passwd', 'application/pdf', 10, gen_random_uuid())$$, :'ach_id'),
                   'HC_VALIDATION_FAILED', 'path characters in names rejected');

-- Upload: only to the reserved path, only by the uploader.
select test.throws(format($$insert into storage.objects (bucket_id, name, metadata) values ('hadctrl-evidence', %L, '{}')$$,
                          (:'p1'::jsonb ->> 'object_path') || '-other'), '42501', 'no upload outside a reservation');
insert into storage.objects (bucket_id, name, metadata)
values ('hadctrl-evidence', :'p1'::jsonb ->> 'object_path', '{"size":999,"mimetype":"application/pdf"}');
select test.throws(format($$select public.finalize_attachment(%L, repeat('a', 64), gen_random_uuid())$$, :'p1'::jsonb ->> 'attachment_id'),
                   'HC_ATTACHMENT_INCOMPLETE', 'a size different from the declared one is refused');
select test.logout();
update storage.objects set metadata = '{"size":1000,"mimetype":"application/pdf"}' where name = :'p1'::jsonb ->> 'object_path';

select test.login('00000000-0000-0000-0000-000000000014');  -- TRN head
select test.throws(format($$insert into storage.objects (bucket_id, name, metadata) values ('hadctrl-evidence', %L, '{}')$$,
                          (:'p1'::jsonb ->> 'object_path')), '%', 'another user cannot write to the reservation');
select test.throws(format($$select public.finalize_attachment(%L, repeat('a', 64), gen_random_uuid())$$, :'p1'::jsonb ->> 'attachment_id'),
                   'HC_NOT_FOUND', 'only the uploader finalizes');
select test.throws(format($$select public.prepare_attachment('achievement', %L, 'x.pdf', 'application/pdf', 10, gen_random_uuid())$$, :'ach_id'),
                   'HC_NOT_FOUND', 'another department cannot attach to this record');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000013');
select public.finalize_attachment((:'p1'::jsonb ->> 'attachment_id')::uuid, repeat('b', 64), '89000000-0000-0000-0000-000000000003') as f1 \gset
select test.eq(:'f1'::jsonb ->> 'lifecycle', 'ready', 'verified upload is linked');
select test.eq((select count(*) from public.attachment_links where achievement_id = :'ach_id'::uuid), 1::bigint, 'one link to the achievement');
select test.logout();

-- Reading follows the record: the director cannot read a draft's evidence; after submission they can.
select test.login('00000000-0000-0000-0000-000000000011');
select test.eq((select count(*) from storage.objects where name = :'p1'::jsonb ->> 'object_path'), 0::bigint,
               'director cannot read evidence of a draft');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000014');
select test.eq((select count(*) from storage.objects where name = :'p1'::jsonb ->> 'object_path'), 0::bigint,
               'another department cannot read it');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000012');  -- LAB head submits
select public.submit_achievement(:'ach_id'::uuid, (select version from public.achievements where id = :'ach_id'::uuid),
  '89000000-0000-0000-0000-000000000004') as s1 \gset
select test.throws(format($$select public.prepare_attachment('achievement', %L, 'متأخر.pdf', 'application/pdf', 10, gen_random_uuid())$$, :'ach_id'),
                   'HC_FORBIDDEN', 'no new evidence after submission');
select test.throws(format($$select public.remove_attachment(%L, gen_random_uuid())$$, :'p1'::jsonb ->> 'attachment_id'),
                   'HC_FORBIDDEN', 'evidence of a submitted record cannot be removed');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000011');
select test.eq((select count(*) from storage.objects where name = :'p1'::jsonb ->> 'object_path'), 1::bigint,
               'the director can read evidence once submitted');
select test.logout();

-- Removal while editable; ten-file limit; expired reservations.
select test.login('00000000-0000-0000-0000-000000000013');
select public.save_achievement('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000f8',
  'منجز بعشرة شواهد', '89000000-0000-0000-0000-000000000010') as ach2 \gset
select (:'ach2'::jsonb ->> 'achievement_id') as ach2_id \gset
select count(public.prepare_attachment('achievement', :'ach2_id'::uuid, 'f' || n || '.png', 'image/png', 10, gen_random_uuid()))
  as reserved from generate_series(1, 10) n \gset
select test.eq(:reserved::bigint, 10::bigint, 'ten reservations accepted');
select test.throws(format($$select public.prepare_attachment('achievement', %L, 'f11.png', 'image/png', 10, gen_random_uuid())$$, :'ach2_id'),
                   'HC_VALIDATION_FAILED', 'at most 10 files per record');
select public.prepare_attachment('task', '00000000-0000-0000-0000-0000000000c1', 'صورة.jpg', 'image/jpeg', 50,
  '89000000-0000-0000-0000-000000000011') as p2 \gset
select test.logout();
update public.attachments set upload_expires_at = now() - interval '1 minute' where id = (:'p2'::jsonb ->> 'attachment_id')::uuid;
select test.login('00000000-0000-0000-0000-000000000013');
select test.throws(format($$select public.finalize_attachment(%L, repeat('c', 64), gen_random_uuid())$$, :'p2'::jsonb ->> 'attachment_id'),
                   'HC_ATTACHMENT_INCOMPLETE', 'an expired reservation cannot be finalized');
select test.throws($$update storage.objects set metadata = '{}'$$, '%', 'clients cannot modify stored objects');
select test.logout();
select private.daily_maintenance();
select test.eq((select lifecycle from public.attachments where id = (:'p2'::jsonb ->> 'attachment_id')::uuid), 'failed',
               'the nightly job marks expired reservations failed');
