import assert from 'node:assert/strict';
import {randomBytes, webcrypto} from 'node:crypto';
import worker, {WakeRelay} from '../relay/worker.mjs';

// No external service, network, real credentials, or Mac/ESP32 side effects.
export async function runRelayTests() {
  const passed = [];
  const originalNow = Date.now;
  const originalCrypto = globalThis.crypto;
  if (!globalThis.crypto) globalThis.crypto = webcrypto;
  let now = 1800000000000;
  Date.now = () => now;
  function makeRelay() {
    const data = new Map();
    let last = Promise.resolve();
    const context = {
      storage: {
        async get(key) { return structuredClone(data.get(key)); },
        async put(key, value) { data.set(key, structuredClone(value)); },
      },
      blockConcurrencyWhile(fn) {
        const result = last.then(fn); last = result.catch(() => {}); return result;
      },
    };
    const env = {DEVICE_TOKEN: randomBytes(32).toString('hex'), PHONE_TOKEN: randomBytes(32).toString('hex')};
    const relay = new WakeRelay(context, env);
    env.WAKE_RELAY = {getByName: () => relay};
    async function call(path, {token = env.PHONE_TOKEN, method = path === '/v1/status' ? 'GET' : 'POST',
      body = {}, raw, headers = {}} = {}) {
      const request = new Request('https://example.workers.dev' + path, {method,
        headers: {Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', ...headers},
        ...(method === 'GET' ? {} : {body: raw === undefined ? JSON.stringify(body) : raw})});
      const response = await worker.fetch(request, env);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      return {status: response.status, body: await response.json()};
    }
    const poll = (body = {ready: true, uptime_ms: 100}) => call('/v1/device/poll', {token: env.DEVICE_TOKEN, body});
    return {env, call, poll};
  }
  async function test(name, fn) { await fn(); passed.push(name); }
  try {
    await test('Authentication separates phone and device tokens', async () => {
      const {env, call, poll} = makeRelay();
      assert.equal((await call('/v1/wake', {token: ''})).status, 401);
      assert.equal((await call('/v1/wake', {token: env.DEVICE_TOKEN})).status, 401);
      assert.equal((await call('/v1/device/poll')).status, 401);
      assert.equal((await poll()).status, 200);
      assert.equal((await call('/v1/wake')).status, 202);
      assert.equal((await call('/v1/wake', {method: 'GET'})).status, 405);
      assert.equal((await call('/unknown')).status, 404);
    });
    await test('Offline and unready devices cannot queue wake commands', async () => {
      const {call, poll} = makeRelay();
      assert.equal((await call('/v1/wake')).status, 503);
      await poll({ready: false, uptime_ms: 100});
      assert.equal((await call('/v1/wake')).status, 409);
      await poll(); now += 20000;
      assert.equal((await call('/v1/wake')).status, 503);
    });
    await test('A wake is claimed once and only its matching acknowledgment changes state', async () => {
      const {call, poll} = makeRelay();
      await poll();
      const queued = await call('/v1/wake');
      const id = queued.body.command.id;
      assert.equal(queued.body.mac_awake, 'unknown');
      const claimed = await poll();
      assert.equal(claimed.body.command.id, id);
      assert.equal(claimed.body.command.action, 'wake');
      assert.equal(claimed.body.command.expires_at, now + 30000);
      assert.equal((await poll()).body.command, null);
      await poll({ready: true, uptime_ms: 200, ack: {id: 'wrong-id', result: 'report_sent'}});
      assert.equal((await call('/v1/status')).body.command.state, 'claimed');
      await poll({ready: true, uptime_ms: 300, ack: {id, result: 'report_sent'}});
      const status = await call('/v1/status');
      assert.equal(status.body.command.state, 'report_sent');
      assert.equal(status.body.mac_awake, 'unknown');
    });
    await test('Concurrent requests and pending requests share one command', async () => {
      const {call, poll} = makeRelay();
      await poll();
      const results = await Promise.all(Array.from({length: 8}, () => call('/v1/wake')));
      assert.equal(new Set(results.map(r => r.body.command.id)).size, 1);
      assert.equal(results.filter(r => r.body.duplicate_suppressed).length, 7);
      now += 11000; await poll();
      const repeated = await call('/v1/wake');
      assert.equal(repeated.body.duplicate_suppressed, true);
      assert.equal(repeated.body.command.id, results[0].body.command.id);
    });
    await test('An expired queue is never delivered after a delayed poll', async () => {
      const {call, poll} = makeRelay();
      await poll(); const previous = await call('/v1/wake');
      now += 30001;
      assert.equal((await poll()).body.command, null);
      assert.equal((await call('/v1/status')).body.command.state, 'expired');
      assert.notEqual((await call('/v1/wake')).body.command.id, previous.body.command.id);
    });
    await test('Malformed device status is rejected', async () => {
      const {poll} = makeRelay();
      for (const body of [{}, {ready: true, uptime_ms: -1}, {ready: true, uptime_ms: 1.5}, {ready: 'yes', uptime_ms: 1}])
        assert.equal((await poll(body)).status, 400);
    });
    await test('JSON and UTF-8 byte limits are enforced before queue changes', async () => {
      const {call, poll} = makeRelay(); await poll();
      for (const raw of ['{', 'null', '[]']) assert.equal((await call('/v1/wake', {raw})).status, 400);
      assert.equal((await call('/v1/wake', {raw: ' '.repeat(2049)})).status, 413);
      assert.equal((await call('/v1/wake', {body: {value: '界'.repeat(800)}})).status, 413);
      assert.equal((await call('/v1/status')).body.command, null);
    });
    await test('Optional extra client token is disabled when absent', async () => {
      const {env, call, poll} = makeRelay(); await poll();
      assert.equal((await call('/v1/wake', {token: String(void 0)})).status, 401);
      env.DOT_TOKEN = randomBytes(32).toString('hex');
      assert.equal((await call('/v1/wake', {token: env.DOT_TOKEN})).status, 202);
      assert.equal((await call('/v1/device/poll', {token: env.DOT_TOKEN})).status, 401);
    });
    return {passed: passed.length, tests: passed};
  } finally {
    Date.now = originalNow;
    if (!originalCrypto) delete globalThis.crypto;
  }
}

if (typeof process !== 'undefined' && process.argv[1] &&
    import.meta.url === new URL('file://' + process.argv[1]).href) {
  const result = await runRelayTests();
  console.log(`${result.passed} relay tests passed`);
  result.tests.forEach(name => console.log(`  PASS ${name}`));
}
