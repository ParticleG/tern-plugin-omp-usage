import { execFile } from "node:child_process";
import { cp, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const extensions = new URL("../omp/extensions/", import.meta.url);

// Each test patches builtins only inside a child with a private HOME. No real
// auth files, native usage command, provider endpoints, clock or timers escape.
async function isolated(t, body, { copyExtension = false } = {}) {
  const home = await mkdtemp(join(tmpdir(), "omp-usage-cache-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  let extensionUrl = new URL("usage-remaining.js", extensions).href;
  if (copyExtension) {
    await cp(extensions, join(home, "extensions"), { recursive: true });
    extensionUrl = pathToFileURL(join(home, "extensions", "usage-remaining.js")).href;
  }
  const script = `
    import assert from 'node:assert/strict';
    import childProcess from 'node:child_process';
    import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
    import { syncBuiltinESMExports } from 'node:module';
    import { join } from 'node:path';
    import { fileURLToPath } from 'node:url';
    let now = 1800000000000;
    Date.now = () => now;
    const initialTime = now;
    let nativeError = false, holdNative = false, failCPA = false, quotaCalls = 0;
    const pendingNative = [];
    const nativeReport = (provider = 'anthropic', usedFraction = 0.2) => ({
      provider,
      limits: [{ id: provider + ':5h', window: { id: '5h', durationMs: 18000000 }, amount: { usedFraction } }],
    });
    let nativeReports = [nativeReport()];
    childProcess.execFile = (_file, _args, _options, callback) => {
      const finish = () => callback(nativeError ? new Error('Synthetic native failure') : null,
        nativeError ? '' : JSON.stringify({ reports: nativeReports }), '');
      if (holdNative) pendingNative.push(finish);
      else queueMicrotask(finish);
    };
    syncBuiltinESMExports();
    globalThis.fetch = async (url, options) => {
      const target = new URL(url);
      assert.equal(target.origin, 'http://quota.invalid');
      assert.equal(options.headers.Authorization, 'Bearer synthetic-only');
      const json = (value, status = 200) => new Response(JSON.stringify(value), { status });
      if (target.pathname === '/v8/management/credentials') {
        if (failCPA) return json({ error: 'synthetic outage' }, 503);
        return json({ files: [
          { auth_index: 'alice', provider: 'codex', email: 'alice@example.test' },
          { auth_index: 'bob', provider: 'codex', email: 'bob@example.test' },
        ], total: 2, has_more: false });
      }
      assert.equal(target.pathname, '/v8/management/requests/api-call');
      quotaCalls++;
      return json({ status_code: 200, header: {}, body: JSON.stringify({
        plan_type: 'pro',
        rate_limit: { primary_window: { used_percent: 25, limit_window_seconds: 18000, reset_after_seconds: 7200 } },
      }) });
    };
    const { default: extension } = await import(process.env.USAGE_EXTENSION_URL);
    const directory = join(process.env.HOME, '.omp', 'cache', 'usage-remaining');
    const provider = 'cpa:shared:openai-codex';
    const cpaConfig = (maxAgeSeconds = 120, intervalSeconds = 3600) => ({
      sources: [{ id: 'shared', type: 'cpa', baseUrl: 'http://quota.invalid', managementKeyEnv: 'SYNTHETIC_CPA_KEY', intervalSeconds, maxAgeSeconds }],
      modelMappings: [{ provider: 'proxy', source: 'shared', quotaProvider: 'codex' }],
    });
    const defaultModels = [
      { provider: 'anthropic', id: 'claude-test', name: 'Native model' },
      { provider: 'proxy', id: 'codex-test', name: 'Proxy model' },
    ];
    let configId = 0;
    function instance(config = {}, models = defaultModels) {
      const configFile = join(process.env.HOME, 'sources-' + configId++ + '.json');
      writeFileSync(configFile, JSON.stringify(config));
      process.env.OMP_USAGE_SOURCES_FILE = configFile;
      const handlers = {}, statuses = [], intervals = [];
      const ctx = {
        models: { current: () => models[0], list: async () => models },
        ui: { setStatus: (_key, value) => statuses.push(value), notify() {} },
        setInterval: (callback, delay) => intervals.push({ callback, delay }),
      };
      extension({ on: (event, callback) => { handlers[event] = callback; } });
      return { handlers, ctx, statuses, intervals, start: () => handlers.session_start({}, ctx),
        update: () => handlers.turn_end({}, ctx), stop: () => handlers.session_shutdown({}, ctx) };
    }
    const files = () => existsSync(directory) ? readdirSync(directory).sort() : [];
    const raw = (file) => readFileSync(join(directory, file), 'utf8');
    const snapshot = (file) => JSON.parse(raw(file));
    ${body}
  `;
  await run(process.execPath, ["--input-type=module", "-e", script], {
    env: { ...process.env, HOME: home, USERPROFILE: home, OMP_USAGE_SOURCES_FILE: join(home, "not-configured.json"), SYNTHETIC_CPA_KEY: "synthetic-only", USAGE_EXTENSION_URL: extensionUrl },
    timeout: 15_000,
  });
}

test("concurrent native-only and CPA factories retain independent complete snapshots", async (t) => {
  await isolated(t, `
    const legacy = join(process.env.HOME, '.omp', 'cache', 'usage-remaining.json');
    mkdirSync(join(process.env.HOME, '.omp', 'cache'), { recursive: true });
    writeFileSync(legacy, 'legacy-cache-must-not-be-used');
    const external = instance(cpaConfig());
    const native = instance();
    holdNative = true;
    const externalStart = external.start(), nativeStart = native.start();
    assert.equal(pendingNative.length, 2);
    // Finish the newer native-only session first, then the external session.
    pendingNative.pop()();
    await nativeStart;
    const nativeFile = files()[0];
    pendingNative.pop()();
    await externalStart;
    holdNative = false;
    assert.equal(files().length, 2);
    const externalFile = files().find((file) => file !== nativeFile);
    for (const file of files()) {
      assert.match(file, new RegExp('^' + process.pid + '-[0-9a-f-]{36}\\\\.json$'));
      assert.equal(statSync(join(directory, file)).mode & 0o777, 0o600);
    }
    const cpa = snapshot(externalFile);
    assert.deepEqual(cpa.providers[provider].accounts, ['alice', 'bob']);
    assert.match(cpa.providers[provider].line, /alice 5h.*75%.*bob 5h.*75%/);
    assert.ok(cpa.providers[provider].details.some((row) => row.account === 'alice' && row.kind === 'plan'));
    assert.equal(cpa.models['Proxy model'].provider, provider);
    assert.equal(cpa.providers[provider].fetchedAt, initialTime);
    assert.equal(cpa.providers[provider].maxAgeMs, 120000);
    assert.equal(snapshot(nativeFile).providers[provider], undefined);
    assert.equal(snapshot(nativeFile).models['Proxy model'].line, '');
    const retained = raw(externalFile);
    now += 60000;
    await native.update();
    assert.equal(raw(externalFile), retained);
    assert.equal(snapshot(nativeFile).providers.anthropic.fetchedAt, now);
    assert.equal(readFileSync(legacy, 'utf8'), 'legacy-cache-must-not-be-used');
    // Shutdown during a pending fetch must not recreate the removed snapshot.
    holdNative = true;
    const pendingUpdate = external.update();
    await external.stop();
    assert.deepEqual(files(), [nativeFile]);
    pendingNative.pop()();
    await pendingUpdate;
    assert.deepEqual(files(), [nativeFile]);
    await native.stop();
    assert.deepEqual(files(), []);
    assert.equal(readFileSync(legacy, 'utf8'), 'legacy-cache-must-not-be-used');
  `);
});

test("native polling and failures never renew external or retained native observations", async (t) => {
  await isolated(t, `
    const owner = instance(cpaConfig());
    await owner.start();
    const file = files()[0];
    const original = snapshot(file);
    assert.equal(quotaCalls, 2);
    assert.match(owner.statuses.at(-1), /80%/);
    now += 60000;
    await owner.update();
    let next = snapshot(file);
    assert.equal(next.providers[provider].fetchedAt, initialTime);
    assert.equal(next.models['Proxy model'].fetchedAt, initialTime);
    assert.equal(next.providers.anthropic.fetchedAt, now);
    assert.equal(quotaCalls, 2);
    const lastNativeObservation = now;
    nativeError = true;
    now += 61000;
    await owner.update();
    next = snapshot(file);
    assert.equal(next.providers.anthropic.fetchedAt, lastNativeObservation);
    assert.equal(next.models['Native model'].fetchedAt, lastNativeObservation);
    assert.equal(next.providers[provider].fetchedAt, initialTime);
    assert.equal(next.providers[provider].maxAgeMs, 120000);
    assert.ok(next.providers[provider].details.some((row) => row.kind === 'stale'));
    assert.doesNotMatch(next.providers[provider].line, /75%/);
    assert.notEqual(next.generatedAt, original.generatedAt);
    assert.match(owner.statuses.at(-1), /80%/);
    await owner.stop();
  `);
});

test("external-only snapshots survive missing native usage and preserve observations after source errors", async (t) => {
  await isolated(t, `
    nativeError = true;
    const owner = instance(cpaConfig(3600, 1));
    await owner.start();
    const file = files()[0];
    let next = snapshot(file);
    assert.equal(next.fetchedAt, initialTime);
    assert.equal(next.providers[provider].fetchedAt, initialTime);
    assert.equal(next.providers[provider].maxAgeMs, 600000);
    assert.equal(next.models['Proxy model'].maxAgeMs, 600000);
    assert.equal(next.providers.anthropic, undefined);
    failCPA = true;
    now += 2000;
    await owner.update();
    next = snapshot(file);
    assert.equal(next.providers[provider].fetchedAt, initialTime);
    assert.equal(next.models['Proxy model'].fetchedAt, initialTime);
    assert.equal(next.fetchedAt, initialTime);
    assert.ok(next.providers[provider].details.some((row) => row.kind === 'error'));
    assert.deepEqual(next.providers[provider].accounts, ['alice', 'bob']);
    assert.match(next.providers[provider].line, /75%/);
    await owner.stop();
  `);
});

test("same-chip ambiguity publishes a current explicit tombstone", async (t) => {
  await isolated(t, `
    nativeReports = [nativeReport('anthropic', 0.2), nativeReport('openai-codex', 0.4)];
    const models = [{ provider: 'anthropic', id: 'a', name: 'Shared' }];
    const owner = instance({}, models);
    await owner.start();
    const file = files()[0];
    assert.deepEqual(snapshot(file).ambiguousModels, []);
    models.push({ provider: 'openai-codex', id: 'b', name: 'Shared' });
    nativeError = true;
    now += 60000;
    await owner.update();
    const next = snapshot(file);
    assert.equal(next.models.Shared, null);
    assert.deepEqual(next.ambiguousModels, ['Shared']);
    assert.equal(next.fetchedAt, initialTime);
    assert.equal(next.generatedAt, now);
    assert.equal(next.providers.anthropic.fetchedAt, initialTime);
    assert.equal(next.providers['openai-codex'].fetchedAt, initialTime);
    await owner.stop();
  `);
});

test("an already loaded extension stops publishing after its source changes", async (t) => {
  await isolated(t, `
    const owner = instance();
    await owner.start();
    const file = files()[0], original = raw(file);
    appendFileSync(fileURLToPath(process.env.USAGE_EXTENSION_URL), '\\n// Simulated installed update.\\n');
    now += 180000;
    nativeReports = [nativeReport('anthropic', 0.9)];
    await owner.update();
    assert.equal(raw(file), original);
    assert.match(owner.statuses.at(-1), /10%/);
    await owner.stop();
    assert.deepEqual(files(), []);
  `, { copyExtension: true });
});

test("startup prunes only canonical snapshots whose processes are provably gone", async (t) => {
  await isolated(t, `
    mkdirSync(directory, { recursive: true });
    const suffix = '-00000000-0000-4000-8000-000000000001.json';
    const dead = '99999991' + suffix, inaccessible = '99999992' + suffix;
    const live = process.pid + suffix, unknown = 'unrelated.json';
    for (const file of [dead, inaccessible, live, unknown]) writeFileSync(join(directory, file), 'retained');
    const kill = process.kill;
    process.kill = (pid, signal) => {
      if (pid === 99999991 || pid === 99999992) {
        throw Object.assign(new Error('synthetic process status'), { code: pid === 99999991 ? 'ESRCH' : 'EPERM' });
      }
      return kill(pid, signal);
    };
    const owner = instance();
    await owner.start();
    assert.equal(existsSync(join(directory, dead)), false);
    for (const file of [inaccessible, live, unknown]) assert.equal(raw(file), 'retained');
    await owner.stop();
    assert.deepEqual(files(), [inaccessible, live, unknown].sort());
  `);
});
