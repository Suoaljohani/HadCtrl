#!/usr/bin/env bash
# Regenerate HadCtrlTests/Fixtures/contracts.json from the locally tested
# database (run scripts/db-test.sh first). Captures real dashboard_snapshot and
# my_context output so Swift DTOs are tested against the actual server contract.
set -euo pipefail
DB="${HC_TEST_DB:-hadctrl_test}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
psql -X -q -t -A -d "$DB" <<'SQL' | sed '/^$/d' > "${HC_OUT:-$ROOT/HadCtrlTests/Fixtures/contracts.json}"
select test.login('00000000-0000-0000-0000-000000000011') \g /dev/null
select jsonb_pretty(jsonb_build_object(
  'dashboard_snapshot', public.dashboard_snapshot('00000000-0000-0000-0000-0000000000f1'),
  'my_context', public.my_context(),
  'create_task', jsonb_build_object('task_id','00000000-0000-0000-0000-000000000c01','status','assigned','version',1,
     'assignee_id','00000000-0000-0000-0000-000000000012','due_at',now()+interval '3 days',
     'original_due_at',now()+interval '3 days','created_at',now(),'updated_at',now(),'replayed',false)));
SQL
python3 -c "import json,sys; json.load(open(sys.argv[1])); print('fixture ok')" "${HC_OUT:-$ROOT/HadCtrlTests/Fixtures/contracts.json}"
