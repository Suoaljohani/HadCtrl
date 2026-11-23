-- Handwritten approval signatures (D-37): reservation, Storage policies, verification,
-- immutability, visibility; device unregistration (D-36).

select test.login('00000000-0000-0000-0000-000000000011');  -- director
select public.prepare_signature('task', '00000000-0000-0000-0000-0000000000c1', 'approve',
  '91000000-0000-0000-0000-000000000001') as s1 \gset
select test.ok((:'s1'::jsonb ->> 'path') like '00000000-0000-0000-0000-0000000000a0/task/00000000-0000-0000-0000-0000000000c1/%.png',
               'server-made path: organization/type/record/signature.png');
select test.eq((public.prepare_signature('task', '00000000-0000-0000-0000-0000000000c1', 'approve',
  '91000000-0000-0000-0000-000000000001')) ->> 'id', :'s1'::jsonb ->> 'id', 'replay with the same request id returns the same reservation');
select test.throws($$select public.prepare_signature('task', '00000000-0000-0000-0000-0000000000c1', 'delete', gen_random_uuid())$$,
                   'HC_VALIDATION_FAILED', 'unknown purpose rejected');
select test.throws($$select public.prepare_signature('task', gen_random_uuid(), 'approve', gen_random_uuid())$$,
                   'HC_NOT_FOUND', 'unknown record rejected');

-- Upload only to the reserved path; the stored object must be a small PNG.
select test.throws(format($$insert into storage.objects (bucket_id, name, metadata) values ('hadctrl-signatures', %L, '{}')$$,
                          (:'s1'::jsonb ->> 'path') || '-other'), '42501', 'no upload outside a reservation');
insert into storage.objects (bucket_id, name, metadata)
values ('hadctrl-signatures', :'s1'::jsonb ->> 'path', '{"size":2048,"mimetype":"image/jpeg"}');
select test.throws(format($$select public.finalize_signature(%L, gen_random_uuid())$$, :'s1'::jsonb ->> 'id'),
                   'HC_ATTACHMENT_INCOMPLETE', 'a non-PNG object is refused');
select test.logout();
update storage.objects set metadata = '{"size":2048,"mimetype":"image/png"}' where name = :'s1'::jsonb ->> 'path';

select test.login('00000000-0000-0000-0000-000000000014');  -- TRN head
select test.throws(format($$select public.finalize_signature(%L, gen_random_uuid())$$, :'s1'::jsonb ->> 'id'),
                   'HC_NOT_FOUND', 'only the signer seals the signature');
select test.throws($$select public.prepare_signature('task', '00000000-0000-0000-0000-0000000000c1', 'approve', gen_random_uuid())$$,
                   'HC_NOT_FOUND', 'a record the caller cannot see cannot be signed');
select test.logout();

select test.login('00000000-0000-0000-0000-000000000011');
select public.finalize_signature((:'s1'::jsonb ->> 'id')::uuid, '91000000-0000-0000-0000-000000000002') as f1 \gset
select test.ok((:'f1'::jsonb ->> 'signed_at') is not null, 'verified signature is sealed');
select test.eq((select lifecycle from public.approval_signatures where id = (:'s1'::jsonb ->> 'id')::uuid), 'signed', 'lifecycle is signed');
select test.throws(format($$select public.finalize_signature(%L, gen_random_uuid())$$, :'s1'::jsonb ->> 'id'),
                   'HC_VALIDATION_FAILED', 'a sealed signature cannot be finalized again');
select test.logout();

select test.eq((select count(*) from public.audit_events
                where action = 'signature_recorded' and entity_id = '00000000-0000-0000-0000-0000000000c1'), 1::bigint,
               'sealing writes one audit event');
select test.throws(format($$update public.approval_signatures set purpose = 'complete' where id = %L$$, :'s1'::jsonb ->> 'id'),
                   'HC_IMMUTABLE', 'a sealed signature cannot be changed, even by the owner role');
select test.throws(format($$delete from public.approval_signatures where id = %L$$, :'s1'::jsonb ->> 'id'),
                   'HC_IMMUTABLE', 'a signature cannot be deleted');

-- Visibility follows the record.
select test.login('00000000-0000-0000-0000-000000000012');  -- LAB head
select test.eq((select count(*) from public.approval_signatures where entity_id = '00000000-0000-0000-0000-0000000000c1'), 1::bigint,
               'the department sees the signature on its task');
select test.eq((select count(*) from storage.objects where name = :'s1'::jsonb ->> 'path'), 1::bigint,
               'and can read the signature image');
select test.logout();
select test.login('00000000-0000-0000-0000-000000000014');  -- TRN head
select test.eq((select count(*) from public.approval_signatures where entity_id = '00000000-0000-0000-0000-0000000000c1'), 0::bigint,
               'another department does not see it');
select test.eq((select count(*) from storage.objects where name = :'s1'::jsonb ->> 'path'), 0::bigint,
               'nor its image');
select test.logout();

-- Expired reservations are closed by maintenance.
select test.login('00000000-0000-0000-0000-000000000011');
select public.prepare_signature('task', '00000000-0000-0000-0000-0000000000c1', 'approve',
  '91000000-0000-0000-0000-000000000003') as s2 \gset
select test.logout();
update public.approval_signatures set upload_expires_at = now() - interval '1 minute' where id = (:'s2'::jsonb ->> 'id')::uuid;
select test.eq(private.expire_signature_reservations(), 1, 'one expired reservation closed');
select test.eq((select lifecycle from public.approval_signatures where id = (:'s2'::jsonb ->> 'id')::uuid), 'expired', 'marked expired');

-- unregister_device (D-36): sign-out stops pushes to this installation.
select test.login('00000000-0000-0000-0000-000000000012');
select public.register_device('91000000-0000-0000-0000-0000000000dd', repeat('ab', 32), 'production') as dev \gset
select test.eq(public.unregister_device('91000000-0000-0000-0000-0000000000dd'), 1, 'own device unregistered');
select test.eq(public.unregister_device('91000000-0000-0000-0000-0000000000dd'), 0, 'idempotent');
select test.logout();
select test.ok((select invalidated_at is not null from public.device_registrations
                where device_id = '91000000-0000-0000-0000-0000000000dd'), 'registration invalidated');
