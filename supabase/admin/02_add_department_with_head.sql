-- HadCtrl — add a department and (optionally) its head (spec §08, §22).
--
-- WHERE:   Supabase dashboard → SQL Editor. Run once per department.
-- BEFORE:  Run 01_bootstrap_first_director.sql. If you set a head, create
--          their login first (Authentication → Users → Add user / Invite).
-- EDIT:    Only the `params` block. Leave v_head_email empty for no head yet.
-- SAFE:    Idempotent; never deletes. Department codes are unique per hospital.

do $$
declare
  -- ===== params: edit these =====
  v_org_name_ar  text := 'مستشفى الحديثة العام';
  v_code         text := 'LAB';                 -- A–Z, 0–9, _ or -, up to 16 chars
  v_name_ar      text := 'المختبر';
  v_category     text := 'medical';             -- medical | technical | administrative
  v_head_email   text := '';                    -- '' = no head yet
  v_head_name    text := '';                    -- display name for the head
  -- ==============================
  v_org  uuid;
  v_dept uuid;
  v_head uuid;
begin
  select id into v_org from public.organizations where name_ar = v_org_name_ar;
  if v_org is null then raise exception 'Hospital % not found. Run 01_bootstrap_first_director.sql first.', v_org_name_ar; end if;

  select id into v_dept from public.departments where organization_id = v_org and code = upper(v_code);
  if v_dept is null then
    insert into public.departments (organization_id, code, name_ar, category)
    values (v_org, upper(v_code), v_name_ar, v_category)
    returning id into v_dept;
    raise notice 'created department % (%)', v_name_ar, upper(v_code);
  end if;

  if btrim(v_head_email) <> '' then
    select id into v_head from auth.users where lower(email) = lower(btrim(v_head_email));
    if v_head is null then raise exception 'No Auth user with email %. Create it first.', v_head_email; end if;
    insert into public.profiles (user_id, display_name, job_title, active)
    values (v_head, coalesce(nullif(btrim(v_head_name), ''), v_head_email), 'رئيس قسم', true)
    on conflict (user_id) do nothing;
    if exists (select 1 from public.department_memberships
               where department_id = v_dept and active and is_primary and user_id <> v_head) then
      raise exception 'Department % already has a different active primary head. Deactivate that membership first.', upper(v_code);
    end if;
    if not exists (select 1 from public.department_memberships
                   where department_id = v_dept and user_id = v_head and role = 'department_head' and active) then
      insert into public.department_memberships (organization_id, department_id, user_id, role, is_primary)
      values (v_org, v_dept, v_head, 'department_head', true);
      raise notice 'set % as head of %', v_head_email, upper(v_code);
    end if;
  end if;
end $$;
