-- Tasks, dependencies, task events, extension requests, achievements,
-- comments and meeting decisions.
-- Spec refs: §12, §13, §16, §24 (DB-14..DB-16, DB-22, DB-24).

-- ---------------------------------------------------------------------------
-- DB-14 tasks
-- ---------------------------------------------------------------------------
create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  department_id uuid not null,
  assignee_id uuid references public.profiles (user_id),
  creator_id uuid not null references public.profiles (user_id),
  parent_task_id uuid,
  linked_goal_id uuid,
  title text not null check (length(btrim(title)) between 3 and 200),
  description text not null default '' check (length(description) <= 8000),
  status text not null default 'draft'
    check (status in ('draft', 'assigned', 'acknowledged', 'in_progress', 'blocked', 'submitted', 'returned', 'completed', 'cancelled')),
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  start_at timestamptz,
  original_due_at timestamptz,
  due_at timestamptz,
  first_submitted_at timestamptz,
  last_submitted_at timestamptz,
  completed_at timestamptz,
  blocked_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (organization_id, id),
  foreign key (organization_id, department_id) references public.departments (organization_id, id),
  foreign key (organization_id, parent_task_id) references public.tasks (organization_id, id),
  foreign key (organization_id, linked_goal_id) references public.goals (organization_id, id),
  check (parent_task_id is null or parent_task_id <> id),
  -- §12: a non-draft task always has an assignee and a due date.
  check (status = 'draft' or (assignee_id is not null and due_at is not null and original_due_at is not null)),
  check (start_at is null or due_at is null or due_at > start_at),
  check (status <> 'completed' or completed_at is not null),
  check (status <> 'blocked' or length(btrim(coalesce(blocked_reason, ''))) >= 3),
  check (first_submitted_at is null or last_submitted_at >= first_submitted_at)
);
create index tasks_scope on public.tasks (organization_id, department_id, status, due_at);
create index tasks_assignee on public.tasks (assignee_id, status) where status not in ('completed', 'cancelled');
create trigger tasks_touch before update on public.tasks
  for each row execute function private.touch_versioned_row();

-- ---------------------------------------------------------------------------
-- DB-15 task_dependencies (acyclic) and task_events (history)
-- ---------------------------------------------------------------------------
create table public.task_dependencies (
  organization_id uuid not null,
  task_id uuid not null,
  depends_on_task_id uuid not null,
  created_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  primary key (task_id, depends_on_task_id),
  check (task_id <> depends_on_task_id),
  foreign key (organization_id, task_id) references public.tasks (organization_id, id),
  foreign key (organization_id, depends_on_task_id) references public.tasks (organization_id, id)
);

create or replace function private.task_dependencies_no_cycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    with recursive reach(id, depth) as (
      select d.depends_on_task_id, 1 from public.task_dependencies d where d.task_id = new.depends_on_task_id
      union all
      select d.depends_on_task_id, r.depth + 1
      from public.task_dependencies d join reach r on d.task_id = r.id
      where r.depth < 256
    )
    select 1 from reach where id = new.task_id
  ) then
    raise exception 'HC_VALIDATION_FAILED' using detail = '{"field":"depends_on_task_id","reason":"cycle"}';
  end if;
  return new;
end;
$$;
create trigger task_dependencies_no_cycle before insert or update on public.task_dependencies
  for each row execute function private.task_dependencies_no_cycle();

create table public.task_events (
  id bigint generated always as identity primary key,
  organization_id uuid not null,
  task_id uuid not null,
  actor_id uuid not null references public.profiles (user_id),
  event text not null,
  from_status text,
  to_status text,
  note text,
  previous_assignee_id uuid references public.profiles (user_id),
  previous_due_at timestamptz,
  request_id uuid,
  created_at timestamptz not null default now(),
  foreign key (organization_id, task_id) references public.tasks (organization_id, id)
);
create index task_events_task on public.task_events (task_id, created_at);
create trigger task_events_immutable before update or delete on public.task_events
  for each row execute function private.audit_immutable();

-- ---------------------------------------------------------------------------
-- DB-16 extension_requests (task or report; verified references)
-- ---------------------------------------------------------------------------
create table public.extension_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  task_id uuid,
  report_id uuid, -- FK added in reports migration
  requested_by uuid not null references public.profiles (user_id),
  current_due_at timestamptz not null,
  requested_due_at timestamptz not null,
  reason text not null check (length(btrim(reason)) >= 3),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'withdrawn')),
  decided_by uuid references public.profiles (user_id),
  decided_at timestamptz,
  decision_note text,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  check (num_nonnulls(task_id, report_id) = 1),
  check (requested_due_at > current_due_at),
  check ((status in ('approved', 'rejected')) = (decided_by is not null and decided_at is not null)),
  foreign key (organization_id, task_id) references public.tasks (organization_id, id)
);
create unique index extension_requests_one_pending_task on public.extension_requests (task_id) where status = 'pending';

-- ---------------------------------------------------------------------------
-- DB-22 achievements
-- ---------------------------------------------------------------------------
create table public.achievements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  department_id uuid not null,
  period_id uuid not null,
  title text not null check (length(btrim(title)) between 3 and 200),
  description text not null default '',
  impact_text text not null default '',
  beneficiary text,
  linked_goal_id uuid,
  linked_task_id uuid,
  linked_measurement_id uuid,
  status text not null default 'draft' check (status in ('draft', 'submitted', 'returned', 'approved', 'rejected', 'archived')),
  created_by uuid not null references public.profiles (user_id),
  submitted_at timestamptz,
  approved_by uuid references public.profiles (user_id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version int not null default 1,
  unique (organization_id, id),
  foreign key (organization_id, department_id) references public.departments (organization_id, id),
  foreign key (organization_id, period_id) references public.reporting_periods (organization_id, id),
  foreign key (organization_id, linked_goal_id) references public.goals (organization_id, id),
  foreign key (organization_id, linked_task_id) references public.tasks (organization_id, id),
  foreign key (organization_id, linked_measurement_id) references public.indicator_measurements (organization_id, id),
  check (status <> 'approved' or (approved_by is not null and approved_at is not null))
);
-- §16: the same task cannot be published as several achievements in one period.
create unique index achievements_one_per_task_period
  on public.achievements (linked_task_id, period_id)
  where linked_task_id is not null and status not in ('rejected', 'archived');
create trigger achievements_touch before update on public.achievements
  for each row execute function private.touch_versioned_row();

create table public.achievement_contributors (
  organization_id uuid not null,
  achievement_id uuid not null,
  department_id uuid not null,
  share_note text,
  primary key (achievement_id, department_id),
  foreign key (organization_id, achievement_id) references public.achievements (organization_id, id),
  foreign key (organization_id, department_id) references public.departments (organization_id, id)
);

-- ---------------------------------------------------------------------------
-- DB-24 comments (typed, verified targets) and decisions
-- ---------------------------------------------------------------------------
create table public.decisions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  subject text not null check (length(btrim(subject)) >= 3),
  summary text not null default '',
  decided_on date not null,
  decision_owner_id uuid not null references public.profiles (user_id),
  created_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);

create table public.decision_task_links (
  organization_id uuid not null,
  decision_id uuid not null,
  task_id uuid not null,
  primary key (decision_id, task_id),
  foreign key (organization_id, decision_id) references public.decisions (organization_id, id),
  foreign key (organization_id, task_id) references public.tasks (organization_id, id)
);

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  task_id uuid,
  report_id uuid,      -- FK added in reports migration
  achievement_id uuid,
  author_id uuid not null references public.profiles (user_id),
  body text not null check (length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now(),
  check (num_nonnulls(task_id, report_id, achievement_id) = 1),
  foreign key (organization_id, task_id) references public.tasks (organization_id, id),
  foreign key (organization_id, achievement_id) references public.achievements (organization_id, id)
);
create index comments_task on public.comments (task_id, created_at) where task_id is not null;
