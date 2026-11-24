#!/usr/bin/env python3
"""Rebuild and run the three-arm dashboard drag probe using this checkout's fixtures.
Run from the repository root after installing benchmarks/frameworks/package-lock.json.
PLAYWRIGHT_PATH can select a Playwright installation with Chromium.
"""
import argparse
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo',type=Path,default=Path.cwd())
parser.add_argument('--trials',type=int,default=12)
parser.add_argument('--out',type=Path,default=Path('saba-drag-ab.json'))
parser.add_argument('--node',default=os.environ.get('SABA_BENCH_NODE','node'))
parser.add_argument('--strategy',choices=('hint','snapshot'),default='hint')
args=parser.parse_args()
root=args.repo.resolve()
output=args.out.resolve()
if not (root/'benchmarks/frameworks/node_modules').is_dir():
    parser.error('Install benchmarks/frameworks dependencies with npm ci before running the experiment')
if args.trials < 6 or args.trials % 6:
    parser.error('Use a positive multiple of six rounds to balance all orders')

workspace=tempfile.TemporaryDirectory(prefix='saba-drag-ab-')
scratch=Path(workspace.name)
dirs=Path('benchmarks/frameworks');framework=scratch/dirs;source=root/dirs
fw=framework/'rich';fw.mkdir(parents=True)
(scratch/'src').symlink_to(root/'src',target_is_directory=True)
(framework/'node_modules').symlink_to(source/'node_modules',target_is_directory=True)
for n in ('package.json','package-lock.json','build.mjs'):shutil.copy(source/n,framework/n)
for f in (source/'rich').iterdir():
 if f.is_file():shutil.copy(f,fw/f.name)
def subst(p,old,new):
 s=p.read_text(); assert s.count(old)==1, (p,old,s.count(old));p.write_text(s.replace(old,new,1))
sub=fw/'dashboard.js'
subst(sub,"        const before = action.type === 'drop' ? visiblePositions(host) : null;","""        const times = action.type === 'drop' ? {event:eventTime,dispatch:performance.now()} : null;
        const before = times ? visiblePositions(host) : null;
        if (times) times.beforeLayoutDone=performance.now();""")
subst(sub,"        await update(boardSnapshot(next), action);","""        const model=boardSnapshot(next);
        if(times) times.modelDone=performance.now();
        await update(model, action);
        if(times) times.renderDone=performance.now();""")
subst(sub,"        const animation = before && animateReorder(before, visiblePositions(host), action.id, pointerMoves);","""        const after = before && visiblePositions(host);
        if(times) times.afterLayoutDone=performance.now();
        const animation = before && animateReorder(before, after, action.id, pointerMoves);
        if(times) {
          times.animateSetupDone=performance.now();
          lifecycle.probeTimes=times;
        }""")
if args.strategy=='hint':
    candidate='saba-hinted'
    keys=fw/'saba-keys-hinted.js';shutil.copy(fw/'saba-keys.js',keys)
    subst(keys,'return (lanes, selected) => {',"""return (lanes, selected, move) => {
    // Move the retained key to its destination before reconciling the full snapshot.
    // The normal reconciler still handles filters, new/removed keys and other edits.
    if (move?.type === 'drop') {
      const view=previous.get(move.id), list=lists[move.lane];
      const before=move.before===null ? null : previous.get(move.before)?.node;
      if (view && list && (before===null || before?.parentNode===list) &&
          (view.node.parentNode!==list || view.node.nextElementSibling!==before)) {
        list.insertBefore(view.node,before);
      }
    }""")
    lab=fw/'saba-hinted.js';shutil.copy(fw/'saba-planned.js',lab)
    subst(lab,"from './saba-keys.js'","from './saba-keys-hinted.js'")
    subst(lab,"  effect(() => updateChrome(snapshot.read()));","  let hint;\n  effect(() => updateChrome(snapshot.read()));")
    subst(lab,"    updateCards(next.lanes, next.selected);","    updateCards(next.lanes, next.selected, hint);")
    subst(lab,"  return next => snapshot.write(next);","""  return (next, action) => {
    hint=action;
    try { snapshot.write(next); } finally { hint=null; }
  };""")

else:
    candidate='saba-snapshot'
    keys=fw/'saba-keys-snapshot.js'
    shutil.copy(fw/'saba-keys.js',keys)
    subst(keys, '    const retained = new Map();', '    const retained = new Map();\n    let nextParents;')
    subst(keys, '        if (cursor !== view.node', '''        // A sibling leaving this list cannot anchor the retained siblings behind it.
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
        if (cursor !== view.node''')
    lab=fw/'saba-snapshot.js'
    shutil.copy(fw/'saba-planned.js',lab)
    subst(lab,"from './saba-keys.js'","from './saba-keys-snapshot.js'")
sub=framework/'build.mjs';old=sub.read_text()
i=old.index('} : rich ? {')+len('} : rich ? {')
j=old.index('} : {',i)
sub.write_text(old[:i]+f"\n  'saba-planned':'rich/saba-planned.js', '{candidate}':'rich/{candidate}.js', react:'rich/react.jsx',\n"+old[j:])
subst(fw/'server.mjs',"['saba-current', 'saba-planned', 'vanilla', 'solid', 'react', 'svelte', 'htmx']",f"['saba-planned','{candidate}','react']")
measure=fw/'measure.mjs'
subst(measure,'async function runVisit(browser, origin, mode, profile, screenshot) {','async function runVisit(browser, origin, mode, profile, screenshot,diagnostic) {')
needle="      if(selector) await page.locator(selector).click(); else await moveCard(page);"
subst(measure,needle,"""      if(action.type==='drop' && diagnostic) await page.evaluate(()=>{
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
"""+needle)
needle='      if(presentation) steps[label].presentation=presentation;'
subst(measure,needle,needle+"""
      if(action.type==='drop') {
        steps[label].phases=await page.evaluate(()=>window.richDashboard.probeTimes);
        if(diagnostic) steps[label].domOps=await page.evaluate(()=>window.probeCounters());
      }""")
subst(measure,"    const samples=[];","    const samples=[], diagnostics=[];")
subst(measure,"?values.screenshot:null);","?values.screenshot:null,round<0);")
subst(measure,"            if(round>=0)samples.push({profile,round:round+1,mode,...result});","            if(round>=0)samples.push({profile,round:round+1,mode,...result});\n            else diagnostics.push({profile,mode,counts:result.steps.drop.domOps});")
subst(measure,"manifest:service.manifest,hashes},summary,samples};","manifest:service.manifest,hashes,diagnostics},summary,samples};")
subprocess.run([args.node, str(framework/'build.mjs'), '--rich'], check=True)
subprocess.run([
    args.node, str(fw/'measure.mjs'), '--profiles', 'constrained', '--trials', str(args.trials),
    '--modes', f'saba-planned,{candidate},react', '--out', str(output),
], cwd=scratch, check=True)
