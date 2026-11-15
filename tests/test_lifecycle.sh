#!/usr/bin/env bash
# Lifecycle tests for lib/pgrun-ci: a stub pgrun CLI and a stub PGRun API,
# branches as databases on a local Postgres (TEST_PG_URL). Covers the gates,
# capacity, engine enforcement, data checks, cleanup and cancellation.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ci="$here/../lib/pgrun-ci"
admin="${TEST_PG_URL:?TEST_PG_URL is required}"
export TEST_PG_URL="$admin"
pass=0; fail=0
root=$(mktemp -d)
# Hermetic: never inherit the runner's own event file (on GitHub it describes THIS public
# repository, and the public-repository guard would refuse every production-like run).
echo '{"repository":{"private":true}}' > "$root/private_event.json"
export GITHUB_EVENT_PATH="$root/private_event.json"
api_pid=""
cleanup_all() {
  [ -n "$api_pid" ] && kill "$api_pid" 2>/dev/null
  for db in $(psql "$admin" -Atc "SELECT datname FROM pg_database WHERE datname LIKE 'stub\\_%' OR datname = 'pgrun_copy_fixture'"); do
    psql "$admin" -qc "DROP DATABASE IF EXISTS $db WITH (FORCE)" >/dev/null 2>&1
  done
  rm -rf "$root"
}
trap cleanup_all EXIT

# The "Safe Copy": a database with rows every production-like branch clones.
psql "$admin" -qc "DROP DATABASE IF EXISTS pgrun_copy_fixture" -c "CREATE DATABASE pgrun_copy_fixture" >/dev/null
psql "${admin%/*}/pgrun_copy_fixture" -q >/dev/null <<'SQL'
CREATE TABLE schema_migrations (version varchar PRIMARY KEY);
INSERT INTO schema_migrations VALUES ('20260101000000');
CREATE TABLE customers (id bigserial PRIMARY KEY, email text, name text NOT NULL);
INSERT INTO customers (email, name) SELECT 'user' || g || '@example.test', 'n' || g FROM generate_series(1, 100) g;
SQL
export STUB_TEMPLATE_DB=pgrun_copy_fixture

ok()   { pass=$((pass + 1)); echo "ok   $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/     /' <<< "$2"; }

recent() { python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=int(__import__("sys").argv[1]))).isoformat())' "$1"; }

context() {   # <protect> <copy status> <updated hours ago|none> [extra jq]
  local updated; [ "$3" = none ] && updated=null || updated="\"$(recent "$3")\""
  jq -n --arg p "$1" --arg c "$2" --argjson u "$updated" '{token: "good", status: 200, body: {
    project: {name: "shop"}, token: {scope: "ci"},
    source: {postgres_version: "18.1", schema_changed: false},
    protect: {status: $p, policy_version: 4, pending_reapproval: false},
    safe_copy: {status: $c, updated_at: $u, policy_version: 4, policy_revoked: false},
    pgx: {enabled: true, eligible: true, verdict: "PGX_COMPATIBLE"},
    capacity: {max_branches: 10, live_branches: 1}, allowances: []}}' | jq "${4:-.}" > "$STUB_DIR/context.json"
}

# run_ci <name> [VAR=value ...] — runs detect + run + cleanup like the composite.
run_ci() {
  local name="$1"; shift
  export RUNNER_TEMP="$root/$name"; mkdir -p "$RUNNER_TEMP"
  export GITHUB_STEP_SUMMARY="$RUNNER_TEMP/summary.md" GITHUB_ENV="$RUNNER_TEMP/env" GITHUB_OUTPUT="$RUNNER_TEMP/out" GITHUB_PATH="$RUNNER_TEMP/path"
  out=$(cd "$root/app" && env PGRUN_IN_API_URL="http://127.0.0.1:$(cat "$STUB_DIR/api_port")" PGRUN_IN_FRAMEWORK=none \
        GITHUB_RUN_ID="${RUN_ID:-1000}" GITHUB_RUN_ATTEMPT=1 GITHUB_REF=refs/pull/7/merge GITHUB_EVENT_NAME=pull_request \
        PGRUN_RETRY_PAUSE=1 PGRUN_PARTIAL_WAIT=2 "$@" bash -c "'$ci' detect >/dev/null && '$ci' run; c=\$?; '$ci' cleanup >/dev/null; exit \$c" 2>&1)
  code=$?
}

live_branches() { ls "$STUB_DIR/branches" 2>/dev/null | wc -l | tr -d ' '; }
creates() { grep -c '^branch create' "$STUB_DIR/calls" 2>/dev/null || true; }

new_stub() {
  export STUB_DIR="$root/stub-$1"; mkdir -p "$STUB_DIR"
  context active ready 2
  [ -n "$api_pid" ] && kill "$api_pid" 2>/dev/null
  rm -f "$STUB_DIR/api_port"; python3 "$here/stub/api.py" & api_pid=$!
  for _ in $(seq 50); do [ -s "$STUB_DIR/api_port" ] && break; sleep 0.1; done
}

export PATH="$here/stub:$PATH"
mkdir -p "$root/app"
MIG_ADD='psql "$DATABASE_URL" -qc "ALTER TABLE customers ADD COLUMN tier text; UPDATE customers SET tier = '"'"'a'"'"'; INSERT INTO schema_migrations VALUES ('"'"'20261015000001'"'"')"'
MIG_LOSS='psql "$DATABASE_URL" -qc "UPDATE customers SET email = NULL; INSERT INTO schema_migrations VALUES ('"'"'20261015000002'"'"')"'

# ---------------------------------------------------------------- gates
new_stub gates
run_ci no-token PGRUN_API_TOKEN=
[ $code = 1 ] && grep -q "no PGRun token" <<< "$out" && [ ! -s "$STUB_DIR/api_calls" ] && ok "K: no token (fork PR) fails before any API call" || bad "K: no token" "$out"

run_ci prt PGRUN_API_TOKEN=good GITHUB_EVENT_NAME=pull_request_target
[ $code = 1 ] && grep -q "refusing to run on pull_request_target" <<< "$out" && ok "K: pull_request_target is refused" || bad "pull_request_target" "$out"

run_ci badtoken PGRUN_API_TOKEN=wrong
[ $code = 1 ] && grep -q "token was rejected (401)" <<< "$out" && [ "$(creates)" = 0 ] && ok "invalid token: actionable 401" || bad "invalid token" "$out"
grep -q "auth=yes" "$STUB_DIR/api_calls" && ! grep -q wrong "$STUB_DIR/calls" 2>/dev/null && ok "token sent as a header, never on a pgrun argv" || bad "token header"

jq '.status = 401 | .body = {error: "unauthorized", reason: "token_expired"}' "$STUB_DIR/context.json" > "$STUB_DIR/c" && mv "$STUB_DIR/c" "$STUB_DIR/context.json"
run_ci expired PGRUN_API_TOKEN=good
[ $code = 1 ] && grep -q "CI token has expired" <<< "$out" && [ "$(creates)" = 0 ] && ok "expired CI token: says so, creates nothing" || bad "expired token" "$out"

jq '.status = 409 | .body = {error: "project_ambiguous", message: "this token can see 3 projects", projects: ["a", "b", "c"]}' "$STUB_DIR/context.json" > "$STUB_DIR/c" && mv "$STUB_DIR/c" "$STUB_DIR/context.json"
run_ci ambiguous PGRUN_API_TOKEN=good
[ $code = 1 ] && grep -q "set the action's \`project\` input to one of: a, b, c" <<< "$out" && ok "project discovery: several projects → names the choices" || bad "ambiguous" "$out"

context draft protect none
run_ci protect PGRUN_API_TOKEN=good
[ $code = 1 ] && grep -q "Protect is not approved for shop" <<< "$out" && [ "$(creates)" = 0 ] && ok "E: Protect not approved fails before provisioning" || bad "E" "$out"

context active ready_to_copy none
run_ci nocopy PGRUN_API_TOKEN=good
[ $code = 1 ] && grep -q "has no Safe Copy yet" <<< "$out" && [ "$(creates)" = 0 ] && ok "F: missing Safe Copy fails before provisioning" || bad "F missing" "$out"

context active ready 1000
run_ci stale PGRUN_API_TOKEN=good
[ $code = 1 ] && grep -q "Safe Copy is 1000h old" <<< "$out" && [ "$(creates)" = 0 ] && ok "F: stale Safe Copy fails with the limit to change" || bad "F stale" "$out"

context active ready 2 '.body.safe_copy.policy_revoked = true'
run_ci revoked PGRUN_API_TOKEN=good
[ $code = 1 ] && grep -q "revoked policy" <<< "$out" && ok "F: copy under a revoked policy fails" || bad "F revoked" "$out"

context active ready 2 '.body.pgx = {enabled: true, eligible: false, reason: "host_pgx_disabled"}'
run_ci pgx-pre PGRUN_API_TOKEN=good
[ $code = 1 ] && grep -q "PGX is required.*host_pgx_disabled" <<< "$out" && [ "$(creates)" = 0 ] && ok "G: PGX ineligible fails before provisioning" || bad "G pre" "$out"

# ------------------------------------------------------- production-like
new_stub pl
run_ci fallback PGRUN_API_TOKEN=good STUB_ENGINE=postgres PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD"
[ $code = 1 ] && grep -q "runs on postgres, not pgx" <<< "$out" && [ "$(live_branches)" = 0 ] && ok "G: a branch that fell back to PostgreSQL fails the run and is deleted" || bad "G fallback" "$out"

run_ci any PGRUN_API_TOKEN=good STUB_ENGINE=postgres PGRUN_IN_ENGINE=any PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD"
[ $code = 0 ] && ok "engine: any accepts stock PostgreSQL" || bad "engine any" "$out"

jq '.body.token.expires_at = (now + 5 * 86400 | todate)' "$STUB_DIR/context.json" > "$STUB_DIR/c" && mv "$STUB_DIR/c" "$STUB_DIR/context.json"
run_ci expiring PGRUN_API_TOKEN=good PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD"
[ $code = 0 ] && grep -q "CI token expires in [45] day" <<< "$out" && ok "a CI token near its expiry warns and still runs" || bad "expiring token" "$out"
jq 'del(.body.token.expires_at)' "$STUB_DIR/context.json" > "$STUB_DIR/c" && mv "$STUB_DIR/c" "$STUB_DIR/context.json"

run_ci valid PGRUN_API_TOKEN=good PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD"
summary=$(cat "$GITHUB_STEP_SUMMARY")
[ -n "${KEEP_SUMMARIES:-}" ] && cp "$GITHUB_STEP_SUMMARY" "$KEEP_SUMMARIES/pass.md"
[ $code = 0 ] && grep -q "PASS" <<< "$summary" && grep -q "Migrations | PASS — 1 applied" <<< "$summary" && grep -q "Data integrity | PASS" <<< "$summary" && [ "$(live_branches)" = 0 ] \
  && ok "B: a valid migration passes on the production-like branch; branch deleted" || bad "B" "$out$summary"
grep -q "Application tests | NOT CONFIGURED" <<< "$summary" && grep -q "Engine | PGX ×1" <<< "$summary" && grep -q "Cleanup | completed" <<< "$summary" && ok "summary: engine, tests not configured, cleanup" || bad "summary" "$summary"
if grep -v '^::add-mask::' <<< "$out$summary" | grep -qE "stub_|postgres://"; then bad "no URL in logs or summary" "$out"; else ok "no URL in logs or summary"; fi

run_ci loss PGRUN_API_TOKEN=good PGRUN_IN_MIGRATE_COMMAND="$MIG_LOSS"
[ -n "${KEEP_SUMMARIES:-}" ] && cp "$GITHUB_STEP_SUMMARY" "$KEEP_SUMMARIES/fail.md"
[ $code = 1 ] && grep -q "values lost: public.customers.email non-null 100 -> 0" <<< "$out" && grep -q "values lost: public.customers.email" "$GITHUB_STEP_SUMMARY" && [ "$(live_branches)" = 0 ] \
  && ok "C: destructive migration fails, naming the column; branch deleted" || bad "C" "$out"

# The approval names the migration file's SHA-256, which the action computes from the checkout.
mkdir -p "$root/app/db/migrate"; printf '%s\n' "$MIG_LOSS" > "$root/app/db/migrate/20261015000002_move_emails.sql"
LOSS_SHA=$(shasum -a 256 "$root/app/db/migrate/20261015000002_move_emails.sql" | cut -d' ' -f1)
context active ready 2 '.body.allowances = [{migration_version: "20261015000002", migration_sha256: "'"$LOSS_SHA"'", kind: "value_loss", target: "customers.email", reason: "emails move to contacts", approved_by: "owner@example.test"}]'
run_ci allowed PGRUN_API_TOKEN=good PGRUN_IN_MIGRATE_COMMAND="$MIG_LOSS"
[ $code = 0 ] && grep -q "approved data loss.*customers.email.*emails move to contacts" <<< "$out" && grep -q "approved: values lost" "$GITHUB_STEP_SUMMARY" \
  && grep -q "20261015000002\` db/migrate/20261015000002_move_emails.sql \`$LOSS_SHA" "$GITHUB_STEP_SUMMARY" && ok "D: approved loss passes with a visible warning; the summary shows the file's SHA-256" || bad "D" "$out$(cat "$GITHUB_STEP_SUMMARY")"
printf '%s -- edited after approval\n' "$MIG_LOSS" > "$root/app/db/migrate/20261015000002_move_emails.sql"
run_ci allowed-edited PGRUN_API_TOKEN=good PGRUN_IN_MIGRATE_COMMAND="$MIG_LOSS"
[ $code = 1 ] && grep -q "file changed after it was approved" <<< "$out" && grep -q "values lost: public.customers.email" <<< "$out" \
  && ok "D: the same version with edited content is not covered by the approval" || bad "D edited" "$out"
rm -r "$root/app/db"
context active ready 2

run_ci migfail PGRUN_API_TOKEN=good PGRUN_IN_MIGRATE_COMMAND='echo "== CreateWidgets: migrating"; exit 3'
[ $code = 1 ] && grep -q "migrations failed" <<< "$out" && [ "$(live_branches)" = 0 ] && ok "a failing migration fails the run; branch deleted" || bad "migration failure" "$out"

run_ci tokenless PGRUN_API_TOKEN=good PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD" \
  PGRUN_IN_TEST_COMMAND='env | grep -c "^PGRUN_API_TOKEN=" > "$RUNNER_TEMP/seen"; psql "$DATABASE_URL" -Atc "select count(*) from customers" > "$RUNNER_TEMP/rows"'
[ $code = 0 ] && [ "$(cat "$RUNNER_TEMP/seen")" = 0 ] && [ "$(cat "$RUNNER_TEMP/rows")" = 100 ] && ok "customer commands get the branch, never the PGRun token" || bad "token isolation" "$out $(cat "$RUNNER_TEMP/seen" 2>/dev/null)"

run_ci appfail PGRUN_API_TOKEN=good PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD" PGRUN_IN_TEST_COMMAND='exit 1'
[ $code = 1 ] && grep -q "Application tests | FAIL" "$GITHUB_STEP_SUMMARY" && ok "a failing test-command fails the run" || bad "test-command failure" "$out"

# ----------------------------------------------------------- capacity
new_stub quota
run_ci noquota PGRUN_API_TOKEN=good STUB_QUOTA=0 PGRUN_IN_CAPACITY_WAIT=3 PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD"
[ $code = 1 ] && grep -q "no capacity for 1 branch(es) after 3s" <<< "$out" && [ "$(live_branches)" = 0 ] && ok "quota exhausted: bounded wait, clear error, nothing held" || bad "quota" "$out"

run_ci partial PGRUN_API_TOKEN=good STUB_QUOTA=2 PGRUN_IN_MODE=fast PGRUN_IN_WORKERS=3 PGRUN_IN_MIN_WORKERS=2 PGRUN_IN_CAPACITY_WAIT=20 \
  PGRUN_IN_TEST_COMMAND='echo "$PGRUN_WORKERS ${DATABASE_URL_1:+1}${DATABASE_URL_2:+2}${DATABASE_URL_3:+3}" > "$RUNNER_TEMP/workers"'
[ $code = 0 ] && [ "$(cat "$RUNNER_TEMP/workers")" = "2 12" ] && grep -q "continuing with 2 of 3 workers" <<< "$out" && [ "$(live_branches)" = 0 ] \
  && ok "fast: quota short → continues with min-workers, says so; all deleted" || bad "fast partial" "$out"

run_ci tooshort PGRUN_API_TOKEN=good STUB_QUOTA=1 PGRUN_IN_MODE=fast PGRUN_IN_WORKERS=3 PGRUN_IN_MIN_WORKERS=2 PGRUN_IN_CAPACITY_WAIT=4 PGRUN_IN_TEST_COMMAND=true
[ $code = 1 ] && grep -q "no capacity for 2 branch(es)" <<< "$out" && [ "$(live_branches)" = 0 ] && ok "fast: below min-workers releases what it held and fails" || bad "fast below min" "$out"

rm -f "$STUB_DIR/calls"
run_ci tplfail PGRUN_API_TOKEN=good STUB_TEMPLATE_FAIL=1 PGRUN_IN_MODE=fast PGRUN_IN_TEST_COMMAND=true
[ $code = 1 ] && grep -q "CI template could not be built" <<< "$out" && [ "$(creates)" = 0 ] && ok "fast: template failure stops before branches" || bad "template failure" "$out"

# J: two runs at once with room for one branch: the second waits for the first.
rm -f "$STUB_DIR/calls"
( RUN_ID=2001 run_ci concurrent-a PGRUN_API_TOKEN=good STUB_QUOTA=1 PGRUN_IN_CAPACITY_WAIT=60 PGRUN_IN_MIGRATE_COMMAND="sleep 4; $MIG_ADD"; echo "$code" > "$root/a.code" ) &
pa=$!
sleep 1
( RUN_ID=2002 run_ci concurrent-b PGRUN_API_TOKEN=good STUB_QUOTA=1 PGRUN_IN_CAPACITY_WAIT=60 PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD"; echo "$code" > "$root/b.code"; echo "$out" > "$root/b.out" ) &
pb=$!
wait "$pa" "$pb"
if [ "$(cat "$root/a.code")" = 0 ] && [ "$(cat "$root/b.code")" = 0 ] && grep -q "waiting for capacity" "$root/b.out" \
   && ! grep -q "ci-pl-7-2001" <(grep "^branch delete" "$STUB_DIR/calls" | grep -v "ci-pl-7-2001-" ) && [ "$(live_branches)" = 0 ]; then
  ok "J: concurrent runs queue under the quota; each deletes only its own branches"
else bad "J" "$(cat "$root/b.out")"; fi
grep "^branch delete" "$STUB_DIR/calls" | awk '{print $4}' | sort > "$root/deleted"
if grep -vqE '^ci-pl-7-200[12]-1-[0-9a-f]{6}-[0-9]+$' "$root/deleted"; then bad "J: a run deleted a branch it does not own" "$(cat "$root/deleted")"; else ok "J: deletions are scoped to the run's prefix"; fi

# Two jobs of ONE run (same run id and attempt, same token and mode, e.g. a
# matrix): B finishes and cleans up while A is still migrating; A's branch survives.
rm -f "$STUB_DIR/calls"
( RUN_ID=2003 run_ci samerun-a PGRUN_API_TOKEN=good STUB_QUOTA=2 PGRUN_IN_MIGRATE_COMMAND="sleep 4; $MIG_ADD"; echo "$code" > "$root/sa.code"; echo "$out" > "$root/sa.out" ) &
pa=$!
sleep 1
( RUN_ID=2003 run_ci samerun-b PGRUN_API_TOKEN=good STUB_QUOTA=2 PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD"; echo "$code" > "$root/sb.code" ) &
pb=$!
wait "$pa" "$pb"
grep "^branch delete" "$STUB_DIR/calls" | awk '{print $4}' | sort > "$root/deleted2"
if [ "$(cat "$root/sa.code")" = 0 ] && [ "$(cat "$root/sb.code")" = 0 ] && [ "$(wc -l < "$root/deleted2" | tr -d ' ')" = 2 ] \
   && [ "$(sort -u "$root/deleted2" | wc -l | tr -d ' ')" = 2 ] && [ "$(live_branches)" = 0 ]; then
  ok "J: two jobs of the same run and token never delete each other's branches"
else bad "J same run" "$(cat "$root/sa.out"; cat "$root/deleted2")"; fi

# --------------------------------------------------------- cancellation
cancel_test() {   # <name> <signal delay s> [VAR=value...]
  local name="$1" delay="$2"; shift 2
  export RUNNER_TEMP="$root/$name"; mkdir -p "$RUNNER_TEMP"
  export GITHUB_STEP_SUMMARY="$RUNNER_TEMP/summary.md" GITHUB_ENV="$RUNNER_TEMP/env" GITHUB_OUTPUT="$RUNNER_TEMP/out" GITHUB_PATH="$RUNNER_TEMP/path"
  (cd "$root/app" && exec env PGRUN_IN_API_URL="http://127.0.0.1:$(cat "$STUB_DIR/api_port")" PGRUN_IN_FRAMEWORK=none PGRUN_API_TOKEN=good \
     GITHUB_RUN_ID=3000 GITHUB_RUN_ATTEMPT=1 GITHUB_REF=refs/pull/9/merge GITHUB_EVENT_NAME=pull_request PGRUN_RETRY_PAUSE=1 "$@" "$ci" run > "$RUNNER_TEMP/log" 2>&1) &
  local pid=$!
  sleep "$delay"
  # GitHub sends SIGINT, then SIGTERM; a background job here ignores SIGINT.
  kill -TERM "$pid" 2>/dev/null
  wait "$pid"; code=$?
  (cd "$root/app" && "$ci" cleanup > /dev/null 2>&1)
}
new_stub cancel
cancel_test cancel-tests 4 PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD" PGRUN_IN_TEST_COMMAND="sleep 60"
[ "$code" = 130 ] && [ "$(live_branches)" = 0 ] && grep -q "CANCELLED" "$GITHUB_STEP_SUMMARY" && ok "H: cancelled during tests → branch deleted, summary says CANCELLED" || bad "H" "$(cat "$RUNNER_TEMP/log") code=$code live=$(live_branches)"
cancel_test cancel-provision 3 STUB_QUOTA=0 PGRUN_IN_CAPACITY_WAIT=120 PGRUN_IN_MIGRATE_COMMAND="$MIG_ADD"
[ "$code" = 130 ] && [ "$(live_branches)" = 0 ] && ok "I: cancelled while waiting for capacity → nothing left" || bad "I" "$(cat "$RUNNER_TEMP/log")"
cancel_test cancel-fast 5 PGRUN_IN_MODE=fast PGRUN_IN_WORKERS=4 PGRUN_IN_TEST_COMMAND="sleep 60"
[ "$code" = 130 ] && [ "$(live_branches)" = 0 ] && [ "$(grep -c '^branch delete' "$STUB_DIR/calls")" -ge 4 ] && ok "H: fast mode cancelled mid-suite → all 4 branches deleted" || bad "H fast" "$(cat "$RUNNER_TEMP/log")"

echo "lifecycle tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
