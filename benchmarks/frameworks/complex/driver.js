const params = new URLSearchParams(location.search);
const scenario = params.get('scenario');
const count = Number(params.get('count'));
const reps = Number(params.get('reps'));
const arm = params.get('arm');
const pixel = 'data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA=';
const pixelNext = 'data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAE=';
const clip = 'data:video/mp4;base64,AAAA';
const clipNext = 'data:video/mp4;base64,AAA=';

function list(size, make) {
  const rows = new Array(size);
  for (let id = 0; id < size; id++) rows[id] = make(id);
  return rows;
}

function chain(records, apply) {
  const steps = [];
  let current = records;
  for (let step = 0; step < reps; step++) {
    const next = new Array(current.length);
    for (let i = 0; i < current.length; i++) next[i] = apply(current[i], i, step);
    steps.push(next);
    current = next;
  }
  return { steps, records: current };
}

function reverseSteps(records) {
  const steps = [];
  let current = records;
  for (let step = 0; step < reps; step++) {
    current = current.slice().reverse();
    steps.push(current);
  }
  return { steps, records: current };
}

const specs = {
  attrs: {
    make: (id) => ({ id, score: id % 1000, label: 'Item ' + id }),
    sparse: (row, i, step) => (i % 97 === step % 97 ? { ...row, score: row.score + 1 } : row),
    dense: (row) => ({ ...row, score: row.score + 1 }),
    check(element, row) {
      if (element.getAttribute('data-id') !== String(row.id)) throw new Error('id');
      if (element.getAttribute('data-key') !== String(row.id)) throw new Error('key');
      if (element.getAttribute('data-score') !== String(row.score)) throw new Error('score');
      const text = row.label + ' · ' + row.score;
      if (element.getAttribute('title') !== text) throw new Error('title');
      if (element.textContent !== text) throw new Error('text');
    },
  },
  images: {
    make: (id) => ({ id, label: 'Photo ' + id, src: pixel }),
    sparse: (row, i, step) => (i % 97 === step % 97 ? { ...row, src: pixelNext } : row),
    dense: (row) => ({ ...row, src: row.src === pixel ? pixelNext : pixel }),
    check(element, row) {
      if (element.tagName !== 'IMG') throw new Error('img');
      if (element.getAttribute('src') !== row.src && element.src !== row.src) throw new Error('src');
      if (element.alt !== row.label && element.getAttribute('alt') !== row.label) throw new Error('alt');
      if (element.getAttribute('data-id') !== String(row.id)) throw new Error('id');
    },
  },
  videos: {
    make: (id) => ({ id, src: clip }),
    sparse: (row, i, step) => (i % 97 === step % 97 ? { ...row, src: clipNext } : row),
    dense: (row) => ({ ...row, src: row.src === clip ? clipNext : clip }),
    check(element, row) {
      if (element.tagName !== 'VIDEO') throw new Error('video');
      if (element.getAttribute('src') !== row.src && element.src !== row.src) throw new Error('src');
      if (element.preload !== 'none' && element.getAttribute('preload') !== 'none') throw new Error('preload');
      if (element.getAttribute('data-id') !== String(row.id)) throw new Error('id');
    },
  },
  nested: {
    make: (id) => ({ id, label: 'Card ' + id, score: id % 1000, src: pixel, on: (id & 1) === 0 }),
    sparse: (row, i, step) => (i % 97 === step % 97 ? { ...row, score: row.score + 1, on: !row.on } : row),
    dense: (row) => ({ ...row, score: row.score + 1, on: !row.on }),
    check(element, row) {
      if (element.getAttribute('data-id') !== String(row.id)) throw new Error('id');
      const image = element.children[0];
      const span = element.children[1];
      const box = element.children[2];
      if (image.getAttribute('src') !== row.src && image.src !== row.src) throw new Error('src');
      if (span.textContent !== row.label + ' · ' + row.score) throw new Error('text');
      if (box.checked !== row.on) throw new Error('checked');
    },
  },
  fields: {
    make: (id) => ({ id, score: id % 1000, author: { name: 'Author ' + id } }),
    sparse: (row, i, step) => (i % 97 === step % 97 ? { ...row, author: { name: row.author.name + '!' } } : row),
    dense: (row) => ({ ...row, score: row.score + 1, author: { name: row.author.name } }),
    check(element, row) {
      if (element.getAttribute('data-id') !== String(row.id)) throw new Error('id');
      if (element.textContent !== row.author.name + ' · ' + row.score) throw new Error('text');
    },
  },
};

function time(steps, run) {
  const start = performance.now();
  for (let i = 0; i < steps.length; i++) run(steps[i], i);
  return (performance.now() - start) / steps.length;
}

function assertRows(host, records, check) {
  if (host.childElementCount !== records.length) throw new Error('count ' + host.childElementCount);
  const indexes = [0, 1, 96, records.length - 1];
  for (let n = 0; n < indexes.length; n++) check(host.children[indexes[n]], records[indexes[n]]);
}

function nodeCensus(root) {
  let elements = 0, comments = 0, texts = 0;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ALL);
  while (walker.nextNode()) {
    const type = walker.currentNode.nodeType;
    if (type === Node.ELEMENT_NODE) elements++;
    else if (type === Node.COMMENT_NODE) comments++;
    else if (type === Node.TEXT_NODE) texts++;
  }
  return { elements, comments, texts };
}

const host = document.querySelector('#host');
const heapOnly = params.get('heap') === '1';
if (scenario === 'empty') {
  window.__complex = { scenario, elements: 0, ...nodeCensus(host) };
  document.documentElement.dataset.done = '1';
} else try {
  const importStarted = performance.now();
  const implementation = await import('/arms/' + scenario + '-' + arm + '.js');
  const evalMs = performance.now() - importStarted;
  let result;
  if (scenario === 'sources') {
    const people = list(count, (id) => ({ id, label: 'Person ' + id }));
    const tasks = list(count, (id) => ({ id, label: 'Task ' + id }));
    host.replaceChildren();
    const mountStarted = performance.now();
    const page = implementation.mountPage(host, people, tasks);
    const mountMs = performance.now() - mountStarted;
    if (heapOnly) {
      if (host.children.length !== 2) throw new Error('sources');
      if (host.firstElementChild.childElementCount !== count) throw new Error('people count');
      if (host.lastElementChild.childElementCount !== count) throw new Error('tasks count');
      const textOf = (row) => row.id + ' · ' + row.label;
      if (host.firstElementChild.children[0].textContent !== textOf(people[0])) throw new Error('person text');
      if (host.lastElementChild.children[0].textContent !== textOf(tasks[0])) throw new Error('task text');
      const census = nodeCensus(host);
      result = { evalMs, mountMs, rows: count * 2, domElements: census.elements, comments: census.comments, texts: census.texts };
    } else {
    const kept = host.firstElementChild.firstElementChild;
    const sparsePeople = chain(people, (row, i, step) => (i % 97 === step % 97 ? { ...row, label: row.label + '!' } : row));
    const sparseTasks = chain(tasks, (row, i, step) => (i % 97 === step % 97 ? { ...row, label: row.label + '!' } : row));
    const sparseMs = time(sparsePeople.steps, (rows, index) => page.replace(rows, sparseTasks.steps[index]));
    const densePeople = chain(sparsePeople.records, (row) => ({ ...row, label: row.label + '*' }));
    const denseTasks = chain(sparseTasks.records, (row) => ({ ...row, label: row.label + '*' }));
    const denseMs = time(densePeople.steps, (rows, index) => page.replace(rows, denseTasks.steps[index]));
    const reversedPeople = reverseSteps(densePeople.records);
    const reversedTasks = reverseSteps(denseTasks.records);
    const reverseMs = time(reversedPeople.steps, (rows, index) => page.replace(rows, reversedTasks.steps[index]));
    if (host.children.length !== 2) throw new Error('sources');
    if (host.firstElementChild.firstElementChild !== kept) throw new Error('person node was replaced');
    if (host.firstElementChild.childElementCount !== count) throw new Error('people count');
    if (host.lastElementChild.childElementCount !== count) throw new Error('tasks count');
    const person = host.firstElementChild.children[0];
    const task = host.lastElementChild.children[0];
    const textOf = (row) => row.id + ' · ' + row.label;
    if (person.textContent !== textOf(reversedPeople.records[0])) throw new Error('person text');
    if (task.textContent !== textOf(reversedTasks.records[0])) throw new Error('task text');
    page.dispose();
    result = { evalMs, mountMs, sparseMs, denseMs, reverseMs, elements: count * 2 };
    }
  } else {
    const spec = specs[scenario];
    const initial = list(count, spec.make);
    host.replaceChildren();
    const mountStarted = performance.now();
    const band = implementation.mountBand(host, initial);
    const mountMs = performance.now() - mountStarted;
    if (heapOnly) {
      assertRows(host, initial, spec.check);
      const census = nodeCensus(host);
      result = { evalMs, mountMs, rows: count, domElements: census.elements, comments: census.comments, texts: census.texts };
    } else {
    const kept = host.querySelector('[data-id="0"]');
    const sparseRun = chain(initial, spec.sparse);
    const sparseMs = time(sparseRun.steps, band.replace);
    const denseRun = chain(sparseRun.records, spec.dense);
    const denseMs = time(denseRun.steps, band.replace);
    const reversed = reverseSteps(denseRun.records);
    const reverseMs = time(reversed.steps, band.replace);
    assertRows(host, reversed.records, spec.check);
    if (host.querySelector('[data-id="0"]') !== kept) throw new Error('row node was replaced');
    band.dispose();
    result = { evalMs, mountMs, sparseMs, denseMs, reverseMs, elements: count };
    }
  }
  window.__complex = { scenario, arm, count, reps, ...result };
} catch (error) {
  window.__complex = { scenario, arm, count, error: String(error && error.stack || error) };
}
document.documentElement.dataset.done = '1';
