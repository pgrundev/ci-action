# Example run

This is real output from the action's own test suite (`tests/test_rails_local.sh`), unedited apart from removed `::add-mask::` lines.
- **The app:** a small Rails 8.1 sample app.
- **The data:** a local PostgreSQL database plays the Safe Copy. Its table `pgrun_ci_probes` holds 50 rows.
- **The server:** the PGRun API and CLI are stubs.
- **Timings:** they show whole seconds, because that machine's clock has whole-second resolution; Linux runners report milliseconds.

The pull request adds two migrations: one adds a column, the other removes a populated column.

## A destructive migration fails

```
pgrun: framework: rails · Ruby ruby-4.0.5
pgrun: project app · Protect active (policy v1) · Safe Copy ready, 0h old
pgrun: 1 branch(es) ready in 0.0s · engines: pgx=1
pgrun: data profile before the migrations
pgrun-profile: 3 tables (exact 3), 54 rows counted, 3 constraints, 0 NOT VALID, 0.0s
pgrun: applying migrations: bin/rails db:migrate
pgrun: data profile after, compared
pgrun-profile: 3 tables (exact 3), 56 rows counted, 3 constraints, 0 NOT VALID, 0.0s
  note: column added: public.pgrun_ci_probes.priority integer NOT NULL
::error title=PGRun data check::column dropped: public.pgrun_ci_probes.note (50 non-null values)
::notice title=PGRun data check::if this loss is intended, a PGRun admin can approve it for the migration that causes it, by version and SHA-256 (the 2 migrations applied are listed with theirs). An approved migration then runs on its own step with Rails' default migrate command; otherwise it must be the only migration the run applies
pgrun-profile: 2 migration(s) applied; 3 tables (exact 3); 1 problem(s), 0 approved loss(es), 0 warning(s)
== 20261015170001 AddPriorityToProbes: migrating ==============================
-- add_column(:pgrun_ci_probes, :priority, :integer, {default: 0, null: false})
== 20261015170001 AddPriorityToProbes: migrated (0.0021s) =====================
== 20261015170002 DropProbeNote: migrating ====================================
-- remove_column(:pgrun_ci_probes, :note, :string)
== 20261015170002 DropProbeNote: migrated (0.0005s) ===========================
::error title=PGRun CI::data checks failed — see the summary for the table, column or constraint.
pgrun: deleted 1 branch(es) in 0 ms
```

The job summary:

| | |
|---|---|
| Project | app |
| Source | PostgreSQL 18.1 |
| Engine | PGX ×1 |
| Snapshot | approved and sanitized (policy v1) |
| Snapshot freshness | 2026-10-15T19:17:35Z (0h old) |
| Tables analyzed | 3 (3 exact) |
| Branch ready | 0.0s (1 branch) |
| Migrations | PASS — 2 applied (0.0s) |
| Data integrity | FAIL (profile 0.0s + 1.0s) |
| Application tests | NOT CONFIGURED |
| Cleanup | completed (deleted 1) |
| Result | **FAIL** |

**Data checks failed** — 1 problem(s):

- ❌ column dropped: public.pgrun_ci_probes.note (50 non-null values)

*2 migration(s) applied, with the SHA-256 an approval must name:*
- `20261015170001` db/migrate/20261015170001_add_priority_to_probes.rb `b35e9af0e421e269353cc952dff4648ae320eb56a7182db328be43363fcca29a`
- `20261015170002` db/migrate/20261015170002_drop_probe_note.rb `9a64ea5a9e858187d4e7c92d16798a5cf501c24a299b4d4e968ffd4720b3f8b7`

## After an admin approves it

The admin approves `drop pgrun_ci_probes.note` for migration `20261015170002` with SHA-256 `9a64ea5a…`. The approved migration then runs as its own step:

```
pgrun: an approved migration is pending: applying the migrations in 2 steps, each profiled
pgrun: applying migrations: bin/rails db:migrate
pgrun: step 1/2 (batch): 20261015170001
pgrun: data profile after step 1, compared
pgrun-profile: 3 tables (exact 3), 55 rows counted, 3 constraints, 0 NOT VALID, 0.1s
  note: column added: public.pgrun_ci_probes.priority integer NOT NULL
pgrun-profile: 1 migration(s) applied; 3 tables (exact 3); 0 problem(s), 0 approved loss(es), 0 warning(s)
pgrun: step 2/2 (approved): 20261015170002
pgrun: data profile after step 2, compared
pgrun-profile: 3 tables (exact 3), 56 rows counted, 3 constraints, 0 NOT VALID, 0.1s
::warning title=PGRun approved data loss::column dropped: public.pgrun_ci_probes.note (50 non-null values) — allowed by migration 20261015170002: notes moved
pgrun-profile: 1 migration(s) applied; 3 tables (exact 3); 0 problem(s), 1 approved loss(es), 0 warning(s)
pgrun: deleted 1 branch(es) in 0 ms
```

Each later outcome was also tested:
- **The file is edited after approval:** "the file changed after it was approved (approved sha256 …, this file …)", and the run fails.
- **A third migration in the same PR clears another column:** that loss still fails. The approval covers only its own step.

## Fast CI

```
pgrun: CI template ci (schema only; rebuilt only when the schema or seed changed)
pgrun: 2 branch(es) ready in 1.0s · engines: pgx=2
pgrun: preparing 2 branch(es): bin/rails db:migrate
pgrun: 2 test files in 2 groups (by file size)
...
1 runs, 1 assertions, 0 failures, 0 errors, 0 skips
...
1 runs, 3 assertions, 0 failures, 0 errors, 0 skips
pgrun: deleted 2 branch(es) in 1000 ms
```
