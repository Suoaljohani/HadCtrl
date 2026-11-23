-- G5 indicators: measurement revisions, review, corrections after freeze,
-- period freeze with immutable snapshot, server-side scoring (mirrors
-- HadCtrl/Domain/IndicatorScoring.swift). Spec §10, §11, §15; API-06/07/13; AC-020.

-- Normalized score 0..100, or NULL when not updated / not computable.
-- Returns (score, state) where state ∈ score | not_updated | not_computable | out_of_range.
create or replace function private.indicator_score(
  p_direction text, p_measurement_type text, p_target numeric, p_range_min numeric, p_range_max numeric,
  p_range_inclusive boolean, p_zero_event boolean,
  p_value numeric, p_numerator numeric, p_denominator numeric, p_not_applicable boolean default false,
  out score numeric, out state text)
language plpgsql immutable
set search_path = ''
as $$
declare
  v_actual numeric;
begin
  if p_not_applicable then score := null; state := 'not_computable'; return; end if;
  if p_measurement_type = 'ratio' then
    if p_numerator is null or p_denominator is null then score := null; state := 'not_updated'; return; end if;
    if p_denominator <= 0 then score := null; state := 'not_computable'; return; end if;
    v_actual := p_numerator / p_denominator * 100;
  else
    if p_value is null then score := null; state := 'not_updated'; return; end if;
    v_actual := p_value;
  end if;
  if v_actual < 0 then score := null; state := 'not_computable'; return; end if;

  if p_direction = 'higher_is_better' then
    if p_target is null or p_target <= 0 then score := null; state := 'not_computable'; return; end if;
    score := least(100, v_actual / p_target * 100);
  elsif p_direction = 'lower_is_better' then
    if p_zero_event then
      score := case when v_actual = 0 then 100 else 0 end;
    elsif p_target is null or p_target <= 0 then
      score := null; state := 'not_computable'; return;
    elsif v_actual = 0 then
      score := 100;
    else
      score := least(100, p_target / v_actual * 100);
    end if;
  else -- within_range
    if (p_range_inclusive and v_actual between p_range_min and p_range_max)
       or (not p_range_inclusive and v_actual > p_range_min and v_actual < p_range_max) then
      score := 100;
    else
      score := 0; state := 'out_of_range'; return;
    end if;
  end if;
  state := 'score';
end;
$$;

create or replace function private.measurement_json(m public.indicator_measurements)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('measurement_id', m.id, 'status', m.status, 'revision', m.revision, 'version', m.version,
    'value', m.value, 'numerator', m.numerator, 'denominator', m.denominator,
    'supersedes_id', m.supersedes_id, 'submitted_at', m.submitted_at, 'approved_at', m.approved_at)
$$;

-- ---------------------------------------------------------------------------
-- API-06 submit_measurement
-- ---------------------------------------------------------------------------
create or replace function public.submit_measurement(
  p_definition_version_id uuid,
  p_period_id uuid,
  p_request_id uuid,
  p_value numeric default null,
  p_numerator numeric default null,
  p_denominator numeric default null,
  p_not_applicable_reason text default null,
  p_source_note text default null,
  p_correction_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_dv public.indicator_definition_versions;
  v_def public.indicator_definitions;
  v_period public.reporting_periods;
  v_approved public.indicator_measurements;
  v_m public.indicator_measurements;
  v_na text := nullif(btrim(coalesce(p_not_applicable_reason, '')), '');
begin
  v_prior := private.idem_begin(v_actor, 'submit_measurement', p_request_id, jsonb_build_object(
    'dv', p_definition_version_id, 'period', p_period_id, 'value', p_value, 'n', p_numerator, 'd', p_denominator,
    'na', p_not_applicable_reason, 'src', p_source_note, 'corr', p_correction_reason));
  if v_prior is not null then return v_prior; end if;

  select * into v_dv from public.indicator_definition_versions where id = p_definition_version_id;
  select * into v_def from public.indicator_definitions where id = v_dv.definition_id;
  if v_def.id is null or not private.can_view_department(v_def.organization_id, v_def.department_id) then
    perform private.fail('HC_NOT_FOUND');
  end if;
  if not ('department_head' = any (private.dept_roles(v_def.department_id))) then
    perform private.fail('HC_FORBIDDEN', '{"reason":"only_department_head_submits"}');
  end if;
  select * into v_period from public.reporting_periods
   where id = p_period_id and organization_id = v_def.organization_id for update;
  if v_period.id is null then perform private.fail('HC_NOT_FOUND'); end if;
  if v_dv.approved_at is null or v_dv.valid_from > v_period.end_date then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"definition_version_id":"not_valid_for_period"}}');
  end if;

  -- Input checks by measurement type (§10).
  if v_na is not null then
    if p_value is not null or p_numerator is not null or p_denominator is not null then
      perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"not_applicable_reason":"no_values_allowed"}}');
    end if;
  elsif v_dv.measurement_type = 'ratio' then
    if p_numerator is null or p_denominator is null or p_value is not null then
      perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"numerator":"required","denominator":"required"}}');
    end if;
    if p_numerator < 0 or p_denominator < 0 then
      perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"denominator":"non_negative"}}');
    end if;
  else
    if p_value is null or p_numerator is not null or p_denominator is not null then
      perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"value":"required"}}');
    end if;
  end if;

  perform 1 from public.indicator_measurements
   where definition_version_id = v_dv.id and period_id = v_period.id for update;
  if exists (select 1 from public.indicator_measurements
             where definition_version_id = v_dv.id and period_id = v_period.id and status in ('draft', 'submitted')) then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"period_id":"open_revision_exists"}}');
  end if;
  select * into v_approved from public.indicator_measurements
   where definition_version_id = v_dv.id and period_id = v_period.id and status = 'approved';
  -- A frozen period accepts only explicit corrections of an approved value (AC-020).
  if v_period.state = 'frozen' and (v_approved.id is null or length(btrim(coalesce(p_correction_reason, ''))) < 3) then
    perform private.fail('HC_PERIOD_FROZEN');
  end if;
  if v_approved.id is not null and length(btrim(coalesce(p_correction_reason, ''))) < 3 then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"correction_reason":"required_to_replace_approved"}}');
  end if;

  insert into public.indicator_measurements (organization_id, department_id, definition_version_id, period_id, revision,
    value, numerator, denominator, not_applicable_reason, status, source_note, entered_by, submitted_at, supersedes_id)
  values (v_def.organization_id, v_def.department_id, v_dv.id, v_period.id,
    coalesce((select max(revision) from public.indicator_measurements where definition_version_id = v_dv.id and period_id = v_period.id), 0) + 1,
    p_value, p_numerator, p_denominator, v_na, 'submitted', p_source_note, v_actor, now(), v_approved.id)
  returning * into v_m;
  perform private.audit(v_m.organization_id, v_m.department_id, v_actor, 'indicator_measurement', v_m.id,
                        case when v_approved.id is null then 'submit' else 'submit_correction' end,
                        null, private.measurement_json(v_m), p_correction_reason, p_request_id);
  return private.idem_finish(v_actor, 'submit_measurement', p_request_id, private.measurement_json(v_m));
end;
$$;

-- ---------------------------------------------------------------------------
-- API-07 decide_measurement
-- ---------------------------------------------------------------------------
create or replace function public.decide_measurement(
  p_measurement_id uuid, p_decision text, p_expected_version int, p_request_id uuid, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_m public.indicator_measurements;
  v_before jsonb;
begin
  v_prior := private.idem_begin(v_actor, 'decide_measurement', p_request_id, jsonb_build_object(
    'id', p_measurement_id, 'decision', p_decision, 'v', p_expected_version, 'note', p_note));
  if v_prior is not null then return v_prior; end if;

  select * into v_m from public.indicator_measurements where id = p_measurement_id for update;
  if v_m.id is null or not private.can_operate_department(v_m.organization_id, v_m.department_id) or v_m.status = 'draft' then
    perform private.fail('HC_NOT_FOUND');
  end if;
  if private.is_department_member(v_m.department_id) or v_m.entered_by = v_actor
     or not private.has_org_role(v_m.organization_id, array['hospital_director']) then
    perform private.fail('HC_FORBIDDEN');
  end if;
  if v_m.version <> p_expected_version then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_m.version));
  end if;
  if v_m.status <> 'submitted' then perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_submitted"}'); end if;
  if p_decision not in ('approved', 'returned') then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"decision":"invalid"}}');
  end if;
  if p_decision = 'returned' and length(btrim(coalesce(p_note, ''))) < 3 then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"note":"required"}}');
  end if;

  v_before := private.measurement_json(v_m);
  if p_decision = 'approved' then
    -- The previous approved revision becomes superseded, never deleted.
    update public.indicator_measurements set status = 'superseded'
     where definition_version_id = v_m.definition_version_id and period_id = v_m.period_id and status = 'approved';
    update public.indicator_measurements set status = 'approved', approved_at = now(), approved_by = v_actor
     where id = v_m.id returning * into v_m;
  else
    update public.indicator_measurements set status = 'returned' where id = v_m.id returning * into v_m;
  end if;
  perform private.audit(v_m.organization_id, v_m.department_id, v_actor, 'indicator_measurement', v_m.id, p_decision,
                        v_before, private.measurement_json(v_m), p_note, p_request_id);
  return private.idem_finish(v_actor, 'decide_measurement', p_request_id, private.measurement_json(v_m));
end;
$$;

-- ---------------------------------------------------------------------------
-- API-13 freeze_period: immutable snapshot of approved results.
-- ---------------------------------------------------------------------------
create or replace function public.freeze_period(p_period_id uuid, p_expected_version int, p_reason text, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_p public.reporting_periods;
  v_payload jsonb;
  v_rev int;
  v_res jsonb;
begin
  v_prior := private.idem_begin(v_actor, 'freeze_period', p_request_id,
    jsonb_build_object('period', p_period_id, 'v', p_expected_version, 'reason', p_reason));
  if v_prior is not null then return v_prior; end if;
  select * into v_p from public.reporting_periods where id = p_period_id for update;
  if v_p.id is null or not private.is_org_member(v_p.organization_id) then perform private.fail('HC_NOT_FOUND'); end if;
  if not private.has_org_role(v_p.organization_id, array['hospital_director']) then perform private.fail('HC_FORBIDDEN'); end if;
  if v_p.version <> p_expected_version then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_p.version));
  end if;
  if v_p.state = 'frozen' then perform private.fail('HC_PERIOD_FROZEN'); end if;

  v_payload := jsonb_build_object(
    'measurements', coalesce((select jsonb_agg(jsonb_build_object(
        'measurement_id', m.id, 'department_id', m.department_id, 'definition_version_id', m.definition_version_id,
        'revision', m.revision, 'value', m.value, 'numerator', m.numerator, 'denominator', m.denominator) order by m.id)
      from public.indicator_measurements m where m.period_id = v_p.id and m.status = 'approved'), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(jsonb_build_object(
        'report_id', r.id, 'department_id', r.department_id, 'status', r.status, 'due_at', r.due_at,
        'first_submitted_at', r.first_submitted_at, 'approved_revision_id', r.approved_revision_id) order by r.id)
      from public.report_instances r where r.period_id = v_p.id), '[]'::jsonb),
    'reason', p_reason);
  select coalesce(max(snapshot_revision), 0) + 1 into v_rev from public.period_snapshots where period_id = v_p.id;
  insert into public.period_snapshots (organization_id, period_id, policy_version, snapshot_revision, frozen_by, data_hash, payload)
  values (v_p.organization_id, v_p.id, 'coverage-80/v1', v_rev, v_actor, md5(v_payload::text), v_payload);
  update public.reporting_periods set state = 'frozen', frozen_at = now(), frozen_by = v_actor where id = v_p.id returning * into v_p;
  perform private.audit(v_p.organization_id, null, v_actor, 'reporting_period', v_p.id, 'freeze', null,
                        jsonb_build_object('snapshot_revision', v_rev), p_reason, p_request_id);
  v_res := jsonb_build_object('period_id', v_p.id, 'state', v_p.state, 'version', v_p.version, 'snapshot_revision', v_rev);
  return private.idem_finish(v_actor, 'freeze_period', p_request_id, v_res);
end;
$$;

revoke execute on function private.measurement_json(public.indicator_measurements) from public, anon, authenticated;
revoke execute on function private.indicator_score(text, text, numeric, numeric, numeric, boolean, boolean, numeric, numeric, numeric, boolean)
  from public, anon, authenticated;
grant execute on function
  public.submit_measurement(uuid, uuid, uuid, numeric, numeric, numeric, text, text, text),
  public.decide_measurement(uuid, text, int, uuid, text),
  public.freeze_period(uuid, int, text, uuid)
to authenticated;
