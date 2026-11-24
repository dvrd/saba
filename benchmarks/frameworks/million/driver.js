const params = new URLSearchParams(location.search);
const count = Number(params.get('count'));
const reps = Number(params.get('reps'));
const arm = params.get('arm');

function rowsOf(size, flip) {
  const rows = new Array(size);
  for (let i = 0; i < size; i++) rows[i] = { id: i, on: ((i & 1) === 0) !== flip };
  return rows;
}

function sparse(rows, step) {
  const next = rows.slice();
  for (let i = step % 97; i < rows.length; i += 97) {
    const row = next[i];
    next[i] = { id: row.id, on: !row.on };
  }
  return next;
}

function dense(rows) {
  const next = new Array(rows.length);
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    next[i] = { id: row.id, on: !row.on };
  }
  return next;
}

function chain(records, apply) {
  const steps = [];
  let current = records;
  for (let step = 0; step < reps; step++) {
    current = apply(current, step);
    steps.push(current);
  }
  return { steps, records: current };
}

const initial = rowsOf(count, false);
const sparseRun = chain(initial, sparse);
const denseRun = chain(sparseRun.records, dense);

function time(steps, replace) {
  const start = performance.now();
  for (let i = 0; i < steps.length; i++) replace(steps[i]);
  return (performance.now() - start) / steps.length;
}

function assertView(host, records, first) {
  if (host.childElementCount !== records.length) {
    throw new Error('count ' + host.childElementCount);
  }
  if (host.firstElementChild !== first) throw new Error('checkbox node was replaced');
  const indexes = [0, 1, 96, 97, records.length - 1];
  for (let n = 0; n < indexes.length; n++) {
    const i = indexes[n];
    const element = host.children[i];
    if (element.type !== 'checkbox') throw new Error('not a checkbox at ' + i);
    if (element.checked !== records[i].on) throw new Error('checked at ' + i);
    if (element.getAttribute('data-id') !== String(records[i].id)) throw new Error('id at ' + i);
  }
}

const host = document.querySelector('#host');
try {
  const importStarted = performance.now();
  const implementation = await import('/arms/' + arm + '.js');
  const evalMs = performance.now() - importStarted;
  host.replaceChildren();
  const mountStarted = performance.now();
  const band = implementation.mountBand(host, initial);
  const mountMs = performance.now() - mountStarted;
  const first = host.firstElementChild;
  const sparseMs = time(sparseRun.steps, band.replace);
  const denseMs = time(denseRun.steps, band.replace);
  assertView(host, denseRun.records, first);
  band.dispose();
  if (host.childElementCount !== 0) throw new Error('dispose left ' + host.childElementCount);
  window.__million = { arm, count, reps, evalMs, mountMs, sparseMs, denseMs, elements: count };
} catch (error) {
  window.__million = { arm, count, error: String(error && error.stack || error) };
}
document.documentElement.dataset.done = '1';
