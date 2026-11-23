#!/usr/bin/env bash
# AC-011 under real concurrency: two sessions submit create_task with the same
# request_id at the same time. Exactly one task and one audit event must exist,
# and both callers must receive the same task_id.
set -euo pipefail
DB="$1"
REQ="40000000-0000-0000-0000-0000000000c1"
CALL="select test.login('00000000-0000-0000-0000-000000000011');
begin;
select public.create_task(p_department_id => '00000000-0000-0000-0000-0000000000d1',
  p_title => 'مهمة متزامنة', p_request_id => '$REQ',
  p_assignee_id => '00000000-0000-0000-0000-000000000012', p_due_at => '2030-01-01T12:00:00Z') ->> 'task_id';
select pg_sleep(1.5);
commit;"
out1=$(mktemp); out2=$(mktemp)
psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" -c "$CALL" >"$out1" 2>&1 &
p1=$!
sleep 0.3
psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" -c "$CALL" >"$out2" 2>&1 &
p2=$!
wait $p1; wait $p2
id1=$(grep -E '^[0-9a-f-]{36}$' "$out1"); id2=$(grep -E '^[0-9a-f-]{36}$' "$out2")
n=$(psql -X -q -t -A -d "$DB" -c "select count(*) from public.tasks where title = 'مهمة متزامنة'")
a=$(psql -X -q -t -A -d "$DB" -c "select count(*) from public.audit_events a join public.tasks t on t.id = a.entity_id where t.title = 'مهمة متزامنة'")
rm -f "$out1" "$out2"
fail=0
[ -n "$id1" ] && [ "$id1" = "$id2" ] && echo "NOTICE:  ok   concurrent duplicates return the same task_id" || { echo "FAIL ids differ: '$id1' '$id2'"; fail=1; }
[ "$n" = "1" ] && echo "NOTICE:  ok   exactly one task row" || { echo "FAIL task rows: $n"; fail=1; }
[ "$a" = "1" ] && echo "NOTICE:  ok   exactly one audit event" || { echo "FAIL audit rows: $a"; fail=1; }
exit $fail
