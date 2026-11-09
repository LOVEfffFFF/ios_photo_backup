const fs = require('node:fs');
async function main() {
  const [file, action = 'status', target, importVariant] = process.argv.slice(2);
  if (!file) throw new Error('Usage: node control.cjs CONNECTION_FILE status|logs|inspect|roundTrip|job [TARGET]');
  const connection = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  const job = ['inspect', 'roundTrip', 'scanEffects', 'filterProbe', 'filterMatrix'].includes(action);
  const route = job ? '/control/jobs' : action === 'job' ? '/control/jobs/' + encodeURIComponent(target || '')
    : action === 'status' ? '/control/status' : action === 'logs' ? '/control/logs' : null;
  if (!route) throw new Error('Unknown action');
  const response = await fetch('http://127.0.0.1:' + connection.port + route, {
    method: job ? 'POST' : 'GET',
    headers: {Authorization: 'Bearer ' + connection.controlToken, 'Content-Type': 'application/json'},
    body: job ? JSON.stringify({kind: action, target, ...(importVariant ? {importVariant} : {})}) : undefined,
    signal: AbortSignal.timeout(15000),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Request failed');
  console.log(JSON.stringify(result, null, 2));
}
main().catch(error => {console.error(error.message); process.exitCode = 1;});
