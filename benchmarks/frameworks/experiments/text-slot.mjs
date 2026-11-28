// Run from a checkout with the scale bundles built (node benchmarks/frameworks/build.mjs --scale).
// Test the compiler's guaranteed-single-text-node case against the existing scale fixture.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const out = path.resolve(process.argv[2] || 'docs/benchmarks/text-slot.json');
const count = Number(process.argv[3] || 1_000_000);
const rounds = Number(process.argv[4] || 3);
const bandProfile = process.argv[5] === '--profile-band';
const attributeProfile = process.argv[5] === '--profile-attribute' || bandProfile;
const bindingProfile = process.argv[5] === '--profile-binding' || attributeProfile;
assert.ok(!process.argv[5] || bindingProfile);
assert.ok(Number.isInteger(count) && count >= 256 && count <= 1_000_000);
assert.ok(Number.isInteger(rounds) && rounds >= 1 && rounds <= 30);
const bench = 'benchmarks/frameworks';
const rich = bench+'/rich';
const temp = await mkdtemp(path.join(os.tmpdir(),'saba-text-slot-'));
function replaceOnce(source, needle, value) {
  assert.equal(source.split(needle).length,2,'Fixture changed: '+needle);
  return source.replace(needle,value);
}
try {
  // Copy only the benchmark sources and the already-verified scale bundles.
  const files = [rich, bench+'/build.mjs',bench+'/package-lock.json',bench+'/dist/scale','src/modules/dom.js'];
  for (const file of files) {
    const dst = path.join(temp,file);
    await mkdir(path.dirname(dst),{recursive:true});
    await cp(path.join(root,file),dst,{recursive:true});
  }
  const app = path.join(temp,rich,'scale.js');
  let code = await readFile(app,'utf8');
  code = replaceOnce(code,"if (mode === 'saba-planned')", "if (mode === 'saba-planned' || mode === 'saba-text-slot')");
  const original = "node.append(document.createComment('value'),label,document.createComment('/value'));";
  code = replaceOnce(code,original,
    "if (mode === 'saba-text-slot') node.append(label);\n    else "+original);
  if (bindingProfile) {
    await cp(new URL('./fixed-cell.js',import.meta.url), path.join(temp,rich,'fixed-cell.js'));
    code = replaceOnce(code,"} else if (mode === 'saba-current') {",` } else if (mode === 'saba-fixed-input') {
  ({mountCell} = await import('./fixed-cell.js'));
} else if (mode === 'saba-current') {`);
    if (attributeProfile) {
      const fixedCell = await readFile(new URL('./fixed-cell.js',import.meta.url),'utf8');
      await writeFile(path.join(temp,rich,'fixed-cell-attr.js'),replaceOnce(fixedCell,
        'this.node.dataset.id = String(record.id);', "this.node.setAttribute('data-id', String(record.id));"));
      code = replaceOnce(code,"} else if (mode === 'saba-fixed-input') {",` } else if (mode === 'saba-fixed-input-attr') {
  ({mountCell} = await import('./fixed-cell-attr.js'));
} else if (mode === 'saba-fixed-input') {`);
    }
    if (bandProfile) {
      await cp(new URL('./text-band.js',import.meta.url), path.join(temp,rich,'text-band.js'));
      code = replaceOnce(code,"} else if (mode === 'saba-fixed-input-attr') {",`} else if (mode === 'saba-band-text' || mode === 'saba-band-dom') {
  const band = await import('./text-band.js');
  mountBand = mode === 'saba-band-text' ? band.mountTextBand : band.mountDomBand;
} else if (mode === 'saba-fixed-input-attr') {`);
    }
    code = replaceOnce(code,'const starts = {};','const starts = {};\nconst mountStages = {bandBuildMs:0,attachLayoutMs:0};');
    code = replaceOnce(code,'  const renderer = mountBand(band,records.slice(start,end));',`  const began = performance.now();
  const renderer = mountBand(band,records.slice(start,end));
  const built = performance.now();
  mountStages.bandBuildMs += built - began;`);
    code = replaceOnce(code,'  const box = node.getBoundingClientRect();','  const box = node.getBoundingClientRect();\n  mountStages.attachLayoutMs += performance.now() - built;');
    code = replaceOnce(code,'window.scale = {start,','window.scale = {mountStages,start,');
  }
  // Record stage boundaries without traversing the DOM inside the click handler.
  code = replaceOnce(code,"marker('mutate','Sampled scores updated');","marker('mutate','Sampled scores updated');\n  starts.updateDomReady = performance.now();");
  code = replaceOnce(code,"marker('jump','Final row');","starts.scrollHandled = performance.now();\n    marker('jump','Final row');");
  await writeFile(app,code);

  const driver = path.join(temp,rich,'scale-run.cjs');
  let js = await readFile(driver,'utf8');
  js = replaceOnce(js,"'saba-planned',...compiledModes","'saba-planned','saba-text-slot',...compiledModes");
  js = replaceOnce(js,"const repetitions = scenario === 'capacity' ? 1 : options.trials;","const repetitions = options.trials;");
  js = replaceOnce(js,'fullCapacityTrials:1','fullCapacityTrials:options.trials');
  if (bindingProfile) {
    js = replaceOnce(js,"'saba-text-slot',...compiledModes","'saba-text-slot','saba-fixed-input',...compiledModes");
    js = replaceOnce(js,"const assets = new Map([","const assets = new Map([\n  ['/fixed-cell.js','benchmarks/frameworks/rich/fixed-cell.js'],");
    js = replaceOnce(js,'result.mountPaintMs = await checkpoint();',`result.mountPaintMs = await checkpoint();
      result.mountStages = await page.evaluate(() => window.scale.mountStages);
      result.postMountRssMiB = await rssMiB(pids);`);
    js = replaceOnce(js,'Planned Saba adds two binding comments.','Both Saba variants and React use a single text child. Fixed input uses a shared update method. No garbage collection is forced.');
    if (attributeProfile) {
      js = replaceOnce(js,"'saba-fixed-input',...compiledModes","'saba-fixed-input','saba-fixed-input-attr',...compiledModes");
      js = replaceOnce(js,"const assets = new Map([","const assets = new Map([\n  ['/fixed-cell-attr.js','benchmarks/frameworks/rich/fixed-cell-attr.js'],");
      js = replaceOnce(js,'Fixed input uses a shared update method.','Both fixed-input variants use the same shared update method. Only the data-id setter differs.');
    }
    if (bandProfile) {
      js = replaceOnce(js,"'saba-fixed-input-attr',...compiledModes","'saba-fixed-input-attr','saba-band-text','saba-band-dom',...compiledModes");
      js = replaceOnce(js,"const assets = new Map([","const assets = new Map([\n  ['/text-band.js','benchmarks/frameworks/rich/text-band.js'],");
      js = replaceOnce(js,'Full mode mounts one component and visible element per record','Full mode connects a cell element per record');
      js = replaceOnce(js,'Both Saba variants and React use a single text child. Both fixed-input variants use the same shared update method. Only the data-id setter differs.',
        'Every cell has one text child. The fixed-input control keeps a class instance per cell. The two band variants retain either a dense array of text nodes or retrieve changed nodes from the host. All Saba arms use setAttribute.');
    }
  }
  js = replaceOnce(js,'assert.equal(result.lastId,count-1);',`assert.equal(result.lastId,count-1);
      const inspection = await page.evaluate(() => {
        const elements = [...document.querySelectorAll('.band')];
        return {
          updateDomMs:window.scale.starts.updateDomReady-window.scale.starts.mutate,
          seekToScrollMs:window.scale.starts.scrollHandled-window.scale.starts.jump,
          // Check a cell at each end of every band outside the timing windows.
          edges:elements.flatMap(b=>[b.firstElementChild,b.lastElementChild]).map(n=>({
            id:Number(n.dataset.id), types:Array.from(n.childNodes,c=>c.nodeType),
            text:n.textContent,
          })),
        };
      });
      for(const edge of inspection.edges) {
        const score=(edge.id*37 + (edge.id%23)*13)%1000 + (edge.id%97===0 || edge.id===count-1 ? 7 : 0);
        assert.equal(edge.text,edge.id+' · '+score);
        assert.deepEqual(edge.types,mode==='saba-planned'?[8,3,8]:[3]);
      }
      result.verifiedBandEdges=inspection.edges.length;
      result.updateDomMs=inspection.updateDomMs;
      result.seekToScrollMs=inspection.seekToScrollMs;`);
  await writeFile(driver,js);
  let comparison = 'saba-planned,saba-text-slot,react';
  if (bindingProfile) comparison = 'saba-text-slot,saba-fixed-input,react';
  if (attributeProfile) comparison = 'saba-fixed-input,saba-fixed-input-attr,react';
  if (bandProfile) comparison = 'saba-fixed-input-attr,saba-band-text,saba-band-dom,react';
  execFileSync(process.execPath,[driver,'--scenarios','capacity','--modes',comparison,
    '--trials',String(rounds),'--count',String(count),'--rss-mib','6144','--old-space-mib','3072','--seconds','150','--out',out],
    {cwd:temp,stdio:'inherit'});
} finally {
  await rm(temp,{recursive:true,force:true});
}
