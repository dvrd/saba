// Full mode keeps an instance, its state and its DOM connected for each record.
// Virtual mode keeps the full data set but gives instances only to its current window.
const query = new URLSearchParams(location.search);
const target = Number(query.get('count'));
const scenario = query.get('scenario');
const buffered = scenario === 'buffered';
const virtual = buffered || scenario === 'virtual';
const observeRowWindow = buffered ? (await import('/sliding-window.js')).observeRowWindow : null;
const mode = query.get('mode');
const columns = 8;
const rowHeight = 26;
const overscan = 2;
const bufferRows = 8;
const refillRows = 3;
const chunkSize = 4096;
const viewport = document.querySelector('#viewport');
const space = document.querySelector('#space');
const mutate = document.querySelector('#mutate');
const jump = document.querySelector('#jump');
const records = [];
const observedWindowNodes = new WeakSet();
const bands = [];
const starts = {};
const paints = {};
let windowBand;
let windowFirst = 0;
let windowRenderer;
let slidingWindow;
let reconciles = 0;
let reconcileMs = 0;
let created = 0;
let lastLayout = 0;
let jumping = false;

new PerformanceObserver(list => {
  for (const entry of list.getEntries()) paints[entry.identifier] = entry.renderTime;
}).observe({type:'element', buffered:true});

function marker(name, text) {
  const label = document.createElement('span');
  label.setAttribute('elementtiming',name);
  label.textContent = text;
  document.querySelector('#status').replaceChildren(label);
}
function verify(condition, message) {
  if (!condition) throw new Error(message);
}
function originalScore(id) { return (id * 37 + (id % 23) * 13) % 1000; }
function cellText(record) { return record.id + ' · ' + record.score; }

class DirectCell {
  constructor(parent, record) {
    this.record = record;
    this.node = document.createElement('div');
    this.node.className = 'cell';
    this.node.dataset.id = String(record.id);
    this.text = document.createTextNode(cellText(record));
    this.node.append(this.text);
    parent.append(this.node);
  }
  update(record) {
    this.record = record;
    this.text.data = cellText(record);
  }
  dispose() { this.node.remove(); }
}

let mountCell;
let mountBand;
if (mode === 'saba-planned') {
  const {signal,effect} = await import('./reactivity.js');
  mountCell = (parent, record) => {
    const item = signal(record);
    const node = document.createElement('div');
    node.className = 'cell';
    node.dataset.id = String(record.id);
    const label = document.createTextNode('');
    node.append(document.createComment('value'),label,document.createComment('/value'));
    const binding = effect(() => {
      const text = cellText(item.read());
      if (label.data !== text) label.data = text;
    });
    parent.append(node);
    return {node, update:item.write, dispose() { binding.dispose(); node.remove(); }};
  };
} else if (mode === 'saba-current') {
  const {jsx,mount} = await import('./dom.js');
  function Tile({record}) {
    return jsx('div',{className:'cell','data-id':record.id},cellText(record));
  }
  mountCell = (parent, record) => {
    const unmount = mount(parent,Tile,{record});
    const node = parent.lastElementChild;
    const label = node.firstChild;
    return {node, record, update(next) { this.record = next; label.data = cellText(next); }, dispose:unmount};
  };
} else if (mode === 'vanilla') {
  mountCell = (parent,record) => new DirectCell(parent,record);
} else if (['react','solid','svelte','saba-compiled','saba-compiled-window','saba-baseline'].includes(mode)) {
  ({mountScaleBand:mountBand} = await import('/scale-' + mode + '.js'));
} else {
  throw new Error('Unknown component implementation');
}

// Each band receives the same immutable record slice in all implementations.
// Keep binding instances for IDs that stay in the band when scrolling or editing.
if (mountCell) mountBand = (host,initialRecords) => {
  let values = initialRecords;
  let cells = initialRecords.map(record => mountCell(host,record));
  return {
    replace(next) {
      if (values.length === next.length && values[0]?.id === next[0]?.id) {
        for (let i = 0; i < next.length; i++) {
          if (values[i] !== next[i]) cells[i].update(next[i]);
        }
      } else {
        const first = next[0]?.id ?? Infinity;
        const last = next.at(-1)?.id ?? -Infinity;
        for (let i = 0; i < values.length; i++) {
          if (values[i].id < first || values[i].id > last) cells[i].dispose();
        }
        let cursor = host.firstElementChild;
        const oldFirst = values[0]?.id ?? Infinity;
        cells = next.map(record => {
          const i = record.id - oldFirst;
          let cell = cells[i];
          if (!cell) cell = mountCell(host,record);
          else if (values[i] !== record) cell.update(record);
          if (cell.node !== cursor) host.insertBefore(cell.node,cursor);
          cursor = cell.node.nextElementSibling;
          return cell;
        });
      }
      values = next;
    },
    dispose() { for (const cell of cells) cell.dispose(); },
  };
};

function makeBand() {
  const band = document.createElement('div');
  band.className = 'band';
  return band;
}

function commitWindow(first, end) {
  const began = performance.now();
  const visible = records.slice(first,end);
  windowBand.style.top = (first / columns * rowHeight) + 'px';
  const destination = starts.jump !== undefined && end === target && starts.jumpWindow === undefined;
  if (destination) starts.jumpRenderer = performance.now();
  if (windowRenderer) windowRenderer.replace(visible,first);
  else windowRenderer = mountBand(windowBand,visible,first);
  if (destination) starts.jumpRendererDone = performance.now();
  windowFirst = first;
  for (const node of windowBand.children) {
    if (!observedWindowNodes.has(node)) {
      observedWindowNodes.add(node);
      created++;
    }
  }
  lastLayout = windowBand.children.length;
  verify(lastLayout === end - first, 'Unexpected virtual window');
  reconciles++;
  const committed = performance.now();
  reconcileMs += committed - began;
  if (destination) {
    starts.jumpWindow = began;
    starts.jumpWindowDone = committed;
  }
}

function renderWindow() {
  const row = Math.floor(viewport.scrollTop / rowHeight);
  const first = Math.max(0,row - overscan) * columns;
  const end = Math.min(target,(Math.ceil((viewport.scrollTop + viewport.clientHeight) / rowHeight) + overscan) * columns);
  commitWindow(first, end);
}

function windowStats() {
  return {first:windowFirst, end:windowFirst + lastLayout, reconciles, reconcileMs};
}

function start() {
  starts.mount = performance.now();
  for (let id = 0; id < target; id++) records.push({id,group:id % 23,score:originalScore(id)});
  const dataReady = performance.now();
  if (virtual) {
    space.style.height = (Math.ceil(target / columns) * rowHeight) + 'px';
    windowBand = makeBand();
    Object.assign(windowBand.style,{position:'absolute',left:'0',right:'0'});
    space.append(windowBand);
    if (buffered) {
      slidingWindow = observeRowWindow(viewport, {
        rowCount: Math.ceil(target / columns), rowHeight, overscanRows: bufferRows, thresholdRows: refillRows,
      }, (first, end) => commitWindow(first * columns, Math.min(target, end * columns)));
    } else renderWindow();
  }
  return {dataMs:dataReady-starts.mount,records:records.length};
}

function step() {
  verify(!virtual && lastLayout < target, 'Invalid full mount step');
  const band = makeBand();
  const start = lastLayout;
  const end = Math.min(target,start + chunkSize);
  const renderer = mountBand(band,records.slice(start,end),start);
  space.append(band);
  bands.push({host:band,renderer,start,end});
  // Require the browser to lay out the most recently connected component.
  const node = band.lastElementChild;
  verify(band.childElementCount === end - start,'Incorrect band size');
  const box = node.getBoundingClientRect();
  verify(node.isConnected && box.height === rowHeight && Number(node.dataset.id) === end-1, 'Last mounted tile was not laid out');
  created = lastLayout = end;
  return end;
}

function checkpoint() {
  const count = virtual ? windowBand.children.length : bands.reduce((sum,band) => sum + band.host.childElementCount,0);
  verify(count === lastLayout && count > 0, 'Mounted component count disagrees with DOM');
  const key = 'mount-' + count;
  marker(key,count.toLocaleString('en-US') + ' mounted cells');
  return {count,key,created};
}
function allowUpdates() {
  verify(virtual || lastLayout === target, 'Incomplete mount');
  mutate.disabled = jump.disabled = false;
}

function cellNode(id) {
  if (virtual) return windowBand.children[id-windowFirst];
  return bands[Math.floor(id/chunkSize)].host.children[id%chunkSize];
}
function change(id) {
  const next = {...records[id],score:records[id].score+7};
  records[id] = next;
}
mutate.addEventListener('click',() => {
  starts.mutate = performance.now();
  const anchor = virtual ? windowFirst : 0;
  const firstNode = cellNode(anchor);
  for (let id = 0; id < target; id += 97) change(id);
  if ((target - 1) % 97 !== 0) change(target-1);
  if (buffered) commitWindow(windowFirst, windowFirst + lastLayout);
  else if (virtual) renderWindow();
  else for (const {renderer,start,end} of bands) renderer.replace(records.slice(start,end),start);
  verify(cellNode(anchor) === firstNode,'Updated component lost its DOM identity');
  marker('mutate','Sampled scores updated');
  mutate.disabled = true;
});
jump.addEventListener('click',() => {
  starts.jump = performance.now();
  jumping = true;
  viewport.scrollTop = viewport.scrollHeight;
});
viewport.addEventListener('scroll',() => {
  if (virtual && !buffered) renderWindow();
  if (jumping && viewport.scrollTop + viewport.clientHeight >= viewport.scrollHeight - 1) {
    jumping = false;
    marker('jump','Final row');
  }
},{passive:true});
window.addEventListener('pagehide', event => {
  if (!event.persisted) slidingWindow?.dispose();
});

function verifyCell(id) {
  const node = cellNode(id);
  verify(node?.isConnected && Number(node.dataset.id) === id &&
    node.textContent === cellText(records[id]),'Wrong visible value for cell '+id);
  const r = node.getBoundingClientRect();
  verify(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2) === node,'Cell outside visible viewport '+id);
}
function verifyUpdate() {
  let changed = 0;
  let total = 0;
  for (const record of records) {
    const dirty = record.id % 97 === 0 || record.id === target-1;
    if (dirty) changed++;
    const expected = originalScore(record.id) + (dirty ? 7 : 0);
    verify(record.score === expected && record.group === record.id % 23, 'Data mismatch '+record.id);
    total += record.score;
  }
  verifyCell(0);
  return {changed,checksum:total};
}
function verifyEnd() {
  verifyCell(target-1);
  const mounted = virtual ? windowBand.childElementCount : bands.reduce((n,b) => n + b.host.childElementCount,0);
  if (virtual) {
    const maxRows = Math.ceil(viewport.clientHeight / rowHeight) + 1 + 2 * (buffered ? bufferRows : overscan);
    verify(mounted <= maxRows * columns,'Overscan limit exceeded');
  }
  else verify(mounted === target,'Full mount missing cells');
  return {mounted,created,lastId:target-1,lastText:cellNode(target-1).textContent};
}
window.scale = {start,step,checkpoint,allowUpdates,verifyUpdate,verifyEnd,starts,paints,windowStats};
