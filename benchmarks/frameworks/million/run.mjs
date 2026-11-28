// Mount and toggle a large checkbox list. The Saba arm is the JSX compiler's
// own output. Results go to --out, never to the historical fair-bench file.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { availableParallelism, cpus, totalmem } from 'node:os';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { build } from 'esbuild';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const directory = path.resolve(here, '..');
const root = path.resolve(directory, '../..');
const options = { rounds: 3, count: 1_000_000, reps: 2, out: path.join(here, 'result.json') };
const flags = { '--rounds': 'rounds', '--count': 'count', '--reps': 'reps', '--out': 'out' };
for (let i = 2; i < process.argv.length; i += 2) {
  const key = flags[process.argv[i]];
  const value = process.argv[i + 1];
  if (!key || value == null) throw new Error('Unknown option ' + process.argv[i]);
  if (key === 'out') options.out = path.resolve(value);
  else options[key] = Number(value);
}
if (!Number.isInteger(options.count) || options.count < 1 || options.count > 2_000_000) {
  throw new Error('Invalid count');
}

const compileDir = mkdtempSync(path.join(tmpdir(), 'saba-million-'));
const compilerBin = path.join(compileDir, 'saba-jsx-compiler');
let shared = process.env.WEBTOOLS_SHARED;
let sharedRoot;
if (!shared) {
  sharedRoot = mkdtempSync(path.join(tmpdir(), 'saba-million-root-'));
  execFileSync('krs', ['install', '--frozen', '--root=' + sharedRoot], { cwd: root, stdio: 'inherit' });
  shared = path.join(sharedRoot, 'shared');
}
execFileSync(process.env.ODIN || 'odin', [
  'build', path.join(directory, 'operations/compile'),
  '-collection:shared=' + shared,
  '-out:' + compilerBin,
], { cwd: root, stdio: 'inherit' });
const generated = path.join(compileDir, 'check-saba.js');
execFileSync(compilerBin, [path.join(here, 'check-saba.jsx'), generated], { cwd: root, stdio: 'inherit' });
const compiled = readFileSync(generated, 'utf8');
if (compiled.includes('/__saba/') || !compiled.includes('createElement("input")') || !compiled.includes('.checked')) {
  throw new Error('Checkbox row did not compile to a direct loop');
}

const bundles = {};
for (const [name, entry] of [['vanilla', path.join(here, 'check-vanilla.js')], ['saba', generated]]) {
  const result = await build({
    absWorkingDir: directory,
    entryPoints: [entry],
    bundle: true,
    minify: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    write: false,
    define: { 'process.env.NODE_ENV': '"production"' },
  });
  bundles[name] = Buffer.from(result.outputFiles[0].contents);
  console.log(name, bundles[name].length, 'bytes');
}

function playwright() {
  const candidates = [process.env.PLAYWRIGHT_PATH, '/tmp/saba-fair-pw/node_modules/playwright-core', 'playwright-core'];
  for (const name of candidates) {
    if (!name) continue;
    try { return require(name); }
    catch { /* try the next install */ }
  }
  throw new Error('Set PLAYWRIGHT_PATH or install playwright-core');
}

function chromePath() {
  if (process.env.SABA_CHROME) return process.env.SABA_CHROME;
  const { globSync } = require('node:fs');
  const hits = globSync(path.join(process.env.HOME, 'Library/Caches/ms-playwright/chromium-*/chrome-mac*/**/Google Chrome for Testing'), { nodir: true });
  if (hits.length) return hits.sort().at(-1);
  return '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
}

const files = new Map([
  ['/', readFileSync(path.join(here, 'index.html'))],
  ['/driver.js', readFileSync(path.join(here, 'driver.js'))],
  ['/arms/vanilla.js', bundles.vanilla],
  ['/arms/saba.js', bundles.saba],
]);
const server = createServer((request, response) => {
  const body = files.get(request.url.split('?')[0]);
  if (!body) {
    response.writeHead(404);
    response.end();
    return;
  }
  const type = request.url.endsWith('.js') ? 'text/javascript; charset=utf-8' : 'text/html; charset=utf-8';
  response.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' });
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
  args: ['--disable-dev-shm-usage'],
});
const arms = ['vanilla', 'saba'];
const visits = [];
try {
  for (let round = 0; round < options.rounds; round++) {
    const order = round % 2 === 0 ? arms : ['saba', 'vanilla'];
    for (const arm of order) {
      const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(String(error.stack || error)));
      const query = new URLSearchParams({
        arm, count: String(options.count), reps: String(options.reps),
      });
      try {
        await page.goto(origin + '/?' + query, { waitUntil: 'load', timeout: 30000 });
        await page.waitForFunction(() => document.documentElement.dataset.done === '1', null, { timeout: 300000 });
        const result = await page.evaluate(() => window.__million);
        if (result.error) throw new Error(result.error);
        visits.push({ round, ...result, pageErrors: errors });
        console.log('round', round, arm, 'mount', result.mountMs.toFixed(1), 'ms sparse', result.sparseMs.toFixed(1), 'dense', result.denseMs.toFixed(1));
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

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}
const fields = ['evalMs', 'mountMs', 'sparseMs', 'denseMs'];
const byArm = {};
for (const arm of arms) {
  const samples = visits.filter(visit => visit.arm === arm && !visit.error);
  byArm[arm] = {
    bytes: bundles[arm].length,
    sha256: createHash('sha256').update(bundles[arm]).digest('hex'),
    failures: visits.filter(visit => visit.arm === arm && visit.error).length,
  };
  for (const field of fields) byArm[arm][field] = median(samples.map(visit => visit[field]));
}
const report = {
  created: new Date().toISOString(),
  machine: { cpu: cpus()[0]?.model, cores: availableParallelism(), memoryBytes: totalmem() },
  options,
  byArm,
  visits,
};
writeFileSync(options.out, JSON.stringify(report, null, 2) + '\n');
rmSync(compileDir, { recursive: true, force: true });
if (sharedRoot) rmSync(sharedRoot, { recursive: true, force: true });
const failed = visits.some(visit => visit.error);
if (failed) process.exit(1);
console.log('vanilla', byArm.vanilla.mountMs.toFixed(1), 'ms mount,', byArm.vanilla.bytes, 'bytes');
console.log('saba   ', byArm.saba.mountMs.toFixed(1), 'ms mount,', byArm.saba.bytes, 'bytes');
