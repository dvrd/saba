'use strict';

// MESA_CHECKOUT=/path/to/bot-mesa node benchmarks/mesa/mesa-sheet.cjs --out result.json
// PLAYWRIGHT_PATH can name an existing local Playwright installation.
// --profile constrained uses the same CPU and network settings as measure.cjs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const { parseArgs } = require('node:util');

const rowCount = 1000;
const pageSize = 200;
const typed = 'quicktype';
const catalog = '/api/sheets';
const list = '/api/sheets/bench/items';
const save = '/api/sandbox/sheets/edit';
const getList = 'GET ' + list;
const postSave = 'POST ' + save;
const firstCell = 'tbody tr[data-row-id="1"] td';
const header = ['Title', 'Site', 'Value', 'Status'];
const viewport = { width: 1200, height: 850 };
const profiles = {
  desktop: { latencyMs: 0, cpuRate: 1, downMbps: null, upMbps: null },
  constrained: { latencyMs: 60, cpuRate: 4, downMbps: 10, upMbps: 2 },
};

function freshRows() {
  return Array.from({ length: rowCount }, (_, i) => ({
    id: i + 1, ordinal: i + 1, version: 1, display_row: i + 2,
    cells: [
      { kind: 'text', text: 'Item ' + (i + 1) }, { kind: 'text', text: 'Factory' },
      { kind: 'number', value: i * 100 }, { kind: 'text', text: 'Open' },
    ],
  }));
}

function makeServer(state, assets) {
  const html = '<!doctype html><html lang="es"><meta charset="utf-8"><title>Sheet fixture</title><link rel="stylesheet" href="/sheets.css"><main id="grid"></main><script type="module" src="/open.js"></script></html>';
  const entry = 'import {mountSheets} from "/sheets.js";mountSheets(document.querySelector("main"),{edit:{userId:()=>1}})';
  const files = new Map([
    ['/', ['text/html', html]], ['/open.js', ['text/javascript', entry]],
    ['/sheets.js', ['text/javascript', assets.js]], ['/sheets.css', ['text/css', assets.css]],
  ]);

  return http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    res.setHeader('Cache-Control', 'no-store');
    function json(value) {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify(value));
    }
    try {
      if (url.pathname.startsWith('/api/')) state.requests.push(req.method + ' ' + url.pathname);
      const file = files.get(url.pathname);
      if (req.method === 'GET' && file) {
        res.setHeader('Content-Type', file[0]);
        return res.end(file[1]);
      }
      if (req.method === 'GET' && url.pathname === catalog) {
        return json({ books: [{ key: 'bench', tabs: [{ name: 'items', position: 0, row_count: rowCount }] }] });
      }
      if (req.method === 'GET' && url.pathname === list) {
        const after = Number(url.searchParams.get('after'));
        assert.equal(Number(url.searchParams.get('limit')), pageSize);
        return json({
          headers: header, rows: state.rows.slice(after, after + pageSize),
          next_after: after + pageSize < rowCount ? after + pageSize : 0,
        });
      }
      if (req.method === 'POST' && url.pathname === save) {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const record = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        const row = state.rows[record.row_id - 1];
        assert.equal(record.expected_version, row.version);
        assert.equal(record.column, 0);
        // This server-only prefix distinguishes authoritative refresh from Mesa's optimistic text.
        row.cells[0] = { kind: 'text', text: 'Saved ' + record.cells[0].text };
        row.version++;
        return json({ event_id: ++state.event });
      }
      res.writeHead(404).end();
    } catch (error) {
      state.failure = error;
      res.writeHead(500).end();
    }
  });
}

// Installed before navigation. All three start clocks are the document's monotonic performance clock.
function instrumentPage() {
  const track = window.__sheetPerf = { ready: 0, keys: [], submit: 0, confirmed: 0 };
  addEventListener('keydown', event => {
    if (!event.isTrusted || !event.target.classList.contains('sheets-input')) return;
    if (event.key === 'Enter' || event.key === 'Tab') track.submit = event.timeStamp;
    else if (/^[a-z]$/.test(event.key)) track.keys.push({ key: event.key, ts: event.timeStamp });
  }, true);
  new MutationObserver(() => {
    const cell = document.querySelector('tbody tr[data-row-id="1"] td');
    if (!cell) return;
    const status = document.querySelector('.sheets-status').textContent;
    if (!track.ready && status.includes('doble clic para editar') && cell.tabIndex === -1) {
      track.ready = performance.now();
    }
    if (track.submit && !track.confirmed && cell.textContent.startsWith('Saved ') &&
        status.includes('guardada') && !cell.querySelector('input')) {
      track.confirmed = performance.now();
    }
  }).observe(document, { subtree: true, childList: true, characterData: true });
}

async function runTrial(browser, state, url, run, profile) {
  state.rows = freshRows();
  state.requests = [];
  const ctx = await browser.newContext({ viewport, serviceWorkers: 'block' });
  try {
    const page = await ctx.newPage();
    const cdp = await ctx.newCDPSession(page);
    if (profile === 'constrained') {
      const config = profiles[profile];
      await cdp.send('Network.enable');
      await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
      await cdp.send('Emulation.setCPUThrottlingRate', { rate: config.cpuRate });
      await cdp.send('Network.emulateNetworkConditions', {
        offline: false, latency: config.latencyMs,
        downloadThroughput: config.downMbps * 1e6 / 8, uploadThroughput: config.upMbps * 1e6 / 8,
      });
    }
    await page.addInitScript(instrumentPage);
    await page.goto(url);
    await page.waitForFunction(() => window.__sheetPerf.ready > 0);
    const frame = (await cdp.send('Page.getFrameTree')).frameTree.frame.id;
    assert.equal(await page.locator('tr[data-row-id]').count(), pageSize);
    assert.deepEqual(state.requests, ['GET ' + catalog, getList]);
    for (let count = 2 * pageSize; count <= rowCount; count += pageSize) {
      await page.locator('.sheets-more').click();
      await page.waitForFunction(n => document.querySelector('.sheets-status').textContent.startsWith(n + ' de 1000 filas'), count);
    }
    assert.equal(await page.locator('tr[data-row-id]').count(), pageSize);
    const readCount = state.requests.length;
    assert.equal(readCount, 1 + rowCount / pageSize);
    const cell = page.locator(firstCell).first();
    await cell.dblclick();
    const input = page.locator('.sheets-input');
    assert.ok(await input.evaluate(el => document.activeElement === el));

    for (const [index, key] of Array.from(typed).entries()) {
      await page.keyboard.press(key);
      // Deterministic 64–100 ms inter-key jitter varies the phase within the display refresh cycle.
      await page.waitForTimeout(64 + ((7 * run + 11 * index + 29) % 37 + 37) % 37);
    }
    assert.equal(await input.inputValue(), typed);

    if (run === -1) {
      // Record Enter's observed outcome once. A fixed Mesa checkout can produce a fresh result here.
      await page.keyboard.press('Enter');
      await page.waitForFunction(() => document.querySelector('.sheets-status').textContent.includes('guardada'));
      const witness = await page.evaluate(() => {
        const cell = document.querySelector('tbody td');
        const input = cell.querySelector('input');
        return {
          status: document.querySelector('.sheets-status').textContent,
          display: cell.textContent, input: input?.value, focused: Boolean(input && input === document.activeElement),
        };
      });
      assert.equal(state.rows[0].cells[0].text, 'Saved ' + typed);
      return { witness, serverTitle: state.rows[0].cells[0].text, saveRequests: state.requests.slice(readCount) };
    }

    await page.keyboard.press('Tab');
    await page.waitForFunction(() => window.__sheetPerf.confirmed > 0, undefined, { timeout: 4000 });
    assert.equal(await cell.textContent(), 'Saved ' + typed);
    assert.match(await page.locator('.sheets-status').textContent(), /200 de 1000 filas/);
    const saveRequests = state.requests.slice(readCount);
    assert.deepEqual(saveRequests, [postSave, getList]);
    const track = await page.evaluate(() => window.__sheetPerf);
    assert.equal(track.keys.length, typed.length);
    await page.waitForTimeout(65);
    return { run, frame, editableMs: track.ready, saveFreshMs: track.confirmed - track.submit, readCount, saveRequests, keys: track.keys };
  } finally {
    await ctx.close();
  }
}

function attachPresentation(samples, trace) {
  for (const sample of samples) {
    const frameEvents = trace.filter(event => event.frame === sample.frame);
    const used = new Set();
    for (const key of sample.keys) {
      const matches = frameEvents.filter(event => Math.abs(event.timeStamp - key.ts) < 1 && !used.has(event.interactionId));
      assert.equal(matches.length, 1, 'Expected one keyboard presentation for ' + JSON.stringify(key));
      const event = matches[0];
      assert.ok(event.commitFinishTime > 0);
      used.add(event.interactionId);
      Object.assign(key, {
        presentedMs: event.duration, traceTimeStamp: event.timeStamp,
        commitFinish: event.commitFinishTime, interaction: event.interactionId,
      });
    }
  }
}

function stats(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const percentile = p => Number(sorted[Math.ceil(p * sorted.length) - 1].toFixed(3));
  return { n: sorted.length, p50: percentile(.5), p95: percentile(.95), min: percentile(1 / sorted.length), max: percentile(1) };
}

async function main() {
  const { values } = parseArgs({ options: {
    out: { type: 'string' }, trials: { type: 'string', default: '20' },
    profile: { type: 'string', default: 'desktop' },
  } });
  assert.ok(process.env.MESA_CHECKOUT, 'Set MESA_CHECKOUT to a local bot-mesa checkout');
  assert.ok(values.out, 'Pass --out result.json');
  assert.ok(Object.hasOwn(profiles, values.profile), 'Use --profile desktop or constrained');
  const trials = Number(values.trials);
  assert.ok(Number.isInteger(trials) && trials > 0 && trials <= 100, 'Use 1–100 trials');
  const mesa = path.resolve(process.env.MESA_CHECKOUT);
  const assets = {
    js: fs.readFileSync(path.join(mesa, 'web/sheets.js')),
    css: fs.readFileSync(path.join(mesa, 'web/sheets.css')),
  };
  const sha = data => createHash('sha256').update(data).digest('hex');
  const { chromium } = require(process.env.PLAYWRIGHT_PATH || 'playwright');
  const state = { rows: [], requests: [], event: 0, failure: null };
  const srv = makeServer(state, assets);
  await new Promise((resolve, reject) => { srv.once('error', reject); srv.listen(0, '127.0.0.1', resolve); });
  const url = 'http://127.0.0.1:' + srv.address().port + '/';
  let browser;
  try {
    browser = await chromium.launch({ channel: 'chromium' });
    const cdp = await browser.newBrowserCDPSession();
    const trace = [];
    cdp.on('Tracing.dataCollected', ({ value }) => {
      for (const event of value) {
        const data = event.args?.data;
        if (event.name === 'EventTiming' && event.ph === 'b' && data?.type === 'keydown' &&
            data.duration > 0 && data.interactionId > 0) trace.push(data);
      }
    });
    await cdp.send('Tracing.start', { categories: 'devtools.timeline', transferMode: 'ReportEvents' });
    const enter = await runTrial(browser, state, url, -1, values.profile);
    const samples = [];
    for (let run = 0; run < trials; run++) samples.push(await runTrial(browser, state, url, run, values.profile));
    const finished = new Promise(resolve => cdp.once('Tracing.tracingComplete', resolve));
    await cdp.send('Tracing.end');
    await finished;
    if (state.failure) throw state.failure;
    attachPresentation(samples, trace);
    const result = {
      browser: browser.version(), os: os.version(), arch: os.arch(), cpus: os.cpus()[0].model,
      commit: execFileSync('git', ['-C', mesa, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
      sha256: { sheetsJS: sha(assets.js), sheetsCSS: sha(assets.css) },
      conditions: {
        profile: values.profile, viewport, throttling: profiles[values.profile],
        source: 'Unmodified Mesa grid and stylesheet in a minimal shell; synthetic, in-memory loopback HTTP with a preselected editing user. Four columns. Five pages loaded and one visible sheet with 200 mounted rows. Successful save resets the snapshot to the first 200 rows.',
        warmups: 1, freshBrowserContexts: trials,
        definitions: 'Editable = navigation start to the MutationObserver callback seeing the first authorized editable cell and status, before interaction or paint. Keys = traced trusted keydown EventTiming to Chromium presentation. Save fresh = trusted Tab timestamp to DOM delivery of authoritative cell and saved status after POST and GET, before the next paint.',
      },
      summary: {
        editableMs: stats(samples.map(s => s.editableMs)),
        keydownToPresentationMs: stats(samples.flatMap(s => s.keys.map(key => key.presentedMs))),
        saveFreshMs: stats(samples.map(s => s.saveFreshMs)),
        saveRequests: [...new Set(samples.map(s => s.saveRequests.length))],
      },
      enter, samples,
    };
    fs.writeFileSync(values.out, JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result.summary));
  } finally {
    try { if (browser) await browser.close(); } finally { await new Promise(resolve => srv.close(resolve)); }
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
