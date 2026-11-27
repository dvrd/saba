// Rebuild and run the three-arm dashboard drag probe from this checkout's fixtures.
// Run from the repository root after installing benchmarks/frameworks/package-lock.json:
//
//   node benchmarks/frameworks/experiments/drag.mjs --strategy hint --trials 12 --out /tmp/drag-hint.json
//
// The probe patches copies of the rich dashboard in a scratch directory, never the
// fixtures themselves. PLAYWRIGHT_PATH can select a Playwright installation with Chromium.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {parseArgs} from 'node:util';

const usage = 'usage: drag.mjs [--repo DIR] [--trials N] [--out FILE] [--node PATH] [--strategy hint|snapshot]';
const {values: args} = parseArgs({options: {
  repo: {type: 'string', default: process.cwd()},
  trials: {type: 'string', default: '12'},
  out: {type: 'string', default: 'saba-drag-ab.json'},
  node: {type: 'string', default: process.env.SABA_BENCH_NODE || process.execPath},
  strategy: {type: 'string', default: 'hint'},
}});
const fail = message => {
  console.error(`${usage}\n${message}`);
  process.exit(2);
};
const trials = Number(args.trials);
if (!['hint', 'snapshot'].includes(args.strategy)) fail('--strategy is hint or snapshot');
const root = path.resolve(args.repo);
const output = path.resolve(args.out);
if (!existsSync(path.join(root, 'benchmarks/frameworks/node_modules'))) {
  fail('Install benchmarks/frameworks dependencies with npm ci before running the experiment');
}
if (!Number.isInteger(trials) || trials < 6 || trials % 6) fail('Use a positive multiple of six rounds to balance all orders');

const scratch = mkdtempSync(path.join(os.tmpdir(), 'saba-drag-ab-'));
// Removes the links to src and node_modules, never what they point at.
process.on('exit', () => rmSync(scratch, {recursive: true, force: true}));
const source = path.join(root, 'benchmarks/frameworks');
const framework = path.join(scratch, 'benchmarks/frameworks');
const rich = path.join(framework, 'rich');
mkdirSync(rich, {recursive: true});
symlinkSync(path.join(root, 'src'), path.join(scratch, 'src'), 'dir');
symlinkSync(path.join(source, 'node_modules'), path.join(framework, 'node_modules'), 'dir');
for (const name of ['package.json', 'package-lock.json', 'build.mjs']) copyFileSync(path.join(source, name), path.join(framework, name));
for (const name of readdirSync(path.join(source, 'rich'))) {
  const file = path.join(source, 'rich', name);
  if (statSync(file).isFile()) copyFileSync(file, path.join(rich, name));
}

// Each marker must occur exactly once, so a fixture edit fails loudly instead of
// silently measuring an unpatched arm.
function subst(file, before, after) {
  const text = readFileSync(file, 'utf8');
  assert.equal(text.split(before).length, 2, `${file}: expected one ${JSON.stringify(before)}`);
  writeFileSync(file, text.replace(before, () => after));
}

const dashboard = path.join(rich, 'dashboard.js');
subst(dashboard, "        const before = action.type === 'drop' ? visiblePositions(host) : null;", `        const times = action.type === 'drop' ? {event:eventTime,dispatch:performance.now()} : null;
        const before = times ? visiblePositions(host) : null;
        if (times) times.beforeLayoutDone=performance.now();`);
subst(dashboard, '        await update(boardSnapshot(next), action);', `        const model=boardSnapshot(next);
        if(times) times.modelDone=performance.now();
        await update(model, action);
        if(times) times.renderDone=performance.now();`);
subst(dashboard, '        const animation = before && animateReorder(before, visiblePositions(host), action.id, pointerMoves);', `        const after = before && visiblePositions(host);
        if(times) times.afterLayoutDone=performance.now();
        const animation = before && animateReorder(before, after, action.id, pointerMoves);
        if(times) {
          times.animateSetupDone=performance.now();
          lifecycle.probeTimes=times;
        }`);

let candidate;
if (args.strategy === 'hint') {
  candidate = 'saba-hinted';
  const keys = path.join(rich, 'saba-keys-hinted.js');
  copyFileSync(path.join(rich, 'saba-keys.js'), keys);
  subst(keys, 'return (lanes, selected) => {', `return (lanes, selected, move) => {
    // Move the retained key to its destination before reconciling the full snapshot.
    // The normal reconciler still handles filters, new/removed keys and other edits.
    if (move?.type === 'drop') {
      const view=previous.get(move.id), list=lists[move.lane];
      const before=move.before===null ? null : previous.get(move.before)?.node;
      if (view && list && (before===null || before?.parentNode===list) &&
          (view.node.parentNode!==list || view.node.nextElementSibling!==before)) {
        list.insertBefore(view.node,before);
      }
    }`);
  const lab = path.join(rich, 'saba-hinted.js');
  copyFileSync(path.join(rich, 'saba-planned.js'), lab);
  subst(lab, "from './saba-keys.js'", "from './saba-keys-hinted.js'");
  subst(lab, '  effect(() => updateChrome(snapshot.read()));', '  let hint;\n  effect(() => updateChrome(snapshot.read()));');
  subst(lab, '    updateCards(next.lanes, next.selected);', '    updateCards(next.lanes, next.selected, hint);');
  subst(lab, '  return next => snapshot.write(next);', `  return (next, action) => {
    hint=action;
    try { snapshot.write(next); } finally { hint=null; }
  };`);
} else {
  candidate = 'saba-snapshot';
  const keys = path.join(rich, 'saba-keys-snapshot.js');
  copyFileSync(path.join(rich, 'saba-keys.js'), keys);
  subst(keys, '    const retained = new Map();', '    const retained = new Map();\n    let nextParents;');
  subst(keys, '        if (cursor !== view.node', `        // A sibling leaving this list cannot anchor the retained siblings behind it.
        // Unchanged order and insertions at the end need no destination map.
        if (cursor && cursor !== view.node) {
          if (!nextParents) {
            nextParents = new Map();
            for (let laneIndex = 0; laneIndex < lanes.length; laneIndex++) {
              for (const item of lanes[laneIndex].cards) {
                const retainedView = previous.get(item.id);
                if (retainedView) nextParents.set(retainedView.node, lists[laneIndex]);
              }
            }
          }
          while (cursor && nextParents.get(cursor) !== list) cursor = cursor.nextElementSibling;
        }
        if (cursor !== view.node`);
  const lab = path.join(rich, 'saba-snapshot.js');
  copyFileSync(path.join(rich, 'saba-planned.js'), lab);
  subst(lab, "from './saba-keys.js'", "from './saba-keys-snapshot.js'");
}

// Build only the three arms: the planned baseline, the candidate and React.
const build = path.join(framework, 'build.mjs');
const original = readFileSync(build, 'utf8');
const start = original.indexOf('} : rich ? {') + '} : rich ? {'.length;
const end = original.indexOf('} : {', start);
assert.ok(start >= '} : rich ? {'.length && end > start, `${build}: no rich entry map`);
writeFileSync(build, original.slice(0, start) +
  `\n  'saba-planned':'rich/saba-planned.js', '${candidate}':'rich/${candidate}.js', react:'rich/react.jsx',\n` +
  original.slice(end));
subst(path.join(rich, 'server.mjs'), "['saba-current', 'saba-planned', 'vanilla', 'solid', 'react', 'svelte', 'htmx']", `['saba-planned','${candidate}','react']`);

// Phase timings for every drop, and DOM operation counts from one diagnostic visit
// before the measured rounds.
const measure = path.join(rich, 'measure.mjs');
subst(measure, 'async function runVisit(browser, origin, mode, profile, screenshot) {', 'async function runVisit(browser, origin, mode, profile, screenshot,diagnostic) {');
const click = '      if(selector) await page.locator(selector).click(); else await moveCard(page);';
subst(measure, click, `      if(action.type==='drop' && diagnostic) await page.evaluate(()=>{
        const original=new Map([...document.querySelectorAll('.rich-card[data-id]')].map(n=>[n.dataset.id,n]));
        const adds=[],removes=[];
        const harvest=records=>{for(const r of records) if(r.target.id?.startsWith('lane-items-')) {
          for(const n of r.addedNodes) if(n.dataset?.id) adds.push(n.dataset.id);
          for(const n of r.removedNodes) if(n.dataset?.id) removes.push(n.dataset.id);
        }};
        const observer=new MutationObserver(harvest);
        observer.observe(document.querySelector('#rich-board'),{childList:true,subtree:true});
        window.probeCounters=()=>{
          harvest(observer.takeRecords()); observer.disconnect();
          return {adds,removes,retainedCards:[...original].filter(([id,node])=>document.getElementById('card-'+id)===node).length};
        };
      });
` + click);
const presentation = '      if(presentation) steps[label].presentation=presentation;';
subst(measure, presentation, presentation + `
      if(action.type==='drop') {
        steps[label].phases=await page.evaluate(()=>window.richDashboard.probeTimes);
        if(diagnostic) steps[label].domOps=await page.evaluate(()=>window.probeCounters());
      }`);
subst(measure, '    const samples=[];', '    const samples=[], diagnostics=[];');
subst(measure, '?values.screenshot:null);', '?values.screenshot:null,round<0);');
subst(measure, '            if(round>=0)samples.push({profile,round:round+1,mode,...result});', `            if(round>=0)samples.push({profile,round:round+1,mode,...result});
            else diagnostics.push({profile,mode,counts:result.steps.drop.domOps});`);
subst(measure, 'manifest:service.manifest,hashes},summary,samples};', 'manifest:service.manifest,hashes,diagnostics},summary,samples};');

function run(command, options = {}) {
  const result = spawnSync(args.node, command, {stdio: 'inherit', ...options});
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
run([build, '--rich']);
run([measure, '--profiles', 'constrained', '--trials', String(trials), '--modes', `saba-planned,${candidate},react`, '--out', output], {cwd: scratch});
