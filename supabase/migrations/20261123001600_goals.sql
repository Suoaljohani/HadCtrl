-- Goals (spec §09, AC-010). A department head (or the director) drafts a goal
-- with its target, time plan, milestones and measuring indicators; the director
-- reviews and activates it. Completion is requested by the head and decided by
-- the director: finishing every task never completes a goal by itself.
-- Same RPC rules: live membership, expected_version, request_id, audit.

alter table public.notifications drop constraint notifications_event_type_check;
alter table public.notifications add constraint notifications_event_type_check check (event_type in (
  'task_assigned', 'task_submitted', 'task_returned', 'task_completed', 'task_due_soon', 'task_overdue',
  'report_due_soon', 'report_overdue', 'report_returned', 'report_approved', 'report_submitted',
  'extension_requested', 'extension_decided', 'achievement_decided', 'decision_needed',
  'measurement_submitted', 'measurement_approved', 'measurement_returned', 'goal_decided'));

create or replace function private.goal_json(g public.goals)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('goal_id', g.id, 'lifecycle', g.lifecycle, 'version', g.version,
    'current_version_id', g.current_version_id)
$$;

create or replace function private.notify_directors(p_org uuid, p_event_key text, p_entity_type text, p_entity_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select m.user_id from public.organization_memberships m
           where m.organization_id = p_org and m.role = 'hospital_director' and m.active loop
    perform private.notify(p_org, r.user_id, 'decision_needed', p_event_key, p_entity_type, p_entity_id);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_goal: draft + version 1 (+ milestones, indicator links).
-- p_plan:       [{"at":"2026-11-30","expected":11}, ...]  (dates inside the window, increasing)
-- p_milestones: [{"title":"…","criterion":"…","weight":40}, ...]  (weights total 100)
-- p_indicators: [{"definition_id":"…","relation":"measures_outcome"|"supports"}, ...]
-- ---------------------------------------------------------------------------
create or replace function public.create_goal(
  p_department_id uuid, p_title text, p_measurement_type text, p_unit text,
  p_start_date date, p_due_date date, p_request_id uuid,
  p_description text default '', p_owner_id uuid default null, p_priority text default 'normal',
  p_baseline numeric default null, p_target numeric default null,
  p_plan jsonb default '[]', p_plan_is_linear boolean default false,
  p_milestones jsonb default '[]', p_indicators jsonb default '[]')
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_errors jsonb := '{}'::jsonb;
  v_dept public.departments;
  v_org public.organizations;
  v_owner uuid := coalesce(p_owner_id, v_actor);
  v_g public.goals;
  v_v public.goal_versions;
  v_is_director boolean;
  v_m jsonb;
  v_i jsonb;
  v_n int := 0;
begin
  v_prior := private.idem_begin(v_actor, 'create_goal', p_request_id, jsonb_build_object(
    'dept', p_department_id, 'title', p_title, 'type', p_measurement_type, 'unit', p_unit, 'start', p_start_date,
    'due', p_due_date, 'desc', p_description, 'owner', p_owner_id, 'prio', p_priority, 'base', p_baseline,
    'target', p_target, 'plan', p_plan, 'linear', p_plan_is_linear, 'ms', p_milestones, 'ind', p_indicators));
  if v_prior is not null then return v_prior; end if;

  select * into v_dept from public.departments where id = p_department_id;
  if v_dept.id is null or not private.can_view_department(v_dept.organization_id, v_dept.id) then
    perform private.fail('HC_NOT_FOUND');
  end if;
  v_is_director := private.has_org_role(v_dept.organization_id, array['hospital_director']);
  if not (v_is_director or 'department_head' = any (private.dept_roles(v_dept.id))) then
    perform private.fail('HC_FORBIDDEN');
  end if;
  select * into v_org from public.organizations where id = v_dept.organization_id;

  if p_title is null or length(btrim(p_title)) < 3 then v_errors := v_errors || '{"title":"too_short"}'; end if;
  if p_measurement_type not in ('count', 'ratio', 'duration', 'milestones') then
    v_errors := v_errors || '{"measurement_type":"invalid"}';
  end if;
  if p_unit is null or length(btrim(p_unit)) < 1 then v_errors := v_errors || '{"unit":"required"}'; end if;
  if p_priority not in ('low', 'normal', 'high', 'urgent') then v_errors := v_errors || '{"priority":"invalid"}'; end if;
  if p_start_date is null or p_due_date is null or p_due_date <= p_start_date then
    v_errors := v_errors || '{"due_date":"after_start"}';
  end if;
  -- §09: what "done" means must be explicit — a target, or weighted milestones.
  if p_measurement_type = 'milestones' then
    if jsonb_typeof(p_milestones) <> 'array' or jsonb_array_length(p_milestones) = 0 then
      v_errors := v_errors || '{"milestones":"required"}';
    elsif exists (select 1 from jsonb_array_elements(p_milestones) m
                  where length(btrim(coalesce(m ->> 'title', ''))) < 2 or length(btrim(coalesce(m ->> 'criterion', ''))) < 3
                     or coalesce((m ->> 'weight')::numeric, 0) <= 0) then
      v_errors := v_errors || '{"milestones":"each_needs_title_criterion_weight"}';
    elsif (select sum((m ->> 'weight')::numeric) from jsonb_array_elements(p_milestones) m) <> 100 then
      v_errors := v_errors || '{"milestones":"weights_must_total_100"}';
    end if;
  elsif p_target is null or p_target <= 0 then
    v_errors := v_errors || '{"target":"required_positive"}';
  end if;
  if jsonb_typeof(p_plan) <> 'array' then v_errors := v_errors || '{"plan":"invalid"}';
  elsif exists (select 1 from jsonb_array_elements(p_plan) with ordinality x(p, i)
                where (p ->> 'at') is null or (p ->> 'expected') is null
                   or (p ->> 'at')::date < p_start_date or (p ->> 'at')::date > p_due_date
                   or (p ->> 'expected')::numeric < 0
                   or exists (select 1 from jsonb_array_elements(p_plan) with ordinality y(q, j)
                              where j = i - 1 and ((q ->> 'at')::date >= (p ->> 'at')::date
                                                   or (q ->> 'expected')::numeric > (p ->> 'expected')::numeric))) then
    v_errors := v_errors || '{"plan":"points_inside_window_and_increasing"}';
  end if;
  if not exists (select 1 from public.organization_memberships m where m.organization_id = v_dept.organization_id
                   and m.user_id = v_owner and m.active)
     and not exists (select 1 from public.department_memberships dm join public.departments d on d.id = dm.department_id
                     where d.organization_id = v_dept.organization_id and dm.user_id = v_owner and dm.active) then
    v_errors := v_errors || '{"owner_id":"not_a_member"}';
  end if;
  if jsonb_typeof(p_indicators) <> 'array' or exists (
       select 1 from jsonb_array_elements(p_indicators) i
        where coalesce(i ->> 'relation', '') not in ('measures_outcome', 'supports')
           or not exists (select 1 from public.indicator_definitions d where d.id = (i ->> 'definition_id')::uuid
                            and d.department_id = v_dept.id and d.active)) then
    v_errors := v_errors || '{"indicators":"same_department_active_indicators_only"}';
  end if;
  if v_errors <> '{}'::jsonb then perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('fields', v_errors)); end if;

  insert into public.goals (organization_id, department_id, owner_id, title, description, priority, start_at, due_at,
    measurement_type, created_by)
  values (v_dept.organization_id, v_dept.id, v_owner, btrim(p_title), coalesce(p_description, ''), p_priority,
    (p_start_date + time '00:00') at time zone v_org.timezone, private.end_of_local_day(p_due_date, v_org.timezone),
    p_measurement_type, v_actor)
  returning * into v_g;
  insert into public.goal_versions (organization_id, goal_id, revision, unit, baseline, target_value, progress_plan,
    plan_is_linear, created_by)
  values (v_g.organization_id, v_g.id, 1, btrim(p_unit), p_baseline,
    case when p_measurement_type = 'milestones' then 100 else p_target end, p_plan, coalesce(p_plan_is_linear, false), v_actor)
  returning * into v_v;
  for v_m in select * from jsonb_array_elements(case when p_measurement_type = 'milestones' then p_milestones else '[]' end) loop
    v_n := v_n + 1;
    insert into public.goal_milestones (organization_id, goal_version_id, ordinal, title, completion_criterion, weight)
    values (v_g.organization_id, v_v.id, v_n, btrim(v_m ->> 'title'), btrim(v_m ->> 'criterion'), (v_m ->> 'weight')::numeric);
  end loop;
  for v_i in select * from jsonb_array_elements(p_indicators) loop
    insert into public.goal_indicator_links (organization_id, goal_id, indicator_definition_id, relation_type)
    values (v_g.organization_id, v_g.id, (v_i ->> 'definition_id')::uuid, v_i ->> 'relation')
    on conflict do nothing;
  end loop;
  update public.goals set current_version_id = v_v.id where id = v_g.id returning * into v_g;

  perform private.audit(v_g.organization_id, v_g.department_id, v_actor, 'goal', v_g.id, 'create', null,
    private.goal_json(v_g), null, p_request_id);
  if not v_is_director then
    perform private.notify_directors(v_g.organization_id, 'goal_review:' || v_g.id, 'goal', v_g.id);
  end if;
  return private.idem_finish(v_actor, 'create_goal', p_request_id, private.goal_json(v_g));
end;
$$;

-- ---------------------------------------------------------------------------
-- decide_goal: the director's lifecycle decisions.
--   activate          draft → active (approves the current version)
--   return            draft stays draft (note to the head)
--   complete          completion_pending → completed
--   reject_completion completion_pending → active (note)
--   cancel            draft/active/completion_pending → cancelled (reason)
-- ---------------------------------------------------------------------------
create or replace function public.decide_goal(
  p_goal_id uuid, p_decision text, p_expected_version int, p_request_id uuid, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_g public.goals;
  v_before jsonb;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_next text;
begin
  v_prior := private.idem_begin(v_actor, 'decide_goal', p_request_id, jsonb_build_object(
    'id', p_goal_id, 'decision', p_decision, 'v', p_expected_version, 'note', p_note));
  if v_prior is not null then return v_prior; end if;
  select * into v_g from public.goals where id = p_goal_id for update;
  if v_g.id is null or not private.can_view_department(v_g.organization_id, v_g.department_id) then
    perform private.fail('HC_NOT_FOUND');
  end if;
  if not private.has_org_role(v_g.organization_id, array['hospital_director']) then perform private.fail('HC_FORBIDDEN'); end if;
  if v_g.version <> p_expected_version then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_g.version));
  end if;
  v_next := case
    when p_decision = 'activate' and v_g.lifecycle = 'draft' then 'active'
    when p_decision = 'return' and v_g.lifecycle = 'draft' then 'draft'
    when p_decision = 'complete' and v_g.lifecycle = 'completion_pending' then 'completed'
    when p_decision = 'reject_completion' and v_g.lifecycle = 'completion_pending' then 'active'
    when p_decision = 'cancel' and v_g.lifecycle in ('draft', 'active', 'completion_pending') then 'cancelled'
  end;
  if p_decision not in ('activate', 'return', 'complete', 'reject_completion', 'cancel') then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"decision":"invalid"}}');
  end if;
  if v_next is null then perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('status', 'not_allowed_from_' || v_g.lifecycle)); end if;
  if p_decision in ('return', 'reject_completion', 'cancel') and (v_note is null or length(v_note) < 3) then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"note":"required"}}');
  end if;

  v_before := private.goal_json(v_g);
  if p_decision = 'activate' then
    update public.goal_versions set approved_by = v_actor, approved_at = now()
     where id = v_g.current_version_id and approved_at is null;
  end if;
  update public.goals set lifecycle = v_next, cancel_reason = case when v_next = 'cancelled' then v_note else cancel_reason end
   where id = v_g.id returning * into v_g;
  -- A "return" changes nothing but the version, so a stale screen sees the decision.
  if p_decision = 'return' then update public.goals set updated_at = now() where id = v_g.id returning * into v_g; end if;
  perform private.audit(v_g.organization_id, v_g.department_id, v_actor, 'goal', v_g.id, 'decide_' || p_decision,
    v_before, private.goal_json(v_g), v_note, p_request_id);
  perform private.notify(v_g.organization_id, v_g.owner_id, 'goal_decided',
                         'goal_decided:' || v_g.id || ':' || v_g.version, 'goal', v_g.id);
  if v_g.created_by <> v_g.owner_id then
    perform private.notify(v_g.organization_id, v_g.created_by, 'goal_decided',
                           'goal_decided:' || v_g.id || ':' || v_g.version, 'goal', v_g.id);
  end if;
  return private.idem_finish(v_actor, 'decide_goal', p_request_id, private.goal_json(v_g) || jsonb_build_object('note', v_note));
end;
$$;

-- ---------------------------------------------------------------------------
-- request_goal_completion: department head asks the director to close an active goal.
-- ---------------------------------------------------------------------------
create or replace function public.request_goal_completion(p_goal_id uuid, p_expected_version int, p_request_id uuid,
  p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_g public.goals;
  v_before jsonb;
begin
  v_prior := private.idem_begin(v_actor, 'request_goal_completion', p_request_id,
    jsonb_build_object('id', p_goal_id, 'v', p_expected_version, 'note', p_note));
  if v_prior is not null then return v_prior; end if;
  select * into v_g from public.goals where id = p_goal_id for update;
  if v_g.id is null or not private.can_view_department(v_g.organization_id, v_g.department_id) then
    perform private.fail('HC_NOT_FOUND');
  end if;
  if not ('department_head' = any (private.dept_roles(v_g.department_id))) then perform private.fail('HC_FORBIDDEN'); end if;
  if v_g.version <> p_expected_version then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_g.version));
  end if;
  if v_g.lifecycle <> 'active' then perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_active"}'); end if;
  v_before := private.goal_json(v_g);
  update public.goals set lifecycle = 'completion_pending' where id = v_g.id returning * into v_g;
  perform private.audit(v_g.organization_id, v_g.department_id, v_actor, 'goal', v_g.id, 'request_completion',
    v_before, private.goal_json(v_g), nullif(btrim(coalesce(p_note, '')), ''), p_request_id);
  perform private.notify_directors(v_g.organization_id, 'goal_completion:' || v_g.id || ':' || v_g.version, 'goal', v_g.id);
  return private.idem_finish(v_actor, 'request_goal_completion', p_request_id, private.goal_json(v_g));
end;
$$;

-- ---------------------------------------------------------------------------
-- set_milestone: 'complete' (department head, active goal) or 'approve' (director).
-- Only approved milestones count toward progress (§11).
-- ---------------------------------------------------------------------------
create or replace function public.set_milestone(p_milestone_id uuid, p_action text, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_ms public.goal_milestones;
  v_g public.goals;
begin
  v_prior := private.idem_begin(v_actor, 'set_milestone', p_request_id, jsonb_build_object('id', p_milestone_id, 'action', p_action));
  if v_prior is not null then return v_prior; end if;
  select * into v_ms from public.goal_milestones where id = p_milestone_id for update;
  select g.* into v_g from public.goals g join public.goal_versions v on v.goal_id = g.id where v.id = v_ms.goal_version_id;
  if v_ms.id is null or v_g.id is null or not private.can_view_department(v_g.organization_id, v_g.department_id) then
    perform private.fail('HC_NOT_FOUND');
  end if;
  if v_g.lifecycle not in ('active', 'completion_pending') then perform private.fail('HC_VALIDATION_FAILED', '{"status":"goal_not_active"}'); end if;
  if p_action = 'complete' then
    if not ('department_head' = any (private.dept_roles(v_g.department_id))) then perform private.fail('HC_FORBIDDEN'); end if;
    if v_ms.completed_at is not null then perform private.fail('HC_VALIDATION_FAILED', '{"status":"already_completed"}'); end if;
    update public.goal_milestones set completed_at = now() where id = v_ms.id returning * into v_ms;
    perform private.notify_directors(v_g.organization_id, 'milestone_completed:' || v_ms.id, 'goal', v_g.id);
  elsif p_action = 'approve' then
    if not private.has_org_role(v_g.organization_id, array['hospital_director']) or private.is_department_member(v_g.department_id) then
      perform private.fail('HC_FORBIDDEN');
    end if;
    if v_ms.completed_at is null or v_ms.approved_by is not null then
      perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_awaiting_approval"}');
    end if;
    update public.goal_milestones set approved_by = v_actor where id = v_ms.id returning * into v_ms;
  else
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"action":"invalid"}}');
  end if;
  update public.goals set updated_at = now() where id = v_g.id returning * into v_g;   -- bumps the goal version
  perform private.audit(v_g.organization_id, v_g.department_id, v_actor, 'goal_milestone', v_ms.id, 'milestone_' || p_action,
    null, jsonb_build_object('completed_at', v_ms.completed_at, 'approved_by', v_ms.approved_by), null, p_request_id);
  return private.idem_finish(v_actor, 'set_milestone', p_request_id,
    private.goal_json(v_g) || jsonb_build_object('milestone_id', v_ms.id, 'completed_at', v_ms.completed_at,
                                                 'approved', v_ms.approved_by is not null));
end;
$$;

-- Grants
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;
revoke execute on function private.goal_json(public.goals), private.notify_directors(uuid, text, text, uuid) from authenticated;
grant execute on function
  public.create_goal(uuid, text, text, text, date, date, uuid, text, uuid, text, numeric, numeric, jsonb, boolean, jsonb, jsonb),
  public.decide_goal(uuid, text, int, uuid, text),
  public.request_goal_completion(uuid, int, uuid, text),
  public.set_milestone(uuid, text, uuid)
to authenticated;
