'use strict';

// From the repository root, after building the production scale bundles:
// node benchmarks/frameworks/experiments/cell-heap.cjs <empty snapshot directory> [comma-separated modes]
// The directory receives one pair of snapshots per mode, raw counters and renderer-cell-heap.json.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {execFileSync} = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const {chromium} = require(process.env.PLAYWRIGHT_PATH || 'playwright');

const count = 20_480;
const defaultModes = ['saba-planned', 'saba-text-slot', 'saba-text-slot-attr', 'saba-fixed-input', 'saba-fixed-input-attr', 'react'];
const bandExports = new Map([['saba-band-text', 'mountTextBand'], ['saba-band-dom', 'mountDomBand']]);
const modes = process.argv[3] ? process.argv[3].split(',') : defaultModes;
assert.ok(modes.every(mode => defaultModes.includes(mode) || bandExports.has(mode)) && new Set(modes).size === modes.length);
assert.ok(process.argv[2], 'Specify an empty directory for the heap snapshots.');
const out = path.resolve(process.argv[2]);
fs.mkdirSync(out, {recursive: true});
assert.equal(fs.readdirSync(out).length, 0, 'Use an empty snapshot directory.');
const fixtures = {
  '/': 'rich/scale.html',
  '/scale.js': 'rich/scale.js',
  '/reactivity.js': 'rich/reactivity.js',
  '/fixed-cell.js': 'experiments/fixed-cell.js',
  '/scale-react.js': 'dist/scale/react.js',
};

function replaceOnce(source, original, replacement) {
  assert.equal(source.split(original).length, 2, 'Scale fixture changed: ' + original);
  return source.replace(original, replacement);
}

function getAssets(mode) {
  const files = Object.fromEntries(Object.entries(fixtures).map(([url, file]) =>
    [url, fs.readFileSync(path.join('benchmarks/frameworks', file), 'utf8')]));
  let scale = files['/scale.js'];
  if (bandExports.has(mode)) {
    const branch = "if (mode === 'saba-planned')";
    files['/text-band.js'] = fs.readFileSync(path.join(__dirname, 'text-band.js'), 'utf8');
    scale = replaceOnce(scale, branch, `if (mode === '${mode}') {
  ({${bandExports.get(mode)}: mountBand} = await import('./text-band.js'));
} else ` + branch);
  }
  if (mode.startsWith('saba-text-slot')) {
    scale = replaceOnce(scale, "if (mode === 'saba-planned')", "if (mode === '" + mode + "')");
    scale = replaceOnce(scale, "node.append(document.createComment('value'),label,document.createComment('/value'));", 'node.append(label);');
    if (mode.endsWith('-attr')) {
      scale = replaceOnce(scale, '\n    node.dataset.id = String(record.id);', "\n    node.setAttribute('data-id', String(record.id));");
    }
  }
  if (mode.startsWith('saba-fixed-input')) {
    const branch = "if (mode === 'saba-planned')";
    scale = replaceOnce(scale, branch, "if (mode === '" + mode + "') {\n  ({mountCell} = await import('./fixed-cell.js'));\n} else " + branch);
    if (mode.endsWith('-attr')) {
      files['/fixed-cell.js'] = replaceOnce(files['/fixed-cell.js'], 'this.node.dataset.id = String(record.id);', "this.node.setAttribute('data-id', String(record.id));");
    }
  }
  files['/scale.js'] = scale;
  return files;
}

async function snapshot(cdp, file) {
  await cdp.send('HeapProfiler.collectGarbage');
  const heap = await cdp.send('Runtime.getHeapUsage');
  const dom = await cdp.send('Memory.getDOMCounters');
  const fd = fs.openSync(file, 'wx');
  const receive = ({chunk}) => fs.writeFileSync(fd, chunk);
  cdp.on('HeapProfiler.addHeapSnapshotChunk', receive);
  try {
    await cdp.send('HeapProfiler.takeHeapSnapshot', {reportProgress: false});
  } finally {
    cdp.off('HeapProfiler.addHeapSnapshotChunk', receive);
    fs.closeSync(fd);
  }
  return {heap, dom};
}

async function visit(mode, metrics) {
  const files = getAssets(mode);
  const server = http.createServer((request, response) => {
    const url = request.url.split('?')[0];
    if (!Object.hasOwn(files, url)) return response.writeHead(404).end();
    response.writeHead(200, {'Content-Type': url === '/' ? 'text/html; charset=utf-8' : 'text/javascript; charset=utf-8'});
    response.end(files[url]);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  try {
    const browser = await chromium.launch({channel: 'chromium'});
    try {
      const page = await browser.newPage({viewport: {width: 1200, height: 900}});
      await page.goto('http://127.0.0.1:' + server.address().port + '/?scenario=capacity&mode=' + mode + '&count=' + count);
      await page.waitForFunction(() => window.scale);
      const cdp = await page.context().newCDPSession(page);
      await cdp.send('HeapProfiler.enable');
      const start = await page.evaluate(() => window.scale.start());
      assert.equal(start.records, count);
      const base = await snapshot(cdp, path.join(out, mode + '-base.heapsnapshot'));
      let mounted = 0;
      while (mounted < count) mounted = await page.evaluate(() => window.scale.step());
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      const cells = await page.evaluate(() => document.querySelectorAll('.cell').length);
      assert.equal(cells, count);
      const full = await snapshot(cdp, path.join(out, mode + '-mount.heapsnapshot'));
      const hashes = Object.fromEntries(Object.entries(files).map(([url, source]) =>
        [url, crypto.createHash('sha256').update(source).digest('hex')]));
      metrics.browser = browser.version();
      metrics.visits.push({mode, cells, base, full, sourceHashes: hashes});
      fs.writeFileSync(path.join(out, 'metrics.json'), JSON.stringify(metrics, null, 2) + '\n');
      console.log(mode + ' complete, ' + cells + ' mounted cells');
    } finally {
      await browser.close();
    }
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
}

async function main() {
  const metrics = {count, cpu: os.cpus()[0].model, visits: []};
  if (modes.some(mode => bandExports.has(mode))) {
    metrics.reproduce = 'node benchmarks/frameworks/experiments/cell-heap.cjs <empty-directory> ' + modes.join(',');
  }
  for (const mode of modes) await visit(mode, metrics);
  execFileSync(process.execPath, [
    path.join(__dirname, 'summarize-cell-heap.cjs'), path.join(out, 'renderer-cell-heap.json'), out,
  ], {stdio: 'inherit'});
}

main().catch(error => { console.error(error); process.exitCode = 1; });
