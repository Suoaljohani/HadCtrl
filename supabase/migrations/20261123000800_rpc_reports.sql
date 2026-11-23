-- G4 recurring reports: scheduling, drafts, submission, review, waiver.
-- Spec refs: §14, §15, API-08, API-09; AC-015..AC-019.

-- Due date for a schedule in a period. Supported rules:
--   {"kind":"day_of_next_period","day":5,"local_time":"23:59"}  (clamped to month length)
--   {"kind":"end_of_period","local_time":"23:59"}
create or replace function private.report_due_at(p_rule jsonb, p_period public.reporting_periods)
returns timestamptz
language plpgsql immutable
set search_path = ''
as $$
declare
  v_time time := coalesce((p_rule ->> 'local_time')::time, time '23:59:59');
  v_next date := p_period.end_date + 1;
  v_day int;
  v_last int;
begin
  if p_rule ->> 'kind' = 'end_of_period' then
    return (p_period.end_date + v_time) at time zone p_period.timezone;
  elsif p_rule ->> 'kind' = 'day_of_next_period' then
    v_day := (p_rule ->> 'day')::int;
    v_last := extract(day from (date_trunc('month', v_next) + interval '1 month - 1 day'))::int;
    return ((date_trunc('month', v_next)::date + (least(greatest(v_day, 1), v_last) - 1)) + v_time) at time zone p_period.timezone;
  end if;
  raise exception 'HC_VALIDATION_FAILED' using detail = '{"field":"due_rule","reason":"unknown_kind"}';
end;
$$;

-- ---------------------------------------------------------------------------
-- Scheduler (server-only; run from Supabase Cron or an admin). Idempotent via
-- unique(schedule_id, department_id, period_id) — AC-018.
-- ---------------------------------------------------------------------------
create or replace function public.generate_report_instances(p_period_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_period public.reporting_periods;
  v_created int := 0;
  v_skipped int := 0;
  r record;
begin
  select * into v_period from public.reporting_periods where id = p_period_id;
  if v_period.id is null then perform private.fail('HC_NOT_FOUND'); end if;
  for r in
    select s.*, tv.template_id
    from public.report_schedules s
    join public.report_template_versions tv on tv.id = s.template_version_id
    join public.report_templates t on t.id = tv.template_id and t.active
    join public.departments d on d.id = s.department_id
    where s.organization_id = v_period.organization_id
      and s.recurrence = v_period.type
      and s.active_from <= v_period.start_date
      and (s.active_to is null or s.active_to >= v_period.end_date)
      and (d.archived_at is null or d.archived_at > (v_period.end_date + 1)::timestamptz)
  loop
    insert into public.report_instances (organization_id, department_id, period_id, schedule_id, template_version_id, due_at)
    values (r.organization_id, r.department_id, v_period.id, r.id, r.template_version_id, private.report_due_at(r.due_rule, v_period))
    on conflict (schedule_id, department_id, period_id) do nothing;
    if found then v_created := v_created + 1; else v_skipped := v_skipped + 1; end if;
  end loop;
  return jsonb_build_object('period_id', v_period.id, 'created', v_created, 'skipped_existing', v_skipped);
end;
$$;

create or replace function private.report_json(r public.report_instances)
returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object('report_id', r.id, 'status', r.status, 'version', r.version, 'due_at', r.due_at,
    'first_submitted_at', r.first_submitted_at, 'last_submitted_at', r.last_submitted_at,
    'latest_revision_id', r.latest_revision_id, 'approved_revision_id', r.approved_revision_id)
$$;

-- Who may edit drafts / submit / review a department's report.
create or replace function private.can_draft_report(p_org uuid, p_dept uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select cardinality(private.dept_roles(p_dept)) > 0
$$;
create or replace function private.can_submit_report(p_org uuid, p_dept uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select 'department_head' = any (private.dept_roles(p_dept))
      or (cardinality(private.dept_roles(p_dept)) > 0 and private.has_delegation(p_org, p_dept, array['submit_reports']))
$$;
create or replace function private.can_decide_report(p_org uuid, p_dept uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  -- A department member never approves the department's own report (§03).
  select not private.is_department_member(p_dept)
     and (private.has_org_role(p_org, array['hospital_director'])
          or private.has_delegation(p_org, p_dept, array['approve_reports']))
$$;

-- ---------------------------------------------------------------------------
-- Draft (create or update the single open draft revision)
-- ---------------------------------------------------------------------------
create or replace function public.save_report_draft(
  p_report_id uuid, p_content jsonb, p_request_id uuid, p_expected_revision_version int default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_r public.report_instances;
  v_rev public.report_revisions;
  v_res jsonb;
begin
  v_prior := private.idem_begin(v_actor, 'save_report_draft', p_request_id,
    jsonb_build_object('report_id', p_report_id, 'content', p_content, 'v', p_expected_revision_version));
  if v_prior is not null then return v_prior; end if;

  if not private.can_read_report(p_report_id) then perform private.fail('HC_NOT_FOUND'); end if;
  select * into v_r from public.report_instances where id = p_report_id for update;
  if not private.can_draft_report(v_r.organization_id, v_r.department_id) then perform private.fail('HC_FORBIDDEN'); end if;
  if v_r.status not in ('not_submitted', 'returned') then
    perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_editable"}');
  end if;
  if p_content is null or jsonb_typeof(p_content) <> 'object' then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"content":"object_required"}}');
  end if;

  select * into v_rev from public.report_revisions
   where report_id = v_r.id and state = 'draft' order by revision desc limit 1 for update;
  if v_rev.id is not null then
    if p_expected_revision_version is distinct from v_rev.version then
      perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_rev.version));
    end if;
    update public.report_revisions set content = p_content, author_id = v_actor where id = v_rev.id returning * into v_rev;
  else
    insert into public.report_revisions (organization_id, report_id, revision, content, author_id)
    values (v_r.organization_id, v_r.id,
            coalesce((select max(revision) from public.report_revisions where report_id = v_r.id), 0) + 1,
            p_content, v_actor)
    returning * into v_rev;
  end if;
  perform private.audit(v_r.organization_id, v_r.department_id, v_actor, 'report_revision', v_rev.id, 'save_draft',
                        null, jsonb_build_object('revision', v_rev.revision, 'version', v_rev.version), null, p_request_id);
  v_res := jsonb_build_object('revision_id', v_rev.id, 'revision', v_rev.revision, 'revision_version', v_rev.version,
                              'report', private.report_json(v_r));
  return private.idem_finish(v_actor, 'save_report_draft', p_request_id, v_res);
end;
$$;

-- ---------------------------------------------------------------------------
-- API-08 submit_report
-- ---------------------------------------------------------------------------
create or replace function public.submit_report(
  p_report_id uuid, p_draft_revision_id uuid, p_expected_version int, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_r public.report_instances;
  v_rev public.report_revisions;
  v_required text[];
  v_missing text[];
  v_before jsonb;
  v_director uuid;
begin
  v_prior := private.idem_begin(v_actor, 'submit_report', p_request_id,
    jsonb_build_object('report_id', p_report_id, 'revision_id', p_draft_revision_id, 'v', p_expected_version));
  if v_prior is not null then return v_prior; end if;

  if not private.can_read_report(p_report_id) then perform private.fail('HC_NOT_FOUND'); end if;
  select * into v_r from public.report_instances where id = p_report_id for update;
  if not private.can_submit_report(v_r.organization_id, v_r.department_id) then perform private.fail('HC_FORBIDDEN'); end if;
  if v_r.version <> p_expected_version then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_r.version));
  end if;
  if v_r.status not in ('not_submitted', 'returned') then
    perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_submittable"}');
  end if;
  select * into v_rev from public.report_revisions where id = p_draft_revision_id and report_id = v_r.id for update;
  if v_rev.id is null or v_rev.state <> 'draft' then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"draft_revision_id":"not_open_draft"}}');
  end if;

  select tv.required_fields into v_required from public.report_template_versions tv where tv.id = v_r.template_version_id;
  select coalesce(array_agg(f), '{}') into v_missing
    from unnest(v_required) f
   where not (v_rev.content ? f) or coalesce(btrim(v_rev.content ->> f), '') = '';
  if cardinality(v_missing) > 0 then
    perform private.fail('HC_VALIDATION_FAILED', jsonb_build_object('fields',
      (select jsonb_object_agg(f, 'required') from unnest(v_missing) f)));
  end if;
  if exists (select 1 from public.attachment_links l join public.attachments a on a.id = l.attachment_id
             where l.report_revision_id = v_rev.id and l.is_required_evidence and a.lifecycle <> 'ready') then
    perform private.fail('HC_ATTACHMENT_INCOMPLETE');
  end if;

  v_before := private.report_json(v_r);
  update public.report_revisions set state = 'submitted', submitted_at = now(), submitted_by = v_actor
   where id = v_rev.id returning * into v_rev;
  -- Compliance uses the FIRST valid submission (AC-015, AC-016).
  update public.report_instances set status = 'submitted', first_submitted_at = coalesce(first_submitted_at, now()),
         last_submitted_at = now(), latest_revision_id = v_rev.id, review_claimed_by = null
   where id = v_r.id returning * into v_r;
  perform private.audit(v_r.organization_id, v_r.department_id, v_actor, 'report', v_r.id, 'submit',
                        v_before, private.report_json(v_r), null, p_request_id);
  for v_director in
    select m.user_id from public.organization_memberships m
    where m.organization_id = v_r.organization_id and m.role = 'hospital_director' and m.active
      and m.valid_from <= now() and (m.valid_to is null or m.valid_to > now())
  loop
    perform private.notify(v_r.organization_id, v_director, 'report_submitted',
                           'report_submitted:' || v_rev.id, 'report', v_r.id);
  end loop;
  return private.idem_finish(v_actor, 'submit_report', p_request_id,
    private.report_json(v_r) || jsonb_build_object('revision_id', v_rev.id, 'submitted_at', v_rev.submitted_at));
end;
$$;

-- ---------------------------------------------------------------------------
-- API-09 decide_report (approve | return). Rejects stale revisions (AC-017).
-- ---------------------------------------------------------------------------
create or replace function public.decide_report(
  p_report_id uuid, p_revision_id uuid, p_decision text, p_expected_version int, p_request_id uuid, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_r public.report_instances;
  v_rev public.report_revisions;
  v_before jsonb;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_snapshot jsonb;
begin
  v_prior := private.idem_begin(v_actor, 'decide_report', p_request_id, jsonb_build_object(
    'report_id', p_report_id, 'revision_id', p_revision_id, 'decision', p_decision, 'v', p_expected_version, 'note', p_note));
  if v_prior is not null then return v_prior; end if;

  if not private.can_read_report(p_report_id) then perform private.fail('HC_NOT_FOUND'); end if;
  select * into v_r from public.report_instances where id = p_report_id for update;
  if not private.can_decide_report(v_r.organization_id, v_r.department_id) then perform private.fail('HC_FORBIDDEN'); end if;
  if p_decision not in ('approved', 'returned') then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"decision":"invalid"}}');
  end if;
  if p_decision = 'returned' and (v_note is null or length(v_note) < 3) then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"note":"required"}}');
  end if;
  if v_r.version <> p_expected_version or v_r.latest_revision_id is distinct from p_revision_id then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_r.version,
                                                                   'latest_revision_id', v_r.latest_revision_id));
  end if;
  if v_r.status not in ('submitted', 'under_review') then
    perform private.fail('HC_VALIDATION_FAILED', '{"status":"not_under_review"}');
  end if;
  select * into v_rev from public.report_revisions where id = p_revision_id for update;

  v_before := private.report_json(v_r);
  insert into public.report_reviews (organization_id, revision_id, reviewer_id, decision, note, request_id)
  values (v_r.organization_id, v_rev.id, v_actor, p_decision, v_note, p_request_id);

  if p_decision = 'approved' then
    -- Freeze what the approval relied on: content + approved measurements (§14, HC-040).
    v_snapshot := jsonb_build_object(
      'schema_version', 1,
      'content', v_rev.content,
      'measurements', coalesce((
        select jsonb_agg(jsonb_build_object('measurement_id', m.id, 'definition_version_id', m.definition_version_id,
                                            'revision', m.revision, 'value', m.value, 'numerator', m.numerator,
                                            'denominator', m.denominator) order by m.id)
        from public.indicator_measurements m
        where m.department_id = v_r.department_id and m.period_id = v_r.period_id and m.status = 'approved'), '[]'::jsonb),
      'approved_at', now(), 'approved_by', v_actor);
    update public.report_revisions set state = 'approved', snapshot_data = v_snapshot where id = v_rev.id;
    update public.report_instances set status = 'approved', approved_revision_id = v_rev.id, review_claimed_by = null
     where id = v_r.id returning * into v_r;
    perform private.notify(v_r.organization_id, v_rev.submitted_by, 'report_approved', 'report_approved:' || v_rev.id, 'report', v_r.id);
  else
    update public.report_revisions set state = 'returned' where id = v_rev.id;
    update public.report_instances set status = 'returned', review_claimed_by = null where id = v_r.id returning * into v_r;
    perform private.notify(v_r.organization_id, v_rev.submitted_by, 'report_returned', 'report_returned:' || v_rev.id, 'report', v_r.id);
  end if;
  perform private.audit(v_r.organization_id, v_r.department_id, v_actor, 'report', v_r.id, p_decision,
                        v_before, private.report_json(v_r), v_note, p_request_id);
  return private.idem_finish(v_actor, 'decide_report', p_request_id, private.report_json(v_r));
end;
$$;

-- ---------------------------------------------------------------------------
-- Waiver (director only; leaves the compliance denominator with a reason — AC-019)
-- ---------------------------------------------------------------------------
create or replace function public.waive_report(p_report_id uuid, p_reason text, p_expected_version int, p_request_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_actor();
  v_prior jsonb;
  v_r public.report_instances;
  v_before jsonb;
begin
  v_prior := private.idem_begin(v_actor, 'waive_report', p_request_id,
    jsonb_build_object('report_id', p_report_id, 'reason', p_reason, 'v', p_expected_version));
  if v_prior is not null then return v_prior; end if;
  if not private.can_read_report(p_report_id) then perform private.fail('HC_NOT_FOUND'); end if;
  select * into v_r from public.report_instances where id = p_report_id for update;
  if not private.has_org_role(v_r.organization_id, array['hospital_director']) then perform private.fail('HC_FORBIDDEN'); end if;
  if v_r.version <> p_expected_version then
    perform private.fail('HC_VERSION_CONFLICT', jsonb_build_object('current_version', v_r.version));
  end if;
  if v_r.status in ('approved', 'waived') then perform private.fail('HC_VALIDATION_FAILED', '{"status":"final"}'); end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then
    perform private.fail('HC_VALIDATION_FAILED', '{"fields":{"reason":"required"}}');
  end if;
  v_before := private.report_json(v_r);
  update public.report_instances set status = 'waived', waiver_reason = btrim(p_reason) where id = v_r.id returning * into v_r;
  perform private.audit(v_r.organization_id, v_r.department_id, v_actor, 'report', v_r.id, 'waive',
                        v_before, private.report_json(v_r), p_reason, p_request_id);
  return private.idem_finish(v_actor, 'waive_report', p_request_id, private.report_json(v_r));
end;
$$;

-- ---------------------------------------------------------------------------
-- Submission compliance for a period (first submission vs due; waived excluded).
-- ---------------------------------------------------------------------------
create or replace function public.report_compliance(p_period_id uuid)
returns jsonb
language sql stable security invoker
set search_path = ''
as $$
  -- security invoker: RLS limits the rows to what the caller may read.
  select jsonb_build_object(
    'period_id', p_period_id,
    'required', count(*) filter (where status <> 'waived'),
    'waived', count(*) filter (where status = 'waived'),
    'submitted', count(*) filter (where first_submitted_at is not null and status <> 'waived'),
    'on_time', count(*) filter (where first_submitted_at is not null and first_submitted_at <= due_at and status <> 'waived'),
    'approved', count(*) filter (where status = 'approved'),
    'returned', count(*) filter (where status = 'returned'),
    'awaiting_review', count(*) filter (where status in ('submitted', 'under_review')))
  from public.report_instances where period_id = p_period_id
$$;

revoke execute on function private.report_due_at(jsonb, public.reporting_periods), private.report_json(public.report_instances)
  from public, anon, authenticated;
revoke execute on function private.can_draft_report(uuid, uuid), private.can_submit_report(uuid, uuid),
  private.can_decide_report(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.generate_report_instances(uuid) from public, anon, authenticated;
grant execute on function
  public.save_report_draft(uuid, jsonb, uuid, int),
  public.submit_report(uuid, uuid, int, uuid),
  public.decide_report(uuid, uuid, text, int, uuid, text),
  public.waive_report(uuid, text, int, uuid),
  public.report_compliance(uuid)
to authenticated;
