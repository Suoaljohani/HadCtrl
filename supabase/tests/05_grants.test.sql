-- Function grants: anon can execute nothing in public; authenticated only the
-- documented RPC list. Guards against inherited default grants on the host.
select test.eq((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')), 0::bigint,
               'anon can execute no public function');
select test.eq((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'private' and has_function_privilege('anon', p.oid, 'execute')), 0::bigint,
               'anon can execute no private function');
select test.eq((select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')),
  'create_department,create_indicator,create_report_template,create_task,dashboard_snapshot,decide_measurement,decide_report,decide_task_extension,ensure_current_period,freeze_period,generate_reports_for_period,list_people,mark_all_notifications_read,mark_notification_read,mark_password_changed,my_context,prepare_employee,register_device,report_compliance,request_task_extension,save_report_draft,schedule_report,submit_measurement,submit_report,transition_task,waive_report',
  'authenticated can execute exactly the documented RPCs');
select test.eq((select count(*) from information_schema.role_table_grants where grantee = 'anon' and table_schema = 'public'), 0::bigint,
               'anon has no table privileges');
