-- In-app administration: departments and employee accounts (spec §03, §08, §22).
--
-- Who:   hospital_director and system_admin of the organization (D-25).
-- How:   * create_department — RPC, authorized here.
--        * employees — two steps so the admin key never reaches the app:
--          1. prepare_employee (called WITH THE ADMIN'S OWN TOKEN) checks
--             authorization and escalation rules and records a pending
--             provisioning row;
--          2. the create-employee Edge Function (server only) creates the Auth
--             user with a temporary password, then calls complete_employee
--             (service role only) to attach profile + memberships atomically.
--        * The employee must change the temporary password at first sign-in.
-- Never: grant hospital_director from the app; let a system_admin create
--        another system_admin; trust client-sent roles for the caller.

alter table public.profiles add column if not exists must_change_password boolean not null default false;

create table public.account_provisioning (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  display_name text not null check (length(btrim(display_name)) between 2 and 120),
  job_title text check (job_title is null or length(job_title) <= 120),
  org_role text not null default 'member' check (org_role in ('member', 'executive_viewer', 'system_admin')),
  department_id uuid,
  department_role text check (department_role in ('department_head', 'department_coordinator')),
  is_primary boolean not null default false,
  requested_by uuid not null references public.profiles (user_id),
  request_id uuid not null,
  status text not null default 'pending' check (status in ('pending', 'completed', 'failed')),
  user_id uuid references auth.users (id),
  account_created boolean,
  failure_code text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  foreign key (organization_id, department_id) references public.departments (organization_id, id),
  check ((department_id is null) = (department_role is null)),
  check (not is_primary or department_role = 'department_head'),
  check ((status = 'completed') = (user_id is not null and completed_at is not null))
);
create index account_provisioning_pending on public.account_provisioning (created_at) where status = 'pending';
-- Server-only table: RLS on, no policies, no client grants.
alter table public.account_provisioning enable row level security;
revoke all on public.account_provisioning from anon, authenticated;

create or replace function private.can_manage_org(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.has_org_role(p_org, array['hospital_director', 'system_admin'])
$$;

-- ---------------------------------------------------------------------------
-- create_department
-- ---------------------------------------------------------------------------
create or replace function public.create_department(
  p_organization_id uuid, p_code text, p_name_ar text, p_category text, p_request_id uuid,
  p_name_en text default null, p_sort_order int default 0)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_errors jsonb := '{}'::jsonb;
  v_d public.departments;
begin
  v_prior := private.idem_begin(v_actor, 'create_department', p_request_id, jsonb_build_object(
    'org', p_organization_id, 'code', p_code, 'name_ar', p_name_ar, 'category', p_category,
    'name_en', p_name_en, 'sort', p_sort_order));
  if v_prior is not null then return v_prior; end if;

  if not private.is_org_member(p_organization_id) then perform private.fail('HC_NOT_FOUND'); end if;
  if not private.can_manage_org(p_organization_id) then perform private.fail('HC_FORBIDDEN'); end if;

  if v_code !~ '^[A-Z0-9][A-Z0-9_-]{0,15}$' then v_errors := v_errors || '{"code":"invalid_format"}';
  elsif exists (select 1 from public.departments d where d.organization_id = p_organization_id and d.code = v_code) then
    v_errors := v_errors || '{"code":"already_used"}';
  end if;
  if p_name_ar is null or length(btrim(p_name_ar)) < 2 then v_errors := v_errors || '{"name_ar":"too_short"}'; end if;
  if p_category not in ('medical', 'technical', 'administrative') then v_errors := v_errors || '{"category":"invalid"}'; end if;
  if v_errors <> '{}'::jsonb then
    perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  insert into public.departments (organization_id, code, name_ar, name_en, category, sort_order)
  values (p_organization_id, v_code, btrim(p_name_ar), nullif(btrim(coalesce(p_name_en, '')), ''), p_category, coalesce(p_sort_order, 0))
  returning * into v_d;
  perform private.audit(v_d.organization_id, v_d.id, v_actor, 'department', v_d.id, 'create', null,
                        jsonb_build_object('code', v_d.code, 'name_ar', v_d.name_ar, 'category', v_d.category), null, p_request_id);
  return private.idem_finish(v_actor, 'create_department', p_request_id,
    jsonb_build_object('department_id', v_d.id, 'code', v_d.code, 'name_ar', v_d.name_ar, 'category', v_d.category, 'version', v_d.version));
end;
$$;

-- ---------------------------------------------------------------------------
-- prepare_employee — runs as the admin (their JWT); all authorization here.
-- ---------------------------------------------------------------------------
create or replace function public.prepare_employee(
  p_organization_id uuid, p_email text, p_display_name text, p_request_id uuid,
  p_job_title text default null, p_org_role text default 'member',
  p_department_id uuid default null, p_department_role text default null, p_is_primary boolean default false)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_role text := coalesce(p_org_role, 'member');
  v_errors jsonb := '{}'::jsonb;
  v_dept public.departments;
  v_id uuid;
begin
  v_prior := private.idem_begin(v_actor, 'prepare_employee', p_request_id, jsonb_build_object(
    'org', p_organization_id, 'email', v_email, 'name', p_display_name, 'title', p_job_title, 'role', v_role,
    'dept', p_department_id, 'dept_role', p_department_role, 'primary', p_is_primary));
  if v_prior is not null then return v_prior; end if;

  if not private.is_org_member(p_organization_id) then perform private.fail('HC_NOT_FOUND'); end if;
  if not private.can_manage_org(p_organization_id) then perform private.fail('HC_FORBIDDEN'); end if;

  -- Escalation rules (§22): never director from the app; only a director may create a system admin.
  if v_role = 'hospital_director' then
    perform private.fail('HC_FORBIDDEN', '{"reason":"director_role_is_bootstrap_only"}');
  end if;
  if v_role = 'system_admin' and not private.has_org_role(p_organization_id, array['hospital_director']) then
    perform private.fail('HC_FORBIDDEN', '{"reason":"only_director_grants_system_admin"}');
  end if;
  if v_role not in ('member', 'executive_viewer', 'system_admin') then v_errors := v_errors || '{"org_role":"invalid"}'; end if;

  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then v_errors := v_errors || '{"email":"invalid"}'; end if;
  if p_display_name is null or length(btrim(p_display_name)) < 2 then v_errors := v_errors || '{"display_name":"too_short"}'; end if;

  if p_department_id is not null then
    select * into v_dept from public.departments d where d.id = p_department_id and d.organization_id = p_organization_id;
    if v_dept.id is null then v_errors := v_errors || '{"department_id":"not_found"}';
    elsif v_dept.archived_at is not null then v_errors := v_errors || '{"department_id":"archived"}';
    end if;
    if p_department_role not in ('department_head', 'department_coordinator') or p_department_role is null then
      v_errors := v_errors || '{"department_role":"required"}';
    end if;
    if coalesce(p_is_primary, false) and p_department_role = 'department_head' and exists (
        select 1 from public.department_memberships m where m.department_id = p_department_id and m.active and m.is_primary) then
      v_errors := v_errors || '{"is_primary":"department_already_has_primary_head"}';
    end if;
  elsif p_department_role is not null then
    v_errors := v_errors || '{"department_id":"required"}';
  end if;
  if coalesce(p_is_primary, false) and p_department_role is distinct from 'department_head' then
    v_errors := v_errors || '{"is_primary":"only_for_head"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  insert into public.account_provisioning (organization_id, email, display_name, job_title, org_role,
    department_id, department_role, is_primary, requested_by, request_id)
  values (p_organization_id, v_email, btrim(p_display_name), nullif(btrim(coalesce(p_job_title, '')), ''), v_role,
    p_department_id, p_department_role, coalesce(p_is_primary, false), v_actor, p_request_id)
  returning id into v_id;
  perform private.audit(p_organization_id, p_department_id, v_actor, 'account_provisioning', v_id, 'prepare', null,
    jsonb_build_object('org_role', v_role, 'department_role', p_department_role), null, p_request_id);
  return private.idem_finish(v_actor, 'prepare_employee', p_request_id,
    jsonb_build_object('provisioning_id', v_id, 'status', 'pending'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Service-only helpers for the Edge Function (never granted to clients).
-- ---------------------------------------------------------------------------
create or replace function public.provisioning_status(p_provisioning_id uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object('provisioning_id', p.id, 'status', p.status, 'email', p.email, 'user_id', p.user_id,
                            'account_created', p.account_created, 'requested_by', p.requested_by)
  from public.account_provisioning p where p.id = p_provisioning_id
$$;

create or replace function public.find_auth_user_id(p_email text)
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select u.id from auth.users u where lower(u.email) = lower(btrim(p_email)) limit 1
$$;

create or replace function public.complete_employee(p_provisioning_id uuid, p_user_id uuid, p_account_created boolean)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_p public.account_provisioning;
begin
  select * into v_p from public.account_provisioning where id = p_provisioning_id for update;
  if v_p.id is null then perform private.fail('HC_NOT_FOUND'); end if;
  if v_p.status = 'completed' then
    return jsonb_build_object('provisioning_id', v_p.id, 'status', v_p.status, 'user_id', v_p.user_id, 'replayed', true);
  end if;
  if v_p.status <> 'pending' then perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_pending"}'); end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id and lower(u.email) = v_p.email) then
    perform private.fail('HC_VALIDATION_FAILED', '{"user_id":"email_mismatch"}');
  end if;

  insert into public.profiles (user_id, display_name, job_title, active, must_change_password)
  values (p_user_id, v_p.display_name, v_p.job_title, true, coalesce(p_account_created, false))
  on conflict (user_id) do update
    set must_change_password = public.profiles.must_change_password or coalesce(p_account_created, false);

  -- Every employee is a member of the organization; extra org role if requested.
  if not exists (select 1 from public.organization_memberships m
                 where m.organization_id = v_p.organization_id and m.user_id = p_user_id and m.role = 'member' and m.active) then
    insert into public.organization_memberships (organization_id, user_id, role, granted_by)
    values (v_p.organization_id, p_user_id, 'member', v_p.requested_by);
  end if;
  if v_p.org_role <> 'member' and not exists (select 1 from public.organization_memberships m
      where m.organization_id = v_p.organization_id and m.user_id = p_user_id and m.role = v_p.org_role and m.active) then
    insert into public.organization_memberships (organization_id, user_id, role, granted_by)
    values (v_p.organization_id, p_user_id, v_p.org_role, v_p.requested_by);
  end if;
  if v_p.department_id is not null and not exists (select 1 from public.department_memberships m
      where m.department_id = v_p.department_id and m.user_id = p_user_id and m.role = v_p.department_role and m.active) then
    -- The unique index rejects a second primary head created concurrently.
    insert into public.department_memberships (organization_id, department_id, user_id, role, is_primary, granted_by)
    values (v_p.organization_id, v_p.department_id, p_user_id, v_p.department_role, v_p.is_primary, v_p.requested_by);
  end if;

  update public.account_provisioning
     set status = 'completed', user_id = p_user_id, account_created = p_account_created, completed_at = now()
   where id = v_p.id;
  perform private.audit(v_p.organization_id, v_p.department_id, v_p.requested_by, 'profile', p_user_id,
    case when p_account_created then 'create_account' else 'attach_existing_account' end, null,
    jsonb_build_object('org_role', v_p.org_role, 'department_id', v_p.department_id, 'department_role', v_p.department_role),
    null, v_p.request_id);
  return jsonb_build_object('provisioning_id', v_p.id, 'status', 'completed', 'user_id', p_user_id, 'replayed', false);
end;
$$;

create or replace function public.fail_provisioning(p_provisioning_id uuid, p_code text)
returns void
language sql security definer
set search_path = ''
as $$
  update public.account_provisioning set status = 'failed', failure_code = left(p_code, 64)
   where id = p_provisioning_id and status = 'pending';
$$;

-- ---------------------------------------------------------------------------
-- Password change acknowledgement (the app calls it after auth.update succeeds).
-- ---------------------------------------------------------------------------
create or replace function public.mark_password_changed()
returns void
language plpgsql security definer
set search_path = ''
as $$
declare v_actor uuid := private.require_actor();
begin
  update public.profiles set must_change_password = false where user_id = v_actor;
end;
$$;

-- ---------------------------------------------------------------------------
-- People in the organization, for the admin screen.
-- ---------------------------------------------------------------------------
create or replace function public.list_people(p_organization_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare v_actor uuid := private.require_actor();
begin
  if not private.is_org_member(p_organization_id) then perform private.fail('HC_NOT_FOUND'); end if;
  if not private.can_manage_org(p_organization_id) then perform private.fail('HC_FORBIDDEN'); end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', p.user_id, 'display_name', p.display_name, 'job_title', p.job_title, 'active', p.active,
      'must_change_password', p.must_change_password,
      'org_roles', coalesce((select jsonb_agg(distinct om.role) from public.organization_memberships om
                             where om.user_id = p.user_id and om.organization_id = p_organization_id and om.active), '[]'::jsonb),
      'departments', coalesce((select jsonb_agg(jsonb_build_object('department_id', d.id, 'name_ar', d.name_ar, 'code', d.code,
                                                                   'role', dm.role, 'is_primary', dm.is_primary) order by d.name_ar)
                               from public.department_memberships dm join public.departments d on d.id = dm.department_id
                               where dm.user_id = p.user_id and dm.organization_id = p_organization_id and dm.active), '[]'::jsonb))
      order by p.display_name)
    from public.profiles p
    where exists (select 1 from public.organization_memberships om where om.user_id = p.user_id and om.organization_id = p_organization_id)
       or exists (select 1 from public.department_memberships dm where dm.user_id = p.user_id and dm.organization_id = p_organization_id)
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- my_context: add must_change_password and a manage flag (body otherwise unchanged).
-- ---------------------------------------------------------------------------
create or replace function public.my_context()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
begin
  return jsonb_build_object(
    'user_id', v_actor,
    'profile', (select jsonb_build_object('display_name', p.display_name, 'job_title', p.job_title,
                                          'must_change_password', p.must_change_password)
                from public.profiles p where p.user_id = v_actor),
    'organizations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'organization_id', o.id, 'name_ar', o.name_ar, 'name_en', o.name_en, 'timezone', o.timezone,
        'is_demo', o.is_demo, 'roles', to_jsonb(private.org_roles(o.id)),
        'departments', coalesce((
          select jsonb_agg(jsonb_build_object('department_id', d.id, 'name_ar', d.name_ar, 'code', d.code,
                                              'roles', to_jsonb(private.dept_roles(d.id))) order by d.sort_order, d.name_ar)
          from public.departments d
          where d.organization_id = o.id and d.archived_at is null and private.is_department_member(d.id)), '[]'::jsonb))
        order by o.name_ar)
      from public.organizations o
      where private.is_org_member(o.id)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants (explicit; see 001100 lockdown)
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon;
grant execute on function private.can_manage_org(uuid) to authenticated;
grant execute on function
  public.create_task(uuid, text, uuid, uuid, timestamptz, date, text, text, timestamptz, uuid, uuid, boolean),
  public.transition_task(uuid, int, text, uuid, text, uuid),
  public.request_task_extension(uuid, timestamptz, text, uuid),
  public.decide_task_extension(uuid, text, uuid, text),
  public.mark_notification_read(uuid),
  public.register_device(uuid, text, text),
  public.my_context(),
  public.save_report_draft(uuid, jsonb, uuid, int),
  public.submit_report(uuid, uuid, int, uuid),
  public.decide_report(uuid, uuid, text, int, uuid, text),
  public.waive_report(uuid, text, int, uuid),
  public.report_compliance(uuid),
  public.submit_measurement(uuid, uuid, uuid, numeric, numeric, numeric, text, text, text),
  public.decide_measurement(uuid, text, int, uuid, text),
  public.freeze_period(uuid, int, text, uuid),
  public.dashboard_snapshot(uuid),
  public.create_department(uuid, text, text, text, uuid, text, int),
  public.prepare_employee(uuid, text, text, uuid, text, text, uuid, text, boolean),
  public.mark_password_changed(),
  public.list_people(uuid)
to authenticated;
-- Edge Function (secret key → service_role) only:
grant execute on function
  public.provisioning_status(uuid), public.find_auth_user_id(text),
  public.complete_employee(uuid, uuid, boolean), public.fail_provisioning(uuid, text)
to service_role;
