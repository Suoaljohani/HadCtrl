-- Local-only shim that reproduces the parts of the Supabase platform the
-- HadCtrl migrations depend on (roles, auth.users, auth.uid(), auth.jwt()).
-- NEVER apply this file to a hosted Supabase project: there these objects
-- already exist and are managed by the platform.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

create schema if not exists auth;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(auth.jwt() ->> 'role', 'anon')
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;

-- Supabase grants these broad defaults on public; reproduce them so the
-- migrations' explicit REVOKEs are tested against the real starting point.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- Hosted Supabase grants EXECUTE on new public functions to anon/authenticated
-- through platform-owned default privileges that a migration's own
-- ALTER DEFAULT PRIVILEGES does not remove. Simulate that with an event
-- trigger so the local suite sees the same starting point.
create or replace function public._shim_grant_new_functions() returns event_trigger
language plpgsql as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() where object_type = 'function' and schema_name = 'public' loop
    execute format('grant execute on function %s to anon, authenticated', r.object_identity);
  end loop;
end $$;
create event trigger _shim_grant_new_functions on ddl_command_end
  when tag in ('CREATE FUNCTION') execute function public._shim_grant_new_functions();
