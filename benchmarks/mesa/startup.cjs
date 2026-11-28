'use strict';

// Focused cold-navigation diagnostic. Run against the standalone Mesa benchmark
// server from the checkout root: node benchmarks/mesa/startup.cjs ORIGIN OUTPUT.json
// With a third argument, compare the planned screen on ORIGIN and PRELOAD_ORIGIN.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const { createHash } = require('node:crypto');
const { chromium } = require(process.env.PLAYWRIGHT_PATH || 'playwright');

const assetPaths = { css: '/style.css', sharedApp: '/app.js', runtime: '/__saba/dom.js',
  detail: '/api/items/42', all: '/api/lists/all', open: '/api/lists/open', marked: '/api/lists/marked' };

async function navigate(browser, origin, profile, mode) {
  const reset = await fetch(origin + '/__bench/reset', {method: 'POST', signal: AbortSignal.timeout(6000)});
  assert.equal(reset.status, 200);
  await reset.text();
  const context = await browser.newContext({viewport: {width: 1200, height: 900}, serviceWorkers: 'block'});
  try {
    const page = await context.newPage();
    page.setDefaultTimeout(12000);
    const requests = [];
    page.on('request', req => requests.push(new URL(req.url()).pathname));
    const session = await context.newCDPSession(page);
    await session.send('Network.enable');
    await session.send('Network.setCacheDisabled', {cacheDisabled: true});
    await session.send('Emulation.setCPUThrottlingRate', {rate: profile.cpuRate});
    await session.send('Network.emulateNetworkConditions', {offline: false, latency: profile.latencyMs,
      downloadThroughput: profile.downMbps * 1e6 / 8, uploadThroughput: profile.upMbps * 1e6 / 8});
    await page.goto(origin + '/?mode=' + mode, {waitUntil: 'commit'});
    await page.waitForFunction(() => document.documentElement.dataset.failure ||
      (performance.getEntriesByName('mesa-editable').length && performance.getEntriesByName('mesa-lists-ready').length));
    const {error, timings, initiators, editable, listsReady, enabled, count} = await page.evaluate(paths => {
      // Times share the document's performance.timeOrigin, sizes are bytes.
      const row = e => [e.startTime, e.requestStart, e.responseStart, e.responseEnd, e.encodedBodySize, e.transferSize];
      const entries = performance.getEntriesByType('resource');
      const timings = {document: row(performance.getEntriesByType('navigation')[0])};
      const initiators = {};
      for (const [name, path] of Object.entries(paths)) {
        const hits = entries.filter(e => new URL(e.name).pathname === path);
        if (hits.length !== 1) throw Error('Expected one resource timing for ' + path);
        timings[name] = row(hits[0]);
        initiators[name] = hits[0].initiatorType;
      }
      return {error: document.documentElement.dataset.failure, timings, initiators, enabled: !document.querySelector('#title').disabled,
        count: document.querySelectorAll('#list-all li').length,
        editable: performance.getEntriesByName('mesa-editable')[0].startTime,
        listsReady: performance.getEntriesByName('mesa-lists-ready')[0].startTime};
    }, {...assetPaths, entry: mode === 'current' ? '/entry.js' : '/planned.js'});
    assert.ok(!error && enabled && count === 1000);
    const expected = ['/', ...Object.values(assetPaths), mode === 'current' ? '/entry.js' : '/planned.js'];
    assert.deepEqual(requests.filter(path => expected.includes(path)).sort(), expected.sort(),
      'Expected exactly one real browser request per document, module, stylesheet and API read');
    const assetsEnd = Math.max(...['entry','css','sharedApp','runtime'].map(k => timings[k][3]));
    const stages = {
      document: timings.document[3],
      documentToLastAsset: assetsEnd - timings.document[3],
      lastAssetToDetailStart: timings.detail[0] - assetsEnd,
      detailFetch: timings.detail[3] - timings.detail[0],
      detailEndToEditable: editable - timings.detail[3],
    };
    return {mode, timings, initiators, stages, editable, listsReady};
  } finally { await context.close(); }
}

function median(data) {
  const xs = [...data].sort((a,b) => a-b);
  const mid = Math.floor(xs.length/2);
  return xs.length % 2 ? xs[mid] : (xs[mid-1] + xs[mid]) / 2;
}

async function main() {
  const [origin, output, preloadOrigin] = process.argv.slice(2);
  if (preloadOrigin) assert.match(preloadOrigin, /^http:\/\/127\.0\.0\.1:\d+$/);
  assert.match(origin, /^http:\/\/127\.0\.0\.1:\d+$/);
  assert.ok(output, 'Supply an output JSON path');
  const benchmarkBytes = await fs.readFile('docs/benchmarks/saba-mesa.json');
  const reference = JSON.parse(benchmarkBytes).metadata;
  const profile = reference.profiles.constrained;
  const browser = await chromium.launch({channel: 'chromium'});
  const pidFile = process.env.SABA_MESA_PERF_BROWSER_PID_FILE;
  try {
    if (pidFile) {
      const cdp = await browser.newBrowserCDPSession();
      const {processInfo} = await cdp.send('SystemInfo.getProcessInfo');
      const pid = processInfo.find(p => p.type === 'browser')?.id;
      assert.ok(Number.isInteger(pid) && pid > 1);
      await fs.writeFile(pidFile, String(pid));
      await cdp.detach();
    }
    const trials = [];
    const modes = preloadOrigin ? ['control', 'preload'] : ['current', 'planned'];
    const verifiedBodySha256 = {};
    if (preloadOrigin) {
      const paths = [...Object.values(assetPaths), '/planned.js'];
      for (const path of paths) {
        const hashes = await Promise.all([origin,preloadOrigin].map(async base => {
          const response = await fetch(base + path);
          assert.equal(response.status, 200);
          return createHash('sha256').update(Buffer.from(await response.arrayBuffer())).digest('hex');
        }));
        assert.equal(hashes[0], hashes[1], 'Content differs for ' + path);
        verifiedBodySha256[path] = hashes[0];
      }
      const [plain, early] = await Promise.all([origin,preloadOrigin].map(async base =>
        (await fetch(base + '/?mode=planned')).text()));
      const links = '<link rel="modulepreload" href="/app.js"><link rel="modulepreload" href="/__saba/dom.js">';
      assert.ok(early.includes(links) && !plain.includes(links));
      assert.equal(early.replace(links, ''), plain);
    }
    for (let i = -1; i < 12; i++) {
      const order = i % 2 === 0 ? modes : [...modes].reverse();
      for (const mode of order) {
        const result = await navigate(browser, mode === 'preload' ? preloadOrigin : origin, profile,
          preloadOrigin ? 'planned' : mode);
        if (preloadOrigin) {
          for (const name of ['sharedApp','runtime']) {
            assert.ok(result.timings[name][5] > 0, 'Missing cold transfer for ' + name);
          }
        }
        if (i >= 0) trials.push({pair: i + 1, ...result, mode});
      }
    }
    const summary = {};
    for (const metric of ['editable', 'listsReady', ...Object.keys(trials[0].stages)]) {
      const values = Object.fromEntries(modes.map(mode =>
        [mode, trials.filter(s => s.mode === mode).map(s => s.stages[metric] ?? s[metric])]));
      const [control, candidate] = modes;
      const diffs = values[candidate].map((v,i) => v-values[control][i]);
      summary[metric] = {[control+'Median']: median(values[control]), [candidate+'Median']: median(values[candidate]),
        pairedMedianDelta: median(diffs), positivePairs: diffs.filter(d => d > 0).length};
    }
    const metadata = {generatedAt: new Date().toISOString(), cpu: os.cpus()[0]?.model, browser: browser.version(), profile,
      modes, verifiedBodySha256,
      referenceSha256: createHash('sha256').update(benchmarkBytes).digest('hex'),
      pairs: 12, warmupPairs: 1, freshContextAndDisabledCache: true, alternatingOrder: true,
      timingColumns: ['startMs', 'requestMs', 'firstByteMs', 'responseEndMs', 'encodedBodyBytes', 'transferBytes'],
      units: 'milliseconds from navigation start; stage lengths and paired second minus first mode deltas in milliseconds'};
    const tmp = output + '.' + process.pid + '.tmp';
    try {
      await fs.writeFile(tmp, JSON.stringify({metadata, summary, trials}, null, 2) + '\n', {flag: 'wx'});
      await fs.rename(tmp, output);
    } finally { await fs.rm(tmp, {force:true}); }
    console.log(JSON.stringify(summary, null, 2));
  } finally {
    await browser.close();
    if (pidFile) await fs.rm(pidFile, {force:true});
  }
}
main().catch(error => {console.error(error); process.exitCode = 1;});
