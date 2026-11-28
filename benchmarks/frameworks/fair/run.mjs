// One edit sequence for every arm. Keyed arms are scored against vanilla-keyed.
// Window recycling is scored against vanilla-slot. Idiomorph is the client
// morph used by the htmx adapter, without a server or a network.
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { availableParallelism, cpus, totalmem } from 'node:os';
import { readFileSync, writeFileSync } from 'node:fs';
import { globSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const directory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.resolve(directory, '../..');
const arms = ['vanilla-keyed', 'vanilla-slot', 'saba-keyed', 'saba-slot', 'preact', 'react', 'solid', 'svelte', 'idiomorph'];
const keyedOps = ['mountMs', 'sparseMs', 'denseMs', 'reverseMs', 'rotateMs', 'spliceMs'];
const slotOps = ['windowMountMs', 'jumpMs', 'shiftMs'];
const options = { rounds: 6, out: path.join(root, 'docs/benchmarks/renderer-fair.json'), list: 2048, window: 256, reps: 12, warmup: 6 };
const flags = { '--rounds': 'rounds', '--out': 'out', '--list': 'list', '--window': 'window', '--reps': 'reps', '--warmup': 'warmup', '--arms': 'arms' };
let selected = arms;
for (let i = 2; i < process.argv.length; i += 2) {
  const key = flags[process.argv[i]];
  const value = process.argv[i + 1];
  if (!key || value == null) throw new Error('Unknown option ' + process.argv[i]);
  if (key === 'out') options.out = path.resolve(value);
  else if (key === 'arms') selected = value.split(',');
  else options[key] = Number(value);
}
if (!selected.length || selected.some(arm => !arms.includes(arm))) throw new Error('Unknown arm');
for (const [key, min, max] of [['rounds', 1, 20], ['list', 64, 20000], ['window', 32, 2000], ['reps', 2, 40], ['warmup', 0, 20]]) {
  if (!Number.isInteger(options[key]) || options[key] < min || options[key] > max) throw new Error('Invalid ' + key);
}

function playwright() {
  const candidates = [process.env.PLAYWRIGHT_PATH, '/tmp/saba-fair-pw/node_modules/playwright-core', 'playwright', 'playwright-core'];
  for (const name of candidates) {
    if (!name) continue;
    try { return require(name); }
    catch { /* try the next install */ }
  }
  throw new Error('Set PLAYWRIGHT_PATH or install playwright-core');
}

function chromePath() {
  if (process.env.SABA_CHROME) return process.env.SABA_CHROME;
  const hits = globSync(path.join(process.env.HOME, 'Library/Caches/ms-playwright/chromium-*/chrome-mac*/**/Google Chrome for Testing'), { nodir: true });
  if (hits.length) return hits.sort().at(-1);
  return '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
}

function contentType(url) {
  if (url.endsWith('.html') || url === '/') return 'text/html; charset=utf-8';
  if (url.endsWith('.js')) return 'text/javascript; charset=utf-8';
  return 'application/octet-stream';
}

const files = new Map();
function add(url, file) {
  files.set(url, readFileSync(file));
}
add('/', path.join(directory, 'fair/index.html'));
add('/driver.js', path.join(directory, 'fair/driver.js'));
const manifest = JSON.parse(readFileSync(path.join(directory, 'dist/fair/manifest.json'), 'utf8'));
for (const arm of selected) {
  const file = path.join(directory, 'dist/fair', arm + '.js');
  add('/arms/' + arm + '.js', file);
  const bytes = files.get('/arms/' + arm + '.js');
  if (createHash('sha256').update(bytes).digest('hex') !== manifest.bundles[arm].sha256) {
    throw new Error('Rebuild fair bundles before measuring ' + arm);
  }
}

const server = createServer((request, response) => {
  const key = request.url.split('?')[0];
  const body = files.get(key);
  if (!body) {
    response.writeHead(404);
    response.end();
    return;
  }
  response.writeHead(200, { 'content-type': contentType(key), 'cache-control': 'no-store' });
  response.end(body);
});
await new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', resolve);
});
const origin = 'http://127.0.0.1:' + server.address().port;
const { chromium } = playwright();
const browser = await chromium.launch({
  executablePath: chromePath(),
  headless: true,
  args: ['--js-flags=--expose-gc', '--enable-precise-memory-info'],
});

function rotate(round) {
  const offset = round % selected.length;
  return selected.slice(offset).concat(selected.slice(0, offset));
}

const visits = [];
try {
  for (let round = 0; round < options.rounds; round++) {
    for (const arm of rotate(round)) {
      const context = await browser.newContext({ viewport: { width: 1200, height: 900 } });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(String(error.stack || error)));
      const query = new URLSearchParams({
        arm,
        list: String(options.list),
        window: String(options.window),
        reps: String(options.reps),
        warmup: String(options.warmup),
      });
      try {
        await page.goto(origin + '/?' + query, { waitUntil: 'load', timeout: 30000 });
        await page.waitForFunction(() => document.documentElement.dataset.done === '1', null, { timeout: 120000 });
        const result = await page.evaluate(() => window.__fair);
        visits.push({ round, arm, ...result, pageErrors: errors });
        const mark = result.error ? 'FAIL' : result.sparseMs.toFixed(3) + ' ms sparse';
        console.log('round', round, arm, mark);
      } catch (error) {
        visits.push({ round, arm, error: String(error.stack || error), pageErrors: errors });
        console.log('round', round, arm, 'FAIL', error.message);
      }
      await context.close();
    }
  }
} finally {
  await browser.close();
  server.close();
}

function samples(arm, field) {
  return visits.filter(visit => visit.arm === arm && !visit.error && visit[field] != null).map(visit => visit[field]);
}

function summary(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  const median = sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  return { n: sorted.length, min: sorted[0], median, max: sorted.at(-1) };
}

function paired(arm, floor, field) {
  const deltas = [];
  const ratios = [];
  for (let round = 0; round < options.rounds; round++) {
    const left = visits.find(visit => visit.round === round && visit.arm === arm && !visit.error);
    const right = visits.find(visit => visit.round === round && visit.arm === floor && !visit.error);
    if (!left || !right || right[field] === 0) continue;
    deltas.push(left[field] - right[field]);
    ratios.push(left[field] / right[field]);
  }
  return { deltaMs: summary(deltas), ratio: summary(ratios) };
}

const fields = ['evalMs', 'mountMs', 'layoutMs', 'heapBytes', 'markers', 'sparseMs', 'denseMs', 'reverseMs', 'rotateMs', 'spliceMs', 'windowMountMs', 'jumpMs', 'shiftMs', 'reverseKept', 'jumpReusedAll'];
const byArm = {};
for (const arm of selected) {
  byArm[arm] = {
    bundleBytes: manifest.bundles[arm].bytes,
    failures: visits.filter(visit => visit.arm === arm && visit.error).length,
  };
  for (const field of fields) byArm[arm][field] = summary(samples(arm, field).map(value => value === true ? 1 : value === false ? 0 : value));
  if (selected.includes('vanilla-keyed')) {
    byArm[arm].versusKeyed = {};
    for (const field of keyedOps) byArm[arm].versusKeyed[field] = paired(arm, 'vanilla-keyed', field);
  }
  if (selected.includes('vanilla-slot')) {
    byArm[arm].versusSlot = {};
    for (const field of slotOps) byArm[arm].versusSlot[field] = paired(arm, 'vanilla-slot', field);
  }
}

const chrome = spawnSync(chromePath(), ['--version'], { encoding: 'utf8' });
const report = {
  created: new Date().toISOString(),
  machine: { cpu: cpus()[0]?.model, cores: availableParallelism(), memoryBytes: totalmem() },
  chrome: (chrome.stdout || chrome.stderr || '').trim(),
  node: process.version,
  options,
  arms: selected,
  manifest,
  byArm,
  visits,
};
writeFileSync(options.out, JSON.stringify(report, null, 2) + '\n');

function cell(arm, field) {
  const value = byArm[arm][field];
  if (!value) return '—';
  if (field === 'heapBytes') return (value.median / 1024 / 1024).toFixed(2) + ' MiB';
  if (field === 'markers' || field === 'jumpReusedAll') return String(value.median);
  return value.median.toFixed(3);
}

const header = ['arm', 'bundle', 'eval', 'mount', 'sparse', 'dense', 'reverse', 'rotate', 'splice', 'win', 'jump', 'shift', 'markers'];
console.log('\n' + header.join('\t'));
for (const arm of selected) {
  const row = [
    arm,
    manifest.bundles[arm].bytes,
    cell(arm, 'evalMs'),
    cell(arm, 'mountMs'),
    cell(arm, 'sparseMs'),
    cell(arm, 'denseMs'),
    cell(arm, 'reverseMs'),
    cell(arm, 'rotateMs'),
    cell(arm, 'spliceMs'),
    cell(arm, 'windowMountMs'),
    cell(arm, 'jumpMs'),
    cell(arm, 'shiftMs'),
    cell(arm, 'markers'),
  ];
  console.log(row.join('\t'));
}
console.log('wrote', options.out);
