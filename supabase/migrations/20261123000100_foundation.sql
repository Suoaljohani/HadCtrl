-- HadCtrl foundation: organizations, people, memberships, departments,
-- delegations, periods, preferences, audit and idempotency.
-- Spec refs: §03, §08, §15, §22, §23 (DB-01..DB-06, DB-13), §24 (DB-27..DB-29), §25.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Shared trigger helpers
-- ---------------------------------------------------------------------------
create or replace function private.touch_row()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.created_at := old.created_at;
  return new;
end;
$$;

-- For tables with an optimistic-concurrency "version" column.
create or replace function private.touch_versioned_row()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.created_at := old.created_at;
  new.version := old.version + 1;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- DB-01 organizations
-- ---------------------------------------------------------------------------
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null check (length(btrim(name_ar)) between 2 and 200),
  name_en text check (name_en is null or length(btrim(name_en)) between 2 and 200),
  timezone text not null default 'Asia/Riyadh',
  calendar_policy text not null default 'gregorian' check (calendar_policy in ('gregorian')),
  week_start smallint not null default 0 check (week_start between 0 and 6), -- 0 = Sunday
  is_demo boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1
);
create trigger organizations_touch before update on public.organizations
  for each row execute function private.touch_versioned_row();

-- ---------------------------------------------------------------------------
-- DB-02 profiles (no passwords; identity comes from auth.users)
-- ---------------------------------------------------------------------------
create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete restrict,
  display_name text not null check (length(btrim(display_name)) between 1 and 120),
  job_title text check (job_title is null or length(job_title) <= 120),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_row();

-- ---------------------------------------------------------------------------
-- DB-03 organization_memberships
-- ---------------------------------------------------------------------------
create table public.organization_memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  user_id uuid not null references public.profiles (user_id) on delete restrict,
  role text not null check (role in ('hospital_director', 'executive_viewer', 'system_admin', 'member')),
  active boolean not null default true,
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  granted_by uuid references public.profiles (user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from)
);
-- One active row per (org, user, role); multiple roles are separate visible rows.
create unique index organization_memberships_active_role
  on public.organization_memberships (organization_id, user_id, role) where active;
create index organization_memberships_user on public.organization_memberships (user_id) where active;
create trigger organization_memberships_touch before update on public.organization_memberships
  for each row execute function private.touch_row();

-- ---------------------------------------------------------------------------
-- DB-04 departments
-- ---------------------------------------------------------------------------
create table public.departments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  code text not null check (code ~ '^[A-Z0-9][A-Z0-9_-]{0,15}$'),
  name_ar text not null check (length(btrim(name_ar)) between 2 and 160),
  name_en text,
  category text not null check (category in ('medical', 'technical', 'administrative')),
  parent_department_id uuid,
  sort_order int not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (organization_id, id),
  unique (organization_id, code),
  check (parent_department_id is null or parent_department_id <> id),
  foreign key (organization_id, parent_department_id) references public.departments (organization_id, id)
);
create trigger departments_touch before update on public.departments
  for each row execute function private.touch_versioned_row();

create or replace function private.departments_no_cycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.parent_department_id is not null and exists (
    with recursive chain(id, depth) as (
      select d.parent_department_id, 1 from public.departments d where d.id = new.parent_department_id
      union all
      select d.parent_department_id, c.depth + 1
      from public.departments d join chain c on d.id = c.id
      where c.id is not null and c.depth < 64
    )
    select 1 from chain where id = new.id
  ) then
    raise exception 'HC_VALIDATION_FAILED' using detail = '{"field":"parent_department_id","reason":"cycle"}';
  end if;
  return new;
end;
$$;
create trigger departments_no_cycle before insert or update of parent_department_id on public.departments
  for each row execute function private.departments_no_cycle();

-- ---------------------------------------------------------------------------
-- DB-05 department_memberships
-- ---------------------------------------------------------------------------
create table public.department_memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  department_id uuid not null,
  user_id uuid not null references public.profiles (user_id) on delete restrict,
  role text not null check (role in ('department_head', 'department_coordinator')),
  is_primary boolean not null default false,
  active boolean not null default true,
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  granted_by uuid references public.profiles (user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  check (not is_primary or role = 'department_head'),
  foreign key (organization_id, department_id) references public.departments (organization_id, id)
);
create unique index department_memberships_active_role
  on public.department_memberships (department_id, user_id, role) where active;
-- Default assignment policy: exactly one active primary head per department.
create unique index department_memberships_one_primary_head
  on public.department_memberships (department_id) where active and is_primary;
create index department_memberships_user on public.department_memberships (user_id) where active;
create trigger department_memberships_touch before update on public.department_memberships
  for each row execute function private.touch_row();

-- ---------------------------------------------------------------------------
-- DB-29 delegations (explicit, time-boxed, server-side)
-- ---------------------------------------------------------------------------
create table public.delegations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  grantor_id uuid not null references public.profiles (user_id),
  grantee_id uuid not null references public.profiles (user_id),
  scope text not null check (scope in ('department', 'organization')),
  department_id uuid,
  operation text not null check (operation in ('review_reports', 'approve_reports', 'submit_reports', 'review_tasks')),
  valid_from timestamptz not null default now(),
  valid_to timestamptz not null,
  revoked_at timestamptz,
  reason text not null check (length(btrim(reason)) >= 3),
  created_at timestamptz not null default now(),
  check (valid_to > valid_from),
  check (grantor_id <> grantee_id),
  check ((scope = 'department') = (department_id is not null)),
  foreign key (organization_id, department_id) references public.departments (organization_id, id)
);
create index delegations_grantee on public.delegations (grantee_id) where revoked_at is null;

-- ---------------------------------------------------------------------------
-- DB-06 reporting_periods
-- ---------------------------------------------------------------------------
create table public.reporting_periods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  type text not null check (type in ('weekly', 'monthly', 'quarterly', 'annual')),
  start_date date not null,
  end_date date not null,
  timezone text not null default 'Asia/Riyadh',
  state text not null default 'planned' check (state in ('planned', 'open', 'review', 'frozen')),
  frozen_at timestamptz,
  frozen_by uuid references public.profiles (user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (organization_id, id),
  unique (organization_id, type, start_date),
  check (end_date >= start_date),
  check ((state = 'frozen') = (frozen_at is not null))
);
create trigger reporting_periods_touch before update on public.reporting_periods
  for each row execute function private.touch_versioned_row();

-- ---------------------------------------------------------------------------
-- DB-13 personal_preferences (user scope)
-- ---------------------------------------------------------------------------
create table public.personal_preferences (
  organization_id uuid not null references public.organizations (id),
  user_id uuid not null references public.profiles (user_id) default auth.uid(),
  pinned_departments uuid[] not null default '{}',
  dashboard_order text[] not null default '{}',
  locale text not null default 'ar' check (locale in ('ar', 'en')),
  number_style text not null default 'arabic_indic' check (number_style in ('arabic_indic', 'latin')),
  default_period_type text not null default 'monthly' check (default_period_type in ('weekly', 'monthly', 'quarterly', 'annual')),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id),
  check (cardinality(pinned_departments) <= 50)
);

-- ---------------------------------------------------------------------------
-- DB-27 audit_events (server-written only)
-- ---------------------------------------------------------------------------
create table public.audit_events (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations (id),
  department_id uuid,
  actor_id uuid references public.profiles (user_id),
  entity_type text not null,
  entity_id uuid not null,
  action text not null,
  before_summary jsonb,
  after_summary jsonb,
  reason text,
  request_id uuid,
  created_at timestamptz not null default now()
);
create index audit_events_entity on public.audit_events (entity_type, entity_id, created_at desc);
create index audit_events_org on public.audit_events (organization_id, created_at desc);

create or replace function private.audit_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'HC_FORBIDDEN' using detail = '{"reason":"audit_events are append-only"}';
end;
$$;
create trigger audit_events_immutable before update or delete on public.audit_events
  for each row execute function private.audit_immutable();

-- ---------------------------------------------------------------------------
-- DB-28 idempotency_requests
-- ---------------------------------------------------------------------------
create table public.idempotency_requests (
  actor_id uuid not null references public.profiles (user_id),
  operation text not null,
  request_id uuid not null,
  request_hash text not null,
  response jsonb,
  status text not null default 'pending' check (status in ('pending', 'completed')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  primary key (actor_id, operation, request_id)
);
create index idempotency_requests_expiry on public.idempotency_requests (expires_at);
