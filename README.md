# PGRun CI

**Disposable PostgreSQL for any stack, any agent, any CI.** Every job gets its own isolated database — a copy-on-write branch of your sanitized production data, or an empty schema — and it is deleted when the job ends.

PGRun provides the database. You decide what to run.

## Any stack: `pgrundev/ci-action/database`

```yaml
    steps:
      - uses: actions/checkout@v7

      - uses: pgrundev/ci-action/database@v1
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}

      # Your own commands. DATABASE_URL is set; the database is deleted when the job ends.
      - run: npm ci && npx prisma migrate deploy && npm test
```

- `data: sanitized` (default) — a branch of the project's Safe Copy: production-like data, protected by your approved Protect policy.
- `data: schema-only` — your schema with empty tables (plus the CI template's seed), for fast unit tests.
- `branches: N` — N isolated databases: `DATABASE_URL_1..N` for parallel test workers.
- Cleanup on success, failure and cancellation; the branch TTL (`1h`) covers a runner that dies.

The action does nothing else: no framework detection, no migrations, no test runner. Full reference, outputs and examples for Rails, Django, Prisma and Go: **[docs/database.md](docs/database.md)**.

## Rails preset: `pgrundev/ci-action`

The root action is an optional, all-in-one preset for Rails. On every pull request it:
1. Creates a copy-on-write PGX branch of your sanitized production data, in seconds.
2. Runs your migrations on it.
3. Checks that they didn't destroy data.
4. Reports the result in the run summary.
5. Deletes the branch.

Your production database is never touched, and pull request code never sees a production credential.

> Status: **v1**. The preset supports Rails; for any other stack use `pgrundev/ci-action/database`.

## Rails: production-like CI in 3 steps

1. **Connect PostgreSQL and approve Protect in PGRun.** Connect the database, review the data-protection policy (what is masked, faked or removed), and approve it. PGRun then builds the sanitized **Safe Copy**.
2. **Add a CI token to GitHub.**
   1. In PGRun, open your project → **CI** → **Create CI token**, and choose how long it lasts (30, 90, 180 or 365 days). The action warns two weeks before it expires.
   2. In GitHub, go to repository **Settings → Secrets and variables → Actions → New repository secret**.
   3. Name it `PGRUN_API_TOKEN` and paste the token.
3. **Add one workflow file** at `.github/workflows/pgrun.yml`:

```yaml
name: PGRun CI

on:
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  production-like:
    # Pull requests from forks get no secrets; run only for this repository's branches.
    if: >-
      github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    timeout-minutes: 45
    concurrency:
      group: pgrun-${{ github.event.pull_request.number || github.ref }}
      cancel-in-progress: true

    steps:
      - uses: actions/checkout@v7

      - uses: pgrundev/ci-action@v1
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}
          mode: production-like
```

`@v1` follows the latest v1 release. To pin an exact, immutable version instead, use the release's full commit SHA, which the [release page](https://github.com/pgrundev/ci-action/releases) lists: `uses: pgrundev/ci-action@<full commit sha>  # v1.0.0`. See [versioning](docs/versioning.md).

That's all. There are no scripts to copy, no Ruby helpers and no database configuration.

## What runs on every pull request

| Step | What happens |
|---|---|
| Authenticate | The token resolves your project. A CI token belongs to one project; an account token that sees several projects needs `project:`. |
| Gates, before anything is created | Protect must be approved, and the Safe Copy must exist, be made under a policy that hasn't been revoked, and be younger than `snapshot-max-hours`. With `engine: pgx`, the project must be PGX-eligible. A failed gate fails the run with the fix to make. |
| Branch | One copy-on-write branch of the Safe Copy, ready in seconds whatever the size of the copy. Nothing is synchronized from production. |
| Engine | With `engine: pgx` (the default), a branch that fell back to stock PostgreSQL fails the run. There is never a silent fallback. |
| Rails setup | Detects Rails from `Gemfile`, `config/application.rb` and `Gemfile.lock`. Installs your Ruby (from `.ruby-version`, `.tool-versions` or the Gemfile) and your bundle with `ruby/setup-ruby`. |
| Migrations | `bin/rails db:migrate` against the branch (`DATABASE_URL`), timed, then `db:abort_if_pending_migrations`. |
| Data checks | A profile of the branch before and after the migrations, compared (see below). |
| Your tests (optional) | `test-command`, against the same branch. |
| Summary | One table in the run summary, plus annotations naming the table, column, constraint or migration. |
| Cleanup | The branch is deleted on success, failure, timeout and cancellation. |

### Data checks

| Check | Fails the run when |
|---|---|
| Rows | A table has fewer rows after the migrations. |
| Values | A column keeps its rows but loses non-null values: a lossy type change, or a backfill that cleared data. |
| Tables and columns | A table or column that held data is dropped. |
| Constraints | A `NOT VALID` constraint is added that the existing rows violate, so `VALIDATE CONSTRAINT` would fail in production. |
| Indexes | An index is left invalid, for example by a failed `CREATE INDEX CONCURRENTLY`. |
| References (Rails) | A migration adds orphans to a relation Rails conventions imply (`<name>_id` → `<names>.id`) where no foreign key enforces it. |
| Polymorphic (Rails) | A `*_type` column no longer holds class names, or no row of a polymorphic association resolves. This also catches a data-protection policy that masks such a column. |
| Migration history | Migrations are still pending after the run. |

These changes are reported but don't fail the run:
- type changes;
- added tables, columns and constraints;
- removed constraints (as a warning);
- problems that were already in the copy before the migrations (as warnings).

**Bounded on big databases.**
- A table estimated at or below `profile-max-exact-rows` (default 5M) is counted exactly. A bigger one is counted on a fixed `TABLESAMPLE` (about 200k rows) and compared as fractions, with a 2% tolerance.
- Every statement has a timeout (`profile-statement-timeout`), and each pass has a time budget (`profile-budget`).
- The summary says which tables were counted exactly, which were sampled, and which weren't profiled.

**What sampling cannot prove.** On a sampled table, a migration that loses a handful of rows or values can pass; large-scale loss cannot. Exact tables have no such gap.

**Not checked by default.**
- Your application's behaviour on the data: run tests written for populated data with `test-command`.
- Query performance.
- Locks the migration would take on production.
- Rollbacks.

### Approving an intentional data loss

When a migration is meant to remove data, approve it in PGRun:
1. Open the project → **CI** → **Approved data changes**.
2. Enter:
   - the migration version and the **SHA-256 of the migration file**. The failing run prints both, under "migration(s) applied";
   - what may be lost: `row_loss` (table), `value_loss` (column) or `drop` (table or column);
   - the exact table or column;
   - the reason.

Only account managers can approve. An approval covers exactly the reviewed file:
- **Edits invalidate it.** If the file changes after approval, even with the same version, the approval no longer applies and the run says so.
- **Only that migration's loss is excused.** With Rails' default migrate command, the approved migration runs as its own step, profiled before and after. The pull request's other migrations are checked without the approval. With a custom `migrate-command`, or another framework, an approval applies only when its migration is the only one the run applies.
- **Only what it names is excused.** Each approved loss is shown on the run as a warning; any loss it doesn't name still fails.

A pull request can't approve its own data loss: approvals live in PGRun, not in the repository.

## Fast CI

Your whole test suite, in parallel. Each worker gets its own empty branch with the production schema (a schema-only CI template), so tests that assume empty tables work unchanged.

```yaml
      - uses: pgrundev/ci-action@v1
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}
          mode: fast
          workers: 8
```

- **Template:** built once, and rebuilt only when the production schema or the seed changes. A CI token cannot set or change the seed, so a pull request cannot alter what every later CI branch starts from: an account manager sets it once with an account token (`pgrun template create <project> ci --schema-only --seed db/ci_seed.sql`). The `seed` input must then name the same file.
- **Branches:** N are created from the template, and each gets your pull request's migrations.
- **Rails preset:** with no `test-command`, test files are split into N groups and run as one process per branch, each with its own `DATABASE_URL`.
  - RSpec is used when `spec/` exists and `rspec-core` is in `Gemfile.lock`; otherwise Minitest.
  - Files are grouped by `spec/parallel_runtime_rspec.log` if you have one, otherwise by file size.
- **Your own runner:** set `test-command`. `DATABASE_URL_1..N`, `PGRUN_WORKERS` and `DATABASE_URL` (the first branch) are exported. With `parallel_tests`, map `TEST_ENV_NUMBER` to `DATABASE_URL_<n>` in `spec/rails_helper.rb`.
- **Capacity:** when the project's branch quota is full, the run waits up to `capacity-wait`. If capacity stays short, it continues with as few as `min-workers` and says so. Every test still runs, just in fewer processes.

## Running your own tests on production-like data

```yaml
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}
          mode: production-like
          test-command: bundle exec rspec spec/production_like
```

Don't point your ordinary suite at production-like data: most tests assume empty tables. Write tests for populated data, such as "every model loads its newest rows" or "this report runs", and run them here.

## Options

| Input | Default | |
|---|---|---|
| `token` | — (required) | The PGRun CI token. |
| `mode` | `production-like` | `production-like` or `fast`. |
| `project` | — | Only needed for an account token that sees several projects. |
| `engine` | `pgx` | `pgx`: fail if a branch isn't on PGX. `postgres`. `any`: accept either. |
| `test-command` | — | Production-like: optional tests. Fast: replaces the Rails preset. |
| `migrate-command` | Rails: `bin/rails db:migrate` | For another framework, or a custom task. |
| `prepare-command` | — | Fast: run on each branch after migrations. |
| `workers` / `min-workers` | `4` / half | Fast: processes and branches. |
| `seed` | — | Fast: SQL loaded into the CI template. An account manager sets it once; a CI token can only use the same file (see Fast mode). |
| `working-directory` | `.` | For a monorepo. |
| `framework` | `auto` | `rails` or `none`. |
| `setup-ruby` / `ruby-version` | `true` / auto | Set `setup-ruby: false` if your job already installed Ruby. |
| `rails-env` | `test` | |
| `capacity-wait` | `1200` | Seconds to wait for the branch quota. |
| `ttl` | `1h` | Branch lifetime if a runner dies. PGRun caps CI-token branches at `6h`. |
| `snapshot-warn-hours` / `snapshot-max-hours` | `24` / `720` | Warn, then fail, on an old Safe Copy. |
| `profile-max-exact-rows` / `profile-budget` / `profile-statement-timeout` | `5000000` / `900` / `120` | Bounds for the data checks. |
| `allow-public-repository` | `false` | Production-like mode refuses to run in a public repository, whose logs anyone can read. |

Output: `result` (`PASS` or `FAIL`).

Services and system packages your app needs (Redis, `libvips`, …) stay ordinary steps in your job before this one. The action uses whatever the job provides.

## Snapshot freshness

The Safe Copy is refreshed on PGRun's schedule, and only under an approved policy.
- **Schema change or unapproved policy edit:** PGRun keeps serving the last approved copy. The run warns, and production migrations missing from the copy are applied with your pull request's.
- **Age:** a copy older than `snapshot-warn-hours` gives a warning; one older than `snapshot-max-hours` fails the run.

## Cleanup and cancellation

Branches are named `ci-<mode>-<pr>-<run id>-<attempt>-<n>`, unique per run. Cleanup deletes only that run's own branches, so concurrent pull requests never touch each other's.

| Situation | What happens |
|---|---|
| Success, failure, timeout | The run step deletes its branches before it exits. |
| Cancellation | GitHub stops the run step, and the action's own `if: always()` cleanup step deletes the run's branches (measured on GitHub: 8 branches in 0.5 s). If the run step gets the signal first, it deletes them itself. |
| Provisioning interrupted | Branches already created are deleted. While waiting for capacity, the run never holds fewer branches than it needs. |
| Run step killed outright | The action's `if: always()` cleanup step deletes what's left. |
| Runner lost | The branch's server-side TTL (`ttl`, default 1h) expires it, and PGRun's sweeper deletes it. |

## Security

- **Least privilege.** Use a **CI token**, not an account token. A CI token:
  - belongs to one project;
  - can create and delete the CI branches that CI tokens of that project created, and read the project's status; developers' branches are out of reach;
  - cannot change a CI template's seed;
  - expires on the date you chose, and can be revoked at any time;
  - cannot change data-protection policies, refresh or copy data, read the production connection, or see other projects.
- **No production credentials in CI.** Branches are cut from the sanitized Safe Copy, and each branch has its own credentials. Code in the job can only reach the disposable branch.
- **Migrations and tests run with `DATABASE_URL` only.** The PGRun token is not in their environment and never on a command line. Branch URLs and passwords are masked in logs. The data checks print names and counts, never row values.
- **Forks.** Pull requests from forks get no secrets: keep the `if:` above. The action also refuses to run under `pull_request_target`, and fails clearly when the token is empty.
- **Know the trust boundary.** Production-like data is the sanitized Safe Copy, and it reaches exactly the people who can push a branch to the repository:
  - Their pull request code runs against it and could send it anywhere.
  - That code runs on the same runner as the action, and runners allow `sudo`, so it could also read the token, which lets it make further branches of the project until the token is revoked.

  The same holds for every GitHub Actions secret, and no YAML condition changes it. Give production-like CI only to repositories whose writers may see the sanitized data, and see [docs/security.md](docs/security.md) for how to narrow it:
  - a GitHub Environment with required reviewers;
  - short branch TTLs;
  - revoking the token.

  GitHub OIDC token exchange, with no long-lived secret at all, is planned.
- **Public repositories.** Production-like mode refuses to run in a public repository, because anyone can read its logs. Opt in with `allow-public-repository: true`.
- **Pin the action** by commit SHA for security-sensitive repositories: `uses: pgrundev/ci-action@<full sha>  # v1.0.0`.

## What you pay for

PGRun has no per-branch, per-seat or per-pull-request fee. You pay for:
- compute while branches run ($0.086 per branch-hour, metered per second);
- storage for the Safe Copy and what branches change ($0.32 per GB-month).

A 7-minute Production-like run uses about 0.12 branch-hours (about $0.01). An 8-worker, 13-minute Fast CI run uses about 1.7 branch-hours (about $0.15). During the beta, usage is covered by the beta credit.

## Compatibility

| | v1 |
|---|---|
| Runner | GitHub-hosted or self-hosted **Linux**, x64 or arm64. Uses bash, `curl`, `jq`, `python3` and `psql`; `psql` is installed if it's missing. |
| Frameworks | Rails (ActiveRecord with the `pg` gem). Other stacks: set `framework: none`, `migrate-command` and `test-command`. The data checks are framework-independent; only the Rails reference checks need Rails. |
| PostgreSQL | Any source PGRun supports. PGX branches are validated for PostgreSQL 18 sources. |
| pgrun CLI | 0.4.0, downloaded from its GitHub release and verified against a pinned SHA-256. |

Versioning: `v1` moves with compatible releases, and `v1.x.y` tags never move. Inputs are only ever added in v1; nothing is renamed or removed.
