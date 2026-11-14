# Security model

## What the workflow can reach

| Credential | Who sees it | What it can do |
|---|---|---|
| `PGRUN_API_TOKEN` (CI token) | The action's own steps. It is not in the environment of migrations or tests, and never on a command line or in a log. Code on the same runner can still obtain it (see below). | One project only: create branches (named `ci-…`, TTL capped at 6 hours), and read or delete only the branches CI tokens of that project created, as recorded by the server; developers' branches are out of reach. Use and rebuild CI templates, but never set or change their seed; read the project's Protect, Safe Copy and PGX status and its approved allowances. Format `pgrun_ci_…`; older PGRun releases reject it. It expires after the 30, 90, 180 or 365 days chosen when it was created. |
| Branch URL (`DATABASE_URL`) | Your migrations and tests. The URL and its password are masked in logs. | Full access to one disposable branch: a copy-on-write clone of the sanitized Safe Copy, with its own credentials and a TTL. |
| Production database | Nobody in CI. | — |

A CI token cannot:
- change or approve a data-protection policy;
- create, copy or refresh a Safe Copy;
- read a production connection string;
- see other projects;
- approve a data loss.

These limits are enforced on the PGRun server, in one allowlist.

## Who can see production-like data

A production-like branch holds the **sanitized** Safe Copy: what the approved Protect policy masked, faked or removed is not in it. Everything the policy copies is.

| Who | Gets the token? | Gets production-like data? |
|---|---|---|
| A pull request from a fork | No: GitHub gives fork PRs no secrets. The job's `if:` skips them, and the action fails before any API call when the token is empty. | No |
| `pull_request_target` | The action refuses to run under it. | No |
| Dependabot pull requests | No: they get Dependabot secrets, not Actions secrets, unless you add one. | No |
| Anyone who can push a branch to the repository | Yes, in effect (see below) | Yes |
| Readers of a **public** repository's logs | No | Only what your code prints. Production-like mode refuses to run in a public repository unless `allow-public-repository: true`. |

### Why anyone who can push gets both

- **The data.** Their pull request's migrations and tests run against the branch with full access. Code can read any table and send it anywhere the runner can reach.
- **The token.** They can edit the workflow in their branch to print it, or read it from the action's process at run time; GitHub-hosted runners give jobs `sudo`. Keeping the token out of the commands' environment stops accidental leaks, not a deliberate one.
- **What a leaked CI token does.** It can create `ci-` branches of that one project, and so read the sanitized copy, until it is revoked. Each branch lives at most 6 hours. It cannot reach unmasked data, production, the policy, developers' branches, other projects, or approvals.

This is GitHub's model for every Actions secret, and no YAML condition changes it. The safeguards that do:

1. **Choose the repository deliberately.** Give production-like CI only to repositories whose writers may see the sanitized data, in practice the people who already work on the application. Fast mode needs no such decision: its branches hold only the schema and your seed file.
2. **A GitHub Environment with required reviewers.** Store `PGRUN_API_TOKEN` as an environment secret and add `environment: pgrun` to the job. A reviewer then approves each run before it gets the token. This works even when the workflow file is edited, because reviewers are enforced by GitHub. The cost is a click per pull request.
3. **Protect the workflow file.** Use CODEOWNERS on `.github/workflows/` with required review, so a change to the workflow cannot merge unreviewed. It does not stop a workflow running from an unmerged branch; only 2 does that.
4. **Revoke and re-mint the token** in PGRun at any time; revocation is immediate.
5. **GitHub OIDC token exchange (planned).** The job presents GitHub's signed identity: repository, ref, workflow and actor. PGRun returns a credential for this run only, which expires with the job and can only create and delete this run's branches. No long-lived secret is stored, and PGRun can refuse refs or workflows it does not trust.

## Data-loss approvals

- Approvals are made in PGRun by account managers, never in the repository, so a pull request cannot approve its own data loss.
- Each approval names a migration version and the **SHA-256 of the migration file**. If the file is edited, even under the same version, the approval stops applying.
- **One migration per approval.** With Rails' default migrate command, the approved migration runs as its own step, profiled before and after, so another migration in the same pull request cannot borrow its approval. With a custom `migrate-command` or another framework, an approval applies only when its migration is the only one the run applies.
- **Limit.** The hash covers the migration file, not code it calls (models, SQL files, libraries). A migration that loads behaviour from elsewhere can change without its hash changing. Reviewers should approve self-contained migrations.

## Data that reaches logs

- **From the action:** only names, types and counts. The data profiler never prints a row value, and it reports a failed statement by its SQLSTATE, never by its message, because messages can quote values.
- **From your migrations and tests:** their output is your own, and on a production-like branch it runs against sanitized data. In a public repository anyone can read it, which is why production-like mode refuses to run there by default.

## Supply chain

- The pgrun CLI is downloaded from its GitHub release and checked against a SHA-256 pinned in the action. A mismatch stops the run before the CLI is unpacked.
- Migration verification (`verify: true`) uses a pgrun CLI already on the runner. The action never downloads an unpinned one, and no release with `bot verify` is pinned yet. pgbot, when missing, comes from `pgrun bot install`, which verifies pgrun's pinned SHA-256. The migration runs under `env -u PGRUN_API_TOKEN`. Its output is redacted of URLs and the token, and printed between `::stop-commands::` markers so it cannot issue workflow commands.
- `ruby/setup-ruby` is pinned by commit.
- The action only sends the token to an `https://` API URL (or localhost, for tests).
- The action itself should be pinned by commit SHA in security-sensitive repositories.
