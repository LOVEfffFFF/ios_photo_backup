// Separate from the backup receiver. Node 20+, no third-party dependencies.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const fail = (code, message) => Object.assign(new Error(message), {code});
const equal = (a, b) => typeof a === 'string' && typeof b === 'string' &&
  Buffer.byteLength(a) === Buffer.byteLength(b) && crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
const loopback = address => ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(address);
const validKey = value => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(value);
const importVariants = new Set(['baseline', 'fileDates', 'adjustmentData', 'resourceImportDate',
  'requestImportDate', 'requestModificationDate', 'combinedDates', 'mainResourceImportDate',
  'customAdjustmentDate']);

async function readJson(req, limit) {
  if (!(req.headers['content-type'] || '').startsWith('application/json')) throw fail(415, 'JSON required');
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw fail(413, 'Request too large');
    chunks.push(chunk);
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error();
    return value;
  } catch { throw fail(400, 'Invalid JSON object'); }
}

function createBridge({directory, pairToken = String(crypto.randomInt(100000, 1000000)),
  controlToken = crypto.randomBytes(32).toString('hex'), now = Date.now,
  lifetimeMs = 7 * 24 * 60 * 60 * 1000} = {}) {
  const expiresAt = now() + lifetimeMs;
  const jobs = new Map();
  let session = null;
  let lastLog = '';
  let failedPairAttempts = 0;
  let pairWindowStarted = now();
  if (directory) fs.mkdirSync(directory, {recursive: true});
  function save(name, data) {
    if (!directory) return;
    const dest = path.join(directory, name);
    fs.writeFileSync(dest + '.tmp', JSON.stringify(data, null, 2), {mode: 0o600});
    fs.renameSync(dest + '.tmp', dest);
  }
  function view() {
    return {protocol: 1, expiresAt, session: session && {...session,
      online: now() < expiresAt && session.status?.enabled === true && now() - session.lastSeen < 15000},
    jobs: [...jobs.values()].map(({result, ...job}) => job)};
  }
  function current(id) {
    if (!session || id !== session.id) throw fail(410, 'Session ended; reconnect on phone');
    return session;
  }
  const server = http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    function reply(status, data) {
      res.writeHead(status, {'Content-Type': 'application/json; charset=utf-8'});
      res.end(JSON.stringify(data));
    }
    try {
      if (req.headers.origin) throw fail(403, 'Browser access disabled');
      if (now() >= expiresAt) throw fail(410, 'Debug bridge expired');
      const route = new URL(req.url, 'http://localhost').pathname;
      if (route === '/health' && req.method === 'GET') return reply(200, {service: 'PhotoBackup debug bridge', protocol: 1});
      const device = route.startsWith('/device/');
      const control = route.startsWith('/control/');
      if (!device && !control) throw fail(404, 'Unknown endpoint');
      if (control && (!loopback(req.socket.remoteAddress) ||
          !/^127\.0\.0\.1:\d+$/.test(req.headers.host || ''))) throw fail(403, 'Local controller only');
      const expected = device ? pairToken : controlToken;
      if (device) {
        if (now() - pairWindowStarted >= 60000) {failedPairAttempts = 0; pairWindowStarted = now();}
        if (failedPairAttempts >= 10) throw fail(429, 'Too many incorrect connection codes; try again in one minute');
      }
      if (!equal(req.headers.authorization, 'Bearer ' + expected)) {
        if (device) failedPairAttempts++;
        throw fail(401, 'Invalid access token');
      }
      if (route === '/device/connect' && req.method === 'POST') {
        const body = await readJson(req, 64 * 1024);
        if (!Array.isArray(body.assets) || !body.assets.length || body.assets.length > 10 ||
            body.assets.some(a => !a || !validKey(a.key) || typeof a.label !== 'string' || a.label.length > 512) ||
            new Set(body.assets.map(a => a.key)).size !== body.assets.length) throw fail(400, 'Select 1 to 10 assets on phone');
        if (session && session.status?.enabled && now() - session.lastSeen < 15000) throw fail(409, 'A phone session is already connected');
        for (const job of jobs.values()) if (['queued', 'running'].includes(job.state)) {
          job.state = 'interrupted'; save(job.id + '.json', job);
        }
        session = {id: crypto.randomUUID(), assets: body.assets.map(a => ({key: a.key, label: a.label})),
          allowRoundTrip: body.allowRoundTrip === true, app: String(body.app || '').slice(0, 512),
          importVariants: Array.isArray(body.importVariants)
            ? [...new Set(['baseline', ...body.importVariants.filter(v => importVariants.has(v))])] : ['baseline'],
          connectedAt: now(), lastSeen: now(), status: {enabled: true, foreground: true, busy: false},
          copies: [], roundTrips: 0};
        lastLog = '';
        save('status.json', view());
        return reply(200, {sessionId: session.id, expiresAt, protocol: 1});
      }
      if (route === '/device/tick' && req.method === 'POST') {
        const body = await readJson(req, 128 * 1024);
        const s = current(body.sessionId);
        if (!body.status || typeof body.status !== 'object') throw fail(400, 'Missing status');
        s.lastSeen = now();
        s.status = {enabled: body.status.enabled === true, foreground: body.status.foreground === true,
          busy: body.status.busy === true, activeJob: String(body.status.activeJob || '').slice(0, 80),
          message: String(body.status.message || '').slice(0, 1024)};
        s.copies = Array.isArray(body.copies) ? body.copies.filter(c => c && validKey(c.key)).slice(0, 10)
          .map(c => ({key: c.key, label: String(c.label || '').slice(0, 512)})) : [];
        lastLog = typeof body.logTail === 'string' ? body.logTail.slice(-32000) : '';
        save('live-log.json', {updatedAt: s.lastSeen, logTail: lastLog});
        let selected = null;
        if (s.status.enabled && s.status.foreground && !s.status.busy) {
          selected = [...jobs.values()].find(j => j.sessionId === s.id && j.state === 'queued');
          if (selected) {selected.state = 'running'; selected.startedAt = now(); save(selected.id + '.json', selected);}
        }
        save('status.json', view());
        return reply(200, {job: selected ? {id: selected.id, kind: selected.kind, target: selected.target,
          ...(selected.importVariant ? {importVariant: selected.importVariant} : {})} : null});
      }
      if (route === '/device/result' && req.method === 'POST') {
        const body = await readJson(req, 12 * 1024 * 1024);
        current(body.sessionId);
        const job = jobs.get(body.jobId);
        if (!job || job.sessionId !== session.id || !['running', 'completed'].includes(job.state)) throw fail(409, 'Job is not running');
        if (typeof body.ok !== 'boolean') throw fail(400, 'Missing result status');
        const result = {ok: body.ok, data: body.data ?? null, error: body.error ?? null};
        const digest = crypto.createHash('sha256').update(JSON.stringify(result)).digest('hex');
        if (job.state === 'completed' && job.resultDigest !== digest) throw fail(409, 'Conflicting duplicate result');
        job.resultDigest = digest;
        job.result = result; job.state = 'completed'; job.finishedAt ??= now();
        save(job.id + '.json', job);
        if (directory) delete job.result;
        save('status.json', view());
        return reply(200, {accepted: true});
      }
      if (route === '/control/status' && req.method === 'GET') return reply(200, view());
      if (route === '/control/logs' && req.method === 'GET') return reply(200, {updatedAt: session?.lastSeen, logTail: lastLog});
      if (route === '/control/jobs' && req.method === 'POST') {
        const body = await readJson(req, 4096);
        if (!session || !session.status.enabled || now() - session.lastSeen > 15000) throw fail(409, 'Phone is offline');
        // scanEffects 覆盖全库、只读，不作用于选中照片，因此没有 target
        const scanEffects = body.kind === 'scanEffects';
        // filterProbe 复用 importVariant 传参：probe:<effectName>:<intensity>
        const filterProbe = body.kind === 'filterProbe';
        if (!['inspect', 'roundTrip', 'scanEffects', 'filterProbe'].includes(body.kind)) throw fail(400, 'Unsupported command');
        if (!scanEffects && !validKey(body.target)) throw fail(400, 'Unsupported command');
        const variant = body.importVariant ?? 'baseline';
        if (!filterProbe && (!importVariants.has(variant) || (variant !== 'baseline' && body.kind !== 'roundTrip'))) throw fail(400, 'Unsupported import variant');
        if (!filterProbe && !session.importVariants.includes(variant)) throw fail(409, 'Install the timestamp test build on phone first');
        if (filterProbe && !/^probe:[A-Za-z0-9_]+:[0-9]*\.?[0-9]+$/.test(String(body.importVariant || ''))) throw fail(400, 'filterProbe needs importVariant=probe:<effectName>:<intensity>');
        const original = !scanEffects && session.assets.some(a => a.key === body.target);
        const copy = !scanEffects && session.copies.some(a => a.key === body.target);
        if (!scanEffects && !original && !copy) throw fail(403, 'Target was not selected on phone');
        if (body.kind === 'roundTrip' && (!original || !session.allowRoundTrip || session.roundTrips >= 10)) throw fail(403, 'Round-trip not allowed or session limit reached');
        if ([...jobs.values()].some(j => j.sessionId === session.id && ['queued', 'running'].includes(j.state))) throw fail(409, 'Wait for the current job');
        if (jobs.size >= 50) throw fail(429, 'Bridge task limit reached; start a new debug session');
        const job = {id: crypto.randomUUID(), sessionId: session.id, kind: body.kind,
          target: scanEffects ? '' : body.target, ...(variant !== 'baseline' ? {importVariant: variant} : {}), state: 'queued', createdAt: now()};
        if (job.kind === 'roundTrip') session.roundTrips++;
        jobs.set(job.id, job); save(job.id + '.json', job); save('status.json', view());
        return reply(201, job);
      }
      if (route.startsWith('/control/jobs/') && req.method === 'GET') {
        const job = jobs.get(route.slice('/control/jobs/'.length));
        if (!job) throw fail(404, 'Unknown job');
        return reply(200, directory ? JSON.parse(fs.readFileSync(path.join(directory, job.id + '.json'), 'utf8')) : job);
      }
      throw fail(404, 'Unknown endpoint or method');
    } catch (error) {
      if (!res.headersSent) reply(error.code >= 400 && error.code <= 599 ? error.code : 500,
        {error: error.code >= 400 && error.code <= 599 ? error.message : 'Bridge internal error'});
    }
  });
  server.requestTimeout = 30000; server.headersTimeout = 15000;
  return {server, pairToken, controlToken, expiresAt};
}

module.exports = {createBridge};
if (require.main === module) {
  const port = Number(process.argv[2] || 18081);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid port');
  const directory = path.resolve(process.argv[3] || path.join(__dirname, 'data', new Date().toISOString().replace(/[:.]/g, '-')));
  const bridge = createBridge({directory});
  bridge.server.on('error', error => {console.error('Debug bridge: ' + error.message); process.exitCode = 1;});
  bridge.server.listen(port, '0.0.0.0', () => {
    const info = {port, directory, pairToken: bridge.pairToken, controlToken: bridge.controlToken,
      expiresAt: bridge.expiresAt, pid: process.pid};
    fs.writeFileSync(path.join(directory, 'connection.json'), JSON.stringify(info, null, 2), {mode: 0o600});
    console.log('Debug bridge listening on port ' + port + '. Connection details saved locally.');
    setTimeout(() => bridge.server.close(), Math.max(1, bridge.expiresAt - Date.now())).unref();
  });
}
