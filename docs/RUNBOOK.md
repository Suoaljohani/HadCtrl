# Runbook

## 1. Schema changes
- Add a new timestamped file under `supabase/migrations/`. Never edit an applied migration.
- Run `scripts/db-test.sh` locally (empty database → all migrations → tests). CI repeats this.
- Apply to the hosted project only after tests pass, in order. Afterwards, run the Supabase security advisor and compare the function fingerprint query in TEST_REPORT with the local database. Never use `db reset`, `drop schema` or destructive statements on the hosted project. Fix forward with a corrective migration after inspecting the current state (§29).

## 2. Bootstrap the first director (trusted admin path, §22)
Run in the Supabase SQL editor as the project owner, after the person has accepted an Auth invite. Replace the placeholders after checking the identity out of band.

```sql
insert into public.organizations (name_ar, name_en) values ('مستشفى الحديثة العام', 'Alhadithah General Hospital') returning id;
insert into public.profiles (user_id, display_name, job_title) values ('<auth user uuid>', '<name>', 'مدير المستشفى');
insert into public.organization_memberships (organization_id, user_id, role) values ('<org id>', '<auth user uuid>', 'hospital_director');
```
There is deliberately no "first user becomes director" function.

## 3. Revoking access
Set `department_memberships.active = false` (or `organization_memberships`, or `profiles.active`). Every RPC and policy re-checks this on each call, so a still-valid token loses access immediately (AC-032). Reassign open tasks with `transition_task(..., 'reassign', ...)`. Do not delete history.

## 4. CI
- `database` job: Ubuntu, local PostgreSQL, migrations + tests.
- `ios-simulator` job: macOS 15, XcodeGen, `xcodebuild -list`, then simulator tests. Artifacts: `.xcresult` and the generated `.xcodeproj`.
- A failing test is fixed, never skipped or `continue-on-error`'d.

## 5. Backups
Supabase database backups do not include Storage objects. Test a restore of both in an isolated project before go-live (§29).
