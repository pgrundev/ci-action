#!/usr/bin/env bash
# Tests for `pgrun-ci verify` (verify: true) against a fake pgrun that prints
# canned pgrun-verify reports. No network, no database.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ci="$here/../lib/pgrun-ci"
pass=0; fail=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
TOKEN="pgrun_ci_00c0ffee11223344aabbccdd"   # a CI token's shape
FAKE_PATH="$here/stub/verify:$PATH"
mkdir -p "$root/app"

ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/     /' <<< "$2"; }

# doc <file> <verdict> <categories json> [jq edit] — a pgrun-verify 1.1.0 report
doc() {
  jq -n --arg v "$2" --argjson c "$3" '{
    kind: "pgrun-verify", version: "1.1.0", project: "__PROJECT__", verdict: $v, categories: $c,
    blocking: false, policy: {fail_on: "critical", block_on: []}, reasons: [],
    summary: {critical: 0, warning: 0, info: 0, new_lint: 0},
    verification: {engine: "postgres", requested_engine: "postgres", branch: "verify-__PROJECT__-pg", database: "app",
                   ready_ms: 1200, migrate_ms: 800, migration_exit_code: 0},
    schema_review: {findings: [], summary: {critical: 0, warning: 0, info: 0}}, new_lint_findings: [],
    pgx: {engine: "pgx", requested_engine: "pgx", branch: "verify-__PROJECT__-pgx", ready_ms: 900, migrate_ms: 700, migration_exit_code: 0},
    pgx_compatible: true,
    cleanup: [{branch: "verify-__PROJECT__-pg", deleted: true}, {branch: "verify-__PROJECT__-pgx", deleted: true}],
    pgbot_version: "0.9.2", duration_ms: 5400}' | jq "${4:-.}" > "$1"
}

CRIT='{id: "table_rewrite", severity: "critical", object: "public.orders", detail: "ALTER COLUMN TYPE rewrites the table under an ACCESS EXCLUSIVE lock", advice: "add a new column, backfill in batches, then swap"}'
WARN='{id: "index_not_concurrent", severity: "warning", object: "public.orders_idx", detail: "CREATE INDEX blocks writes", advice: "use CREATE INDEX CONCURRENTLY"}'
doc "$root/pass.json" pass '["pass"]'
doc "$root/warning.json" warning '["warning"]' ".new_lint_findings = [{id: \"no_pk\", severity: \"warning\", object: \"public.events\", title: \"table without a primary key\"}] | .summary.new_lint = 1
  | .cleanup[1] = {branch: \"verify-__PROJECT__-pgx\", deleted: false, error: \"503 from the API\"}
  | .reasons = [\"verification branch verify-__PROJECT__-pgx could not be deleted (its TTL removes it): 503 from the API\"]"
doc "$root/dangerous.json" dangerous '["dangerous","warning"]' ".schema_review.findings = [$CRIT, $WARN] | .schema_review.summary = {critical: 1, warning: 1, info: 0} | .reasons = [\"schema review: 1 critical, 1 warning\"]"
doc "$root/fail.json" fail '["fail"]' '.verification.migration_exit_code = 1 | .verification.error = "PG::UndefinedTable: relation \"widgets\" does not exist" | .reasons = ["the migration exited 1 on postgres"]'
doc "$root/unsupported.json" unsupported '["unsupported"]' '.pgx_compatible = false | .pgx.migration_exit_code = 1 | .pgx.error = "PGX: unsupported statement CREATE EXTENSION" | .reasons = ["the migration exited 1 on PGX but 0 on PostgreSQL"]'
doc "$root/unavailable.json" unsupported '["unsupported"]' '.pgx_compatible = null | .pgx = {engine: "", requested_engine: "pgx", branch: "verify-__PROJECT__-pgx", unavailable: {error: "engine_unavailable", message: "PGX is not enabled for this project"}} | .reasons = ["PGX unavailable: PGX is not enabled for this project"]'
doc "$root/incomplete.json" incomplete '["incomplete"]' 'del(.schema_review) | .schema_review_skipped = "pgbot 0.8.0 has no `schema` command" | .reasons = ["schema review skipped: pgbot 0.8.0 has no `schema` command"]'
doc "$root/error.json" error '["error"]' '.verification = {engine: "", requested_engine: "postgres", branch: "verify-__PROJECT__-pg", ready_ms: 300000, error: "branch was not ready after 300s"} | del(.pgx, .pgx_compatible, .schema_review) | .reasons = ["branch verify-__PROJECT__-pg was not ready after 300s"]'

# run_verify <name> [VAR=value ...] — the verify step as the composite runs it.
# RUNNER_TEMP is shared by default (one job); outputs and summary are per run.
run_verify() {
  local name="$1"; shift
  local d="$root/run-$name"; mkdir -p "$d"
  export FAKE_DIR="$d"
  out=$(cd "$root/app" && env PATH="$FAKE_PATH" RUNNER_TEMP="${SHARED_TEMP:-$root/temp}" \
        GITHUB_OUTPUT="$d/out" GITHUB_STEP_SUMMARY="$d/summary.md" GITHUB_EVENT_NAME=pull_request \
        PGRUN_API_TOKEN="$TOKEN" PGRUN_IN_API_URL=https://app.pgrun.dev PGRUN_IN_FRAMEWORK=none \
        PGRUN_IN_MIGRATE_COMMAND='bin/migrate' "$@" "$ci" verify 2>&1)
  code=$?
  summary=$(cat "$d/summary.md" 2>/dev/null)
  calls=$(cat "$d/calls" 2>/dev/null)
}
output() { grep "^$1=" "$root/run-$2/out" | tail -1 | cut -d= -f2-; }
report_of() { output report "$1"; }

# ---------------------------------------------------------------- verdicts
# verdict_case <name> <doc> <want exit> <want verdict> <want blocking> <summary text> <annotation regex> [VAR=value...]
verdict_case() {
  local name="$1" d="$2" want="$3" verdict="$4" blocking="$5" text="$6" ann="$7"; shift 7
  run_verify "$name" FAKE_DOC="$root/$d.json" "$@"
  local rep; rep=$(report_of "$name")
  if [ "$code" = "$want" ] && [ "$(output verdict "$name")" = "$verdict" ] && [ "$(output blocking "$name")" = "$blocking" ] \
     && grep -qF -- "$text" <<< "$summary" && grep -qE -- "$ann" <<< "$out" && [ -s "$rep" ] && jq -e . "$rep" > /dev/null; then
    ok "$name: exit $want, verdict $verdict, blocking $blocking"
  else
    bad "$name" "exit $code (want $want) verdict=$(output verdict "$name") blocking=$(output blocking "$name")
$out
$summary"
  fi
}

verdict_case pass pass 0 pass false "✅ Success" "verification: pass"
grep -q '^::error' <<< "$out" && bad "pass: no error annotation" "$out" || ok "pass: no error annotation"
grep -qF "| PostgreSQL run | branch \`verify-default-pg\` · on postgres · ready in 1.2s · migration exit 0 in 0.8s |" <<< "$summary" \
  && grep -qF "· compatible |" <<< "$summary" && ok "pass: summary shows both runs" || bad "pass: summary runs" "$summary"
grep -qF "does not detect conflicts between migrations of parallel pull requests" <<< "$summary" && ok "summary states what verification does not cover" || bad "scope note" "$summary"

verdict_case warning warning 0 warning false "ℹ️ Informational warnings" "^::warning title=PGRun verify::verification branch verify-default-pgx could not be deleted"
grep -qF "\`verify-default-pgx\`: ⚠️ **not deleted** — its TTL (\`1h\`) expires it: 503 from the API" <<< "$summary" && grep -qF "| warning | \`no_pk\` | public.events | table without a primary key |" <<< "$summary" \
  && ok "warning: undeleted verification branch and new lint listed; the step passes" || bad "warning summary" "$summary"

verdict_case dangerous dangerous 1 dangerous true "⚠️ Dangerous operations" "^::error title=PGRun verify table_rewrite::public.orders: ALTER COLUMN TYPE rewrites"
grep -qF "| critical | \`table_rewrite\` | public.orders | ALTER COLUMN TYPE rewrites the table under an ACCESS EXCLUSIVE lock | add a new column, backfill in batches, then swap |" <<< "$summary" \
  && grep -qF "ℹ️ Informational warnings" <<< "$summary" && grep -qF "| Blocking | yes — dangerous |" <<< "$summary" \
  && grep -qE "^::warning title=PGRun verify index_not_concurrent::" <<< "$out" \
  && ok "dangerous: findings with advice; dangerous and warning both listed; below-threshold finding is a warning" || bad "dangerous summary" "$summary$out"
verdict_case dangerous-noblock dangerous 0 dangerous false "⚠️ Dangerous operations" "^::warning title=PGRun verify table_rewrite::" PGRUN_IN_VERIFY_BLOCK_ON="fail,error"
grep -q '^::error' <<< "$out" && bad "dangerous not in block-on: no error annotation" "$out" || ok "dangerous not in block-on: warnings only"
verdict_case dangerous-failon-warning dangerous 1 dangerous true "fail-on \`warning\`" "^::error title=PGRun verify index_not_concurrent::" PGRUN_IN_VERIFY_FAIL_ON=warning

verdict_case fail fail 1 fail true "❌ Confirmed failure" "^::error title=PGRun verify::confirmed failure on PostgreSQL: the migration exited 1 on postgres"
grep -qF 'migration exit 1 in 0.8s · error: PG::UndefinedTable: relation "widgets" does not exist' <<< "$summary" && ok "fail: summary shows the migration error" || bad "fail summary" "$summary"
verdict_case fail-blockon-none fail 0 fail false "❌ Confirmed failure" "^::warning title=PGRun verify::confirmed failure" PGRUN_IN_VERIFY_BLOCK_ON=none
grep -qF "block-on \`none\`" <<< "$summary" && ok "block-on none is reported" || bad "block-on none" "$summary"

verdict_case unsupported unsupported 0 unsupported false "🧪 Unsupported on PGX" "^::warning title=PGRun verify::unsupported on PGX: PGX: unsupported statement"
grep -qF "**not compatible**" <<< "$summary" && ok "unsupported: PGX not compatible in the summary" || bad "unsupported summary" "$summary"
verdict_case unsupported-blocking unsupported 1 unsupported true "🧪 Unsupported on PGX" "^::error title=PGRun verify::unsupported on PGX" PGRUN_IN_VERIFY_BLOCK_ON="fail,dangerous,unsupported,incomplete,error"
verdict_case pgx-unavailable unavailable 0 unsupported false "unavailable: PGX is not enabled for this project" "^::warning title=PGRun verify::unsupported on PGX"

verdict_case incomplete incomplete 1 incomplete true "❓ Incomplete" "^::error title=PGRun verify::incomplete — the migration was not reviewed: pgbot 0.8.0"
grep -qF "| Schema review | skipped: pgbot 0.8.0 has no \`schema\` command |" <<< "$summary" && ok "incomplete: the skip reason is shown, never a pass" || bad "incomplete summary" "$summary"

verdict_case error-exit3 error 1 error true "🛠️ Infrastructure error" "^::error title=PGRun verify::infrastructure error: branch verify-default-pg was not ready after 300s"
grep -q "exit 3" <<< "$out" && ok "exit 3 (infrastructure only) is read from the report" || bad "exit 3" "$out"
verdict_case error-noblock error 0 error false "🛠️ Infrastructure error" "^::warning title=PGRun verify::infrastructure error" PGRUN_IN_VERIFY_BLOCK_ON="fail,dangerous"

# ------------------------------------------------- unreadable report, no CLI
verdict_case unparseable pass 1 error true "pgrun exited 1 without a pgrun-verify 1.x JSON report" "^::error title=PGRun verify::infrastructure error" FAKE_RAW="panic: something went wrong"
jq -e '.source == "pgrun-ci" and .categories == ["error"]' "$(report_of unparseable)" > /dev/null && ok "unparseable: the action writes an error report" || bad "unparseable report"
verdict_case unparseable-noblock pass 0 error false "🛠️ Infrastructure error" "infrastructure error" FAKE_RAW="not json" PGRUN_IN_VERIFY_BLOCK_ON="fail,dangerous,incomplete"
verdict_case two-documents pass 1 error true "without a pgrun-verify 1.x JSON report" "infrastructure error" FAKE_RAW='{"kind":"pgrun-verify"} {"kind":"pgrun-verify"}' FAKE_EXIT=0
verdict_case wrong-kind pass 1 error true "without a pgrun-verify 1.x JSON report" "infrastructure error" FAKE_RAW='{"kind":"pgbot-report","verdict":"pass","blocking":false,"categories":[]}' FAKE_EXIT=0
verdict_case future-major pass 1 error true "without a pgrun-verify 1.x JSON report" "infrastructure error" FAKE_RAW='{"kind":"pgrun-verify","version":"2.0.0","verdict":"pass","blocking":false,"categories":["pass"]}' FAKE_EXIT=0
verdict_case auth-exit2 pass 1 error true "pgrun is not authenticated or not configured (exit 2)" "infrastructure error" FAKE_RAW="" FAKE_EXIT=2
verdict_case old-cli pass 1 error true "no pgrun CLI with \`bot verify\` on this runner" "infrastructure error" FAKE_OLD=1
grep -q "bot verify" <<< "$calls" && bad "old CLI: verify never attempted" "$calls" || ok "old CLI: verify never attempted"

# pgrun not on PATH at all: only system tools and jq.
tools="$root/tools"; mkdir -p "$tools"; ln -sf "$(command -v jq)" "$tools/jq"
run_verify missing PGRUN_IN_VERIFY_BLOCK_ON=fail,dangerous,incomplete,error FAKE_DOC="$root/pass.json" PATH="/usr/bin:/bin:/usr/sbin:/sbin:$tools"
[ "$code" = 1 ] && [ "$(output verdict missing)" = error ] && grep -q "no pgrun CLI with \`bot verify\`" <<< "$summary" && [ -z "$calls" ] \
  && ok "CLI missing: infrastructure error, nothing downloaded unpinned" || bad "CLI missing" "$out$summary"
run_verify missing-noblock PGRUN_IN_VERIFY_BLOCK_ON=fail,dangerous FAKE_DOC="$root/pass.json" PATH="/usr/bin:/bin:/usr/sbin:/sbin:$tools"
[ "$code" = 0 ] && [ "$(output blocking missing-noblock)" = false ] && ok "CLI missing with error not in block-on: reported, not failed" || bad "CLI missing noblock" "$out"

run_verify pgbot-missing FAKE_DOC="$root/pass.json" FAKE_PGBOT=missing
[ "$code" = 0 ] && grep -q "^bot install" <<< "$calls" && grep -q "^bot verify" <<< "$calls" && ok "pgbot missing: pgrun bot install (pinned, verified by pgrun), then verify" || bad "pgbot install" "$out$calls"

# ------------------------------------------------------------ argv, token
run_verify args FAKE_DOC="$root/pass.json" PGRUN_IN_PROJECT=shop PGRUN_IN_TTL=6h
argv=$(grep '^bot verify' <<< "$calls")
[ "$argv" = "bot verify shop --json --fail-on critical --block-on fail,dangerous,incomplete,error --ttl 6h --timeout 300s --compare-pgx -- env -u PGRUN_API_TOKEN RAILS_ENV=test bash -c bin/migrate" ] \
  && ok "argv: project, policy, ttl, compare-pgx; migrate-command is the default command" || bad "argv" "$argv"
run_verify args-custom FAKE_DOC="$root/pass.json" PGRUN_IN_VERIFY_COMPARE_PGX=false PGRUN_IN_VERIFY_COMMAND='npx prisma migrate deploy' PGRUN_IN_VERIFY_BLOCK_ON='fail, error'
argv=$(grep '^bot verify' <<< "$calls")
[ "$argv" = "bot verify --json --fail-on critical --block-on fail,error --ttl 1h --timeout 300s -- env -u PGRUN_API_TOKEN RAILS_ENV=test bash -c npx prisma migrate deploy" ] \
  && ok "argv: verify-command, no compare-pgx, block-on spaces trimmed" || bad "argv custom" "$argv"

run_verify token FAKE_DOC="$root/dangerous.json" FAKE_LEAK=1 FAKE_RUN_MIGRATION=1 \
  PGRUN_IN_VERIFY_COMMAND='echo "migration sees token: ${PGRUN_API_TOKEN:-none}"; echo "url: $DATABASE_URL"; echo "::error::injected by the migration"'
all="$out$summary$calls$(cat "$(report_of token)")"
if grep -qF "$TOKEN" <<< "$all"; then bad "token never in argv, logs, summary or report" "$all"; else ok "token never in argv, logs, summary or report"; fi
grep -q "token_in_env=yes" "$root/run-token/env" && grep -q "migration sees token: none" <<< "$out" && ok "pgrun gets the token by env; the migration does not" || bad "token env" "$out"
grep -q "s3cretpw\|postgres://" <<< "$out$summary" && bad "no branch URL in logs or summary" "$out" || ok "no branch URL in logs or summary"
awk '/^::stop-commands::/ { s = 1 } /^::error::injected/ { if (!s) bad = 1 } /^::[0-9a-f]+::$/ { s = 0 } END { exit bad }' <<< "$out" && grep -q '^::stop-commands::' <<< "$out" \
  && ok "migration output cannot issue workflow commands" || bad "stop-commands" "$out"

# ---------------------------------------------------------------- refusals
run_verify no-token FAKE_DOC="$root/pass.json" PGRUN_API_TOKEN=
[ "$code" = 1 ] && grep -q "no PGRun token" <<< "$out" && [ -z "$calls" ] && ok "no token: refused before pgrun runs" || bad "no token" "$out"
run_verify prt FAKE_DOC="$root/pass.json" GITHUB_EVENT_NAME=pull_request_target
[ "$code" = 1 ] && grep -q "refusing to run on pull_request_target" <<< "$out" && [ -z "$calls" ] && ok "pull_request_target: refused" || bad "prt" "$out"
echo '{"repository":{"private":false}}' > "$root/public.json"
run_verify public FAKE_DOC="$root/pass.json" GITHUB_EVENT_PATH="$root/public.json"
[ "$code" = 1 ] && grep -q "this repository is public" <<< "$out" && [ -z "$calls" ] && ok "public repository: refused" || bad "public" "$out"
run_verify public-allowed FAKE_DOC="$root/pass.json" GITHUB_EVENT_PATH="$root/public.json" PGRUN_IN_ALLOW_PUBLIC_REPOSITORY=true
[ "$code" = 0 ] && ok "public repository with allow-public-repository: runs" || bad "public allowed" "$out"
run_verify bad-failon FAKE_DOC="$root/pass.json" PGRUN_IN_VERIFY_FAIL_ON=high
[ "$code" = 1 ] && grep -q "verify-fail-on must be" <<< "$out" && [ -z "$calls" ] && ok "invalid verify-fail-on: refused" || bad "bad fail-on" "$out"
run_verify bad-blockon FAKE_DOC="$root/pass.json" PGRUN_IN_VERIFY_BLOCK_ON="fail,oops"
[ "$code" = 1 ] && grep -q "unknown category oops" <<< "$out" && [ -z "$calls" ] && ok "invalid verify-block-on: refused" || bad "bad block-on" "$out"
run_verify no-command FAKE_DOC="$root/pass.json" PGRUN_IN_MIGRATE_COMMAND=
[ "$code" = 1 ] && grep -q "no migration command to verify" <<< "$out" && ok "no command: refused" || bad "no command" "$out"
[ ! -e "$root/temp/pgrun-ci/state" ] && ok "verify never writes the run step's state (its cleanup prefix stays the run's own)" || bad "state touched" "$(cat "$root/temp/pgrun-ci/state")"

# -------------------------------------------------------------- concurrency
# N runs at once on ONE runner temp dir (the worst case: one job), each its own
# project, verdict and timing. Reports, outputs and cleanup must stay apart.
N=8; verdicts=(pass dangerous warning fail unsupported incomplete error pass)
export SHARED_TEMP="$root/shared"
for i in $(seq 1 "$N"); do
  ( run_verify "conc-$i" FAKE_DOC="$root/${verdicts[$((i - 1))]}.json" PGRUN_IN_PROJECT="proj$i" FAKE_SLEEP="0.$((RANDOM % 9))"
    echo "$code" > "$root/run-conc-$i/code" ) &
done
wait
unset SHARED_TEMP
reports=(); cerr=""
for i in $(seq 1 "$N"); do
  v="${verdicts[$((i - 1))]}"; rep=$(report_of "conc-$i"); reports+=("$rep")
  s=$(cat "$root/run-conc-$i/summary.md")
  [ "$(jq -r .project "$rep")" = "proj$i" ] || cerr+="run $i: report project $(jq -r .project "$rep"); "
  [ "$(output verdict "conc-$i")" = "$v" ] || cerr+="run $i: verdict $(output verdict "conc-$i") want $v; "
  [ "$(jq -r '[.cleanup[].branch] | join(" ")' "$rep")" = "verify-proj$i-pg verify-proj$i-pgx" ] || cerr+="run $i: cleanup $(jq -c .cleanup "$rep"); "
  grep -q "verify-proj$i-pg" <<< "$s" || cerr+="run $i: own branch missing from summary; "
  for j in $(seq 1 "$N"); do [ "$j" = "$i" ] && continue; grep -q "proj$j\b" <<< "$s" && cerr+="run $i: summary mentions proj$j; "; done
  case "$v" in pass|warning|unsupported) want=0 ;; *) want=1 ;; esac
  [ "$(cat "$root/run-conc-$i/code")" = "$want" ] || cerr+="run $i: exit $(cat "$root/run-conc-$i/code") want $want; "
done
[ "$(printf '%s\n' "${reports[@]}" | sort -u | wc -l | tr -d ' ')" = "$N" ] || cerr+="report paths collide: ${reports[*]}; "
[ -z "$cerr" ] && ok "concurrency: $N parallel runs on one runner keep their reports, outputs, verdicts and cleanup apart" || bad "concurrency" "$cerr"

# ---------------------------------------------- verify: false is a no-op
python3 - "$here/../action.yml" <<'PY' && ok "action.yml: verify defaults to false and gates the only step that runs verify" || bad "action.yml verify gating"
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
assert a["inputs"]["verify"]["default"] == "false"
steps = a["runs"]["steps"]
v = [s for s in steps if "verify" in s.get("run", "") and "pgrun-ci\" verify" in s["run"]]
assert len(v) == 1 and v[0]["if"] == "inputs.verify == 'true'", v
assert all("VERIFY" not in k for s in steps if s is not v[0] for k in (s.get("env") or {}))
PY

echo "verify tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
