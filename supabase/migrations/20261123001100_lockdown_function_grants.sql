-- Corrective: explicit EXECUTE grants on every public function.
-- On the hosted project, functions created by later migrations inherited the
-- platform's default EXECUTE grants for anon/PUBLIC (found by the Supabase
-- security advisor after the first apply). Default-privilege changes depend on
-- which role runs the migration, so rely on explicit revokes instead.
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon;

grant execute on function
  public.create_task(uuid, text, uuid, uuid, timestamptz, date, text, text, timestamptz, uuid, uuid, boolean),
  public.transition_task(uuid, int, text, uuid, text, uuid),
  public.request_task_extension(uuid, timestamptz, text, uuid),
  public.decide_task_extension(uuid, text, uuid, text),
  public.mark_notification_read(uuid),
  public.register_device(uuid, text, text),
  public.my_context(),
  public.save_report_draft(uuid, jsonb, uuid, int),
  public.submit_report(uuid, uuid, int, uuid),
  public.decide_report(uuid, uuid, text, int, uuid, text),
  public.waive_report(uuid, text, int, uuid),
  public.report_compliance(uuid),
  public.submit_measurement(uuid, uuid, uuid, numeric, numeric, numeric, text, text, text),
  public.decide_measurement(uuid, text, int, uuid, text),
  public.freeze_period(uuid, int, text, uuid),
  public.dashboard_snapshot(uuid)
to authenticated;
-- generate_report_instances stays server-only (no client grant).
