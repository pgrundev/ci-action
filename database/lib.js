'use strict';
// pgrundev/ci-action/database — disposable PostgreSQL for any stack.
//
// main: gates → branches → DATABASE_URL for the job's later steps.
// post: delete the branches this step created (runs on success, failure and
//       cancellation; the branch TTL covers a runner that dies).
//
// No dependencies: Node's own fetch and fs. Never prints a connection URL, a
// password or the token — every secret is masked before anything can echo it.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const VERSION = '1.1.0';
const MAX_BRANCHES = 16;
const RESERVED_ENV = /^(GITHUB_|RUNNER_|ACTIONS_|INPUT_|STATE_|LD_|DYLD_)|^(PATH|HOME|SHELL|ENV|BASH_ENV|NODE_OPTIONS|NODE_PATH|PGRUN_API_TOKEN)$/;

class Failure extends Error {}

// ---------------------------------------------------------------- runner I/O
function input(name, fallback = '') {
  const v = process.env[`INPUT_${name.replace(/ /g, '_').toUpperCase()}`];
  return v === undefined || v.trim() === '' ? fallback : v.trim();
}

const issue = (cmd, msg, title) => process.stdout.write(`::${cmd}${title ? ` title=${escapeProp(title)}` : ''}::${escapeData(msg)}\n`);
const escapeData = (s) => String(s).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
const escapeProp = (s) => escapeData(s).replace(/:/g, '%3A').replace(/,/g, '%2C');
const log = (msg) => process.stdout.write(`pgrun: ${msg}\n`);
const warn = (msg) => issue('warning', msg, 'PGRun');
const error = (msg) => issue('error', msg, 'PGRun');
const mask = (secret) => { if (secret) process.stdout.write(`::add-mask::${escapeData(secret)}\n`); };

// GITHUB_ENV / GITHUB_OUTPUT / GITHUB_STATE: the multi-line form with a random
// delimiter, so no value can inject another variable.
function fileCommand(envVar, name, value) {
  const file = process.env[envVar];
  if (!file) return false;
  const delim = `ghadelimiter_${crypto.randomUUID()}`;
  fs.appendFileSync(file, `${name}<<${delim}\n${value}\n${delim}\n`, { encoding: 'utf8' });
  return true;
}
const setOutput = (name, value) => fileCommand('GITHUB_OUTPUT', name, value);
const exportEnv = (name, value) => fileCommand('GITHUB_ENV', name, value);
const summary = (md) => { if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, md); };

// Server messages may quote what they were sent: never let a URL or token through.
function sanitize(text) {
  return String(text ?? '')
    .replace(/postgres(ql)?:\/\/\S+/gi, '<url>')
    .replace(/pgrun_(ci_)?[0-9a-f]{8,}/gi, '<token>')
    .slice(0, 500);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pause = (s) => sleep(Number(process.env.PGRUN_TEST_PAUSE_MS ?? s * 1000));

// ------------------------------------------------------------------ the API
function apiUrl() {
  const url = input('api-url', 'https://app.pgrun.dev').replace(/\/+$/, '');
  // The token goes in a header: never over plain HTTP to another host.
  if (!/^https:\/\//.test(url) && !/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(url)) {
    throw new Failure('api-url must be https://');
  }
  return url;
}

function client(base, token) {
  return async function api(method, p, body) {
    let lastErr;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        const res = await fetch(base + p, {
          method,
          headers: {
            Authorization: `Bearer ${token}`,
            Accept: 'application/json',
            'User-Agent': `pgrun-database-action/${VERSION}`,
            'X-PGRun-Client': `ci/pgrun-database-action-${VERSION}`,
            ...(body ? { 'Content-Type': 'application/json' } : {}),
          },
          body: body ? JSON.stringify(body) : undefined,
          signal: AbortSignal.timeout(30000),
        });
        if (res.status >= 500 && attempt < 3) { await pause(attempt * 2); continue; }
        let json = {};
        try { json = await res.json(); } catch { /* empty or not JSON */ }
        return { status: res.status, json };
      } catch (e) {
        lastErr = e;
        if (attempt < 3) await pause(attempt * 2);
      }
    }
    throw new Failure(`cannot reach the PGRun API at ${base} (${sanitize(lastErr && lastErr.message)})`);
  };
}

const enc = encodeURIComponent;
const message = (r) => sanitize(r.json.message || r.json.error || `HTTP ${r.status}`);

// ------------------------------------------------------------------- inputs
function readInputs() {
  const token = input('token');
  if (!token) {
    throw new Failure('no PGRun token: the `token` input is empty. A pull request from a fork gets no secrets — run this job only for branches of this repository, and store the token as the PGRUN_API_TOKEN secret.');
  }
  mask(token);
  const i = {
    token,
    project: input('project'),
    data: input('data', 'sanitized'),
    template: input('template', 'ci'),
    branches: input('branches', '1'),
    ttl: input('ttl', '1h'),
    engine: input('engine', 'pgx'),
    envName: input('env-name', 'DATABASE_URL'),
    exportEnv: input('export-env', 'true'),
    capacityWait: input('capacity-wait', '600'),
    readyTimeout: input('ready-timeout', '1200'),
    maxAgeHours: input('snapshot-max-hours', '720'),
    allowPublic: input('allow-public-repository', 'false'),
    apiUrl: apiUrl(),
  };
  if (!['sanitized', 'schema-only'].includes(i.data)) throw new Failure(`data must be sanitized or schema-only (got: ${i.data})`);
  if (!/^[a-z0-9][a-z0-9_-]{0,62}$/.test(i.template)) throw new Failure('template must be a CI template name (a-z, 0-9, - and _)');
  if (!/^\d+$/.test(i.branches) || +i.branches < 1 || +i.branches > MAX_BRANCHES) throw new Failure(`branches must be 1..${MAX_BRANCHES}`);
  i.branches = +i.branches;
  if (!['1h', '6h'].includes(i.ttl)) throw new Failure('ttl must be 1h or 6h (PGRun keeps CI branches at most 6h)');
  if (!['pgx', 'postgres', 'any'].includes(i.engine)) throw new Failure('engine must be pgx, postgres or any');
  if (!/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(i.envName) || RESERVED_ENV.test(i.envName)) throw new Failure(`env-name ${i.envName} is not allowed: use a name like DATABASE_URL`);
  if (!['true', 'false'].includes(i.exportEnv)) throw new Failure('export-env must be true or false');
  i.exportEnv = i.exportEnv === 'true';
  for (const k of ['capacityWait', 'readyTimeout', 'maxAgeHours']) {
    if (!/^\d+$/.test(i[k])) throw new Failure(`${k.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)} must be a whole number`);
    i[k] = +i[k];
  }
  return i;
}

// Where a pull request's code could read what this step provides.
function checkEvent(i) {
  const event = process.env.GITHUB_EVENT_NAME || '';
  if (event === 'pull_request_target') {
    throw new Failure('refusing to run on pull_request_target: it would hand pull-request code the PGRun token. Use pull_request.');
  }
  let payload = {};
  try { payload = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')); } catch { /* not on Actions */ }
  if (i.data !== 'sanitized') return;
  const pr = payload.pull_request;
  if (pr && pr.head && pr.head.repo && pr.base && pr.base.repo && pr.head.repo.full_name !== pr.base.repo.full_name) {
    throw new Failure('refusing sanitized data for a pull request from a fork: its code would run against the sanitized copy. Use data: schema-only for fork pull requests.');
  }
  if (payload.repository && payload.repository.private === false && i.allowPublic !== 'true') {
    throw new Failure('this repository is public: anyone can read its Actions logs, and your steps run against the sanitized copy, which they could print. Use a private repository, data: schema-only, or set allow-public-repository: true to accept this.');
  }
}

// --------------------------------------------------------------- the gates
async function context(api, i) {
  const r = await api('GET', `/api/v1/ci/context${i.project ? `?project=${enc(i.project)}` : ''}`);
  switch (r.status) {
    case 200: break;
    case 401:
      if (r.json.reason === 'token_expired') throw new Failure('the PGRun CI token has expired. Create a new CI token for the project in PGRun and update the PGRUN_API_TOKEN repository secret.');
      throw new Failure('the PGRun API token was rejected (401). Create a CI token for the project in PGRun and store it as the PGRUN_API_TOKEN repository secret.');
    case 403: throw new Failure(`the PGRun API token may not use project ${i.project || 'of this run'} (${message(r)}).`);
    case 409: throw new Failure(`${message(r)} — set the \`project\` input to one of: ${(r.json.projects || []).join(', ')}.`);
    case 404:
      if (r.json.error === 'no_project') throw new Failure('this PGRun account has no project yet: connect a database in PGRun first.');
      throw new Failure(`the PGRun API at ${i.apiUrl} does not serve CI (404): branching is not enabled for this account.`);
    default: throw new Failure(`the PGRun API answered ${r.status} for the CI context (${message(r)})`);
  }
  const ctx = r.json;
  if (!ctx.project || !ctx.project.name) throw new Failure('the PGRun API did not name a project');
  const exp = ctx.token && ctx.token.expires_at && Date.parse(ctx.token.expires_at);
  if (exp) {
    const days = Math.floor((exp - Date.now()) / 86400000);
    if (days < 14) warn(`the PGRun CI token expires in ${days} day(s). Create a new one in PGRun and update the PGRUN_API_TOKEN secret before then.`);
  }
  return ctx;
}

// The same gates as the Rails preset: nothing is provisioned from a project
// whose protection is not approved or whose Safe Copy is not usable.
function checkGates(ctx, i) {
  const project = ctx.project.name;
  const protect = (ctx.protect && ctx.protect.status) || 'none';
  const copy = (ctx.safe_copy && ctx.safe_copy.status) || 'none';
  const updated = ctx.safe_copy && ctx.safe_copy.updated_at;
  const pv = (ctx.safe_copy && ctx.safe_copy.policy_version) || (ctx.protect && ctx.protect.policy_version) || '';
  const site = i.apiUrl;
  if (protect !== 'active') throw new Failure(`Protect is not approved for ${project} (status: ${protect}). Approve the data protection policy at ${site} — nothing was provisioned.`);
  if (ctx.safe_copy && ctx.safe_copy.policy_revoked === true) throw new Failure(`the Safe Copy of ${project} was made under a revoked policy (v${pv}). Refresh it in PGRun first.`);
  switch (copy) {
    case 'ready': break;
    case 'action_required':
      if (!updated) throw new Failure(`${project} has no Safe Copy yet: create it in PGRun.`);
      warn(`the Safe Copy of ${project} needs attention in PGRun; this run uses it as approved (policy v${pv}).`);
      break;
    case 'copying':
      if (!updated) throw new Failure(`the first Safe Copy of ${project} is still being created — re-run when it is ready.`);
      warn('a Safe Copy refresh is in progress; branches come from the current copy.');
      break;
    case 'failed': throw new Failure(`the Safe Copy of ${project} failed. See ${site} — nothing was provisioned.`);
    default: throw new Failure(`${project} has no Safe Copy yet (status: ${copy}). Approve Protect and create the Safe Copy in PGRun.`);
  }
  if (!updated) throw new Failure(`${project} has no Safe Copy yet.`);
  const ageH = Math.floor((Date.now() - Date.parse(updated)) / 3600000);
  if (i.data === 'sanitized' && i.maxAgeHours > 0 && ageH >= i.maxAgeHours) {
    throw new Failure(`the Safe Copy is ${ageH}h old (snapshot-max-hours: ${i.maxAgeHours}). Refresh it in PGRun, or raise the limit.`);
  }
  // A schema-only template is PGX-only; a sanitized branch follows `engine`.
  const eligible = ctx.pgx && ctx.pgx.eligible;
  if ((i.engine === 'pgx' || i.data === 'schema-only') && eligible === false) {
    const why = (ctx.pgx && (ctx.pgx.reason || ctx.pgx.verdict)) || 'no verdict';
    throw new Failure(`PGX is required (${i.data === 'schema-only' ? 'schema-only templates run on PGX' : 'engine: pgx'}) but ${project} is not eligible: ${sanitize(why)}. Nothing was provisioned.${i.data === 'sanitized' ? ' Set engine: any to allow stock PostgreSQL.' : ''}`);
  }
  log(`project ${project} · Protect active (policy v${pv}) · Safe Copy ${copy}, ${ageH}h old`);
  return { project, ageH, pv };
}

// --------------------------------------------------------------- templates
async function ensureTemplate(api, project, i, deadline) {
  const p = `/api/v1/projects/${enc(project)}/templates/${enc(i.template)}`;
  // No seed_sql: a CI token never changes a template's seed (an account
  // manager sets it); an existing seed is kept, a new template has none.
  let r = await api('PUT', p, { schema_only: true });
  if (r.status === 403 && r.json.error === 'token_scope') throw new Failure(message(r));
  if (r.status === 422 && r.json.error === 'template_requires_pgx') throw new Failure(`schema-only needs PGX, and ${project} cannot use it: ${sanitize(r.json.reason)}`);
  if (![200, 201, 202].includes(r.status)) throw new Failure(`the CI template ${i.template} could not be defined (${r.status}: ${message(r)})`);
  let said = false;
  for (;;) {
    const status = r.json.status;
    if (status === 'ready') return r.json;
    if (status === 'failed') throw new Failure(`the CI template ${i.template} failed to build: ${sanitize(r.json.error)}. See PGRun.`);
    if (status === 'stale') await api('POST', `${p}/build`);
    if (!said) { log(`building CI template ${i.template} (schema only; rebuilt only when the schema or seed changes)`); said = true; }
    if (Date.now() > deadline) throw new Failure(`the CI template ${i.template} was not ready after ${i.readyTimeout}s`);
    await pause(3);
    r = await api('GET', p);
    if (r.status !== 200) throw new Failure(`the CI template ${i.template} could not be read (${r.status}: ${message(r)})`);
  }
}

// ----------------------------------------------------------------- branches
// ci-db-<pr|run>-<run id>-<attempt>-<tag>-<n>: the random tag keeps two steps
// of one run apart; deletion is by the exact names recorded, never by prefix.
function namePrefix() {
  const pr = (process.env.GITHUB_REF || '').match(/^refs\/pull\/(\d+)\//);
  const tag = crypto.randomBytes(3).toString('hex');
  return `ci-db-${pr ? pr[1] : 'run'}-${process.env.GITHUB_RUN_ID || '0'}-${process.env.GITHUB_RUN_ATTEMPT || '1'}-${tag}`.toLowerCase();
}

// The record post reads: written BEFORE every create, so a step cancelled in
// the middle of a create still leaves the name to delete.
class Ledger {
  constructor(file, base) { this.file = file; this.data = base; }
  static path(id) { return path.join(process.env.RUNNER_TEMP || require('os').tmpdir(), 'pgrun-database', `${id}.json`); }
  add(name) { this.data.names.push(name); this.write(); }
  remove(names) { this.data.names = this.data.names.filter((n) => !names.includes(n)); this.write(); }
  write() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
    fs.writeFileSync(this.file, JSON.stringify(this.data), { mode: 0o600 });
  }
}

async function deleteBranch(api, project, name) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    let r;
    try { r = await api('DELETE', `/api/v1/projects/${enc(project)}/branches/${enc(name)}`); } catch { r = null; }
    if (r && (r.status === 202 || r.status === 200 || r.status === 204 || r.status === 404)) return r.status === 404 ? 'absent' : 'deleted';
    if (r && r.status === 403) return 'refused';
    if (attempt < 3) await pause(attempt * 2);
  }
  return 'failed';
}

const QUOTA = /quota/i;

async function createBranches(api, project, i, ledger, deadline) {
  const started = Date.now();
  let held = [];
  let seq = 0;
  let waited = 0;
  const body = (name) => ({ name, ttl: i.ttl, ...(i.data === 'schema-only' ? { template: i.template } : {}) });
  while (held.length < i.branches) {
    seq += 1; // never reuse a name: a released one may still be deleting
    const name = `${ledger.data.prefix}-${seq}`;
    ledger.add(name);
    const r = await api('POST', `/api/v1/projects/${enc(project)}/branches`, body(name));
    if (r.status === 201) { held.push(name); continue; }
    // A 4xx answer is a refusal: nothing was created under that name.
    if (r.status >= 400 && r.status < 500) ledger.remove([name]);
    const msg = message(r);
    const retryable = (r.status === 422 && QUOTA.test(msg)) || (r.status === 409 && r.json.error === 'template_not_ready') ||
      (r.status === 422 && /being refreshed/.test(msg));
    if (!retryable) throw new Failure(`creating a branch failed (${r.status}): ${msg}`);
    if (waited >= i.capacityWait) {
      throw new Failure(`no capacity for ${i.branches} branch(es) after ${i.capacityWait}s: ${msg}`);
    }
    if (waited === 0) log(`waiting for capacity (up to ${i.capacityWait}s): ${msg}`);
    // Holding part of what we need only blocks other runs: give it back.
    if (held.length > 0) {
      const results = await Promise.all(held.map((n) => deleteBranch(api, project, n)));
      ledger.remove(held.filter((_, n) => results[n] !== 'failed'));
      held = [];
    }
    const s = 10 + Math.floor(Math.random() * 11);
    await pause(s);
    waited += s;
  }
  // Ready = status ready AND a connection URL (PGX: the gateway has routed it).
  const out = [];
  for (const name of held) {
    for (;;) {
      const r = await api('GET', `/api/v1/projects/${enc(project)}/branches/${enc(name)}`);
      if (r.status === 200 && r.json.status === 'ready' && r.json.connection_url) { out.push(r.json); break; }
      if (r.status === 200 && ['failed', 'deleting', 'deleted'].includes(r.json.status)) {
        throw new Failure(`branch ${name} ${r.json.status === 'failed' ? 'failed to start' : 'was deleted while starting'}`);
      }
      if (r.status !== 200 && r.status !== 404) throw new Failure(`reading branch ${name} failed (${r.status}: ${message(r)})`);
      if (Date.now() > deadline) throw new Failure(`branch ${name} was not ready after ${i.readyTimeout}s`);
      await pause(1);
    }
  }
  return { branches: out, waited, ms: Date.now() - started };
}

function parseUrl(url) {
  const u = new URL(url);
  return {
    host: u.hostname,
    port: u.port || '5432',
    database: decodeURIComponent(u.pathname.replace(/^\//, '')),
    username: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
    rawPassword: u.password,
  };
}

// -------------------------------------------------------------------- main
async function main() {
  const id = crypto.randomBytes(8).toString('hex');
  let ledger;
  let api;
  try {
    const i = readInputs();
    checkEvent(i);
    api = client(i.apiUrl, i.token);
    const ctx = await context(api, i);
    const { project, ageH, pv } = checkGates(ctx, i);
    ledger = new Ledger(Ledger.path(id), { apiUrl: i.apiUrl, project, prefix: namePrefix(), names: [] });
    ledger.write();
    const deadline = Date.now() + i.readyTimeout * 1000;
    if (i.data === 'schema-only') await ensureTemplate(api, project, i, deadline);
    const { branches, waited, ms } = await createBranches(api, project, i, ledger, deadline);

    // Mask every form of every secret before any of it reaches a file or log.
    const parts = branches.map((b) => {
      mask(b.connection_url);
      const c = parseUrl(b.connection_url);
      mask(c.password);
      if (c.rawPassword !== c.password) mask(c.rawPassword);
      return c;
    });
    const wrong = branches.filter((b) => i.engine !== 'any' && b.engine !== i.engine);
    if (wrong.length) {
      for (const b of wrong) error(`${b.name} runs on ${b.engine}, not ${i.engine} — no silent fallback`);
      throw new Failure(`the branch engine is not ${i.engine} (engine input): PGRun could not place the branch there. Set engine: any to accept it.`);
    }

    const envs = branches.length > 1 ? branches.map((_, n) => `${i.envName}_${n + 1}`) : [];
    if (i.exportEnv) {
      exportEnv(i.envName, branches[0].connection_url);
      branches.forEach((b, n) => { if (envs[n]) exportEnv(envs[n], b.connection_url); });
    }
    const first = branches[0];
    const meta = branches.map((b, n) => ({
      name: b.name, engine: b.engine, host: parts[n].host, port: parts[n].port, database: parts[n].database,
      username: parts[n].username, expires_at: b.expires_at, ready_ms: b.ready_ms,
      env: i.exportEnv ? (envs[n] || i.envName) : null,
    }));
    setOutput('database-url', first.connection_url);
    setOutput('password', parts[0].password);
    setOutput('branch-name', first.name);
    setOutput('branches', JSON.stringify(meta));
    setOutput('host', parts[0].host);
    setOutput('port', parts[0].port);
    setOutput('database', parts[0].database);
    setOutput('username', parts[0].username);
    setOutput('engine', first.engine);
    setOutput('expires-at', first.expires_at || '');
    setOutput('project', project);

    const engines = [...new Set(branches.map((b) => b.engine))].join(', ');
    log(`${branches.length} ${i.data} branch(es) ready in ${(ms / 1000).toFixed(1)}s on ${engines}${waited ? ` (waited ${waited}s for capacity)` : ''}`);
    log(i.exportEnv ? `${i.envName}${envs.length ? ` and ${envs[0]}..${envs[envs.length - 1]}` : ''} set for the next steps · deleted when the job ends · TTL ${i.ttl}`
      : `connection in this step's outputs (export-env: false) · deleted when the job ends · TTL ${i.ttl}`);
    summary(`### PGRun database\n\n| | |\n|---|---|\n| Project | ${project} |\n| Data | ${i.data === 'sanitized' ? `sanitized Safe Copy (policy v${pv}, ${ageH}h old)` : `schema-only (template ${i.template})`} |\n` +
      `| Branches | ${branches.map((b) => `\`${b.name}\``).join(', ')} |\n| Engine | ${engines} |\n| Ready in | ${(ms / 1000).toFixed(1)}s |\n| Expires | ${first.expires_at || '—'} (deleted when the job ends) |\n\n`);
  } catch (e) {
    // Give back what was created; post deletes whatever is still recorded.
    if (ledger && api) {
      await Promise.all(ledger.data.names.map((n) => deleteBranch(api, ledger.data.project, n)));
      ledger.data.names = [];
      ledger.write();
    }
    if (e instanceof Failure) { error(e.message); process.exitCode = 1; return; }
    error(`unexpected failure: ${sanitize(e && e.message)}`);
    process.exitCode = 1;
  }
}

// -------------------------------------------------------------------- post
// Every ledger of this job (RUNNER_TEMP is the job's own and emptied between
// jobs), not just this step's: the step state can be lost when the main step
// was cancelled, and every post step runs after all of the job's own steps.
async function post() {
  const dir = path.dirname(Ledger.path('x'));
  let files = [];
  try { files = fs.readdirSync(dir).filter((f) => /^[0-9a-f]{16}\.json$/.test(f)).map((f) => path.join(dir, f)); } catch { /* none */ }
  const ledgers = [];
  for (const file of files) {
    try { const data = JSON.parse(fs.readFileSync(file, 'utf8')); if (Array.isArray(data.names)) ledgers.push({ file, data }); } catch { /* unreadable */ }
  }
  const pending = ledgers.filter((l) => l.data.names.length);
  for (const l of ledgers) if (!l.data.names.length) { try { fs.unlinkSync(l.file); } catch { /* gone */ } }
  if (!pending.length) { log('nothing to clean up'); return; }
  const token = input('token');
  const total = pending.reduce((n, l) => n + l.data.names.length, 0);
  if (!token) { warn(`no token to delete ${total} branch(es); PGRun deletes them at their TTL`); return; }
  mask(token);
  const t = Date.now();
  let deleted = 0; let absent = 0; const left = [];
  for (const l of pending) {
    const api = client(l.data.apiUrl, token);
    const results = await Promise.all(l.data.names.map((n) => deleteBranch(api, l.data.project, n)));
    deleted += results.filter((r) => r === 'deleted').length;
    absent += results.filter((r) => r === 'absent').length;
    // Refused = another step's token owns it: that step's own post deletes it.
    l.data.names = l.data.names.filter((_, n) => results[n] === 'failed' || results[n] === 'refused');
    left.push(...l.data.names);
    if (l.data.names.length) fs.writeFileSync(l.file, JSON.stringify(l.data), { mode: 0o600 });
    else { try { fs.unlinkSync(l.file); } catch { /* gone */ } }
  }
  log(`deleted ${deleted} branch(es) in ${Date.now() - t} ms${absent ? ` (${absent} never created or already gone)` : ''}`);
  if (left.length) warn(`could not delete ${left.join(', ')} with this step's token; another PGRun step of this job, or the branch TTL, deletes them`);
  summary(`PGRun cleanup: ${deleted} branch(es) deleted${left.length ? `, ${left.length} left to their TTL` : ''}.\n`);
}

module.exports = { main, post, sanitize, parseUrl, readInputs, checkEvent, checkGates, namePrefix, Ledger, VERSION };
