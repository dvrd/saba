// Compile each complex fixture with the real JSX compiler and time that
// output against a hand-written vanilla keyed loop. Results go to --out,
// never to the historical fair-bench file.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { availableParallelism, cpus, totalmem, tmpdir } from 'node:os';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { build } from 'esbuild';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const directory = path.resolve(here, '..');
const root = path.resolve(directory, '../..');
const fullCounts = {
  attrs: 100_000,
  images: 50_000,
  videos: 10_000,
  nested: 20_000,
  fields: 20_000,
  sources: 50_000,
};
const scenarioNames = Object.keys(fullCounts);
const defaultOut = path.join(here, 'result.json');
const options = {
  rounds: 3,
  reps: 2,
  smoke: false,
  heap: false,
  only: '',
  out: defaultOut,
};
let roundsSet = false;
for (let i = 2; i < process.argv.length; i++) {
  const flag = process.argv[i];
  if (flag === '--smoke') {
    options.smoke = true;
    continue;
  }
  if (flag === '--heap') {
    options.heap = true;
    continue;
  }
  const value = process.argv[++i];
  if (value == null) throw new Error('Missing value for ' + flag);
  if (flag === '--rounds') {
    options.rounds = Number(value);
    roundsSet = true;
  } else if (flag === '--reps') options.reps = Number(value);
  else if (flag === '--only') options.only = value;
  else if (flag === '--out') options.out = path.resolve(value);
  else throw new Error('Unknown option ' + flag);
}
if (options.heap && !roundsSet) options.rounds = 1;
if (options.heap && options.out === defaultOut) options.out = path.join(here, 'heap.json');
if (!Number.isInteger(options.rounds) || options.rounds < 1) throw new Error('Invalid rounds');
if (!Number.isInteger(options.reps) || options.reps < 1 || options.reps % 2 !== 0) {
  throw new Error('Reps must be a positive even integer so reverse restores order');
}
if (path.basename(options.out) === 'renderer-fair.json') {
  throw new Error('Refusing to write the historical fair benchmark');
}
const selected = options.only ? options.only.split(',') : scenarioNames;
for (const name of selected) {
  if (!fullCounts[name]) throw new Error('Unknown scenario ' + name);
}
const counts = {};
for (const name of selected) counts[name] = options.smoke ? 200 : fullCounts[name];

const compileDir = mkdtempSync(path.join(tmpdir(), 'saba-complex-'));
const compilerBin = path.join(compileDir, 'saba-jsx-compiler');
let shared = process.env.WEBTOOLS_SHARED;
let sharedRoot;
if (!shared) {
  sharedRoot = mkdtempSync(path.join(tmpdir(), 'saba-complex-root-'));
  execFileSync('krs', ['install', '--frozen', '--root=' + sharedRoot], { cwd: root, stdio: 'inherit' });
  shared = path.join(sharedRoot, 'shared');
}
execFileSync(process.env.ODIN || 'odin', [
  'build', path.join(directory, 'operations/compile'),
  '-collection:shared=' + shared,
  '-out:' + compilerBin,
], { cwd: root, stdio: 'inherit' });

const resolveSabaRuntime = {
  name: 'saba-runtime',
  setup(builder) {
    builder.onResolve({ filter: /^\/__saba\/dom\.js$/ }, () => ({
      path: path.join(root, 'src/modules/dom.js'),
    }));
    builder.onResolve({ filter: /^\/__saba\/slot-window\.js$/ }, () => ({
      path: path.join(root, 'src/modules/slot-window.js'),
    }));
  },
};

const compiled = {};
const bundles = {};
const pageWrapper = `import { mountPeople } from './people.js';
import { mountTasks } from './tasks.js';
export function mountPage(host, people, tasks) {
  const peopleHost = document.createElement('div');
  const tasksHost = document.createElement('div');
  host.append(peopleHost, tasksHost);
  const peopleBand = mountPeople(peopleHost, people);
  const tasksBand = mountTasks(tasksHost, tasks);
  return {
    replace(nextPeople, nextTasks) {
      peopleBand.replace(nextPeople);
      tasksBand.replace(nextTasks);
    },
    dispose() {
      peopleBand.dispose();
      tasksBand.dispose();
      host.replaceChildren();
    },
  };
}
`;
for (const name of selected) {
  let generated = path.join(compileDir, name + '.js');
  if (name === 'sources') {
    const parts = [];
    for (const part of ['people', 'tasks']) {
      const output = path.join(compileDir, part + '.js');
      execFileSync(compilerBin, [path.join(here, 'fixtures', part + '.jsx'), output], { cwd: root, stdio: 'inherit' });
      parts.push(readFileSync(output, 'utf8'));
    }
    const onePath = path.join(compileDir, 'sources-one.js');
    execFileSync(compilerBin, [path.join(here, 'fixtures', 'sources.jsx'), onePath], { cwd: root, stdio: 'inherit' });
    const oneSource = readFileSync(onePath, 'utf8');
    const redeclared = (oneSource.match(/function textOf/g) || []).length > 1;
    writeFileSync(generated, pageWrapper);
    const source = parts.join('\n');
    compiled[name] = {
      source,
      mode: source.includes('/__saba/') ? 'runtime' : 'direct',
      callsKeyed: /\bkeyed\(/.test(source),
      modules: 2,
      oneModule: redeclared ? 'redeclared textOf/create/move' : 'single module',
    };
  } else {
    execFileSync(compilerBin, [path.join(here, 'fixtures', name + '.jsx'), generated], { cwd: root, stdio: 'inherit' });
    const source = readFileSync(generated, 'utf8');
    compiled[name] = {
      source,
      mode: source.includes('/__saba/') ? 'runtime' : 'direct',
      callsKeyed: /\bkeyed\(/.test(source),
      modules: 1,
      oneModule: 'single module',
    };
  }
  console.log(
    name, compiled[name].mode,
    compiled[name].callsKeyed ? 'calls keyed' : 'no keyed call',
    compiled[name].oneModule,
  );
  for (const arm of ['vanilla', 'saba']) {
    const entry = arm === 'vanilla' ? path.join(here, 'vanilla', name + '.js') : generated;
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
      plugins: arm === 'saba' ? [resolveSabaRuntime] : [],
      logLevel: 'silent',
    });
    const code = Buffer.from(result.outputFiles[0].contents);
    bundles[name + '-' + arm] = code;
    console.log(name, arm, code.length, 'bytes');
  }
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
]);
for (const [name, code] of Object.entries(bundles)) files.set('/arms/' + name + '.js', code);

const server = createServer((request, response) => {
  const body = files.get(request.url.split('?')[0]);
  if (!body) {
    response.writeHead(404);
    response.end();
    return;
  }
  const type = request.url.includes('.js') ? 'text/javascript; charset=utf-8' : 'text/html; charset=utf-8';
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

async function heapSnapshot(page) {
  const client = await page.context().newCDPSession(page);
  let jsHeapUsed = Infinity;
  let chromeNodes = 0;
  try {
    await client.send('Performance.enable');
    for (let pass = 0; pass < 3; pass++) {
      await client.send('HeapProfiler.collectGarbage');
      const usage = await client.send('Runtime.getHeapUsage');
      const { metrics } = await client.send('Performance.getMetrics');
      const nodes = metrics.find((metric) => metric.name === 'Nodes').value;
      if (usage.usedSize < jsHeapUsed) {
        jsHeapUsed = usage.usedSize;
        chromeNodes = nodes;
      }
    }
  } finally {
    await client.detach();
  }
  return { jsHeapUsed, chromeNodes };
}

let baseline = null;
try {
  if (options.heap) {
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
    const page = await context.newPage();
    await page.goto(origin + '/?scenario=empty&heap=1&arm=none&count=0&reps=2', { waitUntil: 'load', timeout: 30000 });
    await page.waitForFunction(() => document.documentElement.dataset.done === '1', null, { timeout: 30000 });
    baseline = await heapSnapshot(page);
    console.log('baseline heap', (baseline.jsHeapUsed / 1048576).toFixed(2), 'MiB', 'nodes', baseline.chromeNodes);
    await context.close();
  }
  for (let round = 0; round < options.rounds; round++) {
    const order = round % 2 === 0 ? arms : ['saba', 'vanilla'];
    for (const scenario of selected) {
      for (const arm of order) {
        const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
        const page = await context.newPage();
        const errors = [];
        page.on('pageerror', error => errors.push(String(error.stack || error)));
        const query = new URLSearchParams({
          scenario, arm, count: String(counts[scenario]), reps: String(options.reps),
          heap: options.heap ? '1' : '0',
        });
        try {
          await page.goto(origin + '/?' + query, { waitUntil: 'load', timeout: 30000 });
          await page.waitForFunction(() => document.documentElement.dataset.done === '1', null, { timeout: 300000 });
          const result = await page.evaluate(() => window.__complex);
          if (!result) throw new Error('Missing result');
          if (result.error) throw new Error(result.error);
          const heap = options.heap ? await heapSnapshot(page) : null;
          visits.push({ round, ...result, ...heap, pageErrors: errors });
          if (options.heap) {
            console.log(
              'round', round, scenario, arm,
              'heap', (heap.jsHeapUsed / 1048576).toFixed(2), 'MiB',
              'rows', result.rows, 'dom', result.domElements, 'comments', result.comments, 'texts', result.texts,
            );
          } else console.log(
            'round', round, scenario, arm,
            'mount', result.mountMs.toFixed(1),
            'sparse', result.sparseMs.toFixed(1),
            'dense', result.denseMs.toFixed(1),
            'reverse', result.reverseMs.toFixed(1),
          );
        } catch (error) {
          visits.push({ round, scenario, arm, count: counts[scenario], error: String(error.stack || error), pageErrors: errors });
          console.log('round', round, scenario, arm, 'FAIL', error.message);
        }
        await context.close();
      }
    }
  }
} finally {
  await browser.close();
  server.close();
}

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

const fields = options.heap
  ? ['jsHeapUsed', 'chromeNodes', 'rows', 'domElements', 'comments', 'texts']
  : ['evalMs', 'mountMs', 'sparseMs', 'denseMs', 'reverseMs'];
const scenarios = {};
for (const name of selected) {
  const byArm = {};
  for (const arm of arms) {
    const samples = visits.filter(visit => visit.scenario === name && visit.arm === arm && !visit.error);
    const code = bundles[name + '-' + arm];
    byArm[arm] = {
      bytes: code.length,
      sha256: createHash('sha256').update(code).digest('hex'),
      failures: visits.filter(visit => visit.scenario === name && visit.arm === arm && visit.error).length,
    };
    for (const field of fields) byArm[arm][field] = median(samples.map(visit => visit[field]));
  }
  const paired = {};
  for (const field of fields) {
    const ratios = [];
    for (let round = 0; round < options.rounds; round++) {
      const left = visits.find(visit => visit.scenario === name && visit.round === round && visit.arm === 'vanilla' && !visit.error);
      const right = visits.find(visit => visit.scenario === name && visit.round === round && visit.arm === 'saba' && !visit.error);
      if (left && right && left[field] > 0) ratios.push(right[field] / left[field]);
    }
    paired[field] = median(ratios);
  }
  const row = { count: counts[name], mode: compiled[name].mode, callsKeyed: compiled[name].callsKeyed, modules: compiled[name].modules, oneModule: compiled[name].oneModule, byArm, paired };
  if (options.heap && baseline) {
    for (const arm of arms) {
      const used = byArm[arm].jsHeapUsed;
      const rows = byArm[arm].rows;
      byArm[arm].retainedBytes = used == null ? null : used - baseline.jsHeapUsed;
      byArm[arm].retainedPerRow = used == null || !rows ? null : (used - baseline.jsHeapUsed) / rows;
    }
    const left = byArm.vanilla.retainedBytes;
    const right = byArm.saba.retainedBytes;
    const rows = byArm.vanilla.rows;
    row.extraBytes = left == null || right == null ? null : right - left;
    row.extraPerRow = row.extraBytes == null || !rows ? null : row.extraBytes / rows;
  }
  scenarios[name] = row;
}

const report = {
  created: new Date().toISOString(),
  machine: { cpu: cpus()[0]?.model, cores: availableParallelism(), memoryBytes: totalmem() },
  options: { ...options, counts },
  baseline,
  scenarios,
  visits,
};
writeFileSync(options.out, JSON.stringify(report, null, 2) + '\n');
rmSync(compileDir, { recursive: true, force: true });
if (sharedRoot) rmSync(sharedRoot, { recursive: true, force: true });
console.log('');
if (options.heap) {
  const mib = (value) => value == null ? 'fail' : (value / 1048576).toFixed(2);
  const bytes = (value) => value == null ? 'fail' : value.toFixed(0);
  console.log('scenario mode rows arm retainedMiB perRow comments texts extraMiB extraPerRow');
  for (const name of selected) {
    const scenario = scenarios[name];
    for (const arm of arms) {
      const row = scenario.byArm[arm];
      console.log(
        name, scenario.mode, row.rows, arm,
        mib(row.retainedBytes), bytes(row.retainedPerRow),
        row.comments, row.texts,
        arm === 'saba' ? mib(scenario.extraBytes) : '',
        arm === 'saba' ? bytes(scenario.extraPerRow) : '',
      );
    }
  }
} else {
  console.log('scenario count mode module arm bytes mount sparse dense reverse');
  for (const name of selected) {
    const scenario = scenarios[name];
    for (const arm of arms) {
      const row = scenario.byArm[arm];
      const cell = (value) => value == null ? 'fail' : value.toFixed(1);
      console.log(
        name, scenario.count, scenario.mode, scenario.oneModule, arm, row.bytes,
        cell(row.mountMs), cell(row.sparseMs), cell(row.denseMs), cell(row.reverseMs),
      );
    }
    const ratio = (value) => value == null ? 'n/a' : value.toFixed(3);
    console.log(name, 'paired saba/vanilla', fields.map(field => field + ' ' + ratio(scenario.paired[field])).join(' '));
  }
}
if (visits.some(visit => visit.error)) process.exit(1);
