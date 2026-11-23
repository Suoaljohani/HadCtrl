-- Goals, indicators, versioned definitions, measurements, period snapshots.
-- Spec refs: §09, §10, §11, §15, §23 (DB-07..DB-12), §24 (DB-30).

-- ---------------------------------------------------------------------------
-- DB-07 goals
-- ---------------------------------------------------------------------------
create table public.goals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  department_id uuid not null,
  owner_id uuid not null references public.profiles (user_id),
  title text not null check (length(btrim(title)) between 3 and 200),
  description text not null default '',
  lifecycle text not null default 'draft'
    check (lifecycle in ('draft', 'active', 'completion_pending', 'completed', 'cancelled', 'archived')),
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  start_at timestamptz not null,
  due_at timestamptz not null,
  measurement_type text not null check (measurement_type in ('count', 'ratio', 'duration', 'milestones')),
  current_version_id uuid,
  cancel_reason text,
  created_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (organization_id, id),
  check (due_at > start_at),
  check (lifecycle <> 'cancelled' or length(btrim(coalesce(cancel_reason, ''))) >= 3),
  foreign key (organization_id, department_id) references public.departments (organization_id, id)
);
create index goals_scope on public.goals (organization_id, department_id, lifecycle);
create trigger goals_touch before update on public.goals
  for each row execute function private.touch_versioned_row();

-- ---------------------------------------------------------------------------
-- DB-08 goal_versions / goal_milestones
-- ---------------------------------------------------------------------------
create table public.goal_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  goal_id uuid not null,
  revision int not null check (revision >= 1),
  unit text not null,
  baseline numeric,
  target_value numeric,
  -- Time-phased plan: [{"at":"2026-11-30","expected":11}, ...]; linear only if approved.
  progress_plan jsonb not null default '[]'::jsonb check (jsonb_typeof(progress_plan) = 'array'),
  plan_is_linear boolean not null default false,
  change_reason text,
  approved_by uuid references public.profiles (user_id),
  approved_at timestamptz,
  created_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  unique (goal_id, revision),
  unique (organization_id, id),
  check (revision = 1 or length(btrim(coalesce(change_reason, ''))) >= 3),
  check ((approved_by is null) = (approved_at is null)),
  foreign key (organization_id, goal_id) references public.goals (organization_id, id)
);
alter table public.goals
  add foreign key (organization_id, current_version_id) references public.goal_versions (organization_id, id);

create table public.goal_milestones (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  goal_version_id uuid not null,
  ordinal int not null check (ordinal >= 1),
  title text not null,
  completion_criterion text not null check (length(btrim(completion_criterion)) >= 3),
  weight numeric not null check (weight > 0 and weight <= 100),
  completed_at timestamptz,
  approved_by uuid references public.profiles (user_id),
  unique (goal_version_id, ordinal),
  foreign key (organization_id, goal_version_id) references public.goal_versions (organization_id, id)
);

-- ---------------------------------------------------------------------------
-- DB-09 / DB-10 indicator definitions and versions
-- ---------------------------------------------------------------------------
create table public.indicator_definitions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  department_id uuid not null,
  code text not null check (code ~ '^[A-Z0-9][A-Z0-9_.-]{0,31}$'),
  title text not null check (length(btrim(title)) between 3 and 200),
  description text not null default '',
  active boolean not null default true,
  current_version_id uuid,
  created_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (organization_id, id),
  unique (organization_id, code),
  foreign key (organization_id, department_id) references public.departments (organization_id, id)
);
create trigger indicator_definitions_touch before update on public.indicator_definitions
  for each row execute function private.touch_versioned_row();

create table public.indicator_definition_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  definition_id uuid not null,
  revision int not null check (revision >= 1),
  measurement_type text not null check (measurement_type in ('ratio', 'count', 'duration', 'milestones')),
  unit text not null,
  direction text not null check (direction in ('higher_is_better', 'lower_is_better', 'within_range')),
  aggregation text not null check (aggregation in ('sum', 'weighted_mean', 'ratio_of_sums', 'latest')),
  frequency text not null check (frequency in ('weekly', 'monthly', 'quarterly', 'annual')),
  zero_event_rule boolean not null default false,
  numerator_description text,
  denominator_description text,
  data_source text not null check (length(btrim(data_source)) >= 2),
  baseline numeric,
  baseline_date date,
  target numeric,
  range_min numeric,
  range_max numeric,
  range_inclusive boolean not null default true,
  weight numeric not null default 1 check (weight > 0),
  valid_from date not null,
  approved_by uuid references public.profiles (user_id),
  approved_at timestamptz,
  created_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  unique (definition_id, revision),
  unique (definition_id, valid_from),
  unique (organization_id, id),
  foreign key (organization_id, definition_id) references public.indicator_definitions (organization_id, id),
  -- §11: within_range needs a sane range; other directions need a target.
  check (direction <> 'within_range' or (range_min is not null and range_max is not null and range_min <= range_max)),
  check (direction = 'within_range' or target is not null),
  -- §11: target = 0 for a higher-is-better indicator is rejected.
  check (not (direction = 'higher_is_better' and target is not null and target <= 0)),
  -- zero_event_rule only applies to lower-is-better event counts with target 0.
  check (not zero_event_rule or (direction = 'lower_is_better' and target = 0)),
  check (direction <> 'lower_is_better' or target > 0 or zero_event_rule),
  check (measurement_type <> 'ratio' or (numerator_description is not null and denominator_description is not null)),
  check (aggregation <> 'ratio_of_sums' or measurement_type = 'ratio'),
  check ((approved_by is null) = (approved_at is null))
);
alter table public.indicator_definitions
  add foreign key (organization_id, current_version_id) references public.indicator_definition_versions (organization_id, id);

-- ---------------------------------------------------------------------------
-- DB-11 indicator_measurements (append-only revisions per period)
-- ---------------------------------------------------------------------------
create table public.indicator_measurements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  department_id uuid not null,
  definition_version_id uuid not null,
  period_id uuid not null,
  revision int not null check (revision >= 1),
  value numeric,
  numerator numeric,
  denominator numeric,
  not_applicable_reason text,
  status text not null default 'draft' check (status in ('draft', 'submitted', 'returned', 'approved', 'superseded')),
  source_note text,
  entered_by uuid not null references public.profiles (user_id),
  submitted_at timestamptz,
  approved_at timestamptz,
  approved_by uuid references public.profiles (user_id),
  supersedes_id uuid references public.indicator_measurements (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (definition_version_id, period_id, revision),
  unique (organization_id, id),
  foreign key (organization_id, department_id) references public.departments (organization_id, id),
  foreign key (organization_id, definition_version_id) references public.indicator_definition_versions (organization_id, id),
  foreign key (organization_id, period_id) references public.reporting_periods (organization_id, id),
  check (denominator is null or denominator >= 0),
  check (numerator is null or numerator >= 0),
  check (not_applicable_reason is null or (value is null and numerator is null and denominator is null)),
  check (status <> 'approved' or (approved_at is not null and approved_by is not null))
);
-- At most one approved measurement per indicator version and period.
create unique index indicator_measurements_one_approved
  on public.indicator_measurements (definition_version_id, period_id) where status = 'approved';
create index indicator_measurements_scope
  on public.indicator_measurements (organization_id, department_id, period_id, status);
create trigger indicator_measurements_touch before update on public.indicator_measurements
  for each row execute function private.touch_versioned_row();

-- ---------------------------------------------------------------------------
-- DB-12 goal_indicator_links
-- ---------------------------------------------------------------------------
create table public.goal_indicator_links (
  organization_id uuid not null,
  goal_id uuid not null,
  indicator_definition_id uuid not null,
  relation_type text not null check (relation_type in ('measures_outcome', 'supports')),
  weight numeric check (weight is null or weight > 0),
  primary key (goal_id, indicator_definition_id),
  foreign key (organization_id, goal_id) references public.goals (organization_id, id),
  foreign key (organization_id, indicator_definition_id) references public.indicator_definitions (organization_id, id)
);

-- ---------------------------------------------------------------------------
-- DB-30 period_snapshots (immutable)
-- ---------------------------------------------------------------------------
create table public.period_snapshots (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  period_id uuid not null,
  policy_version text not null,
  snapshot_revision int not null check (snapshot_revision >= 1),
  generated_at timestamptz not null default now(),
  frozen_by uuid not null references public.profiles (user_id),
  data_hash text not null,
  payload jsonb not null,
  unique (period_id, snapshot_revision),
  foreign key (organization_id, period_id) references public.reporting_periods (organization_id, id)
);
create trigger period_snapshots_immutable before update or delete on public.period_snapshots
  for each row execute function private.audit_immutable();
