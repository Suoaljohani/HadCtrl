-- API-01 dashboard_snapshot. Spec §06, §11, §17.
-- SECURITY INVOKER: every count is computed from rows the caller may read,
-- so the dashboard can never reveal more than the detail screens (§25).
-- STABLE: all queries share the calling statement's snapshot, so a report can
-- never be both "approved" and "awaiting approval" in one document.

create or replace function public.dashboard_snapshot(p_period_id uuid)
returns jsonb
language plpgsql stable security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_p public.reporting_periods;
  v_is_director boolean;
  v_now timestamptz := now();
  v_items jsonb;
  v_cov_required numeric;
  v_cov_covered numeric;
  v_cov_weighted numeric;
  v_coverage numeric;
  v_verdict text;
begin
  if v_uid is null then perform private.fail('HC_AUTH_REQUIRED'); end if;
  if not private.actor_active() then perform private.fail('HC_MEMBERSHIP_INACTIVE'); end if;
  select * into v_p from public.reporting_periods where id = p_period_id;  -- RLS: own org only
  if v_p.id is null then perform private.fail('HC_NOT_FOUND'); end if;
  v_is_director := private.has_org_role(v_p.organization_id, array['hospital_director']);

  -- Indicator coverage over visible, active indicators with an approved version.
  with req as (
    select d.id, d.department_id, v.weight, v.direction, v.measurement_type, v.target, v.range_min, v.range_max,
           v.range_inclusive, v.zero_event_rule, v.id as version_id
    from public.indicator_definitions d
    join public.indicator_definition_versions v on v.id = d.current_version_id
    where d.organization_id = v_p.organization_id and d.active and v.approved_at is not null and v.valid_from <= v_p.end_date
  ), scored as (
    select r.weight, s.score, s.state
    from req r
    left join public.indicator_measurements m
      on m.definition_version_id = r.version_id and m.period_id = v_p.id and m.status = 'approved'
    left join lateral private.indicator_score(r.direction, r.measurement_type, r.target, r.range_min, r.range_max,
                                              r.range_inclusive, r.zero_event_rule, m.value, m.numerator, m.denominator,
                                              m.not_applicable_reason is not null) s on m.id is not null
  )
  select coalesce(sum(weight), 0),
         coalesce(sum(weight) filter (where state in ('score', 'out_of_range')), 0),
         coalesce(sum(weight * score) filter (where state in ('score', 'out_of_range')), 0)
    into v_cov_required, v_cov_covered, v_cov_weighted
  from scored;
  v_coverage := case when v_cov_required > 0 then v_cov_covered / v_cov_required * 100 else 0 end;
  v_verdict := case
    when v_cov_required = 0 or v_coverage < 80 then 'insufficient_data'
    when v_coverage < 100 then 'provisional'
    when v_p.state = 'frozen' then 'final'
    else 'complete_but_open' end;

  -- Up to 10 actionable items, ordered by an explicit rule (§06):
  -- 0 urgent blocker, 1 overdue, 2 ready for my approval, 3 due within 3 days.
  select coalesce(jsonb_agg(x order by x ->> 'kind_rank', x ->> 'due_at') filter (where x is not null), '[]'::jsonb)
    into v_items
  from (
    select jsonb_build_object('kind', k.kind, 'kind_rank', k.rank, 'entity_type', k.etype, 'entity_id', k.eid,
                              'title', k.title, 'department_id', k.dept, 'due_at', k.due) as x
    from (
      select 'urgent_blocker' kind, 0 rank, 'task' etype, t.id eid, t.title, t.department_id dept, t.due_at due
        from public.tasks t where t.organization_id = v_p.organization_id and t.status = 'blocked' and t.priority = 'urgent'
      union all
      select 'overdue', 1, 'task', t.id, t.title, t.department_id, t.due_at
        from public.tasks t where t.organization_id = v_p.organization_id
         and t.status in ('assigned', 'acknowledged', 'in_progress', 'returned') and t.due_at < v_now
      union all
      select 'overdue', 1, 'report', r.id, null, r.department_id, r.due_at
        from public.report_instances r where r.period_id = v_p.id and r.status in ('not_submitted', 'returned') and r.due_at < v_now
      union all
      select 'ready_for_approval', 2, 'task', t.id, t.title, t.department_id, t.due_at
        from public.tasks t where t.organization_id = v_p.organization_id and t.status = 'submitted'
         and t.assignee_id is distinct from v_uid and (v_is_director or t.creator_id = v_uid)
      union all
      select 'ready_for_approval', 2, 'report', r.id, null, r.department_id, r.due_at
        from public.report_instances r where r.period_id = v_p.id and r.status in ('submitted', 'under_review')
         and private.can_decide_report(r.organization_id, r.department_id)
      union all
      select 'due_soon', 3, 'task', t.id, t.title, t.department_id, t.due_at
        from public.tasks t where t.organization_id = v_p.organization_id
         and t.status in ('assigned', 'acknowledged', 'in_progress', 'returned')
         and t.due_at between v_now and v_now + interval '3 days' and t.assignee_id = v_uid
    ) k
    order by k.rank, k.due
    limit 10
  ) q;

  return jsonb_build_object(
    'schema_version', 1,
    'generated_at', v_now,
    'organization_id', v_p.organization_id,
    'period_id', v_p.id,
    'period_state', v_p.state,
    'coverage', jsonb_build_object(
      'required_weight', v_cov_required, 'covered_weight', v_cov_covered, 'coverage_pct', round(v_coverage, 4),
      'measured_score', case when v_cov_covered > 0 then round(v_cov_weighted / v_cov_covered, 4) end,
      'verdict', v_verdict, 'policy', 'coverage-80/v1'),
    'readings', jsonb_build_object(
      'goals_achieved', (select jsonb_build_object('numerator', count(*) filter (where lifecycle = 'completed'),
                                                   'denominator', count(*) filter (where lifecycle in ('active', 'completion_pending', 'completed')))
                         from public.goals g where g.organization_id = v_p.organization_id
                           and g.start_at::date <= v_p.end_date and g.due_at::date >= v_p.start_date),
      'indicators_updated', jsonb_build_object('numerator', v_cov_covered, 'denominator', v_cov_required, 'unit', 'weight'),
      'reports_received', (select jsonb_build_object('numerator', count(*) filter (where first_submitted_at is not null and status <> 'waived'),
                                                     'denominator', count(*) filter (where status <> 'waived'),
                                                     'waived', count(*) filter (where status = 'waived'),
                                                     'late', count(*) filter (where status <> 'waived' and coalesce(first_submitted_at, v_now) > due_at))
                           from public.report_instances r where r.period_id = v_p.id),
      'tasks_completed', (select jsonb_build_object('numerator', count(*) filter (where status = 'completed'),
                                                    'denominator', count(*) filter (where status not in ('draft', 'cancelled')),
                                                    'cancelled', count(*) filter (where status = 'cancelled'))
                          from public.tasks t where t.organization_id = v_p.organization_id
                            and t.original_due_at::date between v_p.start_date and v_p.end_date),
      'achievements_approved', (select count(*) from public.achievements a where a.period_id = v_p.id and a.status = 'approved'),
      'awaiting_my_decision', (select count(*) from jsonb_array_elements(v_items) e where e ->> 'kind' = 'ready_for_approval')),
    'actions', v_items,
    'departments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'department_id', d.id, 'code', d.code, 'name_ar', d.name_ar, 'archived', d.archived_at is not null,
        'open_tasks', (select count(*) from public.tasks t where t.department_id = d.id and t.status not in ('draft', 'completed', 'cancelled')),
        'overdue_tasks', (select count(*) from public.tasks t where t.department_id = d.id
                            and t.status in ('assigned', 'acknowledged', 'in_progress', 'blocked', 'returned') and t.due_at < v_now),
        'reports_pending', (select count(*) from public.report_instances r where r.department_id = d.id and r.period_id = v_p.id
                              and r.status in ('not_submitted', 'returned')))
        order by d.sort_order, d.name_ar)
      from public.departments d where d.organization_id = v_p.organization_id and d.archived_at is null), '[]'::jsonb));
end;
$$;

grant execute on function public.dashboard_snapshot(uuid) to authenticated;
-- Invoker functions above call these helpers as the caller.
grant execute on function private.can_decide_report(uuid, uuid) to authenticated;
grant execute on function private.indicator_score(text, text, numeric, numeric, numeric, boolean, boolean, numeric, numeric, numeric, boolean) to authenticated;
grant execute on function private.fail(text, jsonb) to authenticated;
