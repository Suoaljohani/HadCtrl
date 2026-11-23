#!/usr/bin/env bash
# Recreate a disposable local database from an empty state, apply all
# migrations in order, then run the SQL test suites. Never point this at a
# hosted Supabase project: it DROPs the target database.
set -euo pipefail

DB_NAME="${HC_TEST_DB:-hadctrl_test}"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "${PGHOST:-localhost}" in
  localhost|127.0.0.1|/*|"") ;;
  *) echo "refusing to run against non-local host ${PGHOST}" >&2; exit 2 ;;
esac

"${PSQL[@]}" -d postgres -c "drop database if exists ${DB_NAME} with (force)"
"${PSQL[@]}" -d postgres -c "create database ${DB_NAME}"

"${PSQL[@]}" -d "$DB_NAME" -f "$ROOT/supabase/tests/local/00_supabase_shim.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "apply $(basename "$f")"
  "${PSQL[@]}" -d "$DB_NAME" -f "$f"
done

status=0
for t in "$ROOT"/supabase/tests/*.test.sql; do
  echo "test  $(basename "$t")"
  out="$("${PSQL[@]}" -o /dev/null -d "$DB_NAME" -f "$t" 2>&1)" && rc=0 || rc=$?
  oks=$(grep -c 'NOTICE:  ok' <<<"$out" || true)
  echo "      $oks assertions passed"
  if [ "$rc" -ne 0 ]; then
    grep -vE 'NOTICE:  ok' <<<"$out" >&2
    status=1
  fi
done
for t in "$ROOT"/supabase/tests/*.sh; do
  echo "test  $(basename "$t")"
  out="$("$t" "$DB_NAME" 2>&1)" && rc=0 || rc=$?
  echo "      $(grep -c 'NOTICE:  ok' <<<"$out" || true) assertions passed"
  if [ "$rc" -ne 0 ]; then echo "$out" >&2; status=1; fi
done
exit $status
