#!/usr/bin/env bash
# The production-like run refuses a public repository unless allowed (the guard used
# `.repository.private // empty`, which never matches false — fixed 2026-11-14).
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(dirname "$here")"
pass=0; fail=0
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
run() { # <private> <allow>
  echo "{\"repository\":{\"private\":$1}}" > "$w/event.json"
  env -i PATH="$PATH" HOME="$w" RUNNER_TEMP="$w" GITHUB_WORKSPACE="$w" GITHUB_EVENT_PATH="$w/event.json" GITHUB_EVENT_NAME=pull_request \
    GITHUB_OUTPUT="$w/out" GITHUB_STEP_SUMMARY="$w/sum" PGRUN_API_TOKEN=pgrun_test PGRUN_IN_MODE=production-like \
    PGRUN_IN_ALLOW_PUBLIC_REPOSITORY="$2" PGRUN_API_URL=https://127.0.0.1:9 "$root/lib/pgrun-ci" run 2>&1
}
out=$(run false false); grep -q "this repository is public" <<< "$out" && { pass=$((pass+1)); echo "ok   public repo refused"; } || { fail=$((fail+1)); echo "FAIL public repo not refused"; echo "$out" | tail -3; }
out=$(run true false); grep -q "this repository is public" <<< "$out" && { fail=$((fail+1)); echo "FAIL private repo refused"; } || { pass=$((pass+1)); echo "ok   private repo not refused by the guard"; }
out=$(run false true); grep -q "this repository is public" <<< "$out" && { fail=$((fail+1)); echo "FAIL allow-public-repository ignored"; } || { pass=$((pass+1)); echo "ok   allow-public-repository: true accepted"; }
echo "public guard tests: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
