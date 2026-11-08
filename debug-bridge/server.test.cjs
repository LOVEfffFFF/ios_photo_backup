const {test} = require('node:test');
const assert = require('node:assert/strict');
const {once} = require('node:events');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {createBridge} = require('./server.cjs');

async function fixture(t, options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'photo-debug-test-'));
  const bridge = createBridge({directory, ...options});
  bridge.server.listen(0, '127.0.0.1');
  await once(bridge.server, 'listening');
  t.after(async () => {
    await new Promise(resolve => bridge.server.close(resolve));
    fs.rmSync(directory, {recursive: true, force: true});
  });
  const port = bridge.server.address().port;
  const request = async (route, body, {token = route.startsWith('/device/') ? bridge.pairToken : bridge.controlToken,
    headers = {}, method = body === undefined ? 'GET' : 'POST'} = {}) => {
    if (headers.Host) return new Promise((resolve, reject) => {
      const request = http.request({hostname: '127.0.0.1', port, path: route, method,
        headers: {Authorization: 'Bearer ' + token, ...headers}}, response => {
        let value = ''; response.on('data', chunk => {value += chunk;});
        response.on('end', () => resolve({status: response.statusCode, body: JSON.parse(value)}));
      });
      request.on('error', reject); request.end();
    });
    const response = await fetch('http://127.0.0.1:' + port + route, {
      method, headers: {'Content-Type': 'application/json', Authorization: 'Bearer ' + token, ...headers},
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return {status: response.status, body: await response.json()};
  };
  const connect = async (allowRoundTrip = true, importVariants) => {
    const reply = await request('/device/connect', {assets: [{key: 'asset-1', label: 'synthetic.dng'}], allowRoundTrip, importVariants});
    assert.equal(reply.status, 200); return reply.body.sessionId;
  };
  const tick = (sessionId, status = {}) => request('/device/tick', {sessionId,
    status: {enabled: true, foreground: true, busy: false, ...status}, logTail: 'synthetic log'});
  return {...bridge, directory, request, connect, tick};
}

test('controller requires its own token, local Host, and no browser Origin', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('/control/status', undefined, {token: f.pairToken})).status, 401);
  assert.equal((await f.request('/control/status', undefined, {headers: {Host: 'evil.example'}})).status, 403);
  assert.equal((await f.request('/control/status', undefined, {headers: {Origin: 'http://evil.example'}})).status, 403);
  assert.equal((await f.request('/device/connect', {}, {token: 'wrong'})).status, 401);
  assert.equal((await f.request('/control/status')).status, 200);
});

test('commands are scoped, sequential, and never include deletion or code execution', async t => {
  const f = await fixture(t); await f.connect();
  for (const kind of ['delete', 'eval', 'restoreAll']) assert.equal(
    (await f.request('/control/jobs', {kind, target: 'asset-1'})).status, 400);
  assert.equal((await f.request('/control/jobs', {kind: 'inspect', target: 'unselected'})).status, 403);
  assert.equal((await f.request('/control/jobs', {kind: 'inspect', target: '../secret'})).status, 400);
  assert.equal((await f.request('/control/jobs', {kind: 'inspect', target: 'asset-1'})).status, 201);
  assert.equal((await f.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1'})).status, 409);
});

test('lost claim response cannot cause a second import; duplicate results are idempotent', async t => {
  const f = await fixture(t); const id = await f.connect();
  const job = (await f.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1'})).body;
  assert.equal((await f.tick(id)).body.job.id, job.id);
  assert.equal((await f.tick(id)).body.job, null);
  const completion = {sessionId: id, jobId: job.id, ok: true, data: {strictBytesMatch: false}};
  assert.equal((await f.request('/device/result', completion)).status, 200);
  assert.equal((await f.request('/device/result', completion)).status, 200);
  assert.equal((await f.request('/device/result', {...completion, ok: false})).status, 409);
  const saved = JSON.parse(fs.readFileSync(path.join(f.directory, job.id + '.json')));
  assert.equal(saved.state, 'completed');
  assert.equal(saved.result.data.strictBytesMatch, false);
});

test('paused, busy, stopped and read-only phone sessions cannot import', async t => {
  const f = await fixture(t); const id = await f.connect(false);
  assert.equal((await f.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1'})).status, 403);
  const job = (await f.request('/control/jobs', {kind: 'inspect', target: 'asset-1'})).body;
  assert.equal((await f.tick(id, {foreground: false})).body.job, null);
  assert.equal((await f.tick(id, {busy: true})).body.job, null);
  assert.equal((await f.tick(id, {enabled: false})).body.job, null);
  assert.equal((await f.tick(id)).body.job.id, job.id);
});

test('expired, offline and superseded sessions never replay queued jobs', async t => {
  let now = Date.now();
  const f = await fixture(t, {now: () => now});
  const first = await f.connect();
  const job = (await f.request('/control/jobs', {kind: 'inspect', target: 'asset-1'})).body;
  now += 16000;
  assert.equal((await f.request('/control/jobs', {kind: 'inspect', target: 'asset-1'})).status, 409);
  const second = await f.connect();
  assert.notEqual(second, first);
  assert.equal((await f.tick(first)).status, 410);
  assert.equal((await f.tick(second)).body.job, null);
  assert.equal((await f.request('/control/jobs/' + job.id)).body.state, 'interrupted');
  now = f.expiresAt;
  assert.equal((await f.tick(second)).status, 410);
});

test('default connection code is six digits and remains valid for seven days', async t => {
  let now = Date.now();
  const start = now;
  const f = await fixture(t, {now: () => now});
  assert.match(f.pairToken, /^[1-9][0-9]{5}$/);
  assert.equal(f.expiresAt - start, 7 * 24 * 60 * 60 * 1000);
  now += 2 * 24 * 60 * 60 * 1000;
  const sessionId = await f.connect();
  now = f.expiresAt - 1;
  assert.equal((await f.tick(sessionId)).status, 200);
  now++;
  assert.equal((await f.tick(sessionId)).status, 410);
});

test('ten incorrect short codes pause further attempts until the next minute', async t => {
  let now = Date.now();
  const f = await fixture(t, {now: () => now});
  for (let i = 0; i < 10; i++) assert.equal(
    (await f.request('/device/connect', {}, {token: 'wrong'})).status, 401);
  assert.equal((await f.request('/device/connect', {}, {token: 'wrong'})).status, 429);
  assert.equal((await f.request('/device/connect', {}, {token: f.pairToken})).status, 429);
  now += 60000;
  await f.connect();
});

test('session enforces ten attempts and copies can only be inspected', async t => {
  const f = await fixture(t); const id = await f.connect();
  for (let i = 0; i < 10; i++) {
    const job = (await f.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1'})).body;
    assert.equal((await f.tick(id)).body.job.id, job.id);
    assert.equal((await f.request('/device/result', {sessionId: id, jobId: job.id, ok: true})).status, 200);
  }
  assert.equal((await f.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1'})).status, 403);
  await f.request('/device/tick', {sessionId: id, status: {enabled: true}, copies: [{key: 'copy-1', label: 'synthetic copy'}]});
  assert.equal((await f.request('/control/jobs', {kind: 'roundTrip', target: 'copy-1'})).status, 403);
  assert.equal((await f.request('/control/jobs', {kind: 'inspect', target: 'copy-1'})).status, 201);
});

test('logs are bounded and protocol rejects oversized or malformed payloads', async t => {
  const f = await fixture(t); const id = await f.connect();
  assert.equal((await f.request('/device/tick', {sessionId: id, status: {}, logTail: 'x'.repeat(40000)})).status, 200);
  assert.equal((await f.request('/control/logs')).body.logTail.length, 32000);
  assert.equal((await f.request('/device/tick', {sessionId: id, status: {}, logTail: 'x'.repeat(140000)})).status, 413);
  assert.equal((await f.request('/device/tick', [])).status, 400);
  assert.equal((await f.request('/control/jobs', {kind: 'inspect', target: 'asset-1'}, {headers: {'Content-Type': 'text/plain'}})).status, 415);
});

test('timestamp experiments require phone capability and pass a fixed variant to one copy job', async t => {
  const f = await fixture(t); const id = await f.connect(true, ['fileDates', 'requestModificationDate', 'arbitrary-selector']);
  for (const importVariant of ['eval', 'arbitrary-selector', '../anything']) {
    assert.equal((await f.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant})).status, 400);
  }
  assert.equal((await f.request('/control/jobs', {kind: 'inspect', target: 'asset-1', importVariant: 'fileDates'})).status, 400);
  assert.equal((await f.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'adjustmentData'})).status, 409);
  const job = (await f.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'requestModificationDate'})).body;
  assert.equal(job.importVariant, 'requestModificationDate');
  assert.equal((await f.tick(id)).body.job.importVariant, 'requestModificationDate');
  assert.equal((await f.request('/control/status')).body.session.roundTrips, 1);
});

test('read-only and legacy phones cannot run timestamp experiments', async t => {
  const legacy = await fixture(t); await legacy.connect();
  assert.equal((await legacy.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'fileDates'})).status, 409);
  const readOnly = await fixture(t); await readOnly.connect(false, ['fileDates']);
  assert.equal((await readOnly.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'fileDates'})).status, 403);
});

test('primary resource date experiment rejects an older phone and requires explicit copy permission', async t => {
  const older = await fixture(t); await older.connect(true, ['fileDates', 'combinedDates']);
  assert.equal((await older.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'mainResourceImportDate'})).status, 409);
  const readOnly = await fixture(t); await readOnly.connect(false, ['mainResourceImportDate']);
  assert.equal((await readOnly.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'mainResourceImportDate'})).status, 403);
  const enabled = await fixture(t); const id = await enabled.connect(true, ['mainResourceImportDate']);
  const submitted = await enabled.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'mainResourceImportDate'});
  assert.equal(submitted.status, 201);
  assert.equal((await enabled.tick(id)).body.job.importVariant, 'mainResourceImportDate');
  assert.equal((await enabled.request('/control/status')).body.session.roundTrips, 1);
});

test('fixed adjustment metadata experiment requires a capable writable phone and rejects key-path commands', async t => {
  const older = await fixture(t); await older.connect(true, ['mainResourceImportDate']);
  assert.equal((await older.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'customAdjustmentDate'})).status, 409);
  const readOnly = await fixture(t); await readOnly.connect(false, ['customAdjustmentDate']);
  assert.equal((await readOnly.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'customAdjustmentDate'})).status, 403);
  const enabled = await fixture(t); const id = await enabled.connect(true, ['customAdjustmentDate']);
  assert.equal((await enabled.request('/control/jobs', {kind: 'inspect', target: 'asset-1', importVariant: 'customAdjustmentDate'})).status, 400);
  assert.equal((await enabled.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'additionalAttributes.unmanagedAdjustment.adjustmentTimestamp'})).status, 400);
  const submitted = await enabled.request('/control/jobs', {kind: 'roundTrip', target: 'asset-1', importVariant: 'customAdjustmentDate'});
  assert.equal(submitted.status, 201);
  assert.equal((await enabled.tick(id)).body.job.importVariant, 'customAdjustmentDate');
  assert.equal((await enabled.request('/control/status')).body.session.roundTrips, 1);
});
