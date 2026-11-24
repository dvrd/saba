'use strict';

// Browser-side benchmark driver. The Odin entry point owns the fixture, store and process lifetime.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { chromium } = require(process.env.PLAYWRIGHT_PATH || 'playwright');

const profiles = {
  desktop: { latencyMs: 0, cpuRate: 1, downMbps: null, upMbps: null },
  constrained: { latencyMs: 60, cpuRate: 4, downMbps: 10, upMbps: 2 },
};
const expectedReads = ['/api/items/42', '/api/lists/all', '/api/lists/marked', '/api/lists/open'];
const keys = 'abcdefghij';
const sabaModes = ['current', 'planned'];
const generatedModes = ['planned','generated'];
const windowedModes = ['generated','windowed'];
const frameworkModes = ['saba-current','saba-planned','vanilla','solid','react','svelte','htmx'];

function readOptions(args) {
  const options = { suite:'saba', profiles:Object.keys(profiles) };
  for (let i = 0; i < args.length; i += 2) {
    const value = args[i + 1];
    if (value === undefined) throw Error('Missing value for ' + args[i]);
    switch (args[i]) {
      case '--suite': options.suite = value; break;
      case '--trials': options.trials = Number(value); break;
      case '--profiles': options.profiles = value.split(','); break;
      case '--out': options.out = value; break;
      default: throw Error('Unknown benchmark option ' + args[i]);
    }
  }
  const suites = {saba:sabaModes, generated:generatedModes, windowed:windowedModes, frameworks:frameworkModes};
  assert.ok(Object.hasOwn(suites, options.suite), 'Unknown benchmark suite');
  options.modes = suites[options.suite];
  options.trials ??= options.suite === 'frameworks' ? 28 : 30;
  options.out ??= {saba:'mesa-performance.json',generated:'generated-performance.json',
    windowed:'windowed-performance.json',frameworks:'framework-performance.json'}[options.suite];
  assert.ok(Number.isInteger(options.trials) && options.trials >= 1 && options.trials <= 100,
    'Use 1–100 trials per mode and profile');
  assert.ok(options.profiles.every(name => Object.hasOwn(profiles, name)), 'Unknown profile');
  assert.equal(new Set(options.profiles).size, options.profiles.length, 'Duplicate profile');
  return options;
}

// For seven implementations every one occupies each position twice in fourteen
// rounds. Reversing the second block also balances which entry precedes another.
function roundOrder(modes, round) {
  if (modes.length === 2) return round % 2 === 0 ? modes : [...modes].reverse();
  const positions = [0,1,6,2,5,3,4];
  const normalized = Math.max(0,round);
  const shifted = positions.map(i => modes[(i + normalized) % modes.length]);
  return Math.floor(normalized / modes.length) % 2 === 0 ? shifted : shifted.reverse();
}

function installObservers() {
  window.benchPaints = {};
  new PerformanceObserver(list => {
    for (const entry of list.getEntries()) {
      if (entry.identifier === 'mesa-ready' || entry.identifier === 'mesa-saved') {
        window.benchPaints[entry.identifier] = entry.renderTime;
      }
    }
  }).observe({ type: 'element', buffered: true });
  window.benchKeys = [];
  document.addEventListener('keydown', event => {
    if (event.isTrusted && event.target.id === 'title' && /^[a-j]$/.test(event.key)) {
      window.benchKeys.push({ key: event.key, timestamp: event.timeStamp });
    }
  }, true);
}

async function frames(page, n) {
  await page.evaluate(count => new Promise(resolve => {
    function frame() { if (--count > 0) requestAnimationFrame(frame); else resolve(); }
    requestAnimationFrame(frame);
  }), n);
}

async function measureTyping(page, session, title) {
  const events = [];
  const collect = message => events.push(...message.value);
  session.on('Tracing.dataCollected', collect);
  await session.send('Tracing.start', { categories: 'devtools.timeline', transferMode: 'ReportEvents' });
  try {
    let value = title;
    for (const key of keys) {
      await page.keyboard.press(key);
      value += key;
      // Pace independent interactions so adjacent keys do not share a frame.
      await frames(page, 3);
      assert.equal(await page.locator('#preview').textContent(), value);
    }
    await frames(page, 3);
  } finally {
    const complete = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Error('Chromium tracing did not complete')), 8000);
      session.once('Tracing.tracingComplete', () => { clearTimeout(timer); resolve(); });
    });
    await session.send('Tracing.end');
    await complete;
    session.off('Tracing.dataCollected', collect);
  }
  const observed = await page.evaluate(() => window.benchKeys);
  assert.equal(observed.map(event => event.key).join(''), keys);
  const entries = events.filter(e => e.name === 'EventTiming' && e.ph === 'b')
    .map(e => e.args.data).filter(e => e.type === 'keydown' && e.interactionId > 0);
  assert.equal(entries.length, keys.length, 'Missing trusted key presentation records');
  return observed.map((key, i) => {
    const event = entries[i];
    assert.ok(Math.abs(key.timestamp - event.timeStamp) < 1,
      'Browser input does not match tracing timestamp');
    assert.ok(event.duration > 0 && event.commitFinishTime > 0, 'Key missing a rendered frame');
    return event.duration;
  });
}

function quantile(values, q) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.ceil(sorted.length * q) - 1];
}

function summarize(trials, modes) {
  const result = {};
  for (const profile of new Set(trials.map(t => t.profile))) {
    result[profile] = {};
    for (const mode of modes) {
      const group = trials.filter(t => t.profile === profile && t.mode === mode);
      result[profile][mode] = { trials: group.length };
      const metrics = ['editableMs','readyPaintMs','listsReadyMs','keyMs','ackMs','freshMs','freshPaintMs',
        'lastResponseMs','responseBodyBytes','saveRequests','initialBodyBytes','jsBodyBytes'];
      if (group[0].initialMountedRows !== undefined) {
        metrics.push('initialMountedRows','savedMountedRows','maxSampledMountedRows','initialApiBytes');
      }
      for (const metric of metrics) {
        const values = group.flatMap(t => t[metric]);
        result[profile][mode][metric] = {
          n: values.length, p50: quantile(values,.5), p95: quantile(values,.95),
        };
      }
    }
  }
  return result;
}

// SQLite sorts item 42 first, then by numeric ID. The saved title adds it to
// the marked collection. The same expectations cover server data and DOM rows.
function expectedViews(savedTitle) {
  const all = [42, ...Array.from({length:1000}, (_,i) => i+1).filter(id => id !== 42)];
  return {all, open:all.filter(id => id % 2 === 0), marked:savedTitle ? [42] : []};
}

// Runs in the page after the readiness/paint clocks have finished. In the
// windowed arm, validate every mounted row against its logical index and
// check that the mounted range covers the actual scroll position.
function checkLists({windowed, savedTitle, expected}) {
  let total = 0;
  for (const [view, ids] of Object.entries(expected)) {
    const list = document.getElementById('list-' + view);
    const rows = list.querySelectorAll('li');
    const ensure = (ok, reason) => { if (!ok) throw Error(view + ': ' + reason); };
    total += rows.length;
    let first = 0;
    if (windowed) {
      const viewport = document.getElementById('viewport-' + view);
      ensure(viewport && viewport.contains(list), 'missing scroll viewport');
      ensure(list.offsetHeight === ids.length * 33, 'scroll extent does not cover the logical list');
      if (!ids.length) {
        ensure(rows.length === 0, 'empty logical list contains rows');
        continue;
      }
      ensure(rows.length > 0, 'no visible rows');
      const rowHeight = rows[0].getBoundingClientRect().height;
      ensure(rowHeight === 33 && viewport.clientHeight > 0, 'invalid viewport geometry');
      const visibleFirst = Math.floor(viewport.scrollTop / rowHeight);
      const visibleEnd = Math.ceil((viewport.scrollTop + viewport.clientHeight) / rowHeight);
      first = Number(rows[0].getAttribute('aria-posinset')) - 1;
      ensure(first >= 0 && first <= visibleFirst && first + rows.length >= Math.min(visibleEnd,ids.length),
        'mounted range does not cover the visible rows');
      ensure(rows.length <= Math.ceil(viewport.clientHeight / rowHeight) + 1 + 2 * 8,
        'mounted row count exceeded the viewport and both overscan bands');
      const top = viewport.getBoundingClientRect().top;
      ensure(Math.abs(rows[0].getBoundingClientRect().top - (top + first * rowHeight - viewport.scrollTop)) < 1,
        'mounted band is positioned at the wrong screen coordinate');
    } else {
      ensure(rows.length === ids.length, 'unexpected full-list length');
    }
    for (const [i,row] of rows.entries()) {
      const index = first + i, id = ids[index];
      if (windowed) {
        ensure(Number(row.getAttribute('aria-posinset')) === index + 1 &&
          Number(row.getAttribute('aria-setsize')) === ids.length, 'incorrect accessible logical position or count');
      }
      ensure(row.dataset.id === String(id), 'wrong record at position ' + (index+1));
      ensure(row.textContent === (id === 42 && savedTitle ? savedTitle : 'Item ' + id),
        'wrong title for record ' + id);
    }
  }
  return total;
}

// Inspect already-completed network responses. This verifies offscreen data
// without issuing another request or walking the viewports during timing.
async function checkApiPayloads(replies, savedTitle) {
  function record(id, edited) {
    return {id:String(id), title:edited && id === 42 ? savedTitle : 'Item ' + id,
      revision:edited && id === 42 ? 2 : 1};
  }
  for (const path of expectedReads) {
    const exchanges = replies.filter(r => new URL(r.url()).pathname === path);
    if (path === '/api/items/42') {
      assert.deepEqual(exchanges.map(r=>r.request().method()), ['GET','PATCH','GET']);
      for (const [i,response] of exchanges.entries()) {
        assert.equal(response.status(),200);
        assert.deepEqual(await response.json(),record(42,i > 0));
      }
    } else {
      assert.equal(exchanges.length,2);
      for (const [i,response] of exchanges.entries()) {
        assert.equal(response.status(),200);
        const ids = expectedViews(i ? savedTitle : null)[path.split('/').pop()];
        assert.deepEqual(await response.json(),ids.map(id=>record(id,i > 0)));
      }
    }
  }
}

async function checkScroll(page, savedTitle, peak) {
  const expected = expectedViews(savedTitle);
  for (const fraction of [0.5, 1, 0]) {
    await page.evaluate(fraction => {
      for (const view of ['all','open']) {
        const viewport = document.getElementById('viewport-' + view);
        const end = viewport.scrollHeight - viewport.clientHeight;
        if (end <= 0) throw Error(view + ' cannot scroll');
        viewport.scrollTop = Math.round(fraction * end);
      }
    },fraction);
    await frames(page,2);
    const mounted = await page.evaluate(checkLists,{windowed:true,savedTitle,expected});
    peak = Math.max(peak,mounted);
    for (const view of ['all','open']) {
      const viewport = page.locator('#viewport-' + view);
      assert.ok(await viewport.evaluate((el,f) => Math.abs(el.scrollTop - f*(el.scrollHeight-el.clientHeight)) <= 1,
        fraction), view + ' did not reach the requested scroll position');
    }
  }
  return peak;
}

async function runTrial(browser, origin, profile, mode, checkWindowSuite) {
  const prefix = mode === 'htmx' ? '/fragments/' : '/api/';
  const reads = expectedReads.map(url => url.replace('/api/', prefix));
  const itemPath = reads[0];
  const reset = await fetch(origin + '/__bench/reset', {method: 'POST', signal: AbortSignal.timeout(6000)});
  assert.equal(reset.status, 200); await reset.text();
  const context = await browser.newContext({viewport:{width:1200,height:900},serviceWorkers:'block'});
  const page = await context.newPage();
  const errors = [];
  try {
    page.setDefaultTimeout(12000);
    page.on('pageerror', e => errors.push(e.message));
    const requests = [];
    const replies = [];
    if (checkWindowSuite) {
      page.on('response', response => {
        if (expectedReads.includes(new URL(response.url()).pathname)) replies.push(response);
      });
    }
    const offOrigin = [];
    page.on('request', req => {
      const url = new URL(req.url());
      if (url.protocol === 'http:' || url.protocol === 'https:') {
        if (url.origin !== origin) offOrigin.push(url.origin);
        if (url.pathname.startsWith(prefix)) requests.push({ method:req.method(), path:url.pathname });
      }
    });
    const session = await context.newCDPSession(page);
    const config = profiles[profile];
    await session.send('Network.enable');
    await session.send('Network.setCacheDisabled', { cacheDisabled:true });
    await session.send('Emulation.setCPUThrottlingRate', { rate:config.cpuRate });
    if (config.downMbps !== null) {
      await session.send('Network.emulateNetworkConditions', {
        offline:false,latency:config.latencyMs,
        downloadThroughput:config.downMbps * 1e6 / 8,uploadThroughput:config.upMbps * 1e6 / 8,
      });
    }
    await page.addInitScript(installObservers);
    const compiled = windowedModes.includes(mode);
    await page.goto(origin + (compiled ? '/' + mode : '/?mode=' + mode), {waitUntil:'commit'});
    await page.waitForFunction(() =>
      document.documentElement.dataset.failure ||
      (performance.getEntriesByName('mesa-lists-ready').length && window.benchPaints['mesa-ready'] > 0));
    assert.equal(await page.locator('html').getAttribute('data-failure'), null);
    assert.deepEqual(requests.map(r => r.path).sort(), reads);
    assert.ok(requests.every(r => r.method === 'GET'));
    const input = page.locator('#title');
    assert.ok(await input.isEditable());
    assert.equal(await input.inputValue(), 'Item 42');
    const initialMountedRows = await page.evaluate(checkLists, {
      windowed:mode === 'windowed', savedTitle:null, expected:expectedViews(null)});
    const initialViews = await page.evaluate(() => {
      window.benchRows = ['all','open'].map(id => document.querySelector('#list-' + id + ' [data-id="42"]'));
      return window.benchRows.every(node => node && node.getBoundingClientRect().height > 0);
    });
    assert.ok(initialViews);
    const initial = await page.evaluate(() => {
      const resources = performance.getEntriesByType('resource');
      const scripts = resources.filter(r => new URL(r.name).pathname.endsWith('.js'));
      return {
        initialBodyBytes:performance.getEntriesByType('navigation')[0].encodedBodySize
          + resources.reduce((bytes,r) => bytes + r.encodedBodySize,0),
        jsBodyBytes:scripts.reduce((bytes,r) => bytes + r.encodedBodySize,0),
        scripts:scripts.map(r => new URL(r.name).pathname),
        listsReadyMs:performance.getEntriesByName('mesa-lists-ready')[0].startTime,
        apiBytes:resources.filter(r => new URL(r.name).pathname.startsWith('/api/'))
          .reduce((bytes,r) => bytes + r.encodedBodySize,0),
      };
    });
    if (compiled) {
      const generation = await page.locator('#app').getAttribute('data-generation');
      assert.ok(generation, 'Missing build generation');
      assert.ok(initial.scripts.length && initial.scripts.every(path => path.startsWith('/__saba/build/' + generation + '/')),
        'The page did not load a single immutable module graph');
      assert.equal(new Set(initial.scripts).size, initial.scripts.length, 'Duplicate startup transfer');
    }
    if (frameworkModes.includes(mode)) assert.deepEqual(initial.scripts, ['/frameworks/' + mode + '.js']);
    await input.focus(); await page.keyboard.press('End'); await frames(page, 3);
    const keyMs = await measureTyping(page, session, 'Item 42');
    await page.keyboard.press('Home');
    await page.keyboard.type('!');
    const savedTitle = '!Item 42' + keys;
    assert.equal(await input.inputValue(), savedTitle);
    const beforeSave = requests.length;
    await page.locator('#save').click();
    await page.waitForFunction(() => document.documentElement.dataset.failure ||
      (performance.getEntriesByName('mesa-fresh').length && window.benchPaints['mesa-saved'] > 0));
    assert.equal(await page.locator('html').getAttribute('data-failure'), null);
    const state = await page.evaluate(({itemPath, prefix}) => {
      const start = performance.getEntriesByName('mesa-save-start')[0].startTime;
      const detail = performance.getEntriesByType('resource')
        .filter(r => new URL(r.name).pathname === itemPath && r.startTime >= start)
        .sort((a,b) => a.startTime - b.startTime);
      return {
        editableMs:performance.getEntriesByName('mesa-editable')[0].startTime,
        readyPaintMs:window.benchPaints['mesa-ready'],
        freshMs:performance.getEntriesByName('mesa-fresh')[0].startTime - start,
        freshPaintMs:window.benchPaints['mesa-saved'] - start,
        ackMs:detail[0]?.responseEnd - start,
        titles:['all','open','marked'].map(id => document.querySelector('#list-' + id + ' [data-id="42"]')?.textContent),
        retained:window.benchRows.every((row,i) => row === document.querySelector(
          '#list-' + ['all','open'][i] + ' [data-id="42"]')),
        revision:document.querySelector('#editor').dataset.revision,
        detailRequests:detail.length,
        refreshBytes:performance.getEntriesByType('resource').filter(r => r.startTime >= start &&
          new URL(r.name).pathname.startsWith(prefix)).reduce((total,r) => total+r.encodedBodySize,0),
        lastResponseMs:Math.max(...performance.getEntriesByType('resource').filter(r =>
          r.startTime >= start && new URL(r.name).pathname.startsWith(prefix)).map(r => r.responseEnd)) - start,
      };
    }, {itemPath, prefix});
    const writes = requests.slice(beforeSave);
    assert.equal(writes[0]?.method,'PATCH'); assert.equal(writes[0]?.path,itemPath);
    assert.deepEqual(writes.slice(1).map(r=>r.path).sort(),reads);
    assert.ok(writes.slice(1).every(r => r.method === 'GET'));
    assert.deepEqual(state.titles,Array(3).fill(savedTitle)); assert.ok(state.retained);
    const savedMountedRows = await page.evaluate(checkLists, {
      windowed:mode === 'windowed', savedTitle, expected:expectedViews(savedTitle)});
    assert.equal(state.revision,'2'); assert.equal(state.detailRequests,2);
    assert.ok(state.ackMs > 0 && state.freshMs >= state.ackMs);
    // Public Element Timing entries can be coarsened around a frame boundary.
    assert.ok(state.readyPaintMs >= state.editableMs - 4 && state.freshPaintMs >= state.freshMs - 4);
    const windowMetrics = {};
    if (checkWindowSuite) {
      await checkApiPayloads(replies,savedTitle);
      const maxSampledMountedRows = mode === 'windowed'
        ? await checkScroll(page, savedTitle, Math.max(initialMountedRows,savedMountedRows))
        : Math.max(initialMountedRows,savedMountedRows);
      assert.equal(requests.length, beforeSave + writes.length, 'Scrolling issued an extra API request');
      Object.assign(windowMetrics,{initialMountedRows,savedMountedRows,maxSampledMountedRows,initialApiBytes:initial.apiBytes});
    }
    assert.deepEqual(errors,[]);
    assert.deepEqual(offOrigin,[]);
    return {mode,profile,editableMs:state.editableMs,readyPaintMs:state.readyPaintMs,keyMs,
      ackMs:state.ackMs,freshMs:state.freshMs,freshPaintMs:state.freshPaintMs,
      lastResponseMs:state.lastResponseMs,responseBodyBytes:state.refreshBytes,
      saveRequests:writes.length,listsReadyMs:initial.listsReadyMs,
      initialBodyBytes:initial.initialBodyBytes,jsBodyBytes:initial.jsBodyBytes,...windowMetrics};
  } catch (error) {
    const state = await page.evaluate(() => ({
      status:document.querySelector('#status')?.textContent,fail:document.documentElement.dataset.failure,
      marks:performance.getEntriesByType('mark').map(m=>m.name),paints:window.benchPaints,
      assets:performance.getEntriesByType('resource').map(r=>new URL(r.name).pathname),
    })).catch(() => ({}));
    console.error('Trial failed', {mode,profile,errors,state});
    throw error;
  } finally { await context.close(); }
}

async function main() {
  const origin = process.argv[2];
  assert.match(origin, /^http:\/\/127\.0\.0\.1:\d+$/);
  const options = readOptions(process.argv.slice(3));
  const {modes} = options;
  const browser = await chromium.launch({channel:'chromium', executablePath:process.env.SABA_CHROME || undefined});
  const pidFile = process.env.SABA_MESA_PERF_BROWSER_PID_FILE;
  if (pidFile) {
    try {
      const browserSession = await browser.newBrowserCDPSession();
      const {processInfo} = await browserSession.send('SystemInfo.getProcessInfo');
      const browserPid = processInfo.find(info => info.type === 'browser')?.id;
      assert.ok(Number.isInteger(browserPid) && browserPid > 1);
      await fs.writeFile(pidFile,String(browserPid),'utf8');
      await browserSession.detach();
    } catch (e) { await browser.close(); throw e; }
  }
  let interrupted = false;
  for (const signal of ['SIGINT','SIGTERM']) {
    process.once(signal, () => { interrupted = true; void browser.close(); });
  }
  try {
    const trials = [];
    const metadata = {generatedAt:new Date().toISOString(), platform:os.platform(), osRelease:os.release(),
      arch:os.arch(),cpu:os.cpus()[0]?.model,logicalCpus:os.cpus().length,
      browser:browser.version(),node:process.version,profiles,trialsPerCell:options.trials,
      saveContract:['PATCH /api/items/42',...expectedReads.map(p=>'GET '+p)],
      suite:options.suite,modes,keysPerTrial:keys.length,quantile:'nearest rank',
      modeOrder:options.suite === 'frameworks' ? 'balanced seven-way rotations and reversals' : 'alternating within paired trials',
      cold:'fresh browser context, HTTP cache disabled, warm server and browser process',warmupRoundsPerProfile:1};
    const sources = ['src/modules/dom.js',...['app.js','entry.js','planned.js','index.html','style.css',
      'main.odin','runner.odin','measure.cjs'].map(name=>'testdata/mesa_perf/'+name)];
    if (options.suite === 'generated' || options.suite === 'windowed') {
      sources.push('testdata/mesa_perf/generated.jsx','testdata/mesa_perf/lists/full/list.jsx','.krs/packages.json');
      if (options.suite === 'windowed') sources.push('testdata/mesa_perf/lists/windowed/list.jsx');
      for (const dir of ['src/jsx','src/pages','src/modules']) {
        for (const name of (await fs.readdir(dir)).sort()) {
          if (/\.(js|odin)$/.test(name) && !name.endsWith('_test.odin') && !sources.includes(dir+'/'+name)) sources.push(dir+'/'+name);
        }
      }
      for (const mode of options.suite === 'windowed' ? windowedModes : ['generated']) {
        const document = await fetch(origin + '/' + mode);
        assert.equal(document.status, 200);
        const html = await document.text();
        const paths = [...html.matchAll(/<(?:link rel="modulepreload" href|script type="module" src)="([^"]+)"/g)].map(match => match[1]);
        assert.ok(paths.length > 1 && paths.every(url => url.startsWith('/__saba/build/')));
        metadata[mode + 'Assets'] = Object.fromEntries(await Promise.all(paths.map(async url => {
          const response = await fetch(origin + url);
          assert.equal(response.status, 200);
          const bytes = Buffer.from(await response.arrayBuffer());
          return [url,{decodedBytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')}];
        })));
      }
    }
    if (options.suite === 'frameworks') {
      const fixtureDir = 'testdata/mesa_perf';
      const dir = 'benchmarks/frameworks';
      metadata.build = JSON.parse(await fs.readFile(dir + '/dist/manifest.json','utf8'));
      metadata.fragmentSaveContract = metadata.saveContract.map(req => req.replace('/api/','/fragments/'));
      sources.push(dir+'/package.json',dir+'/package-lock.json',dir+'/build.mjs',dir+'/htmx.html');
      for (const name of await fs.readdir(dir + '/src')) sources.push(dir + '/src/' + name);
      for (const name of await fs.readdir(fixtureDir)) {
        const file = fixtureDir + '/' + name;
        if ((name.endsWith('.html') || name.endsWith('.odin')) && !sources.includes(file)) sources.push(file);
      }
      for (const mode of modes) {
        const response = await fetch(origin + '/frameworks/' + mode + '.js');
        assert.equal(response.status,200);
        const bytes = Buffer.from(await response.arrayBuffer());
        const built = metadata.build.bundles[mode];
        assert.equal(bytes.length,built.bytes);
        assert.equal(createHash('sha256').update(bytes).digest('hex'),built.sha256,mode + ' served a different build');
      }
    }
    metadata.sourceSha256 = Object.fromEntries(await Promise.all(sources.map(async file =>
      [file,createHash('sha256').update(await fs.readFile(file)).digest('hex')])));
    for (const profile of options.profiles) {
      for (let i = -1; i < options.trials; i++) {
        for (const mode of roundOrder(modes,i)) {
          const sample = await runTrial(browser,origin,profile,mode,options.suite === 'windowed');
          if (i >= 0) trials.push({...sample,trial:i+1});
        }
        if (i === -1 || (i+1)%5===0 || i+1===options.trials) {
          console.log(profile,i===-1?'warm-up passed':(i+1)+'/'+options.trials+' rounds');
        }
      }
    }
    assert.equal(interrupted,false);
    const report = {metadata,summary:summarize(trials,modes),trials};
    const out = path.resolve(options.out);
    await fs.mkdir(path.dirname(out),{recursive:true});
    const tmp = out + '.' + process.pid + '.tmp';
    try {
      await fs.writeFile(tmp,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
      await fs.rename(tmp,out);
    } finally { await fs.rm(tmp,{force:true}); }
    console.log(JSON.stringify(report.summary,null,2)); console.log('Report:',out);
  } finally {
    await browser.close();
    if (pidFile) await fs.rm(pidFile,{force:true});
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
