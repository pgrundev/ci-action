# Migration verification (`verify: true`)

Opt-in, off by default. With `verify: true` the action runs
`pgrun bot verify --json` before the mode's run (production-like or fast):

1. pgrun creates its own disposable branches of the project's **Safe Copy**: a PostgreSQL branch (the canonical engine) and, with `verify-compare-pgx: true`, a PGX branch.
2. It runs your migration command on them, with `DATABASE_URL` set to the branch. The PGRun token is not in the migration's environment.
3. PgBot snapshots and lints the schema before and after, and classifies what the migration did: table rewrites, blocking index builds, `SET NOT NULL`, drops, renames, type changes.
4. With PGX, the two resulting schemas are compared.
5. pgrun deletes its branches on every exit path. Their TTL (`ttl`) is the backstop.

The action reads pgrun's report and turns it into a job summary, annotations and step outputs. A blocking verdict fails the step, and the mode's run is skipped.

```yaml
      - uses: pgrundev/ci-action@<full sha>
        with:
          token: ${{ secrets.PGRUN_API_TOKEN }}
          verify: true
          # verify-command: npx prisma migrate deploy   # default: the migrate command
          # verify-block-on: fail,dangerous,incomplete,error
```

## What it does not do

It verifies **one** migration against the project's Safe Copy baseline. It does **not** detect conflicts between parallel migrations from different pull requests or agents against a changing production schema, for example two pull requests that each pass alone but conflict once both are merged. That check is not implemented.

## Verdicts

Every category that applied is listed. A run can be both `dangerous` and `warning`. The verdict is the highest-precedence one:

| Verdict | Summary section | Meaning | Blocks by default |
|---|---|---|---|
| `fail` | ❌ Confirmed failure | The migration exited non-zero on canonical PostgreSQL. | yes |
| `dangerous` | ⚠️ Dangerous operations | The schema review found findings at or above `verify-fail-on`. Each is listed with its advice. | yes |
| `unsupported` | 🧪 Unsupported on PGX | PGX could not run the migration, produced a different schema, or was unavailable for the project. PostgreSQL was fine. | no |
| `incomplete` | ❓ Incomplete | The schema review or lint could not run, for example with an old pgbot. **Never a pass.** | yes |
| `error` | 🛠️ Infrastructure error | A branch never became ready, an API failure, a command that could not start, the CLI missing, or a report the action cannot read. | yes |
| `warning` | ℹ️ Informational warnings | Findings below the threshold, new lint findings, or a verification branch that could not be deleted. | no |
| `pass` | ✅ Success | None of the above. | — |

`verify-block-on` sets which categories fail the step. The action passes it to pgrun and follows the report's `blocking` field. Warnings never fail the step unless you list `warning`.

The action also reports these as `error`, decided by `verify-block-on` like any other: no pgrun with `bot verify` on the runner; pgrun exiting without one pgrun-verify 1.x JSON document on stdout; exit 2 (not authenticated or not configured); exit 64 (arguments rejected, usually a CLI that is too old).

A refusal fails the step whatever `verify-block-on` says. The action refuses on:
- no token;
- `pull_request_target`;
- a public repository without `allow-public-repository: true`;
- an invalid input;
- no migration command;
- a Rails app without its bundle.

## Inputs

| Input | Default | |
|---|---|---|
| `verify` | `false` | `true` runs the verification step. |
| `verify-command` | the migrate command | The command pgrun runs on each verification branch (Rails: `bin/rails db:migrate`). It runs in `working-directory` with `RAILS_ENV` = `rails-env`. |
| `verify-compare-pgx` | `true` | Also run on PGX and compare schemas. |
| `verify-fail-on` | `critical` | Severity that makes a finding `dangerous`: `critical`, `warning` or `none`. |
| `verify-block-on` | `fail,dangerous,incomplete,error` | Comma list of categories that fail the step, or `none`. |

Shared with the rest of the action: `token`, `project`, `api-url`, `ttl`, `working-directory`, `framework`, `rails-env`, `allow-public-repository`.

## Outputs

| Output | |
|---|---|
| `verify-verdict` | `pass`, `warning`, `dangerous`, `fail`, `unsupported`, `incomplete` or `error`. |
| `verify-blocking` | `true` or `false`. |
| `verify-categories` | Every category that applied, comma-separated. |
| `verify-report` | Path of the pgrun-verify JSON report on the runner, for `actions/upload-artifact` or your own checks. Connection URLs are redacted from it. Its directory is unique per run, so several runs on one runner never share it. |

## Getting the CLI

The action never downloads a CLI it can't check against a SHA-256 it pins. The first pgrun release with `bot verify` is not pinned yet. Until it is, install pgrun in a step before this one, at an exact version. For example, with the npm package, which brings PgBot along:

```yaml
      - run: npm install -g @pgrun/cli@<exact version>
```

If pgbot is missing, the action runs `pgrun bot install`. That installs pgrun's pinned pgbot release and verifies its SHA-256.

## Cleanup

pgrun deletes its verification branches itself, also when cancelled: the action forwards the signal and waits for it. A branch it could not delete is listed under **Verification branches** in the summary, with a warning annotation. Its TTL (`ttl`, default `1h`) expires it.

The verification step never touches the branches of the production-like or fast run. Their cleanup step works as before.
