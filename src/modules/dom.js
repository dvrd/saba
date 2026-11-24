// JSX constructs real nodes once. Tracked bindings update their owning DOM positions.
export const Fragment = Symbol("Fragment");
let activeScope = null;
const nodeScopes = new WeakMap();
const nodeRefs = new WeakMap();
const references = new WeakMap();
const styles = new Map();

const nodeCleanups = new WeakMap();
const emptyTextChildren = new WeakMap();
const rangeEnds = new WeakMap();
const bindingType = Symbol("binding");
const childType = Symbol("child");
const keyedType = Symbol("keyed");
const html = "http://www.w3.org/1999/xhtml";
const svg = "http://www.w3.org/2000/svg";
const math = "http://www.w3.org/1998/Math/MathML";
let position = null;
let activation = null;
let preparingRow = null;
const slotRows = new WeakMap();
const slotOwnerWatches = new WeakMap();
let describingSlot = false;

// Compiler metadata is attached to the actual row function so imports and
// aliases keep the same implementation. An ordinary call still builds JSX.
export function registerSlotRow(row, descriptor) {
  slotRows.set(row, Object.freeze({
    tag: descriptor.tag,
    attrs: Object.freeze({...descriptor.attrs}),
    fields: Object.freeze([...descriptor.fields]),
    write: descriptor.write,
  }));
}

export function getSlotRow(row) {
  return slotRows.get(row);
}

// Ownership can change without a DOM mutation (for example a template scope
// attached to an existing element). Notify its window at registration time.
export function watchSlotOwner(node, callback) {
  if (callback) slotOwnerWatches.set(node, callback);
  else slotOwnerWatches.delete(node);
}

function addRootOwner(node, scope) {
  if (!nodeScopes.has(node)) nodeScopes.set(node, new Set());
  nodeScopes.get(node).add(scope);
  if (!scope.slotBinding) slotOwnerWatches.get(node)?.();
}

// Generated attachment queues mutations until every instance has finished
// synchronous setup. Work queued by an abandoned branch is skipped.
function afterSetup(phase, callback) {
  if (!activation) return callback();
  const owner = scopeHere();
  activation[phase].push(() => {
    if (!owner?.disposed) callback();
  });
}

// A claimed binding stages its writes in the activation that claimed it, and
// only until that activation has committed them. A later evaluation writes
// directly, even while an unrelated template is being activated: that other
// activation may roll back and would take the queued write with it.
function stageWrite(transaction, owner, write) {
  if (!transaction || transaction.committed) return write();
  transaction.writes.push(() => {
    if (!owner?.disposed) write();
  });
}

function newTransaction() {
  return { writes: [], listeners: [], ready: [], effects: [], committed: false };
}

// Errors that have no caller to receive them still have to be visible.
function report(error) {
  try {
    if (typeof reportError === "function") reportError(error);
    else console.error(error);
  } catch {
    // A failing reporter must not break the scheduler.
  }
}

const CLEAN = 0, CHECK = 1, DIRTY = 2;
const FLUSH_PASS_LIMIT = 100;
let tracking = null;
let revision = 0;
let batchDepth = 0;
let flushing = false;
let runningEffect = null;
let flushId = 0;
let flushPass = 0;
const pendingEffects = new Set();

function scopeHere() {
  return typeof activeScope === "function" ? activeScope() : activeScope;
}

function withContext(scope, parent, callback) {
  const previousScope = activeScope;
  const previousPosition = position;
  activeScope = scope;
  position = parent;
  try {
    return callback();
  } finally {
    activeScope = previousScope;
    position = previousPosition;
  }
}

// An effect attached to an element also stops when update() removes that
// element while the declaring component remains mounted.
function own(dispose, scope, node) {
  let live = true;
  const stop = () => {
    if (!live) return;
    live = false;
    scope?.owned.delete(stop);
    nodeCleanups.get(node)?.delete(stop);
    dispose();
  };
  scope?.owned.add(stop);
  if (node) {
    if (!scope?.slotBinding) slotOwnerWatches.get(node)?.();
    let cleanups = nodeCleanups.get(node);
    if (!cleanups) nodeCleanups.set(node, cleanups = new Set());
    cleanups.add(stop);
  }
  return stop;
}

function observe(source) {
  if (!tracking || tracking.disposed) return;
  tracking.reads.set(source, source.version);
  if (tracking.effect || tracking.sinks.size) connect(source, tracking);
}

function connect(source, sink) {
  if (source.sinks.has(sink)) return;
  const wake = source.sinks.size === 0 && source.sources && !source.disposed;
  source.sinks.add(sink);
  if (wake) {
    for (const input of source.sources.keys()) connect(input, source);
  }
}

function disconnect(source, sink) {
  if (source.sinks.delete(sink) && !source.sinks.size && source.sources) {
    for (const input of source.sources.keys()) disconnect(input, source);
  }
}

function invalidate(node, level) {
  if (node.disposed || node.state >= level) return;
  node.state = level;
  if (node.effect) pendingEffects.add(node);
  else for (const sink of node.sinks) invalidate(sink, CHECK);
}

function evaluate(node) {
  const previous = tracking;
  const previousEffect = runningEffect;
  tracking = node;
  if (node.effect) runningEffect = node;
  node.reads = new Map();
  node.running = true;
  node.state = CLEAN;
  try {
    return withContext(node.owner, node.position, node.callback);
  } finally {
    for (const input of node.sources.keys()) {
      if (!node.reads.has(input)) disconnect(input, node);
    }
    node.sources = node.reads;
    node.reads = null;
    node.running = false;
    tracking = previous;
    runningEffect = previousEffect;
  }
}

function refresh(node) {
  if (node.running) throw new Error("Reactive dependency cycle.");
  if (node.disposed) return;
  if (node.state === CLEAN && (node.sinks.size || node.epoch === revision)) return;
  if (node.state !== DIRTY) {
    node.state = CLEAN;
    node.epoch = revision;
    let changed = false;
    for (const [input, version] of node.sources) {
      if (input.sources) refresh(input);
      if (input.version !== version) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
  }
  if (node.effect) {
    evaluate(node);
  } else {
    try {
      const value = evaluate(node);
      if (!node.ready || !Object.is(node.value, value)) node.version++;
      node.value = value;
      node.ready = true;
      node.epoch = revision;
      node.failed = false;
      node.error = undefined;
    } catch (error) {
      node.failed = true;
      node.error = error;
      node.ready = false;
      node.version++;
      node.epoch = revision;
    }
  }
}

// A compiler-created binding reports its failure to the writer, which can
// then rely on the committed DOM being unchanged (a rejected keyed snapshot,
// for example). An authored effect has no such contract: its failure is
// reported globally and never reaches the code that wrote the signal. Only
// the first binding error is thrown; any others are reported.
function flush() {
  if (batchDepth || flushing) return;
  flushing = true;
  flushId++;
  let failure, failed = false, overflow = null;
  try {
    let passes = 0, limit = FLUSH_PASS_LIMIT;
    while (pendingEffects.size) {
      if (++passes > limit) {
        // The effects still writing signals are the ones that cannot settle.
        // Retire those, then let every other pending effect observe the
        // final values instead of leaving it marked clean and stale.
        const stuck = overflow ? [] : [...pendingEffects].filter(node =>
          node.wroteFlush === flushId && node.wrotePass >= passes - 2);
        overflow ||= new Error(`Reactive flush exceeded the pass limit (${FLUSH_PASS_LIMIT}).`);
        if (!stuck.length) {
          for (const node of pendingEffects) node.state = CLEAN;
          pendingEffects.clear();
          break;
        }
        for (const node of stuck) {
          node.state = CLEAN;
          pendingEffects.delete(node);
        }
        limit = passes + FLUSH_PASS_LIMIT;
        continue;
      }
      flushPass = passes;
      const wave = [...pendingEffects];
      pendingEffects.clear();
      for (const node of wave) {
        if (node.disposed || node.state === CLEAN) continue;
        try {
          refresh(node);
        } catch (error) {
          if (node.user || failed) report(error);
          else {
            failure = error;
            failed = true;
          }
        }
      }
    }
  } finally {
    flushing = false;
    flushPass = 0;
  }
  if (overflow) {
    if (failed) report(failure);
    throw overflow;
  }
  if (failed) throw failure;
}

export function batch(callback) {
  batchDepth++;
  let threw = false;
  try {
    return callback();
  } catch (error) {
    threw = true;
    throw error;
  } finally {
    batchDepth--;
    if (!threw) flush();
    else {
      // The callback's own exception is the one its caller must see.
      try { flush(); } catch (error) { report(error); }
    }
  }
}

export function untrack(callback) {
  const previous = tracking;
  tracking = null;
  try {
    return callback();
  } finally {
    tracking = previous;
  }
}

export function signal(value) {
  const source = { version: 0, sinks: new Set() };
  const read = () => {
    observe(source);
    return value;
  };
  read.set = (next) => {
    if (Object.is(next, value)) return;
    value = next;
    source.version++;
    revision++;
    if (runningEffect) {
      runningEffect.wroteFlush = flushId;
      runningEffect.wrotePass = flushPass;
    }
    for (const sink of source.sinks) invalidate(sink, DIRTY);
    flush();
  };
  return read;
}

function computation(callback, effect, owner, target) {
  const node = {
    callback,
    effect,
    owner,
    position,
    sources: new Map(),
    sinks: new Set(),
    state: DIRTY,
    version: 0,
    epoch: -1,
    ready: false,
    disposed: false,
  };
  node.stop = own(
    () => {
      node.disposed = true;
      pendingEffects.delete(node);
      for (const input of node.sources.keys()) disconnect(input, node);
      if (node.reads) { for (const input of node.reads.keys()) disconnect(input, node); }
      node.sources.clear();
      node.callback = null;
      node.owner = null;
      node.position = null;
    },
    owner,
    target,
  );
  return node;
}

export function computed(callback) {
  const node = computation(callback, false, scopeHere());
  return () => {
    refresh(node);
    observe(node);
    if (node.failed) throw node.error;
    return node.value;
  };
}

function subscribe(callback, target, user = false) {
  const node = computation(callback, true, scopeHere(), target);
  node.user = user;
  try {
    batch(() => refresh(node));
  } catch (error) {
    node.stop();
    throw error;
  }
  return node.stop;
}

// Each evaluation of an authored effect owns what it creates: cleanups,
// nested effects, computeds, child components and resource subscriptions are
// released before the next evaluation and when the effect stops. A function
// returned by the callback is that evaluation's cleanup.
function ownedEffect(callback) {
  const owner = scopeHere();
  let scope = null, cleanup = null;
  const release = () => {
    const errors = [];
    const done = cleanup, previous = scope;
    cleanup = scope = null;
    if (done) {
      try { untrack(done); } catch (error) { errors.push(error); }
    }
    if (previous) disposeScope(previous, errors);
    return errors;
  };
  let stopped = false;
  // An evaluation that stops its own effect, or disposes the component that
  // declared it, keeps that component's scope current until it returns.
  const current = () => {
    if (scope) return scope;
    if (stopped || owner?.disposed) return owner;
    return scope = createScope(owner);
  };
  const stopRun = own(() => {
    stopped = true;
    const errors = release();
    if (errors.length) throw new AggregateError(errors, "Effect cleanup failed.");
  }, owner);
  let stopEffect;
  try {
    stopEffect = subscribe(() => {
      for (const error of release()) report(error);
      const result = withContext(current, position, callback);
      if (typeof result === "function") {
        if (stopped) untrack(result);
        else cleanup = result;
      }
    }, undefined, true);
  } catch (error) {
    try { stopRun(); } catch (failure) { report(failure); }
    throw error;
  }
  return () => {
    stopEffect();
    stopRun();
  };
}

export function effect(callback) {
  if (activation || preparingRow) {
    const owner = scopeHere(), parent = position;
    let stop = null, cancelled = false;
    const startEffect = () => {
      if (!cancelled) stop = withContext(owner, parent, () => ownedEffect(callback));
    };
    if (activation) afterSetup("effects", startEffect);
    else enqueue(owner, startEffect);
    return () => {
      cancelled = true;
      stop?.();
    };
  }
  return ownedEffect(callback);
}

// Only compiler descriptors install tracked bindings or defer JSX construction.
// An ordinary function remains a value even if it returns a DOM node.
export function binding(read) {
  return { type: bindingType, read };
}
export function textBinding(read) {
  return { type: bindingType, read, textOnly: true };
}
// Compiler-private. A tracked DOM write that starts synchronously in every
// context, as a binding does. effect() defers its first run during row
// preparation and template activation, so it cannot own a first paint.
export function paint(write) {
  return subscribe(write);
}
export function child(tag, props, ...children) {
  return { type: childType, tag, props, children };
}

function copyProps(destination, source, reserved) {
  if (source == null) return;
  source = Object(source);
  for (const name of Reflect.ownKeys(source)) {
    if (reserved && (name === "ref" || name === "children")) continue;
    const descriptor = Object.getOwnPropertyDescriptor(source, name);
    if (!descriptor?.enumerable) continue;
    const property = "value" in descriptor
      ? { value: descriptor.value, writable: true }
      : { get: descriptor.get?.bind(source), set: descriptor.set?.bind(source) };
    Object.defineProperty(destination, name, { ...property, enumerable: true, configurable: true });
  }
}

export function mergeProps(...sources) {
  const props = {};
  for (const source of sources) copyProps(props, source, false);
  return props;
}

export function liveProp(name, read) {
  return Object.defineProperty({}, name, { get: read, enumerable: true, configurable: true });
}

function isText(value) {
  return typeof value === "string" || typeof value === "number" || typeof value === "bigint";
}

function append(parent, value) {
  if (value == null || typeof value === "boolean") return;
  if (Array.isArray(value)) {
    for (const item of value) append(parent, item);
  } else if (value instanceof Node) {
    parent.append(value);
  } else if (isText(value)) {
    parent.append(document.createTextNode(String(value)));
  } else if (value.type === childType) {
    append(parent, jsx(value.tag, value.props, ...value.children));
  } else if (value.type === bindingType) {
    if (value.textOnly) appendText(parent, value.read);
    else appendRange(parent, value.read);
  } else if (value.type === keyedType) {
    return appendKeyed(parent, value);
  } else {
    throw new TypeError("JSX children must be nodes, text, numbers, or arrays.");
  }
}

// The compiler proves the result is a string. Evaluating it can still read
// other signals or create owned work through a getter or coercion.
function appendText(parent, read, claimedText = null) {
  if (preparingRow && activeScope === preparingRow.scope) preparingRow.textParent = parent;
  const text = claimedText || document.createTextNode("");
  if (!claimedText) parent.append(text);
  const owner = scopeHere();
  let releaseBranch;
  let indexed = false;
  subscribe(() => {
    let staged, value;
    try {
      value = withContext(() => staged ||= createScope(owner), position, read);
    } catch (error) {
      if (staged) disposeScope(staged, []);
      throw error;
    }
    try {
      // As in a structural range, a plain scalar write updates the existing
      // branch. Replace its owned work only when a new branch was prepared.
      if (staged) {
        const previous = releaseBranch;
        releaseBranch = own(() => {
          const errors = [];
          disposeScope(staged, errors);
          if (errors.length) throw new AggregateError(errors, "Child cleanup failed.");
        }, owner, text);
        previous?.();
      }
    } finally {
      if (claimedText) owner.slotBinding(() => writeText(value));
      else writeText(value);
    }
  }, text);
  function writeText(value) {
    // normalize() may have detached the sole empty Text. Keep that position
    // owned until the next nonempty value or a managed replacement.
    if (!value && !indexed) {
      emptyTextChildren.set(parent, text);
      indexed = true;
    } else if (value && indexed && (text.parentNode || !parent.firstChild)) {
      emptyTextChildren.delete(parent);
      indexed = false;
      if (!text.parentNode) parent.append(text);
    }
    if (text.data !== value) text.data = value;
  }
}

function clearRange(start, end, errors) {
  if (!start.parentNode || start.parentNode !== end.parentNode) return;
  while (start.nextSibling && start.nextSibling !== end) {
    const node = start.nextSibling;
    disposeNodes([node], errors);
    node.remove();
  }
}

function appendRange(parent, read, start, end) {
  const claimed = start !== undefined;
  if (!claimed) {
    start = document.createComment("saba");
    end = document.createComment("/saba");
    parent.append(start, end);
  }
  rangeEnds.set(start, end);
  const owner = scopeHere();
  const insertion = position;
  const transaction = claimed ? activation : null;
  let branch = null;
  let committed = !claimed;
  let text =
    claimed && start.nextSibling?.nodeType === Node.TEXT_NODE && start.nextSibling.nextSibling === end
      ? start.nextSibling
      : null;
  let list = null;
  own(
    () => {
      const errors = [];
      if (branch) disposeScope(branch, errors);
      if (committed) clearRange(start, end, errors);
      if (errors.length) throw new AggregateError(errors, "Child cleanup failed.");
    },
    owner,
    start,
  );
  subscribe(() => {
    let staged = null;
    // Primitive reads need no branch scope. Components and effects allocate
    // one on demand while preparing a possible structural replacement.
    const stage = () => staged ||= createScope(owner);
    const errors = [];
    let fragment, value, nextList;
    try {
      withContext(stage, insertion, () => {
        value = read();
        if (isText(value) && text && !staged) return;
        if (list && value?.type === keyedType && !staged) return;
        fragment = document.createDocumentFragment();
        nextList = untrack(() => append(fragment, value));
      });
    } catch (error) {
      if (staged) disposeScope(staged, errors);
      if (fragment) disposeNodes([...fragment.childNodes], errors);
      throw error;
    }
    const write = () => {
      committed = true;
      if (!fragment) {
        if (list) {
          list.set(value);
          return;
        }
        const next = String(value);
        if (text.data !== next) text.data = next;
        return;
      }
      if (branch) disposeScope(branch, errors);
      clearRange(start, end, errors);
      branch = staged;
      list = nextList;
      text = isText(value) ? fragment.firstChild : null;
      const nodes = [...fragment.childNodes];
      end.before(fragment);
      if (end.isConnected) activate(nodes);
      if (errors.length) throw new AggregateError(errors, "Child cleanup failed.");
    };
    stageWrite(transaction, owner, write);
  }, start);
}

export function keyed(items, keyOf, renderRow) {
  return { type: keyedType, items, keyOf, renderRow };
}

function passiveTextRoot(value, scope, effectsBefore) {
  if (!value || value !== preparingRow.textParent || value.nodeType !== Node.ELEMENT_NODE ||
      value.parentNode || value.firstChild !== value.lastChild || value.firstChild?.nodeType !== Node.TEXT_NODE) {
    return false;
  }
  // The text subscription must be the row's only owned work. An observed
  // lifetime, including a deferred startup/effect, keeps its original range root.
  return scope.owned.size === 1 && !scope.lifetime && !scope.children.size &&
    !scope.cleanup.length && !scope.pending.length && !scope.refs.size &&
    activation?.effects.length === effectsBefore;
}

function prepareRow(record, renderRow, owner) {
  const scope = createScope(owner);
  const current = signal(record);
  let fragment;
  const previous = preparingRow;
  const effectsBefore = activation?.effects.length;
  preparingRow = {scope, textParent: null};
  try {
    const value = withContext(scope, position, () => renderRow(() => current()));
    if (passiveTextRoot(value, scope, effectsBefore)) {
      scope.roots = [value];
      addRootOwner(value, scope);
      return {first: value, last: value, current, scope};
    }
    const first = document.createComment("row");
    const last = document.createComment("/row");
    rangeEnds.set(first, last);
    fragment = document.createDocumentFragment();
    fragment.append(first);
    withContext(scope, position, () => append(fragment, value));
    fragment.append(last);
    scope.roots = [first, last];
    nodeScopes.set(first, new Set([scope]));
    return { first, last, current, scope };
  } catch (error) {
    disposeScope(scope, []);
    if (fragment) disposeNodes([...fragment.childNodes], []);
    throw error;
  } finally {
    preparingRow = previous;
  }
}

function removeRow(row, errors) {
  disposeScope(row.scope, errors);
  if (row.first === row.last) {
    disposeNodes([row.first], errors);
    row.first.remove();
    return;
  }
  clearRange(row.first, row.last, errors);
  row.first.remove();
  row.last.remove();
}

function placeRow(row, before, added) {
  if (row.last.nextSibling === before) return;
  const parent = before.parentNode;
  const inserted = [];
  for (let node = row.first; node;) {
    const next = node.nextSibling;
    if (added) inserted.push(node);
    if (!added && parent.moveBefore) parent.moveBefore(node, before);
    else parent.insertBefore(node, before);
    if (node === row.last) break;
    node = next;
  }
  if (added && before.isConnected) activate(inserted);
}

// positions[i] is the previous index of the row requested at i, or -1 for a
// new row. Mark a longest increasing subsequence: those rows keep their place.
function stableRows(positions) {
  const count = positions.length;
  const settled = new Uint8Array(count);
  let ordered = true, highest = -1;
  for (let i = 0; i < count && ordered; i++) {
    if (positions[i] < 0) continue;
    ordered = positions[i] > highest;
    highest = positions[i];
  }
  if (ordered) {
    for (let i = 0; i < count; i++) settled[i] = positions[i] >= 0 ? 1 : 0;
    return settled;
  }
  const tails = [], link = new Int32Array(count);
  for (let i = 0; i < count; i++) {
    const value = positions[i];
    if (value < 0) continue;
    let low = 0, high = tails.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (positions[tails[middle]] < value) low = middle + 1;
      else high = middle;
    }
    link[i] = low ? tails[low - 1] : -1;
    tails[low] = i;
  }
  for (let i = tails.length ? tails[tails.length - 1] : -1; i >= 0; i = link[i]) settled[i] = 1;
  return settled;
}

function appendKeyed(parent, descriptor) {
  const first = document.createComment("keyed");
  const last = document.createComment("/keyed");
  rangeEnds.set(first, last);
  parent.append(first, last);
  const owner = scopeHere();
  let rows = new Map();
  const configuration = signal(descriptor);
  own(
    () => {
      const errors = [];
      for (const row of rows.values()) removeRow(row, errors);
      rows.clear();
      if (errors.length) throw new AggregateError(errors, "Keyed row cleanup failed.");
    },
    owner,
    first,
  );
  subscribe(() => {
    const { items, keyOf, renderRow } = configuration();
    const records = Array.from(typeof items === "function" ? items() : items);
    const keys = records.map(keyOf);
    const seen = new Set();
    for (const key of keys) {
      if (typeof key !== "string" && !Number.isFinite(key)) {
        throw new TypeError("A row key must be a string or finite number.");
      }
      if (seen.has(key)) throw new Error(`Duplicate row key: ${key}`);
      seen.add(key);
    }
    untrack(() => {
      const next = new Map(), added = new Set(), errors = [];
      try {
        for (let i = 0; i < keys.length; i++) {
          let row = rows.get(keys[i]);
          if (!row) {
            row = prepareRow(records[i], renderRow, owner);
            added.add(row);
          }
          next.set(keys[i], row);
        }
      } catch (error) {
        for (const row of added) removeRow(row, errors);
        throw error;
      }

      const focused = document.activeElement;
      const selection = focused?.selectionStart != null
        ? [focused.selectionStart, focused.selectionEnd, focused.selectionDirection]
        : null;
      // Retained rows that already appear in the requested relative order
      // stay where they are. Only the others move, so a focused row is not
      // detached unless its own position changes relative to its neighbours.
      const previous = new Map();
      for (const key of rows.keys()) if (next.has(key)) previous.set(key, previous.size);
      const settled = stableRows(keys.map(key => previous.has(key) ? previous.get(key) : -1));
      batch(() => {
        for (const [key, row] of rows) if (!next.has(key)) removeRow(row, errors);
        let before = last;
        for (let i = keys.length - 1; i >= 0; i--) {
          const row = next.get(keys[i]);
          row.current.set(records[i]);
          if (!settled[i]) placeRow(row, before, added.has(row));
          before = row.first;
        }
        rows = next;
      });
      if (focused?.isConnected) {
        if (document.activeElement !== focused) focused.focus({ preventScroll: true });
        if (
          selection && (focused.selectionStart !== selection[0] ||
            focused.selectionEnd !== selection[1] || focused.selectionDirection !== selection[2])
        ) {
          focused.setSelectionRange(...selection);
        }
      }
      if (errors.length) throw new AggregateError(errors, "Keyed row cleanup failed.");
    });
  }, first);
  return configuration;
}

function rootsOf(node) {
  if (!(node instanceof DocumentFragment)) return [node];
  const roots = [];
  for (let root = node.firstChild; root; root = root.nextSibling) {
    roots.push(root);
    const end = rangeEnds.get(root);
    if (end) {
      roots.push(end);
      root = end;
    }
  }
  return roots;
}

function namespaceFor(tag, parent) {
  let space = parent?.namespaceURI || html;
  const name = parent?.localName;
  if (space === svg && ["foreignObject", "desc", "title"].includes(name)) space = html;
  if (space === math) {
    if (["mi", "mo", "mn", "ms", "mtext"].includes(name) && !["mglyph", "malignmark"].includes(tag)) {
      space = html;
    }
    if (
      name === "annotation-xml" &&
      (tag === "svg" || /^(text\/html|application\/xhtml\+xml)$/i.test(parent.getAttribute("encoding")))
    ) space = html;
  }
  if (space === html && tag === "svg") return svg;
  if (space === html && tag === "math") return math;
  return space;
}

const attributeSpaces = {
  xlink: "http://www.w3.org/1999/xlink",
  xml: "http://www.w3.org/XML/1998/namespace",
  xmlns: "http://www.w3.org/2000/xmlns/",
};
const liveProperties = new Set(["value", "checked", "selected", "muted"]);
const enumerated = new Set([
  "contenteditable",
  "draggable",
  "spellcheck",
  "translate",
  "autocapitalize",
  "enterkeyhint",
  "inputmode",
  "popover",
]);

function setStyle(node, current, previous) {
  const set = (name, value) => {
    if (name.startsWith("--") || name.includes("-")) node.style.setProperty(name, value ?? "");
    else node.style[name] = value ?? "";
  };
  if (typeof current === "string") {
    node.style.cssText = current;
    return;
  }
  if (typeof previous === "string") node.style.cssText = "";
  else if (previous) {
    for (const name of Object.keys(previous)) {
      if (!current || !Object.hasOwn(current, name)) set(name, "");
    }
  }
  if (current) { for (const [name, value] of Object.entries(current)) set(name, value); }
}

function attributeText(value, stringValue) {
  if (value == null || (value === false && !stringValue)) return null;
  return value === true && !stringValue ? "" : String(value);
}

const trustedType = Symbol("trusted");
const urlAttributes = new Set(["href", "src", "action", "formaction", "xlink:href"]);

// Opt in to a value the runtime otherwise refuses: a javascript: URL in a
// navigation attribute, or markup for an iframe's srcdoc. The caller vouches
// that the value does not come from another user or an unchecked server field.
export function trusted(value) {
  return Object.freeze({ type: trustedType, value });
}

// The URL parser removes tabs and newlines and ignores leading control
// characters and spaces before it reads the scheme.
function scriptURL(text) {
  return /^javascript:/i.test(text.replace(/[\t\n\r]/g, "").replace(/^[\u0000- ]+/, ""));
}

function checkedAttribute(name, value) {
  if (value?.type === trustedType) return value.value;
  const key = name.toLowerCase();
  if (key === "srcdoc" && typeof value === "string") {
    throw new TypeError("srcdoc is markup. Pass trusted(markup) if its source is trusted.");
  }
  if (urlAttributes.has(key) && value != null && typeof value !== "boolean" && scriptURL(String(value))) {
    throw new TypeError(`Refusing a javascript: URL in ${name}. Use an event handler, or trusted(url).`);
  }
  return value;
}

function writeAttribute(node, name, value, previous) {
  if (name === "style") {
    setStyle(node, value, previous);
    return;
  }
  if (name === "className") name = "class";
  if (name === "htmlFor") name = "for";
  value = checkedAttribute(name, value);
  if (node.namespaceURI === html && liveProperties.has(name) && name in node) {
    const desired = name === "value" ? String(value ?? "") : Boolean(value);
    if (node[name] !== desired) node[name] = desired;
    return;
  }
  const prefix = name.includes(":") || name === "xmlns" ? name.split(":")[0] : "";
  const namespace = node.namespaceURI !== html && Object.hasOwn(attributeSpaces, prefix) &&
    attributeSpaces[prefix];
  const stringValue = name.startsWith("aria-") || name.startsWith("data-") ||
    enumerated.has(name.toLowerCase()) || node.namespaceURI !== html;
  const text = attributeText(value, stringValue);
  if (text === null) {
    if (namespace) node.removeAttributeNS(namespace, name.split(":").pop());
    else node.removeAttribute(name);
  } else {
    if (namespace) node.setAttributeNS(namespace, name, text);
    else node.setAttribute(name, text);
  }
}

function attachAttribute(node, name, value, claimed) {
  if (value?.type === bindingType) {
    const slotWrite = claimed && scopeHere()?.slotBinding;
    if (slotWrite) {
      // Only passive HTML attributes reach this path. Coercion may execute
      // user code, read signals or throw, so finish it in the subscription.
      const stringValue = name.startsWith("aria-") || name.startsWith("data-");
      subscribe(() => {
        const text = attributeText(value.read(), stringValue);
        slotWrite(() => {
          if (text === null) node.removeAttribute(name);
          else node.setAttribute(name, text);
        });
      }, node);
      return;
    }
    let previous;
    const owner = scopeHere();
    const transaction = claimed ? activation : null;
    subscribe(() => {
      const next = value.read();
      const write = () => {
        writeAttribute(node, name, next, previous);
        previous = name === "style" && next && typeof next === "object" ? { ...next } : next;
      };
      stageWrite(transaction, owner, write);
    }, node);
  } else if (claimed) afterSetup("writes", () => writeAttribute(node, name, value));
  else writeAttribute(node, name, value);
}

// JSX event props use onClick/onPointerDown; DOM listeners use click/pointerdown.
function domEventName(eventProp) {
  return eventProp.slice(2).toLowerCase();
}

export function jsx(tag, properties, ...children) {
  if (describingSlot) return {properties, children};
  const props = properties || {};
  const reference = props.ref;
  if (reference != null && !references.has(reference)) {
    throw new TypeError("ref must be an object created by ref(name).");
  }
  if (typeof tag === "function") {
    const scope = createScope(scopeHere());
    try {
      const input = { children };
      copyProps(input, props, true);
      const node = withContext(scope, position, () => untrack(() => tag(input)));
      if (!(node instanceof Node)) {
        throw new TypeError("Components must synchronously return a DOM node.");
      }
      if (node instanceof DocumentFragment && !node.childNodes.length) {
        node.append(document.createComment(""));
      }
      scope.roots = rootsOf(node);
      for (const root of scope.roots) addRootOwner(root, scope);
      captureRef(reference, node);
      return node;
    } catch (error) {
      disposeScope(scope, []);
      throw error;
    }
  }
  const space = namespaceFor(tag, position);
  const node = tag === Fragment
    ? document.createDocumentFragment()
    : space === html
    ? document.createElement(tag)
    : document.createElementNS(space, tag);
  try {
    const inputs = elementAttributes(node, props, false);
    withContext(activeScope, tag === Fragment ? position : node, () => {
      for (const value of children) append(node, value);
    });
    for (const [name, value] of inputs) attachAttribute(node, name, value);
    captureRef(reference, node);
    return node;
  } catch (error) {
    disposeNodes([node], []);
    throw error;
  }
}

// A compiler-recognized row has a single intrinsic return. Capturing its
// ordinary descriptors preserves each original getter and JS coercion when
// an untrusted record is bound to an already-mounted physical slot.
export function prepareSlotBindings(element, text, renderRow, record, write) {
  const previous = describingSlot;
  let row;
  try {
    describingSlot = true;
    row = renderRow(() => record);
  } finally { describingSlot = previous; }
  const scope = createScope(null);
  let pending = [];
  scope.slotBinding = callback => {
    if (pending) pending.push(callback);
    else write(callback);
  };
  const saved = activation;
  const transaction = newTransaction();
  activation = transaction;
  try {
    withContext(scope, element, () => untrack(() => {
      templateElement(element, row.properties || {});
      appendText(element, row.children[0].read, text);
    }));
  } catch (error) {
    disposeScope(scope, []);
    throw error;
  } finally { activation = saved; }
  return {
    commit() {
      scope.roots = [element];
      addRootOwner(element, scope);
      for (let n = 0; n < transaction.writes.length; n++) transaction.writes[n]();
      transaction.committed = true;
      const prepared = pending;
      pending = null;
      for (const callback of prepared) write(callback);
    },
    activate() {
      for (const callback of transaction.listeners) callback();
      for (const callback of transaction.ready) callback();
      start(scope);
      for (const callback of transaction.effects) callback();
    },
    dispose(errors) { disposeScope(scope, errors); },
  };
}

export function ownSlotWindow(host, dispose) {
  return own(dispose, scopeHere(), host);
}

export function releaseSlotNodes(nodes, errors) {
  disposeNodes(nodes, errors);
}

function elementAttributes(node, props, claimed) {
  const inputs = [];
  for (const name of Object.keys(props)) {
    if (name === "children" || name === "ref") continue;
    if (["innerHTML", "outerHTML", "textContent"].includes(name)) {
      throw new TypeError(`Use JSX children instead of ${name}.`);
    }
    // HTML attribute names are case-insensitive, so ONCLICK="…" set as an
    // attribute would install an inline handler. Every spelling is an event.
    if (name.length > 2 && /^on/i.test(name)) {
      const listener = props[name];
      if (listener == null) continue;
      if (typeof listener !== "function") {
        throw new TypeError(`${name} must be an event handler function.`);
      }
      const event = domEventName(name);
      const owner = scopeHere();
      const listen = () => {
        node.addEventListener(event, listener);
        own(() => node.removeEventListener(event, listener), owner, node);
      };
      if (claimed) afterSetup("listeners", listen);
      else listen();
      continue;
    }
    const descriptor = Object.getOwnPropertyDescriptor(props, name);
    const value = descriptor.get ? binding(() => props[name]) : descriptor.value;
    if (liveProperties.has(name)) inputs.push([name, value]);
    else attachAttribute(node, name, value, claimed);
  }
  return inputs;
}

// The template entry preflights all markers before invoking these bridges.
export function templateElement(element, props = {}) {
  const inputs = elementAttributes(element, props, true);
  for (const [name, value] of inputs) attachAttribute(element, name, value, true);
  captureRef(props.ref, element);
  return element;
}

export function templateRange(start, end, value) {
  const read = value?.type === bindingType ? value.read : () => value;
  withContext(activeScope, start.parentNode, () => appendRange(start.parentNode, read, start, end));
}

export function templateRoot(host, setup, ready) {
  const scope = createScope(scopeHere());
  scope.roots = [host];
  addRootOwner(host, scope);
  const parent = activation;
  const transaction = parent || newTransaction();
  activation = transaction;
  try {
    withContext(scope, host, () => untrack(setup));
    if (ready) afterSetup("ready", ready);
    if (!parent) {
      batch(() => {
        // A write can itself stage another (a getter that writes a signal).
        for (let n = 0; n < transaction.writes.length; n++) transaction.writes[n]();
        transaction.committed = true;
        for (const listen of transaction.listeners) listen();
        for (const enable of transaction.ready) enable();
      });
    }
  } catch (error) {
    disposeScope(scope, []);
    throw error;
  } finally {
    activation = parent;
  }
  if (!parent) {
    activate([host]);
    for (const startEffect of transaction.effects) {
      try {
        startEffect();
      } catch (error) {
        reportError(error);
      }
    }
  }
  return () => {
    const errors = [];
    disposeScope(scope, errors);
    if (errors.length) throw new AggregateError(errors, "Template cleanup failed.");
  };
}

function currentScope() {
  const scope = scopeHere();
  if (!scope) {
    throw new Error(
      "Component lifetimes must be declared while a component is constructed.",
    );
  }

  return scope;
}

function createScope(parent) {
  const scope = {
    parent,
    controller: null,
    lifetime: null,
    roots: [],
    children: new Set(),
    refs: new Map(),
    cleanup: [],
    owned: new Set(),
    pending: [],
    mounted: false,
    disposed: false,
  };
  parent?.children.add(scope);
  return scope;
}

function scopeLifetime(scope) {
  if (scope.lifetime) return scope.lifetime;
  const controller = new AbortController();
  scope.controller = controller;
  if (scope.disposed) controller.abort();
  scope.lifetime = Object.freeze({
    abort: controller.signal,
    get root() {
      return scope.roots[0] || null;
    },
    run: (callback) => schedule(scope, callback),
  });

  return scope.lifetime;
}

// Every declaration belongs to one component instance, including repeated fields.
export function ref(name) {
  const scope = currentScope();

  if (typeof name !== "string" || !/^[A-Za-z_$][\w$]*$/.test(name)) {
    throw new TypeError("ref requires a nonempty identifier name.");
  }

  if (scope.refs.has(name)) {
    throw new Error(`Duplicate component reference: ${name}`);
  }

  const state = { owner: scope, node: null };

  const reference = Object.freeze({
    name,
    get current() {
      return state.node;
    },
  });

  references.set(reference, state);
  scope.refs.set(name, state);

  return reference;
}

export function uiRefs(...names) {
  currentScope();
  return Object.freeze(
    Object.fromEntries(names.map((name) => [name, ref(name)])),
  );
}

function captureRef(reference, node) {
  if (reference == null) return;

  const state = references.get(reference);

  if (!(node instanceof Element)) {
    throw new TypeError("A ref must identify one DOM element.");
  }

  if (state.owner.disposed) {
    throw new Error("Cannot bind a disposed component reference.");
  }

  if (state.node) {
    throw new Error(`Reference is already bound: ${reference.name}`);
  }

  state.node = node;
  if (!nodeRefs.has(node)) {
    nodeRefs.set(node, new Set());
  }

  nodeRefs.get(node).add(state);
  slotOwnerWatches.get(node)?.();
}

export function lifetime() {
  return scopeLifetime(currentScope());
}

// Startup is registered during construction and begins after DOM insertion.
export function run(callback) {
  schedule(currentScope(), callback);
}

function schedule(scope, callback) {
  if (typeof callback !== "function") {
    throw new TypeError("run requires a function.");
  }

  enqueue(scope, () => callback(scopeLifetime(scope)));
}

function enqueue(scope, callback) {
  if (scope.disposed) return;
  scope.pending.push(callback);

  if (scope.mounted) {
    queueMicrotask(() => start(scope));
  }
}

function start(scope) {
  if (scope.disposed || !scope.roots.some((node) => node.isConnected)) return;

  scope.mounted = true;

  for (const callback of scope.pending.splice(0)) {
    Promise.resolve()
      .then(() => {
        if (!scope.disposed) {
          return withContext(scope, scope.roots[0]?.parentNode, () => untrack(callback));
        }
      })
      .then((cleanup) => {
        if (typeof cleanup !== "function") return;
        if (scope.disposed) cleanup();
        else scope.cleanup.push(cleanup);
      })
      .catch((error) => {
        if (!scope.disposed) reportError(error);
      });
  }
}

function activate(nodes) {
  for (const node of nodes) {
    const scopes = nodeScopes.get(node);
    if (scopes) for (const scope of scopes) start(scope);

    // Connection can attach new work. Inspect the live child after starting
    // the element, including component scopes rooted on a Text node.
    const child = node.firstChild;
    if (!child) continue;
    if (child.nodeType === Node.TEXT_NODE && !child.nextSibling && !nodeScopes.has(child)) continue;
    activate([...node.childNodes]);
  }
}

function clearRef(state) {
  if (!state.node) return;

  nodeRefs.get(state.node)?.delete(state);

  state.node = null;
}

function disposeScope(scope, errors) {
  if (scope.disposed) return;
  // An abort listener may write signals. Flush them after every descendant
  // has been revoked so queued work cannot reach its former DOM.
  batch(() => disposeScopeTree(scope, errors));
}

function disposeScopeTree(scope, errors) {
  if (scope.disposed) return;
  scope.disposed = true;
  scope.controller?.abort();
  scope.pending.length = 0;

  for (const child of [...scope.children]) disposeScopeTree(child, errors);

  for (const stop of scope.owned) {
    try { stop(); } catch (error) { errors.push(error); }
  }

  for (const callback of scope.cleanup.splice(0).reverse()) {
    try {
      callback();
    } catch (error) {
      errors.push(error);
    }
  }

  for (const state of scope.refs.values()) clearRef(state);

  for (const root of scope.roots) nodeScopes.get(root)?.delete(scope);

  scope.parent?.children.delete(scope);
  scope.parent = null;
  scope.roots.length = 0;
  scope.refs.clear();
}

function disposeNodes(nodes, errors) {
  batch(() => disposeNodeTrees(nodes, errors));
}

function childrenToDispose(parent) {
  const children = [...parent.childNodes];
  const emptyText = emptyTextChildren.get(parent);
  if (emptyText) {
    emptyTextChildren.delete(parent);
    if (!emptyText.parentNode) children.push(emptyText);
  }
  return children;
}

function disposeNodeTrees(nodes, errors) {
  for (const node of nodes) {
    const child = node.firstChild;
    if (emptyTextChildren.has(node) || (child && (child.nodeType !== Node.TEXT_NODE || child.nextSibling))) {
      // Snapshot siblings before a cleanup can move them. The snapshot also
      // includes an owned empty Text detached by normalize().
      disposeNodeTrees(childrenToDispose(node), errors);
    } else if (child) {
      disposeNodeOwners(child, errors);
    }
    disposeNodeOwners(node, errors);
  }
}

function disposeNodeOwners(node, errors) {
  const scopes = nodeScopes.get(node);
  if (scopes?.size) for (const scope of [...scopes]) disposeScopeTree(scope, errors);

  const cleanups = nodeCleanups.get(node);
  if (cleanups) for (const stop of cleanups) {
    try { stop(); } catch (error) { errors.push(error); }
  }

  const refs = nodeRefs.get(node);
  if (refs?.size) for (const state of [...refs]) clearRef(state);
}

function resolveElement(target) {
  const state = references.get(target);
  if (state) {
    if (!state.node) {
      const reason = state.owner.disposed ? "disposed" : "unbound";
      throw new Error(`Cannot use ${reason} ref: ${target.name}`);
    }

    return state.node;
  }

  if (!(target instanceof Element)) {
    throw new TypeError("Expected a DOM element or a ref(name) reference.");
  }
  return target;
}

// Replacing a region disposes its previous components and mounts its new ones.
export function update(target, content) {
  target = resolveElement(target);
  const fragment = document.createDocumentFragment();
  withContext(activeScope, target, () => append(fragment, content));

  const errors = [];
  disposeNodes(childrenToDispose(target), errors);

  target.replaceChildren(fragment);
  activate([...target.childNodes]);

  if (errors.length) {
    throw new AggregateError(errors, "Component cleanup failed.");
  }
}

export function show(element, visible = true) {
  resolveElement(element).hidden = !visible;
}

export function hide(element) {
  show(element, false);
}

export function onCleanup(callback) {
  if (typeof callback !== "function")
    throw new TypeError("Cleanup must be a function.");
  currentScope().cleanup.push(callback);
}

export function mount(parent, Component, properties = {}) {
  parent = resolveElement(parent);

  const content = document.createDocumentFragment();
  withContext(activeScope, parent, () => append(content, jsx(Component, properties)));

  const nodes = [...content.childNodes];

  parent.append(content);
  activate(nodes);

  let disposed = false;

  return () => {
    if (disposed) return;

    disposed = true;
    const errors = [];
    disposeNodes(nodes, errors);

    for (const node of nodes) node.remove();

    if (errors.length) {
      throw new AggregateError(errors, "Component cleanup failed.");
    }
  };
}

export function defineStyle(id, css) {
  if (styles.has(id)) {
    if (styles.get(id) !== css) {
      throw new Error(`Conflicting component style: ${id}`);
    }

    return;
  }

  const style = document.createElement("style");
  style.dataset.component = id;
  style.textContent = css;
  document.head.append(style);
  styles.set(id, css);
}

// Optional persisted state may be missing, malformed, or inaccessible.
export function readSessionData(key) {
  try {
    return JSON.parse(sessionStorage.getItem(key));
  } catch {
    return null;
  }
}

// Writes are required for flows such as OAuth; failure must stop the operation.
export function writeSessionData(key, value) {
  try {
    sessionStorage.setItem(key, JSON.stringify(value));
  } catch {
    throw new Error(
      "We couldn’t save your progress in this browser. Allow site storage and try again.",
    );
  }
}

// Hash values come first; repeated values remain available through getAll().
export function queryParams(source = "all") {
  if (source === "search") return new URLSearchParams(location.search);
  if (source === "hash") return new URLSearchParams(location.hash.slice(1));

  if (source !== "all") throw new TypeError('Unknown URL parameter source.');
  return new URLSearchParams([
    ...queryParams("hash"),
    ...queryParams("search"),
  ]);
}


// Return the field error, or an empty string when the password is valid.
export function validatePassword(value, { newPassword = false } = {}) {
  if (newPassword && [...value].length < 12) {
    return "Use at least 12 characters for your password.";
  }
  if (new TextEncoder().encode(value).length > 1024) {
    return "Your password is too long. Use a shorter one.";
  }
  return "";
}

function validate(field) {
  if (field.disabled) return true;

  let message = "";

  if (field.validity.valueMissing) {
    message =
      field.type === "email"
        ? "Enter your email address."
        : "Complete this field.";
  } else if (field.validity.typeMismatch) {
    message = "Enter a valid email address.";
  } else if (
    field.dataset.newPassword !== undefined ||
    field.autocomplete?.includes("password")
  ) {
    message = validatePassword(field.value, {
      newPassword: field.dataset.newPassword !== undefined,
    });
  }

  field.setAttribute("aria-invalid", String(Boolean(message)));

  const error = field.form?.querySelector(
    `#${CSS.escape(`${field.id}-error`)}`,
  );

  if (error) {
    error.textContent = message;
    error.hidden = !message;
  }

  return !message;
}

export function validateInput(event) {
  validate(event.currentTarget);
}

export function revalidateInput(event) {
  const field = event.currentTarget;
  if (field.getAttribute("aria-invalid") === "true") validate(field);
}

export function validateForm(form) {
  form = resolveElement(form);
  const fields = [...form.querySelectorAll("input")].filter(
    (field) => field.type !== "hidden",
  );

  fields
    .filter((field) => field.type === "email")
    .forEach((field) => {
      field.value = field.value.trim();
    });

  const valid = fields.map(validate);
  if (valid.includes(false)) {
    fields[valid.indexOf(false)].focus();
    return false;
  }

  return true;
}

function getHeaders(body) {
  const headers = { Accept: "application/json" };

  if (body !== undefined) {
    headers["Content-Type"] =
      body instanceof URLSearchParams
        ? "application/x-www-form-urlencoded"
        : "application/json";
  }

  return headers;
}

function isJsonResponse(response) {
  return response.headers.get("Content-Type")?.includes("application/json");
}

export async function api(
  path,
  { method = "GET", body, abort, messages = {} } = {},
) {
  const controller = new AbortController();
  const forwardAbort = () => controller.abort(abort.reason);

  if (abort?.aborted) {
    forwardAbort();
  } else {
    abort?.addEventListener("abort", forwardAbort, { once: true });
  }

  const timeout = setTimeout(() => controller.abort(), 20000);

  try {
    const response = await fetch(path, {
      method,
      credentials: "same-origin",
      cache: "no-store",
      headers: getHeaders(body),
      body:
        body === undefined || body instanceof URLSearchParams
          ? body
          : JSON.stringify(body),
      signal: controller.signal,
    });

    const data = isJsonResponse(response) ? await response.json() : null;

    if (abort?.aborted) throw abort.reason;

    if (!response.ok) {
      const error = new Error(
        messages[data?.error] ||
          (response.status === 429
            ? "Too many attempts. Wait a minute, then try again."
            : "We couldn’t complete that right now. Please try again."),
      );
      error.status = response.status;
      error.code = data?.error;
      throw error;
    }

    return data;
  } catch (error) {
    if (abort?.aborted) throw error;

    if (error.name === "AbortError") {
      throw new Error("That took too long. Please try again.");
    }

    if (error instanceof SyntaxError) {
      throw new Error(
        "We couldn’t read the server’s response. Please try again.",
      );
    }

    if (error instanceof TypeError) {
      throw new Error(
        "We couldn’t connect. Check your connection and try again.",
      );
    }

    throw error;
  } finally {
    clearTimeout(timeout);
    abort?.removeEventListener("abort", forwardAbort);
  }
}

export function notice(
  message,
  kind = "success",
  target = document.querySelector("#form-status"),
) {
  if (!target) return;
  target = resolveElement(target);
  target.textContent = message;
  target.dataset.kind = kind;
  target.hidden = false;

  if (target.isConnected) {
    target.focus();
  } else {
    queueMicrotask(() => {
      if (target.isConnected) target.focus();
    });
  }
}

// AbortSignal.any is missing before Safari 17.4 and Firefox 124. The fallback
// follows the first source to abort and then drops its other listeners.
function anySignal(signals) {
  if (typeof AbortSignal.any === "function") return AbortSignal.any(signals);
  const controller = new AbortController();
  const follow = event => {
    for (const signal of signals) signal.removeEventListener("abort", follow);
    controller.abort(event.target.reason);
  };
  for (const signal of signals) {
    if (signal.aborted) {
      follow({ target: signal });
      break;
    }
    signal.addEventListener("abort", follow, { once: true });
  }
  return controller.signal;
}

// Each caller gets its own lifetime; nested modules inherit the page's notice.
export function pageActions(parent) {
  const scope = lifetime();

  const abort = parent?.abort
    ? anySignal([scope.abort, parent.abort])
    : scope.abort;

  const showNotice = (message, kind) => {
    if (abort.aborted) return;

    const root = scope.root;
    const target = root?.matches?.("#form-status")
      ? root
      : root?.querySelector?.("#form-status");

    if (target) {
      notice(message, kind, target);
    } else {
      parent?.notice?.(message, kind);
    }
  };

  const request = (path, options = {}) => {
    const requestAbort = options.abort
      ? anySignal([abort, options.abort])
      : abort;

    const transport = parent?.request || api;

    return transport(path, { ...options, abort: requestAbort });
  };

  const run = (callback) => {
    return scope.run(async () => {
      if (abort.aborted) return;
      try {
        return await callback({ abort });
      } catch (error) {
        showNotice(error.message, "error");
      }
    });
  };

  const action =
    (callback, errorMessage = (error) => error.message) =>
    async (event) => {
      const button = event.currentTarget;
      if (abort.aborted || button.disabled) return;
      button.disabled = true;
      try {
        await callback(event);
      } catch (error) {
        showNotice(errorMessage(error), "error");
      } finally {
        if (!abort.aborted) button.disabled = false;
      }
    };

  return { abort, request, notice: showNotice, run, action };
}
