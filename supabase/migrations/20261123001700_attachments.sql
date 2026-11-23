-- Evidence attachments (spec §26, API-11). Private bucket; a two-step upload:
-- prepare_attachment authorizes the target record and reserves a server-made
-- path; the client uploads to exactly that path (Storage INSERT policy checks
-- the reservation, the uploader and its expiry); finalize_attachment verifies
-- the stored object's size and type and links it. Reads use short signed URLs
-- that Storage issues only if the SELECT policy (record visibility) allows.

alter table public.attachments add column if not exists target_type text
  check (target_type is null or target_type in ('task', 'report_revision', 'achievement'));
alter table public.attachments add column if not exists target_id uuid;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hadctrl-evidence', 'hadctrl-evidence', false, 20 * 1024 * 1024,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'text/csv',
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Target checks: who may attach evidence to which record, and while it is editable.
create or replace function private.attachment_target(p_type text, p_id uuid)
returns table (organization_id uuid, department_id uuid, readable boolean, writable boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_type = 'task' then
    return query select t.organization_id, t.department_id, private.can_read_task(t.id),
      private.can_read_task(t.id) and t.status not in ('completed', 'cancelled', 'draft')
      and (t.assignee_id = auth.uid() or private.is_department_member(t.department_id))
      from public.tasks t where t.id = p_id;
  elsif p_type = 'achievement' then
    return query select a.organization_id, a.department_id, private.can_read_achievement(a.id),
      private.is_department_member(a.department_id) and a.status in ('draft', 'returned')
      from public.achievements a where a.id = p_id;
  elsif p_type = 'report_revision' then
    return query select r.organization_id, r.department_id, private.can_read_report(r.id),
      private.can_draft_report(r.organization_id, r.department_id) and v.state = 'draft'
      and r.status in ('not_submitted', 'returned')
      from public.report_revisions v join public.report_instances r on r.id = v.report_id where v.id = p_id;
  end if;
end;
$$;

-- Storage policies use these (they run as the caller).
create or replace function private.can_upload_object(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.attachments a
                 where a.object_path = p_name and a.uploader_id = auth.uid() and a.lifecycle = 'pending'
                   and a.upload_expires_at > now())
$$;
create or replace function private.can_read_object(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.attachments a
                 where a.object_path = p_name
                   and ((a.lifecycle = 'ready' and private.can_read_attachment(a.id))
                        or (a.lifecycle = 'pending' and a.uploader_id = auth.uid())))
$$;

drop policy if exists hc_evidence_insert on storage.objects;
create policy hc_evidence_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'hadctrl-evidence' and private.can_upload_object(name));
drop policy if exists hc_evidence_select on storage.objects;
create policy hc_evidence_select on storage.objects for select to authenticated
  using (bucket_id = 'hadctrl-evidence' and private.can_read_object(name));
-- No UPDATE or DELETE policy: clients can neither overwrite nor remove evidence.

-- ---------------------------------------------------------------------------
-- API-11 prepare_attachment
-- ---------------------------------------------------------------------------
create or replace function public.prepare_attachment(
  p_target_type text, p_target_id uuid, p_display_name text, p_mime_type text, p_size_bytes bigint, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_t record;
  v_id uuid := gen_random_uuid();
  v_a public.attachments;
  v_count int;
begin
  v_prior := private.idem_begin(v_actor, 'prepare_attachment', p_request_id, jsonb_build_object(
    'type', p_target_type, 'id', p_target_id, 'name', p_display_name, 'mime', p_mime_type, 'size', p_size_bytes));
  if v_prior is not null then return v_prior; end if;
  if p_target_type not in ('task', 'report_revision', 'achievement') then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"target_type":"invalid"}}');
  end if;
  select * into v_t from private.attachment_target(p_target_type, p_target_id);
  -- Unknown and invisible records look the same (HC-120).
  if v_t.organization_id is null or not coalesce(v_t.readable, false) then perform private.fail('HC_NOT_FOUND'); end if;
  if not v_t.writable then perform private.fail('HC_FORBIDDEN', '{"reason":"record_not_editable_by_you"}'); end if;
  -- §26 limits: 10 files per record, counting reservations still in flight.
  select count(*) into v_count from public.attachments a
   where a.target_type = p_target_type and a.target_id = p_target_id and a.lifecycle in ('pending', 'ready');
  if v_count >= 10 then perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"attachments":"max_10_per_record"}}'); end if;
  begin
    insert into public.attachments (id, organization_id, department_id, object_path, display_name, mime_type, size_bytes,
      uploader_id, target_type, target_id)
    values (v_id, v_t.organization_id, v_t.department_id,
      v_t.organization_id || '/' || v_t.department_id || '/' || v_id, btrim(p_display_name), p_mime_type, p_size_bytes,
      v_actor, p_target_type, p_target_id)
    returning * into v_a;
  exception when check_violation then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"file":"type_size_or_name_not_allowed"}}');
  end;
  perform private.audit(v_a.organization_id, v_a.department_id, v_actor, 'attachment', v_a.id, 'prepare', null,
    jsonb_build_object('target_type', p_target_type, 'target_id', p_target_id, 'size', p_size_bytes, 'mime', p_mime_type),
    null, p_request_id);
  return private.idem_finish(v_actor, 'prepare_attachment', p_request_id, jsonb_build_object(
    'attachment_id', v_a.id, 'bucket', v_a.bucket, 'object_path', v_a.object_path, 'upload_expires_at', v_a.upload_expires_at));
end;
$$;

-- ---------------------------------------------------------------------------
-- API-11 finalize_attachment: the object must exist with the declared size/type.
-- ---------------------------------------------------------------------------
create or replace function public.finalize_attachment(p_attachment_id uuid, p_checksum_sha256 text, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_a public.attachments;
  v_o record;
  v_t record;
begin
  v_prior := private.idem_begin(v_actor, 'finalize_attachment', p_request_id,
    jsonb_build_object('id', p_attachment_id, 'sha', p_checksum_sha256));
  if v_prior is not null then return v_prior; end if;
  select * into v_a from public.attachments where id = p_attachment_id for update;
  if v_a.id is null or v_a.uploader_id <> v_actor then perform private.fail('HC_NOT_FOUND'); end if;
  if v_a.lifecycle <> 'pending' then perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_pending"}'); end if;
  -- Expired reservations are marked failed by the nightly job.
  if v_a.upload_expires_at <= now() then
    perform private.fail('HC_ATTACHMENT_INCOMPLETE', '{"reason":"upload_expired"}');
  end if;
  if p_checksum_sha256 is null or p_checksum_sha256 !~ '^[0-9a-f]{64}$' then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"checksum_sha256":"invalid"}}');
  end if;
  select o.metadata into v_o from storage.objects o where o.bucket_id = v_a.bucket and o.name = v_a.object_path;
  if not found then perform private.fail('HC_ATTACHMENT_INCOMPLETE', '{"reason":"object_missing"}'); end if;
  if coalesce((v_o.metadata ->> 'size')::bigint, -1) <> v_a.size_bytes
     or coalesce(v_o.metadata ->> 'mimetype', '') <> v_a.mime_type then
    perform private.fail('HC_ATTACHMENT_INCOMPLETE', '{"reason":"size_or_type_mismatch"}');
  end if;
  -- The record may have changed since prepare (e.g. submitted): re-check.
  select * into v_t from private.attachment_target(v_a.target_type, v_a.target_id);
  if not coalesce(v_t.writable, false) then perform private.fail('HC_FORBIDDEN', '{"reason":"record_not_editable_by_you"}'); end if;

  update public.attachments set lifecycle = 'ready', finalized_at = now(), checksum_sha256 = p_checksum_sha256
   where id = v_a.id returning * into v_a;
  insert into public.attachment_links (organization_id, attachment_id, task_id, report_revision_id, achievement_id, linked_by)
  values (v_a.organization_id, v_a.id,
    case when v_a.target_type = 'task' then v_a.target_id end,
    case when v_a.target_type = 'report_revision' then v_a.target_id end,
    case when v_a.target_type = 'achievement' then v_a.target_id end, v_actor);
  perform private.audit(v_a.organization_id, v_a.department_id, v_actor, 'attachment', v_a.id, 'finalize', null,
    jsonb_build_object('target_type', v_a.target_type, 'target_id', v_a.target_id, 'sha256', p_checksum_sha256), null, p_request_id);
  return private.idem_finish(v_actor, 'finalize_attachment', p_request_id,
    jsonb_build_object('attachment_id', v_a.id, 'lifecycle', v_a.lifecycle));
end;
$$;

-- ---------------------------------------------------------------------------
-- remove_attachment: only while the record is still editable (§26: evidence of an
-- approved or submitted record is never removed from the app). The stored object
-- stays for the server's retention job; the row is marked deleted, not erased.
-- ---------------------------------------------------------------------------
create or replace function public.remove_attachment(p_attachment_id uuid, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_a public.attachments;
  v_t record;
begin
  v_prior := private.idem_begin(v_actor, 'remove_attachment', p_request_id, jsonb_build_object('id', p_attachment_id));
  if v_prior is not null then return v_prior; end if;
  select * into v_a from public.attachments where id = p_attachment_id for update;
  if v_a.id is null or not private.can_read_attachment(v_a.id) then perform private.fail('HC_NOT_FOUND'); end if;
  select * into v_t from private.attachment_target(v_a.target_type, v_a.target_id);
  if not coalesce(v_t.writable, false) then perform private.fail('HC_FORBIDDEN', '{"reason":"record_not_editable_by_you"}'); end if;
  if v_a.uploader_id <> v_actor and not ('department_head' = any (private.dept_roles(v_a.department_id))) then
    perform private.fail('HC_FORBIDDEN');
  end if;
  delete from public.attachment_links where attachment_id = v_a.id;
  update public.attachments set lifecycle = 'deleted' where id = v_a.id returning * into v_a;
  perform private.audit(v_a.organization_id, v_a.department_id, v_actor, 'attachment', v_a.id, 'remove', null, null, null, p_request_id);
  return private.idem_finish(v_actor, 'remove_attachment', p_request_id,
    jsonb_build_object('attachment_id', v_a.id, 'lifecycle', v_a.lifecycle));
end;
$$;

-- Nightly: reservations that were never finished become failed (never linked).
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
end;
$$;

-- Grants
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;
revoke execute on function private.attachment_target(text, uuid), private.daily_maintenance() from authenticated;
-- Used by Storage RLS policies, which run as the caller.
grant execute on function private.can_upload_object(text), private.can_read_object(text) to authenticated;
grant execute on function
  public.prepare_attachment(text, uuid, text, text, bigint, uuid),
  public.finalize_attachment(uuid, text, uuid),
  public.remove_attachment(uuid, uuid)
to authenticated;
