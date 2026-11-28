'use strict';

// Each visit owns one Chromium process tree. A Node watchdog can terminate it
// without a reply from a busy renderer. Capacity stops are explicit observations.
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const {createHash} = require('node:crypto');
const {chromium} = require(process.env.PLAYWRIGHT_PATH || 'playwright');
const exec = promisify(execFile);
const root = path.resolve(__dirname,'../../..');
const compiledModes = ['react','solid','svelte'];
const modes = ['vanilla','saba-current','saba-planned',...compiledModes];
const availableModes = [...modes,'saba-compiled','saba-compiled-window','saba-baseline'];
const scenarios = ['moderate','virtual','buffered','capacity'];
const assets = new Map([
  ['/','benchmarks/frameworks/rich/scale.html'],
  ['/scale.js','benchmarks/frameworks/rich/scale.js'],
  ['/reactivity.js','benchmarks/frameworks/rich/reactivity.js'],
  ['/dom.js','src/modules/dom.js'],
]);
const options = {oldSpaceMiB:768,out:'rich-scale.json',modes,scenarios:['moderate','buffered','capacity'],trials:3,count:1000000,moderate:10000,rssMiB:900,seconds:45};
const optionsMap = {'--out':'out','--modes':'modes','--scenarios':'scenarios','--trials':'trials','--count':'count',
  '--moderate':'moderate','--rss-mib':'rssMiB','--seconds':'seconds','--old-space-mib':'oldSpaceMiB',
  '--saba-baseline':'sabaBaseline'};
for (let i = 2; i < process.argv.length; i += 2) {
  const key = optionsMap[process.argv[i]];
  const value = process.argv[i+1];
  assert.ok(key && value,'Unknown option or missing value '+process.argv[i]);
  if (key === 'out' || key === 'sabaBaseline') options[key] = value;
  else if (key === 'modes' || key === 'scenarios') options[key] = value.split(',');
  else options[key] = Number(value);
}
for (const [values,allowed] of [[options.modes,availableModes],[options.scenarios,scenarios]]) {
  assert.ok(values.length && values.every(v => allowed.includes(v)) && new Set(values).size === values.length);
}
assert.equal(options.modes.includes('saba-baseline'),Boolean(options.sabaBaseline),
  'Select mode saba-baseline together with --saba-baseline <saved bundle>');
for (const [key,min,max] of [['trials',1,30],['count',256,1e6],['moderate',256,1e6],['rssMiB',128,6144],['seconds',5,180],['oldSpaceMiB',128,3072]]) {
  assert.ok(Number.isInteger(options[key]) && options[key]>=min && options[key]<=max,'Invalid '+key);
}

if (options.rssMiB > 4096) {
  assert.ok(options.rssMiB <= Math.floor(os.totalmem() / 2**20 / 4),
    'High renderer RSS limits must fit within one quarter of this host’s physical memory');
}

async function fixture() {
  const files = new Map();
  const hashes = {};
  let baselineBundle;
  if (options.sabaBaseline) {
    const bytes = await fs.readFile(options.sabaBaseline);
    const url = '/scale-saba-baseline.js';
    files.set(url,bytes);
    baselineBundle = {url,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')};
  }
  if (options.scenarios.includes('buffered')) assets.set('/sliding-window.js','src/modules/sliding-window.js');
  const native = options.modes.filter(mode => compiledModes.includes(mode) || mode.startsWith('saba-compiled'));
  let build;
  if (native.length) {
    const dir = 'benchmarks/frameworks';
    build = JSON.parse(await fs.readFile(path.join(root,dir,'dist/scale/manifest.json'),'utf8'));
    if (native.some(mode => mode.startsWith('saba-compiled'))) {
      assert.ok(build.bundles['saba-compiled'] && build.sabaSourceSha256,
        'Run node benchmarks/frameworks/build.mjs --scale --compiled-saba first');
      for (const [file, expected] of Object.entries(build.sabaSourceSha256)) {
        hashes[file] = createHash('sha256').update(await fs.readFile(path.join(root,file))).digest('hex');
        assert.equal(hashes[file], expected, 'Rebuild the Saba grid after changing '+file);
      }
    }
    const sources = ['build.mjs','package-lock.json','dist/scale/manifest.json','rich/scale-react.jsx',
      'rich/scale-solid.jsx','rich/scale-svelte.js','rich/ScaleBand.svelte','rich/ScaleTile.svelte'];
    for (const file of sources) {
      const relative = dir+'/'+file;
      hashes[relative] = createHash('sha256').update(await fs.readFile(path.join(root,relative))).digest('hex');
    }
    assert.equal(hashes[dir+'/package-lock.json'],build.lockSha256);
    for (const mode of native) assets.set('/scale-'+mode+'.js',dir+'/dist/scale/'+mode+'.js');
  }
  for (const [url,relative] of assets) {
    const bytes = await fs.readFile(path.join(root,relative));
    files.set(url,bytes);
    hashes[relative] = createHash('sha256').update(bytes).digest('hex');
  }
  for (const mode of native) assert.equal(hashes['benchmarks/frameworks/dist/scale/'+mode+'.js'],build.bundles[mode].sha256);
  hashes['benchmarks/frameworks/rich/scale-run.cjs'] = createHash('sha256').update(await fs.readFile(__filename)).digest('hex');
  const server = http.createServer((request,response) => {
    const key = request.url.split('?')[0];
    if (!files.has(key)) { response.writeHead(404); response.end(); return; }
    response.writeHead(200,{'Content-Type':key === '/' ? 'text/html' : 'text/javascript','Cache-Control':'no-store'});
    response.end(files.get(key));
  });
  await new Promise((resolve,reject) => { server.once('error',reject); server.listen(0,'127.0.0.1',resolve); });
  return {server,hashes,build,baselineBundle,origin:'http://127.0.0.1:'+server.address().port};
}

async function rssMiB(pids) {
  // Only PIDs supplied by the CDP session for this visit's dedicated browser.
  const {stdout} = await exec('ps',['-o','rss=','-p',pids.join(',')],{timeout:2000});
  const rows = stdout.trim().split(/\s+/).map(Number);
  assert.ok(rows.length && rows.every(n => Number.isFinite(n) && n>0),'Renderer RSS unavailable');
  return rows.reduce((a,b) => a+b,0)/1024;
}

async function runVisit(origin,mode,scenario,trial) {
  const count = scenario === 'moderate' ? options.moderate : options.count;
  const result = {mode,scenario,trial,target:count,status:'started',lastLayoutConfirmed:0,lastMountPaintConfirmed:0,
    sampledPeakRendererRssMiB:0,checkpoints:[]};
  const processTree = await chromium.launchServer({channel:'chromium',executablePath:process.env.SABA_CHROME,
    args:['--renderer-process-limit=1','--js-flags=--max-old-space-size='+options.oldSpaceMiB]});
  let timer;
  let running = true;
  let kill;
  let browser;
  let start;
  let reason;
  try {
    browser = await chromium.connect(processTree.wsEndpoint());
    result.chromium = browser.version();
    const context = await browser.newContext({viewport:{width:1200,height:900},serviceWorkers:'block'});
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror',e => errors.push(e.message));
    await page.goto(origin+'/?'+new URLSearchParams({mode,scenario,count}));
    await page.waitForFunction(() => Boolean(window.scale));
    const cdp = await browser.newBrowserCDPSession();
    const processes = await cdp.send('SystemInfo.getProcessInfo');
    const pids = processes.processInfo.filter(p => p.type === 'renderer').map(p => p.id);
    assert.ok(pids.length && pids.every(p => Number.isInteger(p) && p>1),'Missing isolated renderer PID');
    const baseline = await rssMiB(pids);
    result.sampledPeakRendererRssMiB = result.initialRendererRssMiB = baseline;
    start = performance.now();
    let rejectStop;
    const stopped = new Promise((_,reject) => { rejectStop = reject; });
    let sampling = false;
    function stop(message) {
      if (reason || !running) return;
      reason = message;
      rejectStop(new Error(message));
      kill = processTree.kill().catch(() => {});
    }
    timer = setInterval(async () => {
      if (!running) return;
      if (performance.now()-start > options.seconds*1000) {
        stop('time-limit');
        return;
      }
      if (sampling) return;
      sampling = true;
      try {
        const rss = await rssMiB(pids);
        result.sampledPeakRendererRssMiB = Math.max(result.sampledPeakRendererRssMiB,rss);
        if (rss >= options.rssMiB) stop('renderer-rss-limit');
      } catch (error) {
        if (running && !reason) stop('watchdog-failure: '+error.message);
      } finally { sampling = false; }
    },200);

    async function presentation(key,action) {
      await page.waitForFunction(k => window.scale.paints[k]>0,key,{timeout:10000});
      const timings = await page.evaluate(({key,action}) =>
        ({paint:window.scale.paints[key],start:window.scale.starts[action]}),{key,action});
      assert.ok(timings.paint>=timings.start-4,'Presentation timestamp precedes input');
      return timings.paint-timings.start;
    }
    async function checkpoint() {
      const {key,count} = await page.evaluate(() => window.scale.checkpoint());
      const ms = await presentation(key,'mount');
      result.lastMountPaintConfirmed = count;
      result.checkpoints.push({mounted:count,markerPaintMs:ms});
      return ms;
    }
    async function journey() {
      const data = await page.evaluate(() => window.scale.start());
      assert.equal(data.records,count);
      result.dataMs = data.dataMs;
      if (scenario !== 'virtual' && scenario !== 'buffered') {
        while (result.lastLayoutConfirmed < count) {
          result.lastLayoutConfirmed = await page.evaluate(() => window.scale.step());
          if (result.lastLayoutConfirmed - result.lastMountPaintConfirmed >= 32768 &&
              result.lastLayoutConfirmed < count) await checkpoint();
        }
      }
      result.mountPaintMs = await checkpoint();
      result.lastLayoutConfirmed = result.lastMountPaintConfirmed;
      await page.evaluate(() => window.scale.allowUpdates());
      await page.locator('#mutate').click();
      result.updatePaintMs = await presentation('mutate','mutate');
      const checked = await page.evaluate(() => window.scale.verifyUpdate());
      const sampled = Math.floor((count-1)/97)+1;
      assert.equal(checked.changed,sampled+Number((count-1)%97!==0));
      Object.assign(result,checked);
      await page.locator('#jump').click();
      result.seekPaintMs = await presentation('jump','jump');
      Object.assign(result,await page.evaluate(() => window.scale.verifyEnd()));
      assert.equal(result.lastId,count-1);
      if (scenario === 'virtual' || scenario === 'buffered') {
        const timing = await page.evaluate(() => window.scale.starts);
        assert.ok(timing.jump <= timing.jumpWindow && timing.jumpWindow <= timing.jumpRenderer &&
          timing.jumpRenderer <= timing.jumpRendererDone && timing.jumpRendererDone <= timing.jumpWindowDone,
          'Missing or out-of-order destination window timings');
        result.seekBeforeWindowMs = timing.jumpWindow - timing.jump;
        result.seekRendererMs = timing.jumpRendererDone - timing.jumpRenderer;
        result.seekWindowMs = timing.jumpWindowDone - timing.jumpWindow;
        result.destinationDom = await page.evaluate(() => {
          const band = document.querySelector('#space .band');
          const walker = document.createTreeWalker(band, NodeFilter.SHOW_ALL);
          const counts = {elements:0, text:0, comments:0};
          while (walker.nextNode()) {
            const type = walker.currentNode.nodeType;
            if (type === Node.ELEMENT_NODE) counts.elements++;
            else if (type === Node.TEXT_NODE) counts.text++;
            else if (type === Node.COMMENT_NODE) counts.comments++;
          }
          return counts;
        });
        assert.equal(result.destinationDom.elements,result.mounted);
      }
      assert.deepEqual(errors,[]);
      // Take one last RSS reading even if a short visit fit between watchdog ticks.
      const rss = await rssMiB(pids);
      result.sampledPeakRendererRssMiB = Math.max(result.sampledPeakRendererRssMiB,rss);
      if (rss >= options.rssMiB) { stop('renderer-rss-limit'); return; }
      result.status = 'completed';
    }
    try {
      await Promise.race([journey(),stopped]);
    } catch (error) {
      if (reason === 'time-limit' || reason === 'renderer-rss-limit') result.status = reason;
      else if (/page crashed|target crashed/i.test(error.message)) result.status = 'renderer-crashed';
      else throw error;
    }
    if (result.status === 'started' && reason) result.status = reason;
    result.elapsedMs = performance.now()-start;
  } finally {
    running = false;
    clearInterval(timer);
    if (kill) await kill;
    else await processTree.close();
  }
  return result;
}

async function main() {
  const {server,hashes,build,baselineBundle,origin} = await fixture();
  const report = {metadata:{generatedAt:new Date().toISOString(),cpu:os.cpus()[0].model,os:os.type()+' '+os.release(),
    totalMemoryMiB:os.totalmem()/2**20,viewport:[1200,900],trials:options.trials,fullCapacityTrials:1,sourceSha256:hashes,build,
    measurements:'Desktop Chromium, fresh browser per run, clocks begin at local data creation or trusted button handler. Mount/seek/update clocks end at visible Element Timing status marker. Complete visits also verify a visible tile by hit test.',
    windowTimings:'On the final-row jump, seekBeforeWindowMs ends at the first destination window commit. seekWindowMs covers that commit including slicing and verification. seekRendererMs covers only the synchronous band replacement inside that commit.',
    guard:{rendererRssMiB:options.rssMiB,wallSeconds:options.seconds,jsOldSpaceMiB:options.oldSpaceMiB,pollMs:200},
    model:'One object per record (id, group, score). Full mode mounts one component and visible element per record in 4096-cell bands; native React, Solid and Svelte use a framework root per band. Planned Saba adds two binding comments. Every implementation receives the same immutable per-band record snapshots. Windowed grids have 8 columns and 16 visible rows. Virtual moves on each scroll with two extra rows per side. Buffered replenishes to eight extra rows when three remain.',
    checkpoints:'DOM count and last-cell layout confirmed for full chunks. Marker presentation sampled every >=32768 cells and at successful completion. Peak is sampled RSS of the isolated browser’s renderer processes, including baseline.'},visits:[]};
  const out = path.resolve(options.out);
  if (baselineBundle) report.metadata.sabaBaseline = baselineBundle;
  const temp = out+'.'+process.pid+'.tmp';
  await fs.mkdir(path.dirname(out),{recursive:true});
  try {
    for (const scenario of options.scenarios) {
      const repetitions = scenario === 'capacity' ? 1 : options.trials;
      for (let i=0; i<repetitions; i++) {
        for (let j=0; j<options.modes.length; j++) {
          const mode = options.modes[(i+j)%options.modes.length];
          const entry = await runVisit(origin,mode,scenario,i+1);
          report.visits.push(entry);
          await fs.writeFile(temp,JSON.stringify(report,null,2)+'\n');
          await fs.rename(temp,out);
          console.log(scenario,mode,'visit '+(i+1),entry.status,'last confirmed mounted:',entry.lastLayoutConfirmed,
            'RSS MiB:',Math.round(entry.sampledPeakRendererRssMiB));
          if (scenario !== 'capacity' && entry.status !== 'completed') throw Error('Unexpected incomplete '+scenario+' visit');
        }
      }
    }
  } finally {
    await new Promise(resolve => server.close(resolve));
    await fs.rm(temp,{force:true});
  }
}
main().catch(error => { console.error(error); process.exitCode=1; });
