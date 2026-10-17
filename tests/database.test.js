'use strict';
// The database action against a stub PGRun API: node --test tests/
const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const ACTION = path.join(__dirname, '..', 'database');

// ------------------------------------------------------------- stub server
function stub(opts = {}) {
  const s = {
    branches: new Map(), deleted: [], created: [], templatePuts: [], quota: opts.quota ?? 10,
    templateStatus: opts.templateStatus ?? 'ready', pollsUntilReady: opts.pollsUntilReady ?? 1, seq: 0,
    context: opts.context ?? {
      project: { name: 'shop', account: 'acme' },
      token: { scope: 'ci', expires_at: new Date(Date.now() + 200 * 86400000).toISOString() },
      protect: { status: 'active', policy_version: 3 },
      safe_copy: { status: 'ready', updated_at: new Date(Date.now() - 3600000).toISOString(), policy_version: 3 },
      pgx: { eligible: true },
    },
    engine: opts.engine ?? 'pgx', auth: [],
  };
  const live = () => [...s.branches.values()].filter((b) => !b.deleted).length;
  s.server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      s.auth.push(req.headers.authorization);
      const send = (code, json) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(json)); };
      const u = new URL(req.url, 'http://x');
      let m;
      if (req.headers.authorization !== 'Bearer pgrun_ci_0123456789abcdef') return send(401, { error: 'unauthorized' });
      if (u.pathname === '/api/v1/ci/context') return send(200, s.context);
      if ((m = u.pathname.match(/^\/api\/v1\/projects\/shop\/templates\/([^/]+)(\/build)?$/))) {
        if (req.method === 'PUT') s.templatePuts.push(JSON.parse(body));
        const st = s.templateStatus;
        if (s.templateStatus === 'building') s.templateStatus = 'ready';
        return send(req.method === 'PUT' && st !== 'ready' ? 202 : 200, { name: m[1], status: st, error: st === 'failed' ? 'boom' : null });
      }
      if (u.pathname === '/api/v1/projects/shop/branches' && req.method === 'POST') {
        const b = JSON.parse(body);
        if (live() >= s.quota) return send(422, { error: `branch quota reached (${live()}/${s.quota} live branches) — delete a branch` });
        s.seq += 1;
        const row = { name: b.name, ttl: b.ttl, template: b.template, polls: 0, n: s.seq, deleted: false };
        s.branches.set(b.name, row); s.created.push(b.name);
        return send(201, { name: b.name, status: 'creating' });
      }
      if ((m = u.pathname.match(/^\/api\/v1\/projects\/shop\/branches\/([^/]+)$/))) {
        const b = s.branches.get(decodeURIComponent(m[1]));
        if (!b || b.deleted) return send(404, { error: 'not_found' });
        if (req.method === 'DELETE') { b.deleted = true; s.deleted.push(b.name); return send(202, { name: b.name, status: 'deleting' }); }
        b.polls += 1;
        const ready = b.polls >= s.pollsUntilReady;
        return send(200, {
          name: b.name, status: ready ? 'ready' : 'starting', engine: s.engine, template: b.template || null,
          expires_at: new Date(Date.now() + 3600000).toISOString(), ready_ms: 900,
          ...(ready ? { connection_url: `postgresql://u_${b.n}:s3cr%2Ft-pw${b.n}xyz@gw${b.n}.example.test:5432/b_${b.n}?sslmode=require` } : {}),
        });
      }
      return send(404, { error: 'no route' });
    });
  });
  return new Promise((r) => s.server.listen(0, '127.0.0.1', () => { s.server.unref(); s.url = `http://127.0.0.1:${s.server.address().port}`; r(s); }));
}

// ------------------------------------------------------- a fake runner job
function job(event = { repository: { private: true } }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pgrun-db-'));
  for (const f of ['env', 'output', 'summary']) fs.writeFileSync(path.join(dir, f), '');
  fs.writeFileSync(path.join(dir, 'event.json'), JSON.stringify(event));
  fs.mkdirSync(path.join(dir, 'temp'));
  return dir;
}

function run(script, dir, api, inputs = {}, extra = {}) {
  const env = {
    PATH: process.env.PATH, RUNNER_TEMP: path.join(dir, 'temp'), GITHUB_ENV: path.join(dir, 'env'),
    GITHUB_OUTPUT: path.join(dir, 'output'), GITHUB_STEP_SUMMARY: path.join(dir, 'summary'),
    GITHUB_EVENT_PATH: path.join(dir, 'event.json'), GITHUB_EVENT_NAME: 'pull_request',
    GITHUB_REF: 'refs/pull/42/merge', GITHUB_RUN_ID: '777', GITHUB_RUN_ATTEMPT: '1', PGRUN_TEST_PAUSE_MS: '5',
    'INPUT_TOKEN': 'pgrun_ci_0123456789abcdef', 'INPUT_API-URL': api.url, ...extra,
  };
  for (const [k, v] of Object.entries(inputs)) env[`INPUT_${k.toUpperCase()}`] = v;
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [path.join(ACTION, script)], { env });
    let out = '';
    p.stdout.on('data', (c) => { out += c; });
    p.stderr.on('data', (c) => { out += c; });
    p.on('close', (code, signal) => resolve({ code, signal, out, proc: p }));
    if (extra.__kill) extra.__kill(p);
  });
}

// GITHUB_ENV / GITHUB_OUTPUT heredoc files → { name: value }
function readFileCommands(file) {
  const out = {};
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^([^<]+)<<(ghadelimiter_[0-9a-f-]+)$/);
    if (!m) continue;
    const v = [];
    for (i++; lines[i] !== m[2]; i++) v.push(lines[i]);
    out[m[1]] = v.join('\n');
  }
  return out;
}

// Nothing secret outside an ::add-mask:: line (the runner masks from there on).
function assertNoLeak(out, secrets) {
  const visible = out.split('\n').filter((l) => !l.startsWith('::add-mask::')).join('\n');
  for (const s of secrets) assert.ok(!visible.includes(s), `leaked: ${s.slice(0, 12)}…\n${visible}`);
  assert.ok(!/postgres(ql)?:\/\//.test(visible), `a URL in the log:\n${visible}`);
}

// ------------------------------------------------------------------- tests
test('sanitized: one branch, DATABASE_URL exported, outputs set, masked, post deletes it', async () => {
  const api = await stub({ pollsUntilReady: 3 });
  const dir = job();
  const r = await run('main.js', dir, api);
  assert.strictEqual(r.code, 0, r.out);
  const env = readFileCommands(path.join(dir, 'env'));
  const out = readFileCommands(path.join(dir, 'output'));
  assert.match(env.DATABASE_URL, /^postgresql:\/\/u_1:s3cr%2Ft-pw1xyz@gw1\.example\.test:5432\/b_1/);
  assert.deepStrictEqual(Object.keys(env), ['DATABASE_URL']);
  assert.strictEqual(out['database-url'], env.DATABASE_URL);
  assert.strictEqual(out.password, 's3cr/t-pw1xyz');
  assert.strictEqual(out.host, 'gw1.example.test');
  assert.strictEqual(out.port, '5432');
  assert.strictEqual(out.database, 'b_1');
  assert.strictEqual(out.username, 'u_1');
  assert.strictEqual(out.engine, 'pgx');
  assert.strictEqual(out.project, 'shop');
  assert.match(out['branch-name'], /^ci-db-42-777-1-[0-9a-f]{6}-1$/);
  const meta = JSON.parse(out.branches);
  assert.strictEqual(meta.length, 1);
  assert.ok(!JSON.stringify(meta).includes('s3cr'), 'branches output has no password');
  // Command data is %-escaped; the runner unescapes it before masking.
  assert.ok(r.out.includes(`::add-mask::${env.DATABASE_URL.replace(/%/g, '%25')}`));
  assert.ok(r.out.includes('::add-mask::s3cr/t-pw1xyz'));
  assert.ok(r.out.includes('::add-mask::s3cr%252Ft-pw1xyz'));
  assert.ok(r.out.includes('::add-mask::pgrun_ci_0123456789abcdef'));
  assertNoLeak(r.out, ['s3cr/t-pw1xyz', 's3cr%2Ft-pw1xyz', 'pgrun_ci_0123456789abcdef']);
  assert.strictEqual(api.created[0], out['branch-name']);
  assert.deepStrictEqual(api.branches.get(api.created[0]).ttl, '1h');
  assert.strictEqual(api.branches.get(api.created[0]).template, undefined);
  assert.ok(api.auth.every((a) => a === 'Bearer pgrun_ci_0123456789abcdef'));

  const p = await run('post.js', dir, api);
  assert.strictEqual(p.code, 0, p.out);
  assert.deepStrictEqual(api.deleted, api.created);
  assert.match(p.out, /deleted 1 branch/);
  assert.deepStrictEqual(fs.readdirSync(path.join(dir, 'temp', 'pgrun-database')), []);
  // A second post (two database steps in one job) has nothing left to do.
  const p2 = await run('post.js', dir, api);
  assert.match(p2.out, /nothing to clean up/);
  api.server.close();
});

test('schema-only: template defined without a seed, branches minted from it, DATABASE_URL_1..N', async () => {
  const api = await stub({ templateStatus: 'building' });
  const dir = job({ repository: { private: false } }); // public repo is fine for schema-only
  const r = await run('main.js', dir, api, { data: 'schema-only', branches: '3', 'env-name': 'TEST_DB' });
  assert.strictEqual(r.code, 0, r.out);
  assert.deepStrictEqual(api.templatePuts, [{ schema_only: true }]);
  assert.strictEqual(api.created.length, 3);
  for (const n of api.created) assert.strictEqual(api.branches.get(n).template, 'ci');
  const env = readFileCommands(path.join(dir, 'env'));
  assert.deepStrictEqual(Object.keys(env).sort(), ['TEST_DB', 'TEST_DB_1', 'TEST_DB_2', 'TEST_DB_3']);
  assert.strictEqual(env.TEST_DB, env.TEST_DB_1);
  assert.notStrictEqual(env.TEST_DB_1, env.TEST_DB_2);
  assertNoLeak(r.out, ['s3cr/t-pw1xyz', 's3cr/t-pw2xyz', 's3cr/t-pw3xyz']);
  await run('post.js', dir, api);
  assert.deepStrictEqual(api.deleted.sort(), api.created.sort());
  api.server.close();
});

test('export-env: false keeps the URL out of the environment', async () => {
  const api = await stub();
  const dir = job();
  const r = await run('main.js', dir, api, { 'export-env': 'false' });
  assert.strictEqual(r.code, 0, r.out);
  assert.deepStrictEqual(readFileCommands(path.join(dir, 'env')), {});
  assert.ok(readFileCommands(path.join(dir, 'output'))['database-url']);
  await run('post.js', dir, api);
  assert.strictEqual(api.deleted.length, 1);
  api.server.close();
});

test('gates: nothing is created when Protect is not active, the copy failed, or PGX is not eligible', async () => {
  const cases = [
    [{ protect: { status: 'draft' } }, /Protect is not approved/],
    [{ safe_copy: { status: 'failed', updated_at: new Date().toISOString() } }, /Safe Copy of shop failed/],
    [{ safe_copy: { status: 'ready', updated_at: new Date(Date.now() - 800 * 3600000).toISOString() } }, /800h old/],
    [{ pgx: { eligible: false, reason: 'extension hll' } }, /PGX is required.*extension hll/],
  ];
  for (const [patch, msg] of cases) {
    const api = await stub();
    api.context = { ...api.context, ...patch };
    const dir = job();
    const r = await run('main.js', dir, api);
    assert.strictEqual(r.code, 1, r.out);
    assert.match(r.out, msg);
    assert.strictEqual(api.created.length, 0);
    api.server.close();
  }
});

test('refusals before any API call: no token (fork PR), pull_request_target, fork PR, public repo, bad inputs', async () => {
  const cases = [
    [{ INPUT_TOKEN: '' }, job(), /no PGRun token/],
    [{ GITHUB_EVENT_NAME: 'pull_request_target' }, job(), /pull_request_target/],
    [{}, job({ repository: { private: true }, pull_request: { head: { repo: { full_name: 'evil/shop' } }, base: { repo: { full_name: 'acme/shop' } } } }), /fork/],
    [{}, job({ repository: { private: false } }), /repository is public/],
    [{ 'INPUT_ENV-NAME': 'PATH' }, job(), /env-name PATH is not allowed/],
    [{ 'INPUT_ENV-NAME': 'NODE_OPTIONS' }, job(), /not allowed/],
    [{ INPUT_TTL: '24h' }, job(), /ttl must be 1h or 6h/],
    [{ INPUT_BRANCHES: '17' }, job(), /branches must be 1\.\.16/],
    [{ INPUT_DATA: 'full' }, job(), /data must be/],
    [{ 'INPUT_API-URL': 'http://evil.example' }, job(), /api-url must be https/],
  ];
  for (const [extra, dir, msg] of cases) {
    const api = await stub();
    const r = await run('main.js', dir, api, {}, extra);
    assert.strictEqual(r.code, 1, r.out);
    assert.match(r.out, msg);
    assert.strictEqual(api.created.length, 0, `${msg}: nothing created`);
    api.server.close();
  }
});

test('public repository: allow-public-repository true accepts sanitized data', async () => {
  const api = await stub();
  const dir = job({ repository: { private: false } });
  const r = await run('main.js', dir, api, { 'allow-public-repository': 'true' });
  assert.strictEqual(r.code, 0, r.out);
  await run('post.js', dir, api);
  api.server.close();
});

test('engine mismatch fails and deletes what it created', async () => {
  const api = await stub({ engine: 'postgres' });
  const dir = job();
  const r = await run('main.js', dir, api, { branches: '2' });
  assert.strictEqual(r.code, 1, r.out);
  assert.match(r.out, /runs on postgres, not pgx/);
  assert.deepStrictEqual(api.deleted.sort(), api.created.sort());
  assertNoLeak(r.out, ['s3cr/t-pw1xyz']);
  const p = await run('post.js', dir, api);
  assert.match(p.out, /nothing to clean up/);
  api.server.close();
});

test('engine: any accepts stock PostgreSQL', async () => {
  const api = await stub({ engine: 'postgres' });
  const dir = job();
  const r = await run('main.js', dir, api, { engine: 'any' });
  assert.strictEqual(r.code, 0, r.out);
  assert.strictEqual(readFileCommands(path.join(dir, 'output')).engine, 'postgres');
  await run('post.js', dir, api);
  api.server.close();
});

test('quota: waits, gives back a partial hold, never reuses a name, then fails after capacity-wait', async () => {
  const api = await stub({ quota: 1 });
  const dir = job();
  const r = await run('main.js', dir, api, { branches: '2', 'capacity-wait': '30' });
  assert.strictEqual(r.code, 1, r.out);
  assert.match(r.out, /no capacity for 2 branch\(es\) after 30s/);
  assert.strictEqual(new Set(api.created).size, api.created.length, 'names never reused');
  assert.deepStrictEqual(api.deleted.sort(), api.created.sort(), 'every partial hold given back');
  api.server.close();
});

test('cancelled mid-provisioning: post deletes what main recorded', async () => {
  const api = await stub({ pollsUntilReady: 100000 });
  const dir = job();
  const r = await run('main.js', dir, api, { branches: '2' }, {
    __kill: (p) => { const t = setInterval(() => { if (api.created.length === 2) { clearInterval(t); p.kill('SIGINT'); } }, 5); },
  });
  assert.ok(r.signal === 'SIGINT' || r.code !== 0, r.out);
  assert.strictEqual(api.deleted.length, 0);
  const p = await run('post.js', dir, api);
  assert.strictEqual(p.code, 0, p.out);
  assert.deepStrictEqual(api.deleted.sort(), api.created.sort());
  api.server.close();
});

test('concurrent jobs: each post deletes only its own branches', async () => {
  const api = await stub();
  const a = job(); const b = job();
  const [ra, rb] = await Promise.all([run('main.js', a, api), run('main.js', b, api)]);
  assert.strictEqual(ra.code, 0, ra.out); assert.strictEqual(rb.code, 0, rb.out);
  const nameA = readFileCommands(path.join(a, 'output'))['branch-name'];
  const nameB = readFileCommands(path.join(b, 'output'))['branch-name'];
  assert.notStrictEqual(nameA, nameB);
  await run('post.js', a, api);
  assert.deepStrictEqual(api.deleted, [nameA]);
  await run('post.js', b, api);
  assert.deepStrictEqual(api.deleted, [nameA, nameB]);
  api.server.close();
});

test('an expired token says so; a server error message never echoes a URL or token', async () => {
  const lib = require('../database/lib');
  assert.strictEqual(lib.sanitize('bad postgresql://u:p@h/db and pgrun_ci_deadbeef00 x'), 'bad <url> and <token> x');
  const api = await stub();
  const dir = job();
  const r = await run('main.js', dir, api, {}, { INPUT_TOKEN: 'pgrun_ci_ffffffffffffffff' });
  assert.strictEqual(r.code, 1);
  assert.match(r.out, /rejected \(401\)/);
  api.server.close();
});

test('schema-only: a failed template build fails without creating branches', async () => {
  const api = await stub({ templateStatus: 'failed' });
  const dir = job();
  const r = await run('main.js', dir, api, { data: 'schema-only' });
  assert.strictEqual(r.code, 1, r.out);
  assert.match(r.out, /failed to build: boom/);
  assert.strictEqual(api.created.length, 0);
  api.server.close();
});
