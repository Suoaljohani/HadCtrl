-- HadCtrl — bootstrap the hospital and its first director (spec §22).
--
-- WHERE:   Supabase dashboard → SQL Editor → New query → paste → Run.
--          (Runs as the project owner. This is the trusted admin path; there is
--          deliberately no "first user becomes director" function in the app.)
-- BEFORE:  Create the person's login first:
--          Authentication → Users → "Add user" (email + password)
--          or "Invite user" (they set the password from the email link).
-- EDIT:    Only the four values in the `params` block below.
-- SAFE:    Idempotent — running it again changes nothing. It never deletes.
--          It refuses to run if the email has no Auth account yet.

do $$
declare
  -- ===== params: edit these =====
  v_email        text := 'director@example.com';           -- the Auth user's email
  v_display_name text := 'اسم المدير';                      -- shown in the app
  v_job_title    text := 'مدير المستشفى';
  v_org_name_ar  text := 'مستشفى الحديثة العام';
  -- ==============================
  v_org_name_en  text := 'Alhadithah General Hospital';
  v_user  uuid;
  v_org   uuid;
  v_start date := date_trunc('month', (now() at time zone 'Asia/Riyadh'))::date;
begin
  if v_email = 'director@example.com' then
    raise exception 'Edit v_email (and the other params) before running.';
  end if;

  select id into v_user from auth.users where lower(email) = lower(btrim(v_email));
  if v_user is null then
    raise exception 'No Auth user with email %. Create it first: Authentication → Users → Add user.', v_email;
  end if;

  -- 1. Hospital (one per name).
  select id into v_org from public.organizations where name_ar = v_org_name_ar;
  if v_org is null then
    insert into public.organizations (name_ar, name_en, timezone, is_demo)
    values (v_org_name_ar, v_org_name_en, 'Asia/Riyadh', false)
    returning id into v_org;
    raise notice 'created organization %', v_org;
  end if;

  -- 2. Profile for the Auth user.
  insert into public.profiles (user_id, display_name, job_title, active)
  values (v_user, v_display_name, v_job_title, true)
  on conflict (user_id) do nothing;

  -- 3. Director membership (server-side role; the app never lets users pick one).
  if not exists (select 1 from public.organization_memberships
                 where organization_id = v_org and user_id = v_user and role = 'hospital_director' and active) then
    insert into public.organization_memberships (organization_id, user_id, role, granted_by)
    values (v_org, v_user, 'hospital_director', null);
    raise notice 'granted hospital_director to %', v_email;
  end if;

  -- 4. Current monthly reporting period, open (the dashboard needs one).
  insert into public.reporting_periods (organization_id, type, start_date, end_date, state)
  values (v_org, 'monthly', v_start, (v_start + interval '1 month - 1 day')::date, 'open')
  on conflict (organization_id, type, start_date) do nothing;

  raise notice 'done: organization %, director %, period starting %', v_org, v_user, v_start;
end $$;

-- Check: should list exactly one row for the director.
select o.name_ar as hospital, p.display_name, m.role, m.active
from public.organization_memberships m
join public.organizations o on o.id = m.organization_id
join public.profiles p on p.user_id = m.user_id
where m.role = 'hospital_director';
