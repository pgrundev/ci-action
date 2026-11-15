#!/usr/bin/env bash
# The Rails adapter end to end on a real Rails app, with the stub CLI/API and
# a local Postgres (no PGRun account needed). Opt-in:
#
#   RAILS_APP=<path to a Rails app with the pg gem, bundle installed>
#   COPY_DB=<database on TEST_PG_URL's server that plays the Safe Copy>
#   TEST_PG_URL=postgres://user@host:port/postgres bash tests/test_rails_local.sh
#
# The app is copied; nothing is changed in RAILS_APP.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ci="$here/../lib/pgrun-ci"
: "${RAILS_APP:?}" "${COPY_DB:?}" "${TEST_PG_URL:?}"
export STUB_TEMPLATE_DB="$COPY_DB" PATH="$here/stub:$PATH"
root=$(mktemp -d); pass=0; fail=0
# Hermetic: never inherit the runner's own event file (on GitHub it describes THIS public
# repository, and the public-repository guard would refuse every production-like run).
echo '{"repository":{"private":true}}' > "$root/private_event.json"
export GITHUB_EVENT_PATH="$root/private_event.json"
export STUB_DIR="$root/stub"; mkdir -p "$STUB_DIR"
jq -n '{token: "good", status: 200, body: {project: {name: "app"}, source: {postgres_version: "18.1"},
  protect: {status: "active", policy_version: 1}, safe_copy: {status: "ready", updated_at: (now | todate), policy_version: 1},
  pgx: {eligible: true}, allowances: []}}' > "$STUB_DIR/context.json"
python3 "$here/stub/api.py" & api=$!
# shellcheck disable=SC2154  # $db is the trap's own loop variable
trap 'kill $api 2>/dev/null; for db in $(psql "$TEST_PG_URL" -Atc "SELECT datname FROM pg_database WHERE datname LIKE '"'"'stub\\_%'"'"'"); do psql "$TEST_PG_URL" -qc "DROP DATABASE $db WITH (FORCE)" >/dev/null 2>&1; done; rm -rf "$root"' EXIT
for _ in $(seq 50); do [ -s "$STUB_DIR/api_port" ] && break; sleep 0.1; done

run() {   # <name> <app dir> [VAR=value...]
  local name="$1" app="$2"; shift 2
  export RUNNER_TEMP="$root/$name"; mkdir -p "$RUNNER_TEMP"
  export GITHUB_STEP_SUMMARY="$RUNNER_TEMP/summary.md" GITHUB_OUTPUT="$RUNNER_TEMP/out"
  out=$(cd "$app" && env PGRUN_IN_API_URL="http://127.0.0.1:$(cat "$STUB_DIR/api_port")" PGRUN_API_TOKEN=good GITHUB_RUN_ID=$RANDOM \
        GITHUB_REF=refs/pull/1/merge GITHUB_EVENT_NAME=pull_request "$@" \
        bash -c "'$ci' detect && '$ci' run; c=\$?; '$ci' cleanup >/dev/null; exit \$c" 2>&1); code=$?
  if [ -n "${KEEP_OUT:-}" ]; then printf '%s\n' "$out" > "$KEEP_OUT/$name.log"; cp "$GITHUB_STEP_SUMMARY" "$KEEP_OUT/$name.md" 2>/dev/null || true; fi
}
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; sed 's/^/     /' <<< "$2" | tail -30; }

app="$root/app"; cp -R "$RAILS_APP" "$app"; rm -rf "$app/.git" "$app/tmp/cache"

run detect "$app"
grep -q "framework: rails" <<< "$out" && ok "N: Rails detected from Gemfile, config/application.rb, bin/rails" || bad "detect" "$out"

run no-pending "$app"
[ $code = 0 ] && grep -q "Migrations | PASS — 0 applied" "$GITHUB_STEP_SUMMARY" && grep -q "Data integrity | PASS" "$GITHUB_STEP_SUMMARY" \
  && ok "N: production-like, no pending migrations → PASS with no app-specific files" || bad "no pending" "$out"

cat > "$app/db/migrate/20261015170001_add_priority_to_probes.rb" <<'RUBY'
class AddPriorityToProbes < ActiveRecord::Migration[8.1]
  def change
    add_column :pgrun_ci_probes, :priority, :integer, default: 0, null: false
  end
end
RUBY
run valid "$app"
[ $code = 0 ] && grep -q "Migrations | PASS — 1 applied" "$GITHUB_STEP_SUMMARY" && grep -q "column added: public.pgrun_ci_probes.priority integer NOT NULL" "$GITHUB_STEP_SUMMARY" \
  && ok "B: a valid Rails migration passes; the summary lists the new column" || bad "valid" "$out$(cat "$GITHUB_STEP_SUMMARY")"

cat > "$app/db/migrate/20261015170002_drop_probe_note.rb" <<'RUBY'
class DropProbeNote < ActiveRecord::Migration[8.1]
  def change
    remove_column :pgrun_ci_probes, :note, :string
  end
end
RUBY
run destructive "$app"
[ $code = 1 ] && grep -q "column dropped: public.pgrun_ci_probes.note (50 non-null values)" <<< "$out" \
  && ok "C: remove_column on a populated column fails with the column named" || bad "destructive" "$out"

# An approval naming this file's SHA-256: the action runs it on its own step, so
# the approval covers exactly that migration and the other pending one is checked alone.
note_sha=$(shasum -a 256 "$app/db/migrate/20261015170002_drop_probe_note.rb" | cut -d' ' -f1)
allow() { jq --argjson a "$1" '.body.allowances = $a' "$STUB_DIR/context.json" > "$STUB_DIR/c.json" && mv "$STUB_DIR/c.json" "$STUB_DIR/context.json"; }
allow '[{"migration_version":"20261015170002","migration_sha256":"'"$note_sha"'","kind":"drop","target":"pgrun_ci_probes.note","reason":"notes moved"}]'
run approved "$app"
[ $code = 0 ] && grep -q "applying the migrations in 2 steps" <<< "$out" && grep -q "approved data loss.*pgrun_ci_probes.note.*notes moved" <<< "$out" \
  && grep -q "Migrations | PASS — 2 applied" "$GITHUB_STEP_SUMMARY" && grep -q "$note_sha" "$GITHUB_STEP_SUMMARY" \
  && ok "D: approved remove_column runs on its own step and passes with a warning" || bad "approved" "$out"

cat > "$app/db/migrate/20261015170004_clear_names.rb" <<'RUBY'
class ClearNames < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE pgrun_ci_probes SET status = NULL"
  end
end
RUBY
run approved-plus-unapproved "$app"
[ $code = 1 ] && grep -q "approved data loss.*pgrun_ci_probes.note" <<< "$out" && grep -q "values lost: public.pgrun_ci_probes.status" <<< "$out" \
  && ok "D: an unapproved migration in the same PR cannot borrow the approval" || bad "approved+unapproved" "$out"
rm "$app/db/migrate/20261015170004_clear_names.rb"
allow '[]'
rm "$app/db/migrate/20261015170002_drop_probe_note.rb"

cat > "$app/db/migrate/20261015170003_broken.rb" <<'RUBY'
class Broken < ActiveRecord::Migration[8.1]
  def change
    add_index :pgrun_ci_probes, :no_such_column
  end
end
RUBY
run broken "$app"
[ $code = 1 ] && grep -q "migrations failed" <<< "$out" && grep -q "Migrations | FAIL" "$GITHUB_STEP_SUMMARY" && ok "a failing Rails migration fails the run with its output" || bad "broken" "$out"
rm "$app/db/migrate/20261015170003_broken.rb"

run fast "$app" PGRUN_IN_MODE=fast PGRUN_IN_WORKERS=2
[ $code = 0 ] && grep -q "test files in 2 groups" <<< "$out" && grep -q "Application tests | PASS" "$GITHUB_STEP_SUMMARY" \
  && ok "fast: Rails Minitest preset, 2 branches, per-process DATABASE_URL, no configuration" || bad "fast" "$out"

run fast-more-workers-than-files "$app" PGRUN_IN_MODE=fast PGRUN_IN_WORKERS=4
[ $code = 0 ] && grep -q "2 test files in 2 groups" <<< "$out" && [ "$(grep -c " runs, .* assertions" <<< "$out")" = 2 ] \
  && ok "fast: more workers than test files runs each file once (no empty group runs the whole suite)" || bad "fast 4 workers" "$out"

rm "$app/Gemfile.lock"
run nolock "$app"
[ $code = 1 ] && grep -q "Gemfile.lock is missing" <<< "$out" && ok "actionable setup error: no Gemfile.lock" || bad "nolock" "$out"

echo "rails tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
