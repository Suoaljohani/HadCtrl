-- RPC framework (errors, actor, idempotency, audit, notifications) and the
-- task slice: API-04 create_task, API-05 transition_task, API-15 request_extension,
-- decide_extension, mark_notification_read, API-14 register_device.
-- Spec refs: §12, §13, §18, §25, §27; AC-011..AC-014, AC-024, AC-032.
--
-- Error contract: RAISE with MESSAGE = one of the HC_* codes from §27 and
-- DETAIL = JSON (never row content the caller may not read). PostgREST
-- returns them as {code:"P0001", message:"HC_...", details:"{...}"}.

-- ---------------------------------------------------------------------------
-- Framework
-- ---------------------------------------------------------------------------
create or replace function private.fail(p_code text, p_detail jsonb default '{}'::jsonb)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception '%', p_code using detail = p_detail::text, errcode = 'P0001';
end;
$$;

-- Returns the authenticated, active caller or fails (AC-032: checked per call).
create or replace function private.require_actor()
returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v uuid := auth.uid();
begin
  if v is null then
    perform private.fail('HC_AUTH_REQUIRED');
  end if;
  if not exists (select 1 from public.profiles p where p.user_id = v and p.active) then
    perform private.fail('HC_MEMBERSHIP_INACTIVE');
  end if;
  return v;
end;
$$;

-- Idempotency (DB-28). Returns the stored response if this request already
-- completed; NULL if the caller should proceed. Concurrent duplicates block on
-- the primary key until the first transaction commits, then see its response.
create or replace function private.idem_begin(p_actor uuid, p_operation text, p_request_id uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hash text := md5(p_payload::text);
  v_row public.idempotency_requests;
begin
  if p_request_id is null then
    perform private.fail('HC_VALIDATION_FAILED', '{"field":"request_id","reason":"required"}');
  end if;
  insert into public.idempotency_requests (actor_id, operation, request_id, request_hash)
  values (p_actor, p_operation, p_request_id, v_hash)
  on conflict do nothing;
  if found then
    return null;
  end if;
  select * into v_row from public.idempotency_requests
  where actor_id = p_actor and operation = p_operation and request_id = p_request_id;
  if v_row.request_hash <> v_hash then
    perform private.fail('HC_IDEMPOTENCY_MISMATCH');
  end if;
  return v_row.response || jsonb_build_object('replayed', true);
end;
$$;

create or replace function private.idem_finish(p_actor uuid, p_operation text, p_request_id uuid, p_response jsonb)
returns jsonb
language sql
set search_path = ''
as $$
  update public.idempotency_requests
     set response = p_response, status = 'completed'
   where actor_id = p_actor and operation = p_operation and request_id = p_request_id;
  select p_response || jsonb_build_object('replayed', false);
$$;

create or replace function private.audit(
  p_org uuid, p_dept uuid, p_actor uuid, p_entity_type text, p_entity_id uuid, p_action text,
  p_before jsonb, p_after jsonb, p_reason text, p_request_id uuid)
returns void
language sql
set search_path = ''
as $$
  insert into public.audit_events
    (organization_id, department_id, actor_id, entity_type, entity_id, action, before_summary, after_summary, reason, request_id)
  values (p_org, p_dept, p_actor, p_entity_type, p_entity_id, p_action, p_before, p_after, p_reason, p_request_id);
$$;

-- In-app notification + outbox row, deduplicated by event key (§18).
create or replace function private.notify(
  p_org uuid, p_recipient uuid, p_event_type text, p_event_key text, p_entity_type text, p_entity_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_recipient is null then
    return;
  end if;
  insert into public.notifications (organization_id, recipient_id, event_type, event_key, entity_type, entity_id)
  values (p_org, p_recipient, p_event_type, p_event_key, p_entity_type, p_entity_id)
  on conflict (recipient_id, event_key) do nothing
  returning id into v_id;
  if v_id is not null then
    insert into public.notification_outbox (organization_id, event_key, recipient_id, channel, notification_id)
    values (p_org, p_recipient::text || ':' || p_event_key, p_recipient, 'apns', v_id)
    on conflict (event_key) do nothing;
  end if;
end;
$$;

-- "Date only" deadlines resolve to the end of that day in hospital time (§15).
create or replace function private.end_of_local_day(p_date date, p_tz text)
returns timestamptz
language sql immutable
set search_path = ''
as $$
  select ((p_date + time '23:59:59') at time zone p_tz)
$$;

-- Active member of a department eligible to receive assignments.
create or replace function private.is_assignable(p_dept uuid, p_user uuid)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (
    select 1 from public.department_memberships m
    join public.profiles p on p.user_id = m.user_id and p.active
    where m.department_id = p_dept and m.user_id = p_user and m.active
      and m.valid_from <= now() and (m.valid_to is null or m.valid_to > now()))
$$;

create or replace function private.task_json(t public.tasks)
returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'task_id', t.id, 'status', t.status, 'version', t.version,
    'assignee_id', t.assignee_id, 'due_at', t.due_at, 'original_due_at', t.original_due_at,
    'created_at', t.created_at, 'updated_at', t.updated_at)
$$;

-- ---------------------------------------------------------------------------
-- API-04 create_task
-- ---------------------------------------------------------------------------
create or replace function public.create_task(
  p_department_id uuid,
  p_title text,
  p_request_id uuid,
  p_assignee_id uuid default null,
  p_due_at timestamptz default null,
  p_due_date date default null,
  p_description text default '',
  p_priority text default 'normal',
  p_start_at timestamptz default null,
  p_linked_goal_id uuid default null,
  p_parent_task_id uuid default null,
  p_as_draft boolean default false)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_dept public.departments;
  v_org public.organizations;
  v_due timestamptz;
  v_prior jsonb;
  v_task public.tasks;
  v_errors jsonb := '{}'::jsonb;
begin
  v_prior := private.idem_begin(v_actor, 'create_task', p_request_id, jsonb_build_object(
    'department_id', p_department_id, 'title', p_title, 'assignee_id', p_assignee_id, 'due_at', p_due_at,
    'due_date', p_due_date, 'description', p_description, 'priority', p_priority, 'start_at', p_start_at,
    'linked_goal_id', p_linked_goal_id, 'parent_task_id', p_parent_task_id, 'as_draft', p_as_draft));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_dept from public.departments where id = p_department_id;
  -- Unknown and unauthorized departments are indistinguishable (HC-120).
  if v_dept.id is null or not private.can_operate_department(v_dept.organization_id, v_dept.id) then
    perform private.fail('HC_NOT_FOUND');
  end if;
  if not (private.has_org_role(v_dept.organization_id, array['hospital_director'])
          or 'department_head' = any (private.dept_roles(v_dept.id))) then
    perform private.fail('HC_FORBIDDEN', '{"reason":"cannot_assign_in_department"}');
  end if;
  if v_dept.archived_at is not null then
    perform private.fail('HC_VALIDATION_FAILED', '{"department_id":"archived"}');
  end if;
  select * into v_org from public.organizations where id = v_dept.organization_id;

  v_due := coalesce(p_due_at, case when p_due_date is not null then private.end_of_local_day(p_due_date, v_org.timezone) end);

  if p_title is null or length(btrim(p_title)) < 3 then
    v_errors := v_errors || '{"title":"too_short"}';
  end if;
  if p_priority not in ('low', 'normal', 'high', 'urgent') then
    v_errors := v_errors || '{"priority":"invalid"}';
  end if;
  if not p_as_draft then
    if p_assignee_id is null then
      v_errors := v_errors || '{"assignee_id":"required"}';
    elsif not private.is_assignable(v_dept.id, p_assignee_id) then
      v_errors := v_errors || '{"assignee_id":"not_active_department_member"}';
    end if;
    if v_due is null then
      v_errors := v_errors || '{"due_at":"required"}';
    elsif v_due <= now() then
      v_errors := v_errors || '{"due_at":"must_be_future"}';
    end if;
  end if;
  if p_start_at is not null and v_due is not null and v_due <= p_start_at then
    v_errors := v_errors || '{"start_at":"after_due"}';
  end if;
  if p_linked_goal_id is not null and not exists (
      select 1 from public.goals g where g.id = p_linked_goal_id and g.organization_id = v_dept.organization_id
        and private.can_view_department(g.organization_id, g.department_id)) then
    v_errors := v_errors || '{"linked_goal_id":"not_found"}';
  end if;
  if p_parent_task_id is not null and not (
      private.can_read_task(p_parent_task_id)
      and exists (select 1 from public.tasks pt where pt.id = p_parent_task_id and pt.organization_id = v_dept.organization_id)) then
    v_errors := v_errors || '{"parent_task_id":"not_found"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  insert into public.tasks (organization_id, department_id, assignee_id, creator_id, parent_task_id, linked_goal_id,
                            title, description, status, priority, start_at, original_due_at, due_at)
  values (v_dept.organization_id, v_dept.id, p_assignee_id, v_actor, p_parent_task_id, p_linked_goal_id,
          btrim(p_title), coalesce(p_description, ''), case when p_as_draft then 'draft' else 'assigned' end,
          p_priority, p_start_at, v_due, v_due)
  returning * into v_task;

  insert into public.task_events (organization_id, task_id, actor_id, event, to_status, request_id)
  values (v_task.organization_id, v_task.id, v_actor, 'created', v_task.status, p_request_id);
  perform private.audit(v_task.organization_id, v_task.department_id, v_actor, 'task', v_task.id, 'create',
                        null, private.task_json(v_task), null, p_request_id);
  if v_task.status = 'assigned' then
    perform private.notify(v_task.organization_id, v_task.assignee_id, 'task_assigned',
                           'task_assigned:' || v_task.id, 'task', v_task.id);
  end if;

  return private.idem_finish(v_actor, 'create_task', p_request_id, private.task_json(v_task));
end;
$$;

-- ---------------------------------------------------------------------------
-- API-05 transition_task
-- ---------------------------------------------------------------------------
create or replace function public.transition_task(
  p_task_id uuid,
  p_expected_version int,
  p_transition text,
  p_request_id uuid,
  p_note text default null,
  p_new_assignee_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_t public.tasks;
  v_before jsonb;
  v_to text;
  v_is_director boolean;
  v_is_head boolean;
  v_is_assignee boolean;
  v_can_approve boolean;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  v_prior := private.idem_begin(v_actor, 'transition_task', p_request_id, jsonb_build_object(
    'task_id', p_task_id, 'expected_version', p_expected_version, 'transition', p_transition,
    'note', p_note, 'new_assignee_id', p_new_assignee_id));
  if v_prior is not null then
    return v_prior;
  end if;

  if not private.can_read_task(p_task_id) then
    perform private.fail('HC_NOT_FOUND');
  end if;
  select * into v_t from public.tasks where id = p_task_id for update;
  if v_t.version <> p_expected_version then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_t.version));
  end if;
  v_before := private.task_json(v_t);

  v_is_director := private.has_org_role(v_t.organization_id, array['hospital_director']);
  v_is_head := 'department_head' = any (private.dept_roles(v_t.department_id));
  v_is_assignee := v_t.assignee_id = v_actor and private.is_assignable(v_t.department_id, v_actor);
  -- Approver: director, or the (still active) head who created it; never the assignee.
  v_can_approve := v_t.assignee_id is distinct from v_actor
                   and (v_is_director or (v_t.creator_id = v_actor and v_is_head)
                        or private.has_delegation(v_t.organization_id, v_t.department_id, array['review_tasks']));

  case p_transition
    when 'assign' then
      if v_t.status <> 'draft' then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not (v_t.creator_id = v_actor and (v_is_director or v_is_head)) then perform private.fail('HC_FORBIDDEN'); end if;
      if v_t.assignee_id is null or not private.is_assignable(v_t.department_id, v_t.assignee_id) then
        perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"assignee_id":"not_active_department_member"}}');
      end if;
      if v_t.due_at is null or v_t.due_at <= now() then
        perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"due_at":"must_be_future"}}');
      end if;
      v_to := 'assigned';
    when 'acknowledge' then
      if v_t.status <> 'assigned' then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not v_is_assignee then perform private.fail('HC_FORBIDDEN'); end if;
      v_to := 'acknowledged';
    when 'start' then
      if v_t.status not in ('assigned', 'acknowledged', 'returned') then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not v_is_assignee then perform private.fail('HC_FORBIDDEN'); end if;
      v_to := 'in_progress';
    when 'block' then
      if v_t.status not in ('acknowledged', 'in_progress') then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not (v_is_assignee or v_is_director) then perform private.fail('HC_FORBIDDEN'); end if;
      if v_note is null or length(v_note) < 3 then perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"note":"required"}}'); end if;
      v_to := 'blocked';
    when 'unblock' then
      if v_t.status <> 'blocked' then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not (v_is_assignee or v_is_director) then perform private.fail('HC_FORBIDDEN'); end if;
      v_to := 'in_progress';
    when 'submit' then
      if v_t.status not in ('assigned', 'acknowledged', 'in_progress', 'returned') then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not v_is_assignee then perform private.fail('HC_FORBIDDEN'); end if;
      v_to := 'submitted';
    when 'approve' then
      if v_t.status <> 'submitted' then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not v_can_approve then perform private.fail('HC_FORBIDDEN'); end if;
      v_to := 'completed';
    when 'return' then
      if v_t.status <> 'submitted' then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not v_can_approve then perform private.fail('HC_FORBIDDEN'); end if;
      if v_note is null or length(v_note) < 3 then perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"note":"required"}}'); end if;
      v_to := 'returned';
    when 'cancel' then
      if v_t.status in ('completed', 'cancelled') then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not (v_is_director or (v_t.creator_id = v_actor and v_is_head)) then perform private.fail('HC_FORBIDDEN'); end if;
      if v_note is null or length(v_note) < 3 then perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"note":"required"}}'); end if;
      v_to := 'cancelled';
    when 'reassign' then
      if v_t.status in ('completed', 'cancelled', 'draft') then perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}'); end if;
      if not (v_is_director or v_is_head) then perform private.fail('HC_FORBIDDEN'); end if;
      if v_note is null or length(v_note) < 3 then perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"note":"required"}}'); end if;
      if p_new_assignee_id is null or p_new_assignee_id = v_t.assignee_id
         or not private.is_assignable(v_t.department_id, p_new_assignee_id) then
        perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"new_assignee_id":"not_active_department_member"}}');
      end if;
      v_to := case when v_t.status = 'submitted' then 'assigned' else v_t.status end;
    else
      perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"transition":"unknown"}}');
  end case;

  update public.tasks set
    status = v_to,
    blocked_reason = case when v_to = 'blocked' then v_note else null end,
    first_submitted_at = case when v_to = 'submitted' then coalesce(first_submitted_at, now()) else first_submitted_at end,
    last_submitted_at = case when v_to = 'submitted' then now() else last_submitted_at end,
    completed_at = case when v_to = 'completed' then now() else completed_at end,
    assignee_id = case when p_transition = 'reassign' then p_new_assignee_id else assignee_id end
  where id = v_t.id
  returning * into v_t;

  insert into public.task_events (organization_id, task_id, actor_id, event, from_status, to_status, note,
                                  previous_assignee_id, request_id)
  values (v_t.organization_id, v_t.id, v_actor, p_transition, v_before ->> 'status', v_t.status, v_note,
          case when p_transition = 'reassign' then (v_before ->> 'assignee_id')::uuid end, p_request_id);
  perform private.audit(v_t.organization_id, v_t.department_id, v_actor, 'task', v_t.id, p_transition,
                        v_before, private.task_json(v_t), v_note, p_request_id);

  case p_transition
    when 'assign' then
      perform private.notify(v_t.organization_id, v_t.assignee_id, 'task_assigned', 'task_assigned:' || v_t.id, 'task', v_t.id);
    when 'reassign' then
      perform private.notify(v_t.organization_id, v_t.assignee_id, 'task_assigned',
                             'task_assigned:' || v_t.id || ':' || v_t.version, 'task', v_t.id);
    when 'submit' then
      perform private.notify(v_t.organization_id, v_t.creator_id, 'task_submitted',
                             'task_submitted:' || v_t.id || ':' || v_t.version, 'task', v_t.id);
    when 'approve' then
      perform private.notify(v_t.organization_id, v_t.assignee_id, 'task_completed', 'task_completed:' || v_t.id, 'task', v_t.id);
    when 'return' then
      perform private.notify(v_t.organization_id, v_t.assignee_id, 'task_returned',
                             'task_returned:' || v_t.id || ':' || v_t.version, 'task', v_t.id);
    else
      null;
  end case;

  return private.idem_finish(v_actor, 'transition_task', p_request_id, private.task_json(v_t));
end;
$$;

-- ---------------------------------------------------------------------------
-- API-15 request_extension / decide_extension (tasks; AC-013)
-- ---------------------------------------------------------------------------
create or replace function public.request_task_extension(
  p_task_id uuid, p_proposed_due_at timestamptz, p_reason text, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_t public.tasks;
  v_id uuid;
  v_res jsonb;
begin
  v_prior := private.idem_begin(v_actor, 'request_task_extension', p_request_id,
    jsonb_build_object('task_id', p_task_id, 'proposed_due_at', p_proposed_due_at, 'reason', p_reason));
  if v_prior is not null then return v_prior; end if;

  if not private.can_read_task(p_task_id) then perform private.fail('HC_NOT_FOUND'); end if;
  select * into v_t from public.tasks where id = p_task_id for update;
  if v_t.assignee_id <> v_actor then perform private.fail('HC_FORBIDDEN'); end if;
  if v_t.status in ('draft', 'completed', 'cancelled') then
    perform private.fail('HC_VALIDATION_FAILED', '{"transition":"invalid_from_status"}');
  end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"reason":"required"}}');
  end if;
  if p_proposed_due_at is null or p_proposed_due_at <= v_t.due_at then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"proposed_due_at":"must_be_after_current_due"}}');
  end if;
  if exists (select 1 from public.extension_requests e where e.task_id = v_t.id and e.status = 'pending') then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"task_id":"pending_request_exists"}}');
  end if;

  insert into public.extension_requests (organization_id, task_id, requested_by, current_due_at, requested_due_at, reason)
  values (v_t.organization_id, v_t.id, v_actor, v_t.due_at, p_proposed_due_at, btrim(p_reason))
  returning id into v_id;
  insert into public.task_events (organization_id, task_id, actor_id, event, note, request_id)
  values (v_t.organization_id, v_t.id, v_actor, 'extension_requested', btrim(p_reason), p_request_id);
  perform private.audit(v_t.organization_id, v_t.department_id, v_actor, 'extension_request', v_id, 'create',
                        null, jsonb_build_object('task_id', v_t.id, 'requested_due_at', p_proposed_due_at), p_reason, p_request_id);
  perform private.notify(v_t.organization_id, v_t.creator_id, 'extension_requested', 'extension_requested:' || v_id, 'task', v_t.id);

  v_res := jsonb_build_object('extension_request_id', v_id, 'status', 'pending', 'task_due_at', v_t.due_at);
  return private.idem_finish(v_actor, 'request_task_extension', p_request_id, v_res);
end;
$$;

create or replace function public.decide_task_extension(
  p_extension_request_id uuid, p_decision text, p_request_id uuid, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_e public.extension_requests;
  v_t public.tasks;
  v_res jsonb;
begin
  v_prior := private.idem_begin(v_actor, 'decide_task_extension', p_request_id,
    jsonb_build_object('id', p_extension_request_id, 'decision', p_decision, 'note', p_note));
  if v_prior is not null then return v_prior; end if;

  select * into v_e from public.extension_requests where id = p_extension_request_id and task_id is not null for update;
  if v_e.id is null or not private.can_read_task(v_e.task_id) then perform private.fail('HC_NOT_FOUND'); end if;
  select * into v_t from public.tasks where id = v_e.task_id for update;
  if not ((private.has_org_role(v_t.organization_id, array['hospital_director'])
           or (v_t.creator_id = v_actor and 'department_head' = any (private.dept_roles(v_t.department_id))))
          and v_e.requested_by <> v_actor) then
    perform private.fail('HC_FORBIDDEN');
  end if;
  if v_e.status <> 'pending' then perform private.fail('HC_VALIDATION_FAILED', '{"status":"already_decided"}'); end if;
  if p_decision not in ('approved', 'rejected') then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"decision":"invalid"}}');
  end if;
  if p_decision = 'rejected' and length(btrim(coalesce(p_note, ''))) < 3 then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"note":"required"}}');
  end if;

  update public.extension_requests
     set status = p_decision, decided_by = v_actor, decided_at = now(), decision_note = nullif(btrim(coalesce(p_note, '')), '')
   where id = v_e.id returning * into v_e;
  if p_decision = 'approved' then
    insert into public.task_events (organization_id, task_id, actor_id, event, previous_due_at, note, request_id)
    values (v_t.organization_id, v_t.id, v_actor, 'due_changed', v_t.due_at, p_note, p_request_id);
    -- original_due_at is never changed (§12).
    update public.tasks set due_at = v_e.requested_due_at where id = v_t.id returning * into v_t;
  end if;
  perform private.audit(v_t.organization_id, v_t.department_id, v_actor, 'extension_request', v_e.id, p_decision,
                        null, jsonb_build_object('task_due_at', v_t.due_at), p_note, p_request_id);
  perform private.notify(v_t.organization_id, v_e.requested_by, 'extension_decided', 'extension_decided:' || v_e.id, 'task', v_t.id);

  v_res := jsonb_build_object('extension_request_id', v_e.id, 'status', v_e.status, 'task', private.task_json(v_t));
  return private.idem_finish(v_actor, 'decide_task_extension', p_request_id, v_res);
end;
$$;

-- ---------------------------------------------------------------------------
-- Notifications: mark read (reading never completes the underlying action).
-- ---------------------------------------------------------------------------
create or replace function public.mark_notification_read(p_notification_id uuid)
returns timestamptz
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_at timestamptz;
begin
  update public.notifications set read_at = coalesce(read_at, now())
   where id = p_notification_id and recipient_id = v_actor
  returning read_at into v_at;
  if v_at is null then perform private.fail('HC_NOT_FOUND'); end if;
  return v_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- API-14 register_device (binds to the caller; cannot target another user)
-- ---------------------------------------------------------------------------
create or replace function public.register_device(p_device_id uuid, p_token text, p_environment text)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_id uuid;
begin
  if p_token !~ '^[0-9a-f]{32,200}$' or p_environment not in ('development', 'production') then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"token":"invalid"}}');
  end if;
  -- A token moves with the device: drop it from any previous binding.
  delete from public.device_registrations
   where apns_token = p_token and environment = p_environment and not (user_id = v_actor and device_id = p_device_id);
  insert into public.device_registrations (user_id, device_id, apns_token, environment)
  values (v_actor, p_device_id, p_token, p_environment)
  on conflict (user_id, device_id) do update
    set apns_token = excluded.apns_token, environment = excluded.environment,
        last_seen_at = now(), invalidated_at = null
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Session context: memberships the caller currently holds (for app routing).
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
    'profile', (select jsonb_build_object('display_name', p.display_name, 'job_title', p.job_title)
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
-- Execute grants: authenticated only, never anon/public.
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
-- Framework helpers above are internal: only callable from definer RPCs.
revoke execute on all functions in schema private from public, anon;
revoke execute on function
  private.fail(text, jsonb), private.require_actor(), private.idem_begin(uuid, text, uuid, jsonb),
  private.idem_finish(uuid, text, uuid, jsonb), private.audit(uuid, uuid, uuid, text, uuid, text, jsonb, jsonb, text, uuid),
  private.notify(uuid, uuid, text, text, text, uuid), private.end_of_local_day(date, text),
  private.is_assignable(uuid, uuid), private.task_json(public.tasks)
from authenticated;
grant execute on function
  public.create_task(uuid, text, uuid, uuid, timestamptz, date, text, text, timestamptz, uuid, uuid, boolean),
  public.transition_task(uuid, int, text, uuid, text, uuid),
  public.request_task_extension(uuid, timestamptz, text, uuid),
  public.decide_task_extension(uuid, text, uuid, text),
  public.mark_notification_read(uuid),
  public.register_device(uuid, text, text),
  public.my_context()
to authenticated;
