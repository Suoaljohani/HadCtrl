# Runbook

## 1. Schema changes
- Add a new timestamped file under `supabase/migrations/`. Never edit an applied migration.
- Run `scripts/db-test.sh` locally (empty database → all migrations → tests). CI repeats this.
- Apply to the hosted project only after tests pass, in order. Afterwards, run the Supabase security advisor and compare the function fingerprint query in TEST_REPORT with the local database. Never use `db reset`, `drop schema` or destructive statements on the hosted project. Fix forward with a corrective migration after inspecting the current state (§29).

## 2. Bootstrap the hospital, first director and departments (trusted admin path, §22)
Scripts: `supabase/admin/`. Run them in the Supabase dashboard → **SQL Editor** (as the project owner).
1. Create the director's login: **Authentication → Users → Add user** (email + password) or **Invite user**.
2. Open `supabase/admin/01_bootstrap_first_director.sql`, edit the four values in its `params` block (email, display name, job title, hospital name), paste and **Run**. It creates the hospital, the director's profile and membership, and the current open monthly period. It is idempotent, never deletes, and refuses to run if the email has no Auth account yet.
3. For each department: create the head's login (if any), then edit and run `02_add_department_with_head.sql`.
4. Sign in to the app with that email and password.

There is deliberately no "first user becomes director" function in the app. Roles come only from these server-side rows.

## 2b. Reports and indicators (D-29)
In the app, as the director: Settings → «الأقسام والموظفون» → «قالب تقرير دوري جديد» (fields, departments, due day) and «مؤشر أداء جديد». Then Reports tab → «توليد تقارير الفترة» (or «فتح الفترة الحالية» if no period exists). The nightly job `hadctrl-daily` does the same for the current month; check it with `select * from cron.job_run_details order by start_time desc limit 5;`.

## 3. Revoking access
Set `department_memberships.active = false` (or `organization_memberships`, or `profiles.active`). Every RPC and policy re-checks this on each call, so a still-valid token loses access immediately (AC-032). Reassign open tasks with `transition_task(..., 'reassign', ...)`. Do not delete history.

## 4. CI
- `database` job: Ubuntu, local PostgreSQL, migrations + tests.
- `ios-simulator` job: macOS 15, XcodeGen, `xcodebuild -list`, then simulator tests. Artifacts: `.xcresult` and the generated `.xcodeproj`.
- A failing test is fixed, never skipped or `continue-on-error`'d.

## 5. Backups
Supabase database backups do not include Storage objects. Test a restore of both in an isolated project before go-live (§29).
