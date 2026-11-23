-- Recurring reports: templates, versions, schedules, instances, revisions, reviews.
-- Spec refs: §14, §15, §24 (DB-17..DB-21).

create table public.report_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  name_ar text not null check (length(btrim(name_ar)) between 3 and 200),
  frequency text not null check (frequency in ('weekly', 'monthly', 'quarterly', 'annual')),
  active boolean not null default true,
  current_version_id uuid,
  created_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (organization_id, id)
);
create trigger report_templates_touch before update on public.report_templates
  for each row execute function private.touch_versioned_row();

create table public.report_template_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  template_id uuid not null,
  revision int not null check (revision >= 1),
  schema_version int not null default 1,
  -- JSON-Schema-like definition of sections and required fields.
  field_schema jsonb not null check (jsonb_typeof(field_schema) = 'object'),
  required_fields text[] not null default '{}',
  allowed_attachment_types text[] not null default '{application/pdf,image/jpeg,image/png,image/heic}',
  review_plan text not null default 'director' check (review_plan in ('director', 'delegated_reviewer')),
  created_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  unique (template_id, revision),
  unique (organization_id, id),
  foreign key (organization_id, template_id) references public.report_templates (organization_id, id)
);
alter table public.report_templates
  add foreign key (organization_id, current_version_id) references public.report_template_versions (organization_id, id);

create table public.report_schedules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  template_version_id uuid not null,
  department_id uuid not null,
  recurrence text not null check (recurrence in ('weekly', 'monthly', 'quarterly', 'annual')),
  -- e.g. {"kind":"day_of_next_period","day":5,"local_time":"23:59"}
  due_rule jsonb not null check (jsonb_typeof(due_rule) = 'object' and due_rule ? 'kind'),
  active_from date not null,
  active_to date,
  created_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (template_version_id, department_id, recurrence, active_from),
  check (active_to is null or active_to >= active_from),
  foreign key (organization_id, template_version_id) references public.report_template_versions (organization_id, id),
  foreign key (organization_id, department_id) references public.departments (organization_id, id)
);

create table public.report_instances (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  department_id uuid not null,
  period_id uuid not null,
  schedule_id uuid not null,
  template_version_id uuid not null,
  due_at timestamptz not null,
  status text not null default 'not_submitted'
    check (status in ('not_submitted', 'submitted', 'under_review', 'returned', 'approved', 'waived')),
  first_submitted_at timestamptz,
  last_submitted_at timestamptz,
  latest_revision_id uuid,
  approved_revision_id uuid,
  review_claimed_by uuid references public.profiles (user_id),
  waiver_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (organization_id, id),
  -- §15/AC-018: one instance per schedule, department and period.
  unique (schedule_id, department_id, period_id),
  foreign key (organization_id, department_id) references public.departments (organization_id, id),
  foreign key (organization_id, period_id) references public.reporting_periods (organization_id, id),
  foreign key (organization_id, schedule_id) references public.report_schedules (organization_id, id),
  foreign key (organization_id, template_version_id) references public.report_template_versions (organization_id, id),
  check (status <> 'waived' or length(btrim(coalesce(waiver_reason, ''))) >= 3),
  check (status <> 'approved' or approved_revision_id is not null),
  check (status in ('not_submitted', 'waived') or first_submitted_at is not null)
);
create index report_instances_scope on public.report_instances (organization_id, department_id, period_id, status);
create trigger report_instances_touch before update on public.report_instances
  for each row execute function private.touch_versioned_row();

create table public.report_revisions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  report_id uuid not null,
  revision int not null check (revision >= 1),
  content jsonb not null default '{}'::jsonb check (jsonb_typeof(content) = 'object'),
  schema_version int not null default 1,
  state text not null default 'draft' check (state in ('draft', 'submitted', 'returned', 'approved', 'superseded')),
  author_id uuid not null references public.profiles (user_id),
  submitted_at timestamptz,
  submitted_by uuid references public.profiles (user_id),
  snapshot_data jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (report_id, revision),
  unique (organization_id, id),
  foreign key (organization_id, report_id) references public.report_instances (organization_id, id),
  check (state = 'draft' or (submitted_at is not null and submitted_by is not null))
);
create trigger report_revisions_touch before update on public.report_revisions
  for each row execute function private.touch_versioned_row();

-- A submitted revision's content is frozen (§14).
create or replace function private.report_revision_frozen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.state <> 'draft' and (new.content is distinct from old.content
      or new.submitted_at is distinct from old.submitted_at
      or new.submitted_by is distinct from old.submitted_by
      or new.report_id is distinct from old.report_id
      or new.revision is distinct from old.revision) then
    raise exception 'HC_FORBIDDEN' using detail = '{"reason":"submitted revision is immutable"}';
  end if;
  return new;
end;
$$;
create trigger report_revisions_frozen before update on public.report_revisions
  for each row execute function private.report_revision_frozen();

alter table public.report_instances
  add foreign key (organization_id, latest_revision_id) references public.report_revisions (organization_id, id),
  add foreign key (organization_id, approved_revision_id) references public.report_revisions (organization_id, id);

create table public.report_reviews (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  revision_id uuid not null,
  reviewer_id uuid not null references public.profiles (user_id),
  decision text not null check (decision in ('approved', 'returned')),
  note text,
  request_id uuid,
  decided_at timestamptz not null default now(),
  foreign key (organization_id, revision_id) references public.report_revisions (organization_id, id),
  check (decision <> 'returned' or length(btrim(coalesce(note, ''))) >= 3)
);
create unique index report_reviews_one_decision on public.report_reviews (revision_id);
create trigger report_reviews_immutable before update or delete on public.report_reviews
  for each row execute function private.audit_immutable();

-- Typed FKs deferred from the execution migration.
alter table public.extension_requests
  add foreign key (organization_id, report_id) references public.report_instances (organization_id, id);
create unique index extension_requests_one_pending_report on public.extension_requests (report_id) where status = 'pending';
alter table public.comments
  add foreign key (organization_id, report_id) references public.report_instances (organization_id, id);
