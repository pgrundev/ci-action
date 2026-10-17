# `pgrundev/ci-action/database` — disposable PostgreSQL for any stack

One step gives your job an isolated PostgreSQL database. Your own steps then use it, with any framework, language or tool. The database is deleted when the job ends.

```yaml
name: CI

on:
  pull_request:

permissions:
  contents: read

jobs:
  test:
    # Pull requests from forks get no secrets; run only for this repository's branches.
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: pgrundev/ci-action/database@v1
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}

      # Your commands. DATABASE_URL is set.
      - run: ./run-your-migrations-and-tests.sh
```

What the action does, and all it does:

1. **Checks the gates.** Protect must be approved and the Safe Copy usable — the same rules as the Rails preset. Nothing is created otherwise.
2. **Creates the branches.** They're isolated, copy-on-write, on PGX by default, and ready in seconds.
3. **Hands you the connection.** It masks the URL and the password in the logs, sets `DATABASE_URL` for the job's later steps, and returns metadata as step outputs.
4. **Deletes the branches when the job ends.** This happens on success, on failure and on cancellation. If the runner itself dies, PGRun deletes them at their TTL (1 hour by default).

It doesn't detect your framework, install a language, run migrations or run tests. You do that, in your own steps.

## Setup

1. **Connect your database in PGRun** and turn on Auto Protect (or approve your own Protect policy). PGRun builds the sanitized **Safe Copy**.
2. **Create a CI token.** In PGRun, open your project → **CI** → **Create CI token**. Then in GitHub, open **Settings → Secrets and variables → Actions** and add it as the `PGRUN_API_TOKEN` secret.
3. **Add the step above to your workflow.**

## Inputs

| Input | Default | |
|---|---|---|
| `token` | — | A PGRun CI token (required). Store it as a secret. |
| `data` | `sanitized` | `sanitized` is a branch of the Safe Copy: production-like data under your approved Protect policy. `schema-only` has your schema with empty tables, plus the CI template's seed. |
| `branches` | `1` | 1–16 isolated databases. With more than one, `DATABASE_URL_1..N` are set too, and `DATABASE_URL` = `DATABASE_URL_1`. |
| `ttl` | `1h` | `1h` or `6h`. PGRun deletes the branches at this age if the job's cleanup never ran. |
| `engine` | `pgx` | `pgx` fails if a branch isn't on PGX (never a silent fallback). `postgres` requires stock PostgreSQL; `any` accepts either. |
| `env-name` | `DATABASE_URL` | The environment variable the URL is exported as, for example `TEST_DATABASE_URL`. |
| `export-env` | `true` | `false` exports nothing; the connection is then only in the step's outputs. |
| `template` | `ci` | For `schema-only`, the name of the CI template. It's created on first use. |
| `project` | — | Only for an account token that sees several projects. A CI token belongs to one project. |
| `capacity-wait` | `600` | Seconds to wait for the project's branch quota before failing. |
| `ready-timeout` | `1200` | Seconds to wait for the branches, and for a schema-only template build. |
| `snapshot-max-hours` | `720` | For `sanitized`, fail when the Safe Copy is older than this. `0` means never. |
| `allow-public-repository` | `false` | See [Security](#security). |
| `api-url` | `https://app.pgrun.dev` | |

## Outputs

| Output | |
|---|---|
| `database-url` | The URL of the first branch. It's masked in the logs. |
| `password` | The password of the first branch. It's masked in the logs. |
| `host`, `port`, `database`, `username` | The parts of the first branch's connection. |
| `engine` | `pgx` or `postgres`: what the branch actually runs on. |
| `branch-name`, `project`, `expires-at` | The branch name, its PGRun project, and when PGRun deletes it if cleanup never runs. |
| `branches` | A JSON array of every branch (`name`, `engine`, `host`, `port`, `database`, `username`, `expires_at`, `env`). It never contains a URL or a password. |

The outputs are for the steps of the same job. GitHub won't pass a masked value to another job, and you shouldn't try to: the database belongs to this job.

## Examples

These are examples, not integrations. Each one is just your usual commands with `DATABASE_URL` set.

### Rails

```yaml
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - uses: pgrundev/ci-action/database@v1
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}

      - run: bin/rails db:migrate && bin/rails test
        env:
          RAILS_ENV: test
```

Rails reads `DATABASE_URL` in every environment. For migration-safety and data-loss checks with no setup, use the [Rails preset](../README.md#rails-preset-pgrundevci-action) instead.

### Django

```yaml
      - uses: actions/setup-python@v6
        with:
          python-version: "3.13"

      - uses: pgrundev/ci-action/database@v1
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}

      - run: |
          pip install -r requirements.txt
          python manage.py migrate
          python manage.py test --keepdb
```

In `settings.py`, read the URL, for example with `dj-database-url`:

```python
import dj_database_url
DATABASES = {"default": dj_database_url.config(conn_max_age=0)}
# Run the tests in the PGRun database itself instead of creating test_<name>:
DATABASES["default"]["TEST"] = {"NAME": DATABASES["default"]["NAME"]}
```

### Prisma (Node.js)

```yaml
      - uses: actions/setup-node@v6
        with:
          node-version: 24

      - uses: pgrundev/ci-action/database@v1
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}

      - run: |
          npm ci
          npx prisma migrate deploy
          npm test
```

`schema.prisma` uses `url = env("DATABASE_URL")`. Use `migrate deploy` in CI, not `migrate dev`: the latter needs a shadow database.

### Go

```yaml
      - uses: actions/setup-go@v6
        with:
          go-version: stable

      - uses: pgrundev/ci-action/database@v1
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}

      - run: |
          go run github.com/golang-migrate/migrate/v4/cmd/migrate@v4.18.3 -path db/migrations -database "$DATABASE_URL" up
          go test ./...
```

Your tests read `os.Getenv("DATABASE_URL")`, for example with `pgx.Connect(ctx, os.Getenv("DATABASE_URL"))`.

### Fast tests on several empty databases

```yaml
      - uses: pgrundev/ci-action/database@v1
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}
          data: schema-only
          branches: 4

      # DATABASE_URL_1..4: one per test worker.
      - run: ./bin/parallel-tests --workers 4
```

A schema-only branch comes from a CI template, which PGRun builds once from your Safe Copy's schema and rebuilds only when the schema changes. To start every branch with reference data, an account manager sets the template's seed once in PGRun (`pgrun template create ci --schema-only --seed db/ci_seed.sql`). A CI token can't change the seed.

## Cleanup

| What happens | What deletes the branches |
|---|---|
| The job succeeds, or a later step fails | The action's post step at the end of the job |
| The run is cancelled, or a step times out | The post step. It runs on cancellation too and deletes every branch the step recorded, including one created a moment before the cancel. |
| The action itself fails, e.g. on a gate or the engine | The action, before it exits |
| The runner dies (no post step can run) | PGRun, at the branch TTL (`ttl`, at most 6h) |

The action deletes only the branches it created. It records their exact names before creating them, and a CI token can only reach branches that the same token created. Two jobs, matrix entries or workflows that run at the same time never touch each other's databases.

## Security

- **The token** is masked, sent only in a header, and only over HTTPS.
- **URLs and passwords** are masked before anything can print them, including the percent-encoded and decoded forms of the password. GitHub masks exact strings only: a command that transforms the value (base64, splitting it) can still reveal it, so don't print connection details.
- **Fork pull requests** get no secrets, so the step fails with a clear message. Add the `if:` above to skip those jobs. `data: sanitized` also refuses a fork pull request even when secrets are passed to it: its code would run against the sanitized copy. `schema-only` is allowed there.
- **`pull_request_target`** is always refused: it would hand pull-request code the token.
- **Public repositories:** `data: sanitized` refuses to run in one, because anyone can read its Actions logs and your steps could print the data. `schema-only` is allowed. Set `allow-public-repository: true` to accept this.
- **The CI token** can create, read and delete only its own `ci-` branches of its one project. It can't change Protect, reach the source database, change a template's seed or create unprotected copies.
- **An exported `DATABASE_URL`** is visible to every later step of the job, including third-party actions. Use `export-env: false` and pass `steps.<id>.outputs.database-url` to just the steps that need it.
