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

## 2c. Signatures, device unregistration (migration 001800) and APNs push

1. Apply `supabase/migrations/20261123001800_signatures.sql` in the SQL Editor (non-destructive: new table, bucket, policies, three RPCs, `daily_maintenance` gains signature expiry). Verify with the function fingerprint query (§1) and the security advisor. Until it is applied the app keeps approving without a signature step and Settings says signatures await the server update.
2. Push (needs a paid Apple Developer account):
   - Create an APNs auth key (.p8) in Certificates, Identifiers & Profiles; enable Push Notifications on the app id; regenerate the provisioning profile.
   - In Supabase → Edge Functions → Secrets set `APNS_KEY_P8` (file contents), `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` (bundle id) and a random `PUSH_SENDER_SECRET`. Never commit them.
   - Deploy `supabase/functions/push-sender` with `verify_jwt = false` (the function checks its own secret).
   - Schedule it every minute (SQL Editor; store the secret in Vault first: `select vault.create_secret('<secret>', 'push_sender_secret');`):
     ```sql
     select cron.schedule('hadctrl-push', '* * * * *', $$
       select net.http_post(
         url := 'https://<project-ref>.supabase.co/functions/v1/push-sender',
         headers := jsonb_build_object('x-push-sender-secret',
           (select decrypted_secret from vault.decrypted_secrets where name = 'push_sender_secret')),
         body := '{}'::jsonb);
     $$);
     ```
   - Sign the IPA with `HC_ENABLE_PUSH=1` so the push entitlement is included.

## 3. Revoking access
Set `department_memberships.active = false` (or `organization_memberships`, or `profiles.active`). Every RPC and policy re-checks this on each call, so a still-valid token loses access immediately (AC-032). Reassign open tasks with `transition_task(..., 'reassign', ...)`. Do not delete history.

## 4. CI
- `database` job: Ubuntu, local PostgreSQL, migrations + tests.
- `ios-simulator` job: macOS 15, XcodeGen, `xcodebuild -list`, then simulator tests. Artifacts: `.xcresult` and the generated `.xcodeproj`.
- A failing test is fixed, never skipped or `continue-on-error`'d.

## 5. Backups
Supabase database backups do not include Storage objects. Test a restore of both in an isolated project before go-live (§29).
