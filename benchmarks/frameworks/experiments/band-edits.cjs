// node benchmarks/frameworks/experiments/band-edits.cjs <output.json>
'use strict';
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const {readFileSync, writeFileSync} = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {chromium} = require(process.env.PLAYWRIGHT_PATH || 'playwright');

const fixture = readFileSync(path.join(__dirname, '../rich/scale.html'), 'utf8');
const renderer = readFileSync(path.join(__dirname, 'text-band.js'), 'utf8');
const scale = readFileSync(path.join(__dirname, '../rich/scale.js'), 'utf8');
const fixed = readFileSync(path.join(__dirname, 'fixed-cell.js'), 'utf8');
function replaceOnce(source, old, next) {
  assert.equal(source.split(old).length, 2, 'Fixture changed: ' + old);
  return source.replace(old, next);
}
// Use the scale fixture's band unchanged and export its ordinary mount entry.
const scaleBranch = "if (mode === 'saba-planned')";
const fixedBand = replaceOnce(scale, scaleBranch, `if (mode === 'saba-fixed-input-attr') {
  ({mountCell} = await import('/fixed-cell-attr.js'));
} else ` + scaleBranch) + '\nexport {mountBand};\n';
const fixedCell = replaceOnce(fixed, 'this.node.dataset.id = String(record.id);',
  "this.node.setAttribute('data-id', String(record.id));");
const settings = {cells: 4096, warmups: 12, blocks: 6, stepsPerBlock: 6};
const modes = ['mountTextBand', 'mountDomBand', 'saba-fixed-input-attr'];
const orders = [[0,1,2], [1,2,0], [2,0,1], [2,1,0], [1,0,2], [0,2,1]];
const strides = [97, 1];
const sha = text => createHash('sha256').update(text).digest('hex');

async function measure({mode, stride, cells, warmups, blocks, stepsPerBlock}) {
  const mount = mode === 'saba-fixed-input-attr'
    ? (await import('/scale.js')).mountBand
    : (await import('/text-band.js'))[mode];
  const host = document.createElement('div');
  host.className = 'band';
  document.querySelector('#space').append(host);
  const initial = Array.from({length: cells}, (_, id) => ({id, group: id % 23, score: id % 1000}));
  const rows = [initial];
  const steps = warmups + blocks * stepsPerBlock;
  let timedWrites = 0;
  for (let step = 0; step <= steps; step++) {
    const next = rows[step].slice();
    for (let id = step % stride; id < cells; id += stride) {
      const old = next[id];
      next[id] = {id, group: old.group, score: old.score + 1};
      if (step >= warmups && step < steps) timedWrites++;
    }
    rows.push(next);
  }
  const band = mount(host, initial);
  const layout = () => host.lastElementChild.getBoundingClientRect().height;
  if (layout() !== 26) throw Error('Band was not laid out');
  let current = 0;
  while (current < warmups) band.replace(rows[++current]);
  const blockMs = [];
  for (let block = 0; block < blocks; block++) {
    layout();
    const end = current + stepsPerBlock;
    const begin = performance.now();
    while (current < end) band.replace(rows[++current]);
    blockMs.push(performance.now() - begin);
  }
  // Acquire validation references only after timing, so the DOM-lookup arm
  // need not retain Text wrappers for this assertion during measurement.
  const nodes = Array.from(host.children);
  const texts = nodes.map(node => node.firstChild);
  function verify(snapshot) {
    if (host.childNodes.length !== cells) throw Error('Incorrect cell count');
    for (let id = 0; id < cells; id++) {
      const node = host.children[id];
      if (node !== nodes[id] || !node.isConnected || node.getAttribute('data-id') !== String(id) ||
        node.childNodes.length !== 1 || node.firstChild !== texts[id] ||
        node.firstChild.nodeType !== Node.TEXT_NODE || node.firstChild.data !== id + ' · ' + snapshot[id].score) {
        throw Error('Incorrect cell for ' + mode + ' at ' + id);
      }
    }
  }
  verify(rows[current]);
  const expected = new Set();
  for (let id = current % stride; id < cells; id += stride) expected.add(texts[id]);
  const observer = new MutationObserver(() => {});
  observer.observe(host, {subtree: true, childList: true, characterData: true});
  band.replace(rows[++current]);
  const changes = observer.takeRecords();
  observer.disconnect();
  for (const change of changes) {
    if (change.type !== 'characterData' || !expected.delete(change.target)) throw Error('Unexpected DOM write');
  }
  if (expected.size) throw Error('Missing DOM writes');
  verify(rows[current]);
  band.dispose();
  if (host.firstChild) throw Error('Band disposal left cells');
  return {blockMs, msPerReplace: blockMs.reduce((sum, value) => sum + value, 0) / (blocks * stepsPerBlock),
    timedWrites, verifiedCells: cells, verificationWrites: changes.length};
}

async function visit(browser, input) {
  const page = await browser.newPage({viewport: {width: 1200, height: 900}});
  try {
    const origin = 'http://127.0.0.1:43191';
    await page.route(origin + '/**', route => {
      const pathname = new URL(route.request().url()).pathname;
      if (pathname === '/') return route.fulfill({contentType: 'text/html', body: fixture,
        headers: {'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp'}});
      if (pathname === '/scale.js') return route.fulfill({contentType: 'text/javascript', body: fixedBand});
      if (pathname === '/fixed-cell-attr.js') return route.fulfill({contentType: 'text/javascript', body: fixedCell});
      if (pathname === '/text-band.js') return route.fulfill({contentType: 'text/javascript', body: renderer});
      return route.abort();
    });
    await page.goto(origin + '/?mode=saba-fixed-input-attr');
    return await page.evaluate(measure, input);
  } finally {
    await page.close();
  }
}

async function main() {
  assert.ok(process.argv[2], 'Provide an output JSON path');
  const browser = await chromium.launch({channel: 'chromium'});
  try {
    const report = {chromium: browser.version(), cpu: os.cpus()[0].model, settings,
      sourceSha256: {fixture: sha(fixture), renderer: sha(renderer), fixedBand: sha(fixedBand),
        fixedCell: sha(fixedCell), driver: sha(readFileSync(__filename))},
      method: 'One fresh page and context per variant and density visit, in the same serial browser. Six rounds cover all six variant orders per density. Each precomputed snapshot shares unchanged records and replaces affected records. Rotate the first edited ID modulo stride. Time blocks of synchronous replace calls after warm-up, each preceded by forced layout. Verify visible text and DOM identity outside timing. Values exclude presentation.',
      visits: []};
    for (let round = 0; round < 6; round++) {
      const densityOrder = round % 2 ? [...strides].reverse() : strides;
      for (const stride of densityOrder) {
        const order = orders[(round + strides.indexOf(stride) * 3) % orders.length];
        for (const index of order) {
          const mode = modes[index];
          const result = await visit(browser, {mode, stride, ...settings});
          report.visits.push({trial: round + 1, stride, mode, ...result});
        }
      }
    }
    writeFileSync(process.argv[2], JSON.stringify(report, null, 2) + '\n');
    console.log(report.visits.length + ' verified visits');
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
