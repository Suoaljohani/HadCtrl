-- Authorization helpers, grants and RLS policies.
-- Spec refs: §03, §22, §25, §26, HC-120, AC-002/003/021/032.
--
-- Design:
--  * Every role check reads organization_memberships / department_memberships /
--    delegations with active + validity window + active profile, at call time.
--    No trust in user_metadata or client-sent roles.
--  * Helpers live in schema "private" (not exposed by PostgREST), are
--    SECURITY DEFINER with an empty search_path so they can read membership
--    tables without recursing through those tables' own RLS.
--  * The client gets SELECT only (plus own preferences/profile text). All
--    sensitive writes go through RPCs in the next migrations.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function private.actor_active()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.active)
$$;

create or replace function private.org_roles(p_org uuid)
returns text[]
language sql stable security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct m.role), '{}')
  from public.organization_memberships m
  join public.profiles p on p.user_id = m.user_id and p.active
  join public.organizations o on o.id = m.organization_id and o.active
  where m.organization_id = p_org
    and m.user_id = auth.uid()
    and m.active
    and m.valid_from <= now()
    and (m.valid_to is null or m.valid_to > now())
$$;

create or replace function private.has_org_role(p_org uuid, p_roles text[])
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.org_roles(p_org) && p_roles
$$;

create or replace function private.dept_roles(p_dept uuid)
returns text[]
language sql stable security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct m.role), '{}')
  from public.department_memberships m
  join public.profiles p on p.user_id = m.user_id and p.active
  join public.departments d on d.id = m.department_id
  join public.organizations o on o.id = d.organization_id and o.active
  where m.department_id = p_dept
    and m.user_id = auth.uid()
    and m.active
    and m.valid_from <= now()
    and (m.valid_to is null or m.valid_to > now())
$$;

create or replace function private.has_delegation(p_org uuid, p_dept uuid, p_ops text[])
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.delegations g
    join public.profiles p on p.user_id = g.grantee_id and p.active
    where g.organization_id = p_org
      and g.grantee_id = auth.uid()
      and g.revoked_at is null
      and g.valid_from <= now() and g.valid_to > now()
      and g.operation = any (p_ops)
      and (g.scope = 'organization' or g.department_id = p_dept)
  )
$$;

-- Any current, active relationship with the organization.
create or replace function private.is_org_member(p_org uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select cardinality(private.org_roles(p_org)) > 0
      or exists (
        select 1 from public.department_memberships m
        join public.profiles p on p.user_id = m.user_id and p.active
        join public.organizations o on o.id = m.organization_id and o.active
        where m.organization_id = p_org and m.user_id = auth.uid() and m.active
          and m.valid_from <= now() and (m.valid_to is null or m.valid_to > now()))
      or exists (
        select 1 from public.delegations g
        join public.profiles p on p.user_id = g.grantee_id and p.active
        where g.organization_id = p_org and g.grantee_id = auth.uid() and g.revoked_at is null
          and g.valid_from <= now() and g.valid_to > now())
$$;

-- Operational read of a department's working data (drafts excluded elsewhere).
create or replace function private.can_operate_department(p_org uuid, p_dept uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.has_org_role(p_org, array['hospital_director'])
      or cardinality(private.dept_roles(p_dept)) > 0
      or private.has_delegation(p_org, p_dept, array['review_reports', 'approve_reports', 'submit_reports', 'review_tasks'])
$$;

-- Read of a department's definitions and approved results.
create or replace function private.can_view_department(p_org uuid, p_dept uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.can_operate_department(p_org, p_dept)
      or private.has_org_role(p_org, array['executive_viewer'])
$$;

create or replace function private.is_department_member(p_dept uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select cardinality(private.dept_roles(p_dept)) > 0
$$;

create or replace function private.can_read_task(p_task uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.tasks t
    where t.id = p_task
      and private.is_org_member(t.organization_id)
      and (
        private.has_org_role(t.organization_id, array['hospital_director'])
        or private.is_department_member(t.department_id)
        or private.has_delegation(t.organization_id, t.department_id, array['review_tasks'])
        or t.assignee_id = auth.uid()
        or t.creator_id = auth.uid()
      )
      and (t.status <> 'draft' or t.creator_id = auth.uid())
  )
$$;

create or replace function private.can_read_report(p_report uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.report_instances r
    where r.id = p_report
      and (private.can_operate_department(r.organization_id, r.department_id)
           or (r.status = 'approved' and private.has_org_role(r.organization_id, array['executive_viewer'])))
  )
$$;

create or replace function private.can_read_achievement(p_achievement uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.achievements a
    where a.id = p_achievement
      and (private.is_department_member(a.department_id)
           or (a.status <> 'draft' and private.has_org_role(a.organization_id, array['hospital_director']))
           or (a.status = 'approved' and private.is_org_member(a.organization_id)))
  )
$$;

create or replace function private.can_read_attachment(p_attachment uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.attachments a
    where a.id = p_attachment
      and a.lifecycle <> 'deleted'
      and private.is_org_member(a.organization_id)
      and (
        (a.uploader_id = auth.uid() and a.lifecycle in ('pending', 'ready', 'failed'))
        or exists (
          select 1 from public.attachment_links l
          left join public.report_revisions rr on rr.id = l.report_revision_id
          left join public.indicator_measurements im on im.id = l.measurement_id
          where l.attachment_id = a.id
            and (
              (l.task_id is not null and private.can_read_task(l.task_id))
              or (l.report_revision_id is not null and private.can_read_report(rr.report_id))
              or (l.achievement_id is not null and private.can_read_achievement(l.achievement_id))
              or (l.measurement_id is not null and private.can_view_department(im.organization_id, im.department_id))
            )
        )
      )
  )
$$;

grant usage on schema private to authenticated;
revoke all on all functions in schema private from public, anon;
grant execute on function
  private.actor_active(), private.org_roles(uuid), private.has_org_role(uuid, text[]),
  private.dept_roles(uuid), private.has_delegation(uuid, uuid, text[]), private.is_org_member(uuid),
  private.can_operate_department(uuid, uuid), private.can_view_department(uuid, uuid),
  private.is_department_member(uuid), private.can_read_task(uuid), private.can_read_report(uuid),
  private.can_read_achievement(uuid), private.can_read_attachment(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Grants: start from nothing, then grant the minimum.
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

grant select on
  public.organizations, public.profiles, public.organization_memberships, public.departments,
  public.department_memberships, public.delegations, public.reporting_periods, public.personal_preferences,
  public.audit_events, public.goals, public.goal_versions, public.goal_milestones,
  public.indicator_definitions, public.indicator_definition_versions, public.indicator_measurements,
  public.goal_indicator_links, public.period_snapshots, public.tasks, public.task_dependencies,
  public.task_events, public.extension_requests, public.achievements, public.achievement_contributors,
  public.decisions, public.decision_task_links, public.comments, public.report_templates,
  public.report_template_versions, public.report_schedules, public.report_instances,
  public.report_revisions, public.report_reviews, public.attachments, public.attachment_links,
  public.notifications, public.device_registrations
to authenticated;

grant insert, update, delete on public.personal_preferences to authenticated;
grant update (display_name, job_title) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Enable RLS everywhere (including tables with no client grant).
-- ---------------------------------------------------------------------------
do $$
declare
  t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    -- Not FORCE: SECURITY DEFINER helpers/RPCs run as the table owner and
    -- must read memberships without recursing through these policies.
    execute format('alter table public.%I enable row level security', t.tablename);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Policies (authenticated only; anon has no grants and no policies)
-- ---------------------------------------------------------------------------
create policy organizations_select on public.organizations for select to authenticated
  using (private.is_org_member(id));

create policy profiles_select on public.profiles for select to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.organization_memberships om
      where om.user_id = profiles.user_id and private.is_org_member(om.organization_id))
    or exists (
      select 1 from public.department_memberships dm
      where dm.user_id = profiles.user_id and private.is_org_member(dm.organization_id))
  );
create policy profiles_update_self on public.profiles for update to authenticated
  using (user_id = auth.uid() and private.actor_active())
  with check (user_id = auth.uid());

create policy org_memberships_select on public.organization_memberships for select to authenticated
  using (user_id = auth.uid()
         or private.has_org_role(organization_id, array['hospital_director', 'system_admin']));

create policy departments_select on public.departments for select to authenticated
  using (private.has_org_role(organization_id, array['hospital_director', 'executive_viewer', 'system_admin'])
         or private.can_operate_department(organization_id, id));

create policy dept_memberships_select on public.department_memberships for select to authenticated
  using (user_id = auth.uid()
         or private.has_org_role(organization_id, array['hospital_director', 'system_admin'])
         or 'department_head' = any (private.dept_roles(department_id)));

create policy delegations_select on public.delegations for select to authenticated
  using (grantee_id = auth.uid() or grantor_id = auth.uid()
         or private.has_org_role(organization_id, array['hospital_director']));

create policy periods_select on public.reporting_periods for select to authenticated
  using (private.is_org_member(organization_id));

create policy prefs_select on public.personal_preferences for select to authenticated
  using (user_id = auth.uid());
create policy prefs_insert on public.personal_preferences for insert to authenticated
  with check (user_id = auth.uid() and private.is_org_member(organization_id));
create policy prefs_update on public.personal_preferences for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and private.is_org_member(organization_id));
create policy prefs_delete on public.personal_preferences for delete to authenticated
  using (user_id = auth.uid());

create policy audit_select on public.audit_events for select to authenticated
  using (private.has_org_role(organization_id, array['hospital_director'])
         or (actor_id = auth.uid() and private.is_org_member(organization_id)));

-- Performance
create policy goals_select on public.goals for select to authenticated
  using (private.can_view_department(organization_id, department_id)
         and (lifecycle <> 'draft' or private.can_operate_department(organization_id, department_id)));
create policy goal_versions_select on public.goal_versions for select to authenticated
  using (exists (select 1 from public.goals g where g.id = goal_versions.goal_id));
create policy goal_milestones_select on public.goal_milestones for select to authenticated
  using (exists (select 1 from public.goal_versions v where v.id = goal_milestones.goal_version_id));
create policy indicator_definitions_select on public.indicator_definitions for select to authenticated
  using (private.can_view_department(organization_id, department_id));
create policy indicator_versions_select on public.indicator_definition_versions for select to authenticated
  using (exists (select 1 from public.indicator_definitions d where d.id = indicator_definition_versions.definition_id));
create policy measurements_select on public.indicator_measurements for select to authenticated
  using ((private.is_department_member(department_id) )
         or (status <> 'draft' and private.can_operate_department(organization_id, department_id))
         or (status = 'approved' and private.has_org_role(organization_id, array['executive_viewer'])));
create policy goal_indicator_links_select on public.goal_indicator_links for select to authenticated
  using (exists (select 1 from public.goals g where g.id = goal_indicator_links.goal_id));
create policy period_snapshots_select on public.period_snapshots for select to authenticated
  using (private.has_org_role(organization_id, array['hospital_director', 'executive_viewer']));

-- Execution
create policy tasks_select on public.tasks for select to authenticated
  using (private.can_read_task(id));
create policy task_dependencies_select on public.task_dependencies for select to authenticated
  using (private.can_read_task(task_id) and private.can_read_task(depends_on_task_id));
create policy task_events_select on public.task_events for select to authenticated
  using (private.can_read_task(task_id));
create policy extension_requests_select on public.extension_requests for select to authenticated
  using ((task_id is not null and private.can_read_task(task_id))
         or (report_id is not null and private.can_read_report(report_id)));
create policy achievements_select on public.achievements for select to authenticated
  using (private.can_read_achievement(id));
create policy achievement_contributors_select on public.achievement_contributors for select to authenticated
  using (private.can_read_achievement(achievement_id));
create policy decisions_select on public.decisions for select to authenticated
  using (private.has_org_role(organization_id, array['hospital_director', 'executive_viewer']));
create policy decision_task_links_select on public.decision_task_links for select to authenticated
  using (private.has_org_role(organization_id, array['hospital_director', 'executive_viewer'])
         and private.can_read_task(task_id));
create policy comments_select on public.comments for select to authenticated
  using ((task_id is not null and private.can_read_task(task_id))
         or (report_id is not null and private.can_read_report(report_id))
         or (achievement_id is not null and private.can_read_achievement(achievement_id)));

-- Reports
create policy report_templates_select on public.report_templates for select to authenticated
  using (private.is_org_member(organization_id));
create policy report_template_versions_select on public.report_template_versions for select to authenticated
  using (private.is_org_member(organization_id));
create policy report_schedules_select on public.report_schedules for select to authenticated
  using (private.can_view_department(organization_id, department_id));
create policy report_instances_select on public.report_instances for select to authenticated
  using (private.can_read_report(id));
create policy report_revisions_select on public.report_revisions for select to authenticated
  using (
    exists (
      select 1 from public.report_instances r
      where r.id = report_revisions.report_id
        and (
          private.is_department_member(r.department_id)
          or (report_revisions.state <> 'draft' and private.can_operate_department(r.organization_id, r.department_id))
          or (report_revisions.state = 'approved' and private.has_org_role(r.organization_id, array['executive_viewer']))
        )
    )
  );
create policy report_reviews_select on public.report_reviews for select to authenticated
  using (exists (select 1 from public.report_revisions v where v.id = report_reviews.revision_id));

-- Attachments and notifications
create policy attachments_select on public.attachments for select to authenticated
  using (private.can_read_attachment(id));
create policy attachment_links_select on public.attachment_links for select to authenticated
  using (private.can_read_attachment(attachment_id));
create policy notifications_select on public.notifications for select to authenticated
  using (recipient_id = auth.uid() and private.is_org_member(organization_id));
create policy device_registrations_select on public.device_registrations for select to authenticated
  using (user_id = auth.uid());
