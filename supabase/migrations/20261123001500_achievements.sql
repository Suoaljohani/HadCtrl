-- Achievements (spec §16, API-10). A department documents a result with its
-- impact; the director approves, returns (asks for clarification/evidence) or
-- rejects. Nothing is deleted: decisions are kept in achievement_reviews.
-- Same RPC rules as elsewhere: live membership, expected_version, request_id, audit.

create table public.achievement_reviews (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  achievement_id uuid not null,
  reviewer_id uuid not null references public.profiles (user_id),
  decision text not null check (decision in ('approved', 'returned', 'rejected')),
  note text,
  request_id uuid,
  decided_at timestamptz not null default now(),
  foreign key (organization_id, achievement_id) references public.achievements (organization_id, id),
  check (decision = 'approved' or length(btrim(coalesce(note, ''))) >= 3)
);
create index achievement_reviews_by_achievement on public.achievement_reviews (achievement_id, decided_at desc);
create trigger achievement_reviews_immutable before update or delete on public.achievement_reviews
  for each row execute function private.audit_immutable();
alter table public.achievement_reviews enable row level security;
create policy achievement_reviews_select on public.achievement_reviews for select to authenticated
  using (private.can_read_achievement(achievement_id));
grant select on public.achievement_reviews to authenticated;

create or replace function private.achievement_json(a public.achievements)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('achievement_id', a.id, 'status', a.status, 'version', a.version,
    'submitted_at', a.submitted_at, 'approved_at', a.approved_at)
$$;

-- ---------------------------------------------------------------------------
-- save_achievement: create a draft (p_achievement_id null) or edit a draft /
-- returned achievement. Any member of the department may draft (§03).
-- ---------------------------------------------------------------------------
create or replace function public.save_achievement(
  p_department_id uuid, p_period_id uuid, p_title text, p_request_id uuid,
  p_achievement_id uuid default null, p_expected_version int default null,
  p_description text default '', p_impact_text text default '', p_beneficiary text default null,
  p_linked_task_id uuid default null, p_linked_measurement_id uuid default null,
  p_contributor_department_ids uuid[] default '{}')
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_errors jsonb := '{}'::jsonb;
  v_dept public.departments;
  v_period public.reporting_periods;
  v_a public.achievements;
  v_before jsonb;
  v_c uuid;
begin
  v_prior := private.idem_begin(v_actor, 'save_achievement', p_request_id, jsonb_build_object(
    'id', p_achievement_id, 'dept', p_department_id, 'period', p_period_id, 'title', p_title, 'v', p_expected_version,
    'desc', p_description, 'impact', p_impact_text, 'ben', p_beneficiary, 'task', p_linked_task_id,
    'm', p_linked_measurement_id, 'contrib', p_contributor_department_ids));
  if v_prior is not null then return v_prior; end if;

  select * into v_dept from public.departments where id = p_department_id;
  if v_dept.id is null or not private.is_department_member(v_dept.id) then
    -- Not a member: unknown and unauthorized look the same (HC-120), except for readers who may see it.
    if v_dept.id is not null and private.can_view_department(v_dept.organization_id, v_dept.id) then
      perform private.fail('HC_FORBIDDEN');
    end if;
    perform private.fail('HC_NOT_FOUND');
  end if;
  select * into v_period from public.reporting_periods where id = p_period_id and organization_id = v_dept.organization_id;
  if v_period.id is null then perform private.fail('HC_NOT_FOUND'); end if;
  if v_period.state = 'frozen' then perform private.fail('HC_PERIOD_FROZEN'); end if;

  if p_title is null or length(btrim(p_title)) < 3 then v_errors := v_errors || '{"title":"too_short"}'; end if;
  if p_linked_task_id is not null and not exists (
       select 1 from public.tasks t where t.id = p_linked_task_id and t.department_id = v_dept.id and t.status = 'completed') then
    v_errors := v_errors || '{"linked_task_id":"must_be_completed_task_of_department"}';
  end if;
  if p_linked_measurement_id is not null and not exists (
       select 1 from public.indicator_measurements m where m.id = p_linked_measurement_id
          and m.department_id = v_dept.id and m.status = 'approved') then
    v_errors := v_errors || '{"linked_measurement_id":"must_be_approved_reading_of_department"}';
  end if;
  if exists (select 1 from unnest(coalesce(p_contributor_department_ids, '{}')) c
             where c = v_dept.id or not exists (select 1 from public.departments d where d.id = c
                     and d.organization_id = v_dept.organization_id and d.archived_at is null)) then
    v_errors := v_errors || '{"contributor_department_ids":"invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('fields', v_errors)); end if;

  begin
    if p_achievement_id is null then
      insert into public.achievements (organization_id, department_id, period_id, title, description, impact_text,
        beneficiary, linked_task_id, linked_measurement_id, created_by)
      values (v_dept.organization_id, v_dept.id, v_period.id, btrim(p_title), coalesce(p_description, ''),
        coalesce(p_impact_text, ''), nullif(btrim(coalesce(p_beneficiary, '')), ''), p_linked_task_id,
        p_linked_measurement_id, v_actor)
      returning * into v_a;
    else
      select * into v_a from public.achievements where id = p_achievement_id for update;
      if v_a.id is null or v_a.department_id <> v_dept.id then perform private.fail('HC_NOT_FOUND'); end if;
      if v_a.version is distinct from p_expected_version then
        perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_a.version));
      end if;
      if v_a.status not in ('draft', 'returned') then
        perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_editable"}');
      end if;
      v_before := private.achievement_json(v_a);
      update public.achievements set title = btrim(p_title), description = coalesce(p_description, ''),
        impact_text = coalesce(p_impact_text, ''), beneficiary = nullif(btrim(coalesce(p_beneficiary, '')), ''),
        period_id = v_period.id, linked_task_id = p_linked_task_id, linked_measurement_id = p_linked_measurement_id
       where id = v_a.id returning * into v_a;
    end if;
  exception when unique_violation then
    -- §16: the same task cannot be published twice in one period.
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"linked_task_id":"already_used_in_period"}}');
  end;

  delete from public.achievement_contributors where achievement_id = v_a.id;
  foreach v_c in array coalesce(p_contributor_department_ids, '{}') loop
    insert into public.achievement_contributors (organization_id, achievement_id, department_id)
    values (v_a.organization_id, v_a.id, v_c) on conflict do nothing;
  end loop;

  perform private.audit(v_a.organization_id, v_a.department_id, v_actor, 'achievement', v_a.id,
    case when p_achievement_id is null then 'create' else 'update' end, v_before, private.achievement_json(v_a), null, p_request_id);
  return private.idem_finish(v_actor, 'save_achievement', p_request_id, private.achievement_json(v_a));
end;
$$;

-- ---------------------------------------------------------------------------
-- submit_achievement: the department head sends it for the director's decision.
-- ---------------------------------------------------------------------------
create or replace function public.submit_achievement(p_achievement_id uuid, p_expected_version int, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_a public.achievements;
  v_before jsonb;
  r record;
begin
  v_prior := private.idem_begin(v_actor, 'submit_achievement', p_request_id,
    jsonb_build_object('id', p_achievement_id, 'v', p_expected_version));
  if v_prior is not null then return v_prior; end if;
  select * into v_a from public.achievements where id = p_achievement_id for update;
  if v_a.id is null or not private.can_read_achievement(v_a.id) then perform private.fail('HC_NOT_FOUND'); end if;
  if not ('department_head' = any (private.dept_roles(v_a.department_id))) then
    perform private.fail('HC_FORBIDDEN', '{"reason":"only_department_head_submits"}');
  end if;
  if v_a.version <> p_expected_version then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_a.version));
  end if;
  if v_a.status not in ('draft', 'returned') then perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_submittable"}'); end if;
  -- §16: the impact must be stated before review.
  if length(btrim(v_a.impact_text)) < 3 then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"impact_text":"required"}}');
  end if;
  v_before := private.achievement_json(v_a);
  update public.achievements set status = 'submitted', submitted_at = now() where id = v_a.id returning * into v_a;
  perform private.audit(v_a.organization_id, v_a.department_id, v_actor, 'achievement', v_a.id, 'submit',
    v_before, private.achievement_json(v_a), null, p_request_id);
  for r in select m.user_id from public.organization_memberships m
           where m.organization_id = v_a.organization_id and m.role = 'hospital_director' and m.active loop
    perform private.notify(v_a.organization_id, r.user_id, 'decision_needed',
                           'achievement_submitted:' || v_a.id || ':' || v_a.version, 'achievement', v_a.id);
  end loop;
  return private.idem_finish(v_actor, 'submit_achievement', p_request_id, private.achievement_json(v_a));
end;
$$;

-- ---------------------------------------------------------------------------
-- API-10 decide_achievement: approve publishes it; returned/rejected need a note.
-- The director decides, never a member of the department or its author (D-07).
-- ---------------------------------------------------------------------------
create or replace function public.decide_achievement(
  p_achievement_id uuid, p_decision text, p_expected_version int, p_request_id uuid, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_a public.achievements;
  v_before jsonb;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  v_prior := private.idem_begin(v_actor, 'decide_achievement', p_request_id, jsonb_build_object(
    'id', p_achievement_id, 'decision', p_decision, 'v', p_expected_version, 'note', p_note));
  if v_prior is not null then return v_prior; end if;
  select * into v_a from public.achievements where id = p_achievement_id for update;
  if v_a.id is null or not private.can_read_achievement(v_a.id) then perform private.fail('HC_NOT_FOUND'); end if;
  if not private.has_org_role(v_a.organization_id, array['hospital_director'])
     or private.is_department_member(v_a.department_id) or v_a.created_by = v_actor then
    perform private.fail('HC_FORBIDDEN');
  end if;
  if p_decision not in ('approved', 'returned', 'rejected') then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"decision":"invalid"}}');
  end if;
  if p_decision <> 'approved' and (v_note is null or length(v_note) < 3) then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"note":"required"}}');
  end if;
  if v_a.version <> p_expected_version then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_a.version));
  end if;
  if v_a.status <> 'submitted' then perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_submitted"}'); end if;

  v_before := private.achievement_json(v_a);
  update public.achievements set status = p_decision,
    approved_by = case when p_decision = 'approved' then v_actor end,
    approved_at = case when p_decision = 'approved' then now() end
   where id = v_a.id returning * into v_a;
  insert into public.achievement_reviews (organization_id, achievement_id, reviewer_id, decision, note, request_id)
  values (v_a.organization_id, v_a.id, v_actor, p_decision, v_note, p_request_id);
  perform private.audit(v_a.organization_id, v_a.department_id, v_actor, 'achievement', v_a.id, 'decide_' || p_decision,
    v_before, private.achievement_json(v_a), v_note, p_request_id);
  perform private.notify(v_a.organization_id, v_a.created_by, 'achievement_decided',
                         'achievement_decided:' || v_a.id || ':' || v_a.version, 'achievement', v_a.id);
  return private.idem_finish(v_actor, 'decide_achievement', p_request_id, private.achievement_json(v_a));
end;
$$;

-- Grants
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;
revoke execute on function private.achievement_json(public.achievements) from authenticated;
grant execute on function
  public.save_achievement(uuid, uuid, text, uuid, uuid, int, text, text, text, uuid, uuid, uuid[]),
  public.submit_achievement(uuid, int, uuid),
  public.decide_achievement(uuid, text, int, uuid, text)
to authenticated;
