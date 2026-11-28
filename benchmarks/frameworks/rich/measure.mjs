import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir, mkdir, writeFile, rename } from 'node:fs/promises';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { applyBoardAction, boardSnapshot, createBoard } from './board-model.js';
import { inspectorText } from './display.js';
import { modes, startServer } from './server.mjs';
import { startPresentation } from './presentation.mjs';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_PATH || 'playwright');
const { values } = parseArgs({options:{trials:{type:'string',default:'7'},profiles:{type:'string',default:'desktop,constrained'},
  modes:{type:'string',default:modes.join(',')},out:{type:'string',default:'docs/benchmarks/rich-dashboard.json'},screenshot:{type:'string'}}});
const rounds = Number(values.trials);
const availableProfiles = {desktop:{cpu:1,latency:0},constrained:{cpu:4,latency:60,downMbps:10,upMbps:2}};
const selected = values.modes.split(',');
const profiles = values.profiles.split(',');
assert.ok(Number.isInteger(rounds) && rounds >= 1 && rounds <= 100);
assert.ok(selected.length && new Set(selected).size===selected.length && selected.every(mode=>modes.includes(mode)));
assert.ok(profiles.length && new Set(profiles).size===profiles.length && profiles.every(p=>availableProfiles[p]));
const actions = [
  ['select',{type:'select',id:5},'#card-5'],
  ['batch',{type:'bulk'},'#bulk'],
  ['undo',{type:'undo'},'#undo'],
  ['filterOn',{type:'filter'},'#filter'],
  ['filterOff',{type:'filter'},'#filter'],
  ['drop',{type:'drop',id:1,lane:1,before:2}],
];
function observe() {
  window.benchPaints = {};
  new PerformanceObserver(list => {
    for (const entry of list.getEntries()) {
      if (entry.identifier.startsWith('rich-')) window.benchPaints[entry.identifier] = entry.renderTime;
    }
  }).observe({type:'element',buffered:true});
  function capture(e) {
    if (e.isTrusted && window.benchArmed === e.type) {
      window.benchInputStart = e.timeStamp;
      window.benchArmed = null;
    }
  }
  document.addEventListener('click',capture,true);
  document.addEventListener('pointerup',capture,true);
}
async function verify(page, board) {
  const expected = boardSnapshot(board);
  const actual = await page.evaluate(() => {
    const el = id=>document.getElementById(id);
    return {
      selected:Number(el('inspector').dataset.id), inspector:el('inspector').textContent,
      revision:Number(el('board').dataset.revision), undo:!el('undo').disabled, filter:el('filter').getAttribute('aria-pressed')==='true',
      stats:['total','points','high'].map(k=>Number(el(k).textContent)),
      bins:Array.from({length:8},(_,i)=>Number(el('bin-'+i).dataset.value)),
      lanes:Array.from({length:4},(_,i)=>Array.from(el('lane-items-'+i).children, card=>[
        Number(card.dataset.id),...['label','owner','priority','points'].map(k=>card.querySelector('[data-'+k+']').textContent),
        card.getAttribute('aria-pressed')==='true',
      ])),
    };
  });
  assert.deepEqual(actual,{
    selected:expected.selected, inspector:inspectorText(expected.inspector),revision:expected.revision,
    undo:expected.canUndo,filter:expected.filter,stats:[expected.total,expected.points,expected.high],bins:expected.bins,
    lanes:expected.lanes.map(l=>l.cards.map(c=>[c.id,c.title,c.owner,c.priority,String(c.points),c.id===expected.selected])),
  });
  return actual;
}
async function moveCard(page) {
  const a=await page.locator('#card-1').boundingBox();
  const b=await page.locator('#card-2').boundingBox();
  assert.ok(a && b && b.y < 900);
  await page.mouse.move(a.x+a.width/2,a.y+a.height/2);
  await page.mouse.down();
  await page.mouse.move(b.x+b.width/2,b.y+b.height*.2,{steps:12});
  await page.mouse.up();
}
async function waitPaint(page,id) {
  await page.waitForFunction(id=>window.benchPaints[id]>0 || window.richDashboard?.phase==='failed',id);
  const error=await page.evaluate(()=>window.richDashboard?.error);
  if(error) throw Error(error);
}
async function runVisit(browser, origin, mode, profile, screenshot) {
  const ctx=await browser.newContext({viewport:{width:1440,height:900},serviceWorkers:'block'});
  try {
    const page=await ctx.newPage();page.setDefaultTimeout(12000);
    const errors=[], urls=[], responseErrors=[];
    page.on('pageerror',error=>errors.push(error.message));
    page.on('request',request=>{if (/^https?:/.test(request.url())) urls.push(request.url());});
    page.on('response',res=>{if(res.status()>=400)responseErrors.push([res.status(),res.url()]);});
    const cdp=await ctx.newCDPSession(page);
    await cdp.send('Network.enable');await cdp.send('Network.setCacheDisabled',{cacheDisabled:true});
    const config=availableProfiles[profile];
    await cdp.send('Emulation.setCPUThrottlingRate',{rate:config.cpu});
    if (config.latency) await cdp.send('Network.emulateNetworkConditions',{offline:false,latency:config.latency,
      downloadThroughput:config.downMbps*1e6/8,uploadThroughput:config.upMbps*1e6/8});
    await page.addInitScript(observe);
    await page.goto(origin+'/'+mode,{waitUntil:'commit'});
    await waitPaint(page,'rich-view-0');
    let board=createBoard();
    const baseline=await verify(page,board);
    assert.equal(baseline.stats[0],240);
    const startup=await page.evaluate(()=>({
      paintMs:window.benchPaints['rich-view-0'],commitMs:performance.getEntriesByName('rich-ready')[0].startTime,
      nodes:document.querySelectorAll('#app *').length, cards:document.querySelectorAll('.rich-card').length,
    }));
    if(screenshot) {await mkdir(path.dirname(screenshot),{recursive:true});await page.screenshot({path:screenshot});}
    const steps={};
    for (const [label,action,selector] of actions) {
      const endTrace=action.type==='drop'?await startPresentation(cdp):null;
      await page.evaluate(type=>{window.benchInputStart=null;window.benchArmed=type;},selector?'click':'pointerup');
      if(selector) await page.locator(selector).click(); else await moveCard(page);
      board=applyBoardAction(board,action);
      const rev=board.revision;
      await waitPaint(page,'rich-view-'+rev);
      if(endTrace) await waitPaint(page,'rich-drop-painted-'+rev);
      const presentation=endTrace?await endTrace():null;
      const state=await verify(page,board);
      if(label==='batch') assert.equal(state.stats[1]-baseline.stats[1],144);
      if(label==='undo') assert.deepEqual(state.stats,baseline.stats);
      if(label==='filterOn') assert.equal(state.stats[0],35);
      if(label==='drop') {
        assert.deepEqual(state.lanes.map(l=>l.length),[59,61,60,60]);assert.equal(state.lanes[1][0][0],1);
      }
      steps[label]=await page.evaluate(({rev,type})=>{
        const input=window.benchInputStart;
        if (!(input > 0)) throw Error('Missing trusted input timestamp');
        const commit=performance.getEntriesByName('rich-'+type+'-commit').at(-1).startTime;
        const paint=window.benchPaints['rich-view-'+rev];
        return {commitMs:commit-input,paintMs:paint-input,...(type==='drop'?{
          settledPaintMs:window.benchPaints['rich-drop-painted-'+rev]-input,animation:window.richDashboard.lastAnimation,
        }:{})};
      },{rev,type:action.type});
      if(presentation) steps[label].presentation=presentation;
      assert.ok(steps[label].commitMs>=0 && steps[label].paintMs>=steps[label].commitMs-4);
    }
    assert.deepEqual(errors,[]);assert.deepEqual(responseErrors,[]);
    assert.ok(urls.every(url=>new URL(url).origin===origin));
    const requests=urls.filter(url=>new URL(url).pathname==='/board').length;
    assert.equal(requests,mode==='htmx'?7:0);
    const animation=steps.drop.animation;
    assert.ok(animation.frames.length>=2 && animation.moved.length>0 && animation.pointerMoves>1,'Animation did not run');
    const resourceBytes=await page.evaluate(()=>performance.getEntriesByType('resource').filter(e=>new URL(e.name).pathname==='/board').reduce((s,e)=>s+e.encodedBodySize,0));
    return {startup,steps,requests,fragmentBytes:resourceBytes};
  } finally {await ctx.close();}
}
const median=nums=>{const v=[...nums].sort((a,b)=>a-b), i=Math.floor(v.length/2);return v.length%2?v[i]:(v[i-1]+v[i])/2;};
function order(round) {
  const shifts=selected.length===7?[0,1,6,2,5,3,4]:selected.map((_,i)=>i);
  const result=shifts.map(i=>selected[(i+Math.max(0,round))%selected.length]);
  return Math.floor(Math.max(0,round)/selected.length)%2 ? result.reverse() : result;
}
function summarize(rows) {
  const medianOf=f=>median(rows.map(f));
  const steps=Object.fromEntries(actions.map(([k])=>[k,medianOf(r=>r.steps[k].paintMs)]));
  const traces=rows.map(r=>r.steps.drop.presentation).filter(t=>t.available && t.maxGapMs!==null);
  return {startup:medianOf(r=>r.startup.paintMs),...steps,settled:medianOf(r=>r.steps.drop.settledPaintMs),
    presentationSamples:traces.length,presentedFrames:traces.length?median(traces.map(t=>t.count)):null,
    worstPresentedGapMs:traces.length?median(traces.map(t=>t.maxGapMs)):null,
    animationWorstFrameGap:medianOf(r=>{const t=r.steps.drop.animation.frames;return Math.max(...t.slice(1).map((v,i)=>v-t[i]));})};
}
const service=await startServer();
try {
  const browser=await chromium.launch({channel:'chromium'});
  try {
    const samples=[];
    for(const profile of profiles) {
      for(let round=-1;round<rounds;round++) {
        for(const mode of order(round)) {
          try {
            const result=await runVisit(browser,service.origin,mode,profile,round===0&&mode==='saba-planned'&&profile===profiles[0]?values.screenshot:null);
            if(round>=0)samples.push({profile,round:round+1,mode,...result});
          } catch(e) {throw Error(profile+' '+mode+' round '+(round+1),{cause:e});}
        }
        console.log(profile,round<0?'warm-up verified':'round '+(round+1)+'/'+rounds);
      }
    }
    const summary=Object.fromEntries(profiles.map(p=>[p,Object.fromEntries(selected.map(m=>[m,summarize(samples.filter(r=>r.profile===p&&r.mode===m))]))]));
    const dir=path.dirname(fileURLToPath(import.meta.url));
    const sources=(await readdir(dir)).filter(n=>!n.startsWith('scale') && /\.(?:[cm]?js|jsx|svelte|css)$/.test(n));
    const hashes=Object.fromEntries(await Promise.all([...sources,'../build.mjs','../package-lock.json','../../../src/modules/dom.js'].map(async f=>[f,createHash('sha256').update(await readFile(path.resolve(dir,f))).digest('hex')])));
    const report={metadata:{created:new Date().toISOString(),browser:browser.version(),cpu:os.cpus()[0].model,node:process.version,profiles:availableProfiles,rounds,warmups:1,modes:selected,manifest:service.manifest,hashes},summary,samples};
    await mkdir(path.dirname(values.out),{recursive:true});
    const tmp=values.out+'.'+process.pid+'.tmp';await writeFile(tmp,JSON.stringify(report,null,2)+'\n',{flag:'wx'});await rename(tmp,values.out);
    console.log('Report',values.out);
  } finally {await browser.close();}
} finally {await service.close();}
