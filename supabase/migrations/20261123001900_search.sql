-- Global search (spec §17, API-19, D-39).
--
-- One RPC returns categorized matches across departments, goals, tasks, reports,
-- achievements and indicators. Visibility is decided here, on the server, with the
-- same helpers the RLS policies use — a result the caller could not open is never
-- returned (no client-side filtering of fetched rows). Arabic spelling variants
-- (أ/إ/آ/ا, ى/ي, ة/ه, ؤ/و, ئ/ي, diacritics, tatweel) are normalized on both sides;
-- the original text is returned for display.

create or replace function private.normalize_ar(p text)
returns text language sql immutable set search_path = '' as $$
  select lower(translate(regexp_replace(coalesce(p, ''), '[ً-ْٰـ]', '', 'g'),
                         'أإآٱىةؤئ', 'اااايهوي'))
$$;

create or replace function public.search_records(p_query text, p_period_id uuid default null, p_limit integer default 8)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_q text := btrim(private.normalize_ar(p_query));
  v_like text;
  v_limit integer := least(greatest(coalesce(p_limit, 8), 1), 25);
  v_out jsonb;
begin
  if char_length(v_q) < 2 or char_length(v_q) > 80 then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"query":"length"}}');
  end if;
  -- Escape LIKE wildcards typed by the user.
  v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  select jsonb_build_object(
    'departments', coalesce((
      select jsonb_agg(x order by x ->> 'title') from (
        select jsonb_build_object('id', d.id, 'title', d.name_ar, 'subtitle', d.code,
                                  'status', case when d.archived_at is null then 'active' else 'archived' end) x
        from public.departments d
        where (private.has_org_role(d.organization_id, array['hospital_director', 'executive_viewer', 'system_admin'])
               or private.can_operate_department(d.organization_id, d.id))
          and (private.normalize_ar(d.name_ar) like v_like or lower(d.code) like v_like)
        order by d.archived_at nulls first, d.name_ar limit v_limit) s), '[]'::jsonb),
    'goals', coalesce((
      select jsonb_agg(x) from (
        select jsonb_build_object('id', g.id, 'title', g.title, 'subtitle', d.name_ar, 'status', g.lifecycle,
                                  'department_id', g.department_id) x
        from public.goals g join public.departments d on d.id = g.department_id
        where private.can_view_department(g.organization_id, g.department_id)
          and (g.lifecycle <> 'draft' or private.can_operate_department(g.organization_id, g.department_id))
          and private.normalize_ar(g.title) like v_like
        order by g.due_at desc limit v_limit) s), '[]'::jsonb),
    'tasks', coalesce((
      select jsonb_agg(x) from (
        select jsonb_build_object('id', t.id, 'title', t.title, 'subtitle', d.name_ar, 'status', t.status,
                                  'department_id', t.department_id) x
        from public.tasks t join public.departments d on d.id = t.department_id
        where private.can_read_task(t.id) and private.normalize_ar(t.title) like v_like
        order by t.due_at desc nulls last limit v_limit) s), '[]'::jsonb),
    'reports', coalesce((
      select jsonb_agg(x) from (
        select jsonb_build_object('id', r.id, 'title', rt.name_ar, 'subtitle', d.name_ar, 'status', r.status,
                                  'department_id', r.department_id, 'period_id', r.period_id) x
        from public.report_instances r
        join public.report_template_versions v on v.id = r.template_version_id
        join public.report_templates rt on rt.id = v.template_id
        join public.departments d on d.id = r.department_id
        where private.can_read_report(r.id)
          and (p_period_id is null or r.period_id = p_period_id)
          and (private.normalize_ar(rt.name_ar) like v_like or private.normalize_ar(d.name_ar) like v_like)
        order by r.due_at desc limit v_limit) s), '[]'::jsonb),
    'achievements', coalesce((
      select jsonb_agg(x) from (
        select jsonb_build_object('id', a.id, 'title', a.title, 'subtitle', d.name_ar, 'status', a.status,
                                  'department_id', a.department_id, 'period_id', a.period_id) x
        from public.achievements a join public.departments d on d.id = a.department_id
        where private.can_read_achievement(a.id)
          and (p_period_id is null or a.period_id = p_period_id)
          and private.normalize_ar(a.title) like v_like
        order by a.created_at desc limit v_limit) s), '[]'::jsonb),
    'indicators', coalesce((
      select jsonb_agg(x) from (
        select jsonb_build_object('id', i.id, 'title', i.title, 'subtitle', d.name_ar || ' · ' || i.code,
                                  'status', case when i.active then 'active' else 'inactive' end,
                                  'department_id', i.department_id) x
        from public.indicator_definitions i join public.departments d on d.id = i.department_id
        where private.can_view_department(i.organization_id, i.department_id)
          and (private.normalize_ar(i.title) like v_like or lower(i.code) like v_like)
        order by i.code limit v_limit) s), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;
revoke execute on function private.normalize_ar(text) from authenticated;
grant execute on function public.search_records(text, uuid, integer) to authenticated;
