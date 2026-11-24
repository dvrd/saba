const query = new URLSearchParams(location.search);
const arm = query.get('arm');
const listSize = numberParam('list', 2048);
const windowSize = numberParam('window', 256);
const warmup = numberParam('warmup', 6);
let reps = numberParam('reps', 12);
if (reps % 2) reps += 1;
const far = 100000;
const shiftBy = 32;

function numberParam(name, fallback) {
  const value = Number(query.get(name));
  return Number.isInteger(value) && value > 0 ? value : fallback;
}

function textOf(record) {
  return record.id + ' · ' + record.score;
}

function fail(message) {
  throw new Error(message);
}

function elementMap(host) {
  const map = new Map();
  for (const element of host.children) map.set(element.getAttribute('data-id'), element);
  return map;
}

function assertView(host, records) {
  const elements = host.children;
  if (elements.length !== records.length) fail('row count ' + elements.length + ' wanted ' + records.length);
  for (let i = 0; i < records.length; i++) {
    const element = elements[i];
    const record = records[i];
    if (element.getAttribute('data-id') !== String(record.id)) fail('id at ' + i);
    if (element.childNodes.length !== 1 || element.firstChild.nodeType !== Node.TEXT_NODE ||
        element.firstChild.data !== textOf(record)) {
      fail('text at ' + i + ': ' + element.textContent);
    }
  }
}

function preserved(before, records, host) {
  const after = elementMap(host);
  let present = 0;
  let kept = 0;
  for (let i = 0; i < records.length; i++) {
    const previous = before.get(String(records[i].id));
    if (!previous) continue;
    present++;
    if (after.get(String(records[i].id)) === previous) kept++;
  }
  return { present, kept };
}

function commentCount(host) {
  let count = 0;
  const walker = document.createTreeWalker(host, NodeFilter.SHOW_COMMENT);
  while (walker.nextNode()) count++;
  return count;
}

function observe(host, fn) {
  let attributes = 0;
  let characterData = 0;
  let added = 0;
  let removed = 0;
  const observer = new MutationObserver(() => {});
  observer.observe(host, { subtree: true, attributes: true, characterData: true, childList: true });
  fn();
  for (const record of observer.takeRecords()) {
    if (record.type === 'attributes') attributes++;
    else if (record.type === 'characterData') characterData++;
    else {
      added += record.addedNodes.length;
      removed += record.removedNodes.length;
    }
  }
  observer.disconnect();
  return { attributes, characterData, added, removed };
}

function time(steps, replace) {
  const start = performance.now();
  for (let i = 0; i < steps.length; i++) {
    const step = steps[i];
    replace(step.records, step.first);
  }
  return (performance.now() - start) / steps.length;
}

function chain(records, count, apply) {
  const steps = [];
  let current = records;
  for (let i = 0; i < count; i++) {
    current = apply(current, i);
    steps.push({ records: current });
  }
  return { steps, records: current };
}

function sparse(records, step) {
  const next = records.slice();
  for (let i = step % 97; i < records.length; i += 97) {
    const record = next[i];
    next[i] = { id: record.id, score: record.score + 1 };
  }
  return next;
}

function dense(records) {
  const next = new Array(records.length);
  for (let i = 0; i < records.length; i++) {
    const record = records[i];
    next[i] = { id: record.id, score: record.score + 1 };
  }
  return next;
}

function reversed(records) {
  const next = records.slice();
  next.reverse();
  return next;
}

function rotated(records) {
  if (!records.length) return records;
  const next = records.slice(1);
  next.push(records[0]);
  return next;
}

function spliced(records, step) {
  const removeAt = Math.floor(records.length * 0.05);
  const without = records.slice(0, removeAt).concat(records.slice(removeAt + 1));
  const created = { id: 1_000_000 + step, score: step };
  const insertAt = Math.min(Math.floor(records.length * 0.2), without.length);
  return without.slice(0, insertAt).concat([created], without.slice(insertAt));
}

const pool = new Map();
function stored(id) {
  let record = pool.get(id);
  if (!record) pool.set(id, record = { id, score: id % 1000 });
  return record;
}

function windowRecords(first, count) {
  const records = new Array(count);
  for (let i = 0; i < count; i++) records[i] = stored(first + i);
  return records;
}

function listRecords(count) {
  const records = new Array(count);
  for (let id = 0; id < count; id++) records[id] = { id, score: id % 1000 };
  return records;
}

function sameOrder(before, host) {
  const after = host.children;
  if (before.length !== after.length) return false;
  for (let i = 0; i < before.length; i++) if (before[i] !== after[i]) return false;
  return true;
}

function sameSet(before, host) {
  if (before.length !== host.childElementCount) return false;
  const seen = new Set(host.children);
  for (let i = 0; i < before.length; i++) if (!seen.has(before[i])) return false;
  return true;
}

function report(error) {
  window.__fair = { arm, error: String(error && error.stack || error) };
  document.documentElement.dataset.done = '1';
}
addEventListener('error', event => report(event.error || event.message));
addEventListener('unhandledrejection', event => report(event.reason));

const importStarted = performance.now();
const implementation = await import('/arms/' + arm + '.js');
const evalMs = performance.now() - importStarted;
const kind = implementation.kind;
const host = document.querySelector('#host');

function mount(records, first) {
  host.replaceChildren();
  const started = performance.now();
  const band = implementation.mountBand(host, records, first);
  return { band, ms: performance.now() - started };
}

function finish(band) {
  band.dispose();
  const leftover = host.childNodes.length;
  host.replaceChildren();
  return leftover;
}

let rows = listRecords(listSize);
const mounted = mount(rows, 0);
if (globalThis.gc) {
  gc();
  gc();
}
const heapBytes = performance.memory ? performance.memory.usedJSHeapSize : null;
const layoutStarted = performance.now();
host.getBoundingClientRect();
const layoutMs = performance.now() - layoutStarted;
const markers = commentCount(host);
assertView(host, rows);

const warm = chain(rows, warmup, sparse);
for (const step of warm.steps) mounted.band.replace(step.records);
rows = warm.records;
assertView(host, rows);
const identity = elementMap(host);

const sparseRun = chain(rows, reps, sparse);
const sparseMs = time(sparseRun.steps, mounted.band.replace);
rows = sparseRun.records;
assertView(host, rows);
const sparseKept = preserved(identity, rows, host);
if (kind === 'keyed' && sparseKept.kept !== sparseKept.present) fail('sparse lost a keyed node');

const denseRun = chain(rows, reps, dense);
const denseMs = time(denseRun.steps, mounted.band.replace);
rows = denseRun.records;
assertView(host, rows);
const denseKept = preserved(identity, rows, host);
if (kind === 'keyed' && denseKept.kept !== denseKept.present) fail('dense lost a keyed node');

const orderBeforeReverse = [...host.children];
const reverseRun = chain(rows, reps, reversed);
const reverseMs = time(reverseRun.steps, mounted.band.replace);
rows = reverseRun.records;
assertView(host, rows);
const reverseKept = preserved(identity, rows, host);
if (kind === 'keyed' && reverseKept.kept !== reverseKept.present) fail('reverse lost a keyed node');
if (kind === 'slot' && !sameOrder(orderBeforeReverse, host)) fail('slot reverse moved elements');

const rotateRun = chain(rows, reps, rotated);
const rotateMs = time(rotateRun.steps, mounted.band.replace);
rows = rotateRun.records;
assertView(host, rows);
const rotateKept = preserved(identity, rows, host);
if (kind === 'keyed' && rotateKept.kept !== rotateKept.present) fail('rotate lost a keyed node');

const spliceRun = chain(rows, reps, spliced);
const spliceMs = time(spliceRun.steps, mounted.band.replace);
rows = spliceRun.records;
assertView(host, rows);
const spliceKept = preserved(identity, rows, host);

const listMutations = {
  sparse: observe(host, () => mounted.band.replace(sparse(rows, 0))),
  reverse: observe(host, () => mounted.band.replace(reversed(rows))),
};
const listLeftover = finish(mounted.band);

const initialWindow = windowRecords(0, windowSize);
const windowed = mount(initialWindow, 0);
assertView(host, initialWindow);
const windowNodes = [...host.children];
windowed.band.replace(windowRecords(far, windowSize), far);
windowed.band.replace(initialWindow, 0);
assertView(host, initialWindow);

const jumpSteps = [];
for (let i = 0; i < reps; i++) {
  const first = i % 2 === 0 ? far : 0;
  jumpSteps.push({ records: windowRecords(first, windowSize), first });
}
const jumpMs = time(jumpSteps, windowed.band.replace);
assertView(host, initialWindow);
const jumpReusedAll = sameOrder(windowNodes, host);
if (kind === 'slot' && !jumpReusedAll) fail('slot jump rebuilt elements');
if (kind === 'keyed' && jumpReusedAll) fail('keyed jump reused every element');

const shiftSteps = [];
for (let i = 0; i < reps; i++) {
  const first = i % 2 === 0 ? shiftBy : 0;
  shiftSteps.push({ records: windowRecords(first, windowSize), first });
}
const shiftMs = time(shiftSteps, windowed.band.replace);
assertView(host, initialWindow);
const shiftReusedAll = sameSet(windowNodes, host);
if (kind === 'slot' && !shiftReusedAll) fail('slot shift rebuilt elements');
if (kind === 'slot' && !sameOrder(windowNodes, host)) fail('slot shift did not restore order');

const windowMutations = {
  jump: observe(host, () => windowed.band.replace(windowRecords(far, windowSize), far)),
  shift: observe(host, () => {
    windowed.band.replace(initialWindow, 0);
    windowed.band.replace(windowRecords(shiftBy, windowSize), shiftBy);
  }),
};
const windowLeftover = finish(windowed.band);

window.__fair = {
  arm,
  kind,
  listSize,
  windowSize,
  warmup,
  reps,
  evalMs,
  mountMs: mounted.ms,
  layoutMs,
  heapBytes,
  markers,
  elements: listSize,
  sparseMs,
  denseMs,
  reverseMs,
  rotateMs,
  spliceMs,
  sparseKept: sparseKept.kept / sparseKept.present,
  denseKept: denseKept.kept / denseKept.present,
  reverseKept: reverseKept.kept / reverseKept.present,
  rotateKept: rotateKept.kept / rotateKept.present,
  spliceKept: spliceKept.present ? spliceKept.kept / spliceKept.present : 1,
  listMutations,
  listLeftover,
  windowMountMs: windowed.ms,
  jumpMs,
  shiftMs,
  jumpReusedAll,
  shiftReusedAll,
  windowMutations,
  windowLeftover,
};
document.documentElement.dataset.done = '1';
