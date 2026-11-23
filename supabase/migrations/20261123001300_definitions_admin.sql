-- G4–G5 definitions from the app (spec §09, §10, §14, §15; D-29).
-- Defining obligations (report templates, schedules) and measures (indicators)
-- is a director decision (§03 table: system admin "not automatically").
-- Every function: live director check, idempotent request_id, audit.

create or replace function private.require_director(p_org uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_org_member(p_org) then perform private.fail('HC_NOT_FOUND'); end if;
  if not private.has_org_role(p_org, array['hospital_director']) then perform private.fail('HC_FORBIDDEN'); end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Periods: ensure the current month exists (open). Idempotent.
-- ---------------------------------------------------------------------------
create or replace function private.ensure_month_period(p_org uuid, p_tz text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_start date := date_trunc('month', (now() at time zone p_tz))::date;
  v_id uuid;
begin
  insert into public.reporting_periods (organization_id, type, start_date, end_date, state, timezone)
  values (p_org, 'monthly', v_start, (v_start + interval '1 month - 1 day')::date, 'open', p_tz)
  on conflict (organization_id, type, start_date) do nothing;
  select id into v_id from public.reporting_periods where organization_id = p_org and type = 'monthly' and start_date = v_start;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Report templates (+ version 1). Fields: [{"key":"summary","label":"الملخص","required":true}, ...]
-- ---------------------------------------------------------------------------
create or replace function public.create_report_template(
  p_organization_id uuid, p_name_ar text, p_frequency text, p_fields jsonb, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_errors jsonb := '{}'::jsonb;
  v_t public.report_templates;
  v_v public.report_template_versions;
  v_required text[];
begin
  v_prior := private.idem_begin(v_actor, 'create_report_template', p_request_id, jsonb_build_object(
    'org', p_organization_id, 'name', p_name_ar, 'freq', p_frequency, 'fields', p_fields));
  if v_prior is not null then return v_prior; end if;
  perform private.require_director(p_organization_id);

  if p_name_ar is null or length(btrim(p_name_ar)) < 3 then v_errors := v_errors || '{"name_ar":"too_short"}'; end if;
  if p_frequency not in ('weekly', 'monthly', 'quarterly', 'annual') then v_errors := v_errors || '{"frequency":"invalid"}'; end if;
  if p_fields is null or jsonb_typeof(p_fields) <> 'array' or jsonb_array_length(p_fields) = 0 or jsonb_array_length(p_fields) > 30 then
    v_errors := v_errors || '{"fields":"one_to_thirty_fields"}';
  elsif exists (select 1 from jsonb_array_elements(p_fields) f
                where coalesce(f ->> 'key', '') !~ '^[a-z][a-z0-9_]{0,39}$' or length(btrim(coalesce(f ->> 'label', ''))) < 2) then
    v_errors := v_errors || '{"fields":"each_needs_key_and_label"}';
  elsif (select count(distinct f ->> 'key') from jsonb_array_elements(p_fields) f) <> jsonb_array_length(p_fields) then
    v_errors := v_errors || '{"fields":"duplicate_keys"}';
  end if;
  if v_errors <> '{}'::jsonb then perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('fields', v_errors)); end if;

  select coalesce(array_agg(f ->> 'key'), '{}') into v_required
    from jsonb_array_elements(p_fields) f where coalesce((f ->> 'required')::boolean, false);

  insert into public.report_templates (organization_id, name_ar, frequency, created_by)
  values (p_organization_id, btrim(p_name_ar), p_frequency, v_actor) returning * into v_t;
  insert into public.report_template_versions (organization_id, template_id, revision, field_schema, required_fields, created_by)
  values (p_organization_id, v_t.id, 1, jsonb_build_object('fields', p_fields), v_required, v_actor) returning * into v_v;
  update public.report_templates set current_version_id = v_v.id where id = v_t.id returning * into v_t;

  perform private.audit(p_organization_id, null, v_actor, 'report_template', v_t.id, 'create', null,
    jsonb_build_object('name_ar', v_t.name_ar, 'frequency', v_t.frequency, 'fields', jsonb_array_length(p_fields)), null, p_request_id);
  return private.idem_finish(v_actor, 'create_report_template', p_request_id,
    jsonb_build_object('template_id', v_t.id, 'template_version_id', v_v.id, 'name_ar', v_t.name_ar, 'frequency', v_t.frequency));
end;
$$;

-- ---------------------------------------------------------------------------
-- Schedule a template for departments: due on day N of the next period.
-- ---------------------------------------------------------------------------
create or replace function public.schedule_report(
  p_template_id uuid, p_department_ids uuid[], p_due_day int, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_t public.report_templates;
  v_org public.organizations;
  v_from date;
  v_count int := 0;
  v_dept uuid;
begin
  v_prior := private.idem_begin(v_actor, 'schedule_report', p_request_id, jsonb_build_object(
    'template', p_template_id, 'depts', p_department_ids, 'day', p_due_day));
  if v_prior is not null then return v_prior; end if;

  select * into v_t from public.report_templates where id = p_template_id;
  if v_t.id is null then perform private.fail('HC_NOT_FOUND'); end if;
  perform private.require_director(v_t.organization_id);
  select * into v_org from public.organizations where id = v_t.organization_id;
  if p_due_day is null or p_due_day not between 1 and 28 then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"due_day":"between_1_and_28"}}');
  end if;
  if p_department_ids is null or cardinality(p_department_ids) = 0 then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"department_ids":"required"}}');
  end if;
  if exists (select 1 from unnest(p_department_ids) d
             where not exists (select 1 from public.departments x where x.id = d and x.organization_id = v_t.organization_id
                                 and x.archived_at is null)) then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"department_ids":"not_found_or_archived"}}');
  end if;

  v_from := date_trunc('month', (now() at time zone v_org.timezone))::date;
  foreach v_dept in array p_department_ids loop
    insert into public.report_schedules (organization_id, template_version_id, department_id, recurrence, due_rule, active_from, created_by)
    values (v_t.organization_id, v_t.current_version_id, v_dept, v_t.frequency,
            jsonb_build_object('kind', 'day_of_next_period', 'day', p_due_day, 'local_time', '23:59'), v_from, v_actor)
    on conflict (template_version_id, department_id, recurrence, active_from) do nothing;
    if found then v_count := v_count + 1; end if;
  end loop;
  perform private.audit(v_t.organization_id, null, v_actor, 'report_template', v_t.id, 'schedule', null,
    jsonb_build_object('departments', cardinality(p_department_ids), 'due_day', p_due_day), null, p_request_id);
  return private.idem_finish(v_actor, 'schedule_report', p_request_id,
    jsonb_build_object('template_id', v_t.id, 'scheduled', v_count, 'active_from', v_from));
end;
$$;

-- ---------------------------------------------------------------------------
-- Director-triggered generation for a period (the scheduler stays idempotent).
-- ---------------------------------------------------------------------------
create or replace function public.generate_reports_for_period(p_period_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_p public.reporting_periods;
  v_res jsonb;
begin
  select * into v_p from public.reporting_periods where id = p_period_id;
  if v_p.id is null then perform private.fail('HC_NOT_FOUND'); end if;
  perform private.require_director(v_p.organization_id);
  if v_p.state = 'frozen' then perform private.fail('HC_PERIOD_FROZEN'); end if;
  v_res := public.generate_report_instances(p_period_id);
  perform private.audit(v_p.organization_id, null, v_actor, 'reporting_period', v_p.id, 'generate_reports', null, v_res, null, null);
  return v_res;
end;
$$;

create or replace function public.ensure_current_period(p_organization_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_org public.organizations;
  v_id uuid;
begin
  perform private.require_director(p_organization_id);
  select * into v_org from public.organizations where id = p_organization_id;
  v_id := private.ensure_month_period(p_organization_id, v_org.timezone);
  return jsonb_build_object('period_id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Indicators: definition + approved version 1 (director defines = approves).
-- ---------------------------------------------------------------------------
create or replace function public.create_indicator(
  p_organization_id uuid, p_department_id uuid, p_code text, p_title text,
  p_measurement_type text, p_unit text, p_direction text, p_aggregation text, p_frequency text,
  p_data_source text, p_request_id uuid,
  p_target numeric default null, p_range_min numeric default null, p_range_max numeric default null,
  p_numerator_description text default null, p_denominator_description text default null,
  p_weight numeric default 1, p_zero_event_rule boolean default false, p_description text default '')
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_errors jsonb := '{}'::jsonb;
  v_org public.organizations;
  v_d public.indicator_definitions;
  v_v public.indicator_definition_versions;
begin
  v_prior := private.idem_begin(v_actor, 'create_indicator', p_request_id, jsonb_build_object(
    'org', p_organization_id, 'dept', p_department_id, 'code', p_code, 'title', p_title, 'type', p_measurement_type,
    'unit', p_unit, 'dir', p_direction, 'agg', p_aggregation, 'freq', p_frequency, 'src', p_data_source,
    'target', p_target, 'min', p_range_min, 'max', p_range_max, 'num', p_numerator_description,
    'den', p_denominator_description, 'w', p_weight, 'zero', p_zero_event_rule));
  if v_prior is not null then return v_prior; end if;
  perform private.require_director(p_organization_id);
  select * into v_org from public.organizations where id = p_organization_id;

  if not exists (select 1 from public.departments d where d.id = p_department_id and d.organization_id = p_organization_id and d.archived_at is null) then
    v_errors := v_errors || '{"department_id":"not_found"}';
  end if;
  if v_code !~ '^[A-Z0-9][A-Z0-9_.-]{0,31}$' then v_errors := v_errors || '{"code":"invalid_format"}';
  elsif exists (select 1 from public.indicator_definitions i where i.organization_id = p_organization_id and i.code = v_code) then
    v_errors := v_errors || '{"code":"already_used"}';
  end if;
  if p_title is null or length(btrim(p_title)) < 3 then v_errors := v_errors || '{"title":"too_short"}'; end if;
  if p_data_source is null or length(btrim(p_data_source)) < 2 then v_errors := v_errors || '{"data_source":"required"}'; end if;
  if p_unit is null or length(btrim(p_unit)) < 1 then v_errors := v_errors || '{"unit":"required"}'; end if;
  if v_errors <> '{}'::jsonb then perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('fields', v_errors)); end if;

  insert into public.indicator_definitions (organization_id, department_id, code, title, description, created_by)
  values (p_organization_id, p_department_id, v_code, btrim(p_title), coalesce(p_description, ''), v_actor)
  returning * into v_d;
  begin
    -- The table's CHECK constraints encode the §11 rules (target>0 for higher-is-better,
    -- ranges, zero-event rule, ratio descriptions, ratio_of_sums only for ratios).
    insert into public.indicator_definition_versions (organization_id, definition_id, revision, measurement_type, unit,
      direction, aggregation, frequency, zero_event_rule, numerator_description, denominator_description, data_source,
      target, range_min, range_max, weight, valid_from, approved_by, approved_at, created_by)
    values (p_organization_id, v_d.id, 1, p_measurement_type, btrim(p_unit), p_direction, p_aggregation, p_frequency,
      coalesce(p_zero_event_rule, false), nullif(btrim(coalesce(p_numerator_description, '')), ''),
      nullif(btrim(coalesce(p_denominator_description, '')), ''), btrim(p_data_source),
      p_target, p_range_min, p_range_max, coalesce(p_weight, 1),
      date_trunc('month', (now() at time zone v_org.timezone))::date, v_actor, now(), v_actor)
    returning * into v_v;
  exception when check_violation then
    perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object('definition', 'inconsistent_rule')));
  end;
  update public.indicator_definitions set current_version_id = v_v.id where id = v_d.id;
  perform private.audit(p_organization_id, p_department_id, v_actor, 'indicator_definition', v_d.id, 'create', null,
    jsonb_build_object('code', v_code, 'direction', p_direction, 'target', p_target), null, p_request_id);
  return private.idem_finish(v_actor, 'create_indicator', p_request_id,
    jsonb_build_object('definition_id', v_d.id, 'definition_version_id', v_v.id, 'code', v_code));
end;
$$;

-- ---------------------------------------------------------------------------
-- Daily maintenance (hosted: pg_cron): current month period + report instances.
-- ---------------------------------------------------------------------------
create or replace function private.daily_maintenance()
returns void language plpgsql security definer set search_path = '' as $$
declare r record; v_period uuid;
begin
  for r in select id, timezone from public.organizations where active loop
    v_period := private.ensure_month_period(r.id, r.timezone);
    perform public.generate_report_instances(v_period);
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    if exists (select 1 from cron.job where jobname = 'hadctrl-daily') then
      perform cron.unschedule('hadctrl-daily');
    end if;
    -- 00:10 Asia/Riyadh = 21:10 UTC.
    perform cron.schedule('hadctrl-daily', '10 21 * * *', 'select private.daily_maintenance()');
  else
    raise notice 'pg_cron not available here; daily maintenance must be scheduled on the hosted project';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;
revoke execute on function private.require_director(uuid), private.ensure_month_period(uuid, text), private.daily_maintenance()
  from authenticated;
grant execute on function
  public.create_report_template(uuid, text, text, jsonb, uuid),
  public.schedule_report(uuid, uuid[], int, uuid),
  public.generate_reports_for_period(uuid),
  public.ensure_current_period(uuid),
  public.create_indicator(uuid, uuid, text, text, text, text, text, text, text, text, uuid, numeric, numeric, numeric, text, text, numeric, boolean, text)
to authenticated;
