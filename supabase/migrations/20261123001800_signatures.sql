-- Handwritten approval signatures (D-37) and device unregistration (D-36).
--
-- A signature is a PNG drawn by the decider's finger, stored in a private
-- bucket and recorded immutably next to the decision it accompanies. Two steps,
-- like evidence attachments: prepare_signature authorizes the record and
-- reserves a server-made path; the client uploads exactly there (Storage INSERT
-- policy checks the reservation, uploader and expiry); finalize_signature checks
-- the stored object (PNG, 1 byte .. 512 KB) and seals the row with an audit event.
-- The decision itself is still made by the existing decide_* / transition RPCs,
-- which keep their own authorization; a signature never grants anything.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hadctrl-signatures', 'hadctrl-signatures', false, 512 * 1024, array['image/png'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.approval_signatures (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  department_id uuid,
  entity_type text not null check (entity_type in ('task', 'report', 'measurement', 'achievement', 'goal')),
  entity_id uuid not null,
  purpose text not null check (purpose in ('approve', 'activate', 'complete')),
  signer_id uuid not null references public.profiles (user_id),
  object_path text not null unique,
  lifecycle text not null default 'pending' check (lifecycle in ('pending', 'signed', 'expired')),
  upload_expires_at timestamptz not null,
  signed_at timestamptz,
  request_id uuid not null,
  created_at timestamptz not null default now(),
  unique (signer_id, request_id),
  check ((lifecycle = 'signed') = (signed_at is not null))
);
create index if not exists approval_signatures_entity on public.approval_signatures (entity_type, entity_id) where lifecycle = 'signed';

alter table public.approval_signatures enable row level security;
revoke all on public.approval_signatures from public, anon, authenticated;
grant select on public.approval_signatures to authenticated;

-- Who can see a record (and therefore its signatures).
create or replace function private.signature_target(p_type text, p_id uuid)
returns table (organization_id uuid, department_id uuid, readable boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_type = 'task' then
    return query select t.organization_id, t.department_id, private.can_read_task(t.id) from public.tasks t where t.id = p_id;
  elsif p_type = 'report' then
    return query select r.organization_id, r.department_id, private.can_read_report(r.id)
      from public.report_instances r where r.id = p_id;
  elsif p_type = 'achievement' then
    return query select a.organization_id, a.department_id, private.can_read_achievement(a.id)
      from public.achievements a where a.id = p_id;
  elsif p_type = 'goal' then
    return query select g.organization_id, g.department_id, private.can_view_department(g.organization_id, g.department_id)
      from public.goals g where g.id = p_id;
  elsif p_type = 'measurement' then
    return query select m.organization_id, m.department_id, private.can_view_department(m.organization_id, m.department_id)
      from public.indicator_measurements m where m.id = p_id;
  end if;
end;
$$;


-- Signatures are immutable once sealed; only pending -> signed / expired.
create or replace function private.signature_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'HC_IMMUTABLE' using errcode = 'P0001'; end if;
  if old.lifecycle <> 'pending'
     or new.id <> old.id or new.object_path <> old.object_path or new.signer_id <> old.signer_id
     or new.entity_type <> old.entity_type or new.entity_id <> old.entity_id or new.purpose <> old.purpose then
    raise exception 'HC_IMMUTABLE' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
drop trigger if exists approval_signatures_guard on public.approval_signatures;
create trigger approval_signatures_guard before update or delete on public.approval_signatures
  for each row execute function private.signature_guard();

create or replace function private.can_upload_signature(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.approval_signatures s
                 where s.object_path = p_name and s.signer_id = auth.uid() and s.lifecycle = 'pending'
                   and s.upload_expires_at > now())
$$;
create or replace function private.can_read_signature(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.approval_signatures s
                 where s.object_path = p_name
                   and (s.signer_id = auth.uid()
                        or (s.lifecycle = 'signed'
                            and exists (select 1 from private.signature_target(s.entity_type, s.entity_id) t where t.readable))))
$$;

drop policy if exists approval_signatures_select on public.approval_signatures;
create policy approval_signatures_select on public.approval_signatures for select to authenticated
  using (private.can_read_signature(object_path));

drop policy if exists hc_signatures_insert on storage.objects;
create policy hc_signatures_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'hadctrl-signatures' and private.can_upload_signature(name));
drop policy if exists hc_signatures_select on storage.objects;
create policy hc_signatures_select on storage.objects for select to authenticated
  using (bucket_id = 'hadctrl-signatures' and private.can_read_signature(name));

-- ---------------------------------------------------------------------------
-- prepare_signature: reserve a path for a record the caller can see.
-- ---------------------------------------------------------------------------
create or replace function public.prepare_signature(p_entity_type text, p_entity_id uuid, p_purpose text, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_t record;
  v_id uuid := gen_random_uuid();
  v_path text;
begin
  v_prior := private.idem_begin(v_actor, 'prepare_signature', p_request_id,
    jsonb_build_object('type', p_entity_type, 'id', p_entity_id, 'purpose', p_purpose));
  if v_prior is not null then return v_prior; end if;
  if p_entity_type not in ('task', 'report', 'measurement', 'achievement', 'goal')
     or p_purpose not in ('approve', 'activate', 'complete') then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"entity_type":"invalid"}}');
  end if;
  select * into v_t from private.signature_target(p_entity_type, p_entity_id);
  if v_t.organization_id is null or not coalesce(v_t.readable, false) then perform private.fail('HC_NOT_FOUND'); end if;
  if not private.is_org_member(v_t.organization_id) then perform private.fail('HC_FORBIDDEN'); end if;
  v_path := v_t.organization_id::text || '/' || p_entity_type || '/' || p_entity_id::text || '/' || v_id::text || '.png';
  insert into public.approval_signatures (id, organization_id, department_id, entity_type, entity_id, purpose,
                                          signer_id, object_path, upload_expires_at, request_id)
  values (v_id, v_t.organization_id, v_t.department_id, p_entity_type, p_entity_id, p_purpose,
          v_actor, v_path, now() + interval '15 minutes', p_request_id);
  return private.idem_finish(v_actor, 'prepare_signature', p_request_id,
    jsonb_build_object('id', v_id, 'bucket', 'hadctrl-signatures', 'path', v_path));
end;
$$;

-- ---------------------------------------------------------------------------
-- finalize_signature: verify the uploaded PNG and seal the signature.
-- ---------------------------------------------------------------------------
create or replace function public.finalize_signature(p_signature_id uuid, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_s public.approval_signatures;
  v_meta jsonb;
  v_size bigint;
begin
  v_prior := private.idem_begin(v_actor, 'finalize_signature', p_request_id, jsonb_build_object('id', p_signature_id));
  if v_prior is not null then return v_prior; end if;
  select * into v_s from public.approval_signatures where id = p_signature_id for update;
  if v_s.id is null or v_s.signer_id <> v_actor then perform private.fail('HC_NOT_FOUND'); end if;
  if v_s.lifecycle <> 'pending' then perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_pending"}'); end if;
  if v_s.upload_expires_at <= now() then perform private.fail('HC_ATTACHMENT_INCOMPLETE', '{"reason":"upload_expired"}'); end if;
  select o.metadata into v_meta from storage.objects o where o.bucket_id = 'hadctrl-signatures' and o.name = v_s.object_path;
  if not found then perform private.fail('HC_ATTACHMENT_INCOMPLETE', '{"reason":"object_missing"}'); end if;
  v_size := coalesce((v_meta ->> 'size')::bigint, -1);
  if v_size < 1 or v_size > 512 * 1024 or coalesce(v_meta ->> 'mimetype', '') <> 'image/png' then
    perform private.fail('HC_ATTACHMENT_INCOMPLETE', '{"reason":"size_or_type_mismatch"}');
  end if;
  update public.approval_signatures set lifecycle = 'signed', signed_at = now() where id = v_s.id returning * into v_s;
  perform private.audit(v_s.organization_id, v_s.department_id, v_actor, v_s.entity_type, v_s.entity_id,
    'signature_recorded', null, jsonb_build_object('signature_id', v_s.id, 'purpose', v_s.purpose), null, p_request_id);
  return private.idem_finish(v_actor, 'finalize_signature', p_request_id,
    jsonb_build_object('id', v_s.id, 'signed_at', v_s.signed_at, 'path', v_s.object_path));
end;
$$;

-- ---------------------------------------------------------------------------
-- unregister_device: sign-out stops pushes to this installation (D-36).
-- ---------------------------------------------------------------------------
create or replace function public.unregister_device(p_device_id uuid)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_n integer;
begin
  update public.device_registrations set invalidated_at = now()
   where user_id = v_actor and device_id = p_device_id and invalidated_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Expired reservations are closed by the nightly job (keeps the table honest).
create or replace function private.expire_signature_reservations()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  update public.approval_signatures set lifecycle = 'expired'
   where lifecycle = 'pending' and upload_expires_at <= now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function private.daily_maintenance()
returns void language plpgsql security definer set search_path = '' as $$
declare r record; v_period uuid;
begin
  for r in select id, timezone from public.organizations where active loop
    v_period := private.ensure_month_period(r.id, r.timezone);
    perform public.generate_report_instances(v_period);
  end loop;
  perform private.deadline_reminders();
  update public.attachments set lifecycle = 'failed' where lifecycle = 'pending' and upload_expires_at < now();
  perform private.expire_signature_reservations();
end;
$$;

-- Grants
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;
revoke execute on function private.signature_target(text, uuid), private.signature_guard(),
  private.expire_signature_reservations(), private.daily_maintenance() from authenticated;
-- Used by Storage and table RLS policies, which run as the caller.
grant execute on function private.can_upload_signature(text), private.can_read_signature(text) to authenticated;
grant execute on function
  public.prepare_signature(text, uuid, text, uuid),
  public.finalize_signature(uuid, uuid),
  public.unregister_device(uuid)
to authenticated;
