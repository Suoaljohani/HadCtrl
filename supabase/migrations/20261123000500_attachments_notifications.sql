-- Evidence attachments, in-app notifications, device registrations and outbox.
-- Spec refs: §16, §18, §26, §24 (DB-23, DB-25, DB-26).

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  department_id uuid not null,
  bucket text not null default 'hadctrl-evidence' check (bucket = 'hadctrl-evidence'),
  -- Server-generated: <org>/<dept>/<attachment id>; never derived from user text.
  object_path text not null unique,
  display_name text not null check (length(display_name) between 1 and 200 and display_name !~ '[/\\[:cntrl:]]'),
  mime_type text not null check (mime_type in (
    'application/pdf', 'image/jpeg', 'image/png', 'image/heic',
    'text/csv', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 20 * 1024 * 1024),
  checksum_sha256 text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9a-f]{64}$'),
  lifecycle text not null default 'pending' check (lifecycle in ('pending', 'ready', 'failed', 'quarantined', 'deleted')),
  uploader_id uuid not null references public.profiles (user_id),
  upload_expires_at timestamptz not null default now() + interval '1 hour',
  finalized_at timestamptz,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, department_id) references public.departments (organization_id, id),
  check (lifecycle <> 'ready' or (finalized_at is not null and checksum_sha256 is not null))
);
create index attachments_pending on public.attachments (upload_expires_at) where lifecycle = 'pending';

-- Typed links: exactly one verified target per row.
create table public.attachment_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  attachment_id uuid not null,
  task_id uuid,
  report_revision_id uuid,
  achievement_id uuid,
  measurement_id uuid,
  is_required_evidence boolean not null default false,
  linked_by uuid not null references public.profiles (user_id),
  created_at timestamptz not null default now(),
  check (num_nonnulls(task_id, report_revision_id, achievement_id, measurement_id) = 1),
  foreign key (organization_id, attachment_id) references public.attachments (organization_id, id),
  foreign key (organization_id, task_id) references public.tasks (organization_id, id),
  foreign key (organization_id, report_revision_id) references public.report_revisions (organization_id, id),
  foreign key (organization_id, achievement_id) references public.achievements (organization_id, id),
  foreign key (organization_id, measurement_id) references public.indicator_measurements (organization_id, id)
);
create index attachment_links_attachment on public.attachment_links (attachment_id);
-- §16: max 10 files per record.
create or replace function private.attachment_links_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  n int;
begin
  select count(*) into n from public.attachment_links l
  where (new.task_id is not null and l.task_id = new.task_id)
     or (new.report_revision_id is not null and l.report_revision_id = new.report_revision_id)
     or (new.achievement_id is not null and l.achievement_id = new.achievement_id)
     or (new.measurement_id is not null and l.measurement_id = new.measurement_id);
  if n >= 10 then
    raise exception 'HC_VALIDATION_FAILED' using detail = '{"field":"attachments","reason":"max_10_per_record"}';
  end if;
  return new;
end;
$$;
create trigger attachment_links_limit before insert on public.attachment_links
  for each row execute function private.attachment_links_limit();

-- ---------------------------------------------------------------------------
-- DB-25 notifications and device registrations
-- ---------------------------------------------------------------------------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  recipient_id uuid not null references public.profiles (user_id),
  event_type text not null check (event_type in (
    'task_assigned', 'task_submitted', 'task_returned', 'task_completed', 'task_due_soon', 'task_overdue',
    'report_due_soon', 'report_overdue', 'report_returned', 'report_approved', 'report_submitted',
    'extension_requested', 'extension_decided', 'achievement_decided', 'decision_needed')),
  -- Dedupe key: recipient + entity + event + time window (§18).
  event_key text not null,
  entity_type text not null check (entity_type in ('task', 'report', 'goal', 'indicator', 'achievement', 'department')),
  entity_id uuid not null,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  unique (recipient_id, event_key)
);
create index notifications_inbox on public.notifications (recipient_id, created_at desc);

create table public.device_registrations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id),
  device_id uuid not null,          -- random, app-generated, not hardware-derived
  apns_token text not null check (apns_token ~ '^[0-9a-f]{32,200}$'),
  environment text not null check (environment in ('development', 'production')),
  last_seen_at timestamptz not null default now(),
  invalidated_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, device_id),
  unique (apns_token, environment)
);

-- ---------------------------------------------------------------------------
-- DB-26 notification_outbox (server-side delivery state)
-- ---------------------------------------------------------------------------
create table public.notification_outbox (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations (id),
  event_key text not null unique,
  recipient_id uuid not null references public.profiles (user_id),
  channel text not null check (channel in ('in_app', 'apns')),
  notification_id uuid references public.notifications (id),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'cancelled')),
  attempt_count int not null default 0 check (attempt_count between 0 and 20),
  next_attempt_at timestamptz not null default now(),
  last_error_code text,
  created_at timestamptz not null default now()
);
create index notification_outbox_due on public.notification_outbox (next_attempt_at) where status = 'pending';
