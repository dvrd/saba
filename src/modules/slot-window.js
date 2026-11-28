// A contiguous logical window. Record IDs have no role in physical placement.
import {
  Fragment, getSlotRow, jsx, keyed, mount, ownSlotWindow, prepareSlotBindings,
  releaseSlotNodes, signal, watchSlotOwner,
} from "./dom.js";
import {isScalarRecord} from "./scalar-records.js";
export {scalarRecord} from "./scalar-records.js";

const empty = Symbol("unbound slot");
const activeHosts = new WeakSet();

function checkRange(first, records) {
  if (!Array.isArray(records)) throw new TypeError("A slot window expects an array of records.");
  const length = records.length;
  if (!Number.isSafeInteger(first) || first < 0 || !Number.isSafeInteger(length) || length < 0 ||
      length > 0xffffffff || !Number.isSafeInteger(first + length)) {
    throw new RangeError("A slot window requires a nonnegative, safe integer range.");
  }
  return length;
}

// [prefix, overlap, suffix]. Overlapping logical indices keep their own
// handles. The outgoing edges supply handles for incoming indices.
function allocate(old, start, first, count, makeSlot) {
  const low = Math.max(start, first), high = Math.min(start + old.length, first + count);
  if (high <= low || start === first) {
    const kept = Math.min(count, old.length);
    if (old.length === count) return {next: old, prefix: 0, suffix: count, retired: []};
    const next = old.slice(0, kept);
    while (next.length < count) next.push(makeSlot());
    return {next, prefix: 0, suffix: kept, retired: old.slice(kept)};
  }
  const prefix = low - first, suffix = high - first;
  const free = [...old.slice(0, low - start), ...old.slice(high - start)];
  const next = new Array(count);
  let used = 0;
  for (let i = 0; i < count; i++) {
    if (i >= prefix && i < suffix) next[i] = old[first + i - start];
    else next[i] = used < free.length ? free[used++] : makeSlot();
  }
  return {next, prefix, suffix, retired: free.slice(used)};
}

function move(host, element, before) {
  if (element.parentNode === host && typeof host.moveBefore === "function") host.moveBefore(element, before);
  else host.insertBefore(element, before);
}

function place(host, plan) {
  const {next, prefix, suffix} = plan;
  for (let i = 0; i < prefix; i++) move(host, next[i].element, next[prefix].element);
  for (let i = suffix; i < next.length; i++) move(host, next[i].element, null);
}

function checkedView(host, renderRow, impl) {
  if (activeHosts.has(host) || host.childNodes.length) throw new Error("A slot window needs an empty, exclusive host.");
  activeHosts.add(host);
  let disposed = false, updating = false;
  let state;
  try { state = impl(host, renderRow); }
  catch (error) { activeHosts.delete(host); throw error; }
  function finish() {
    try { state.dispose(); }
    finally { activeHosts.delete(host); }
  }
  const release = ownSlotWindow(host, () => {
    disposed = true;
    if (updating) state.cancel?.();
    else finish();
  });
  return {
    replace(first, records) {
      if (disposed || updating) throw new Error("Cannot replace a disposed or updating slot window.");
      updating = true;
      try {
        const count = checkRange(first, records);
        const snapshot = new Array(count);
        for (let i = 0; i < count; i++) snapshot[i] = records[i];
        if (disposed) throw new Error("Slot window disposed during preparation.");
        state.replace(first, snapshot);
      } finally {
        updating = false;
        if (disposed) finish();
      }
    },
    dispose: release,
  };
}

// Unknown renderers may own events, effects or multiple roots. Preserve the
// ordinary keyed lifecycle by logical index, including fragment ranges.
function trackedWindow(host, renderRow) {
  const rows = signal([]);
  const dispose = mount(host, () => jsx(Fragment, null, keyed(rows, entry => entry.index,
    entry => renderRow(() => entry().record))));
  return {dispose, replace(first, records) {
    rows.set(Array.from(records, (record, offset) => ({index: first + offset, record})));
  }};
}

function scalarWindow(host, renderRow) {
  const descriptor = getSlotRow(renderRow);
  const attrs = Object.entries(descriptor.attrs);
  let slots = [], first = 0, version = 0, closed = false;
  let dirty = false;
  const detached = new Set();
  function invalidate() { dirty = true; }
  function mutations(records) {
    for (const change of records) {
      // The viewport owner may position its band before every replacement.
      if (change.target === host && change.type === "attributes") continue;
      dirty = true;
      for (const node of change.removedNodes) detached.add(node);
    }
  }
  const observer = new MutationObserver(mutations);
  const observe = () => observer.observe(host, {subtree: true, childList: true, attributes: true, characterData: true});
  observe();

  // Drain unrelated records before the binding's own native attribute or
  // Text write. An external edit to the same tracked node still invalidates.
  function trackedWrite(callback) {
    mutations(observer.takeRecords());
    callback();
    observer.takeRecords();
  }

  // Cleanup hooks and startup effects run arbitrary application code. Keep
  // the guard active across them even while a physical plan is committing.
  function userWork(callback) {
    if (closed) return callback();
    observe();
    try { return callback(); }
    finally {
      mutations(observer.takeRecords());
      observer.disconnect();
    }
  }

  function makeSlot() {
    const doc = host.ownerDocument, element = doc.createElement(descriptor.tag), text = doc.createTextNode("");
    for (const [name, value] of attrs) element.setAttribute(name, value);
    element.append(text);
    watchSlotOwner(element, invalidate);
    watchSlotOwner(text, invalidate);
    return {element, text, record: empty, binding: null};
  }

  function stopBinding(slot, errors) {
    if (!slot.binding) return;
    userWork(() => slot.binding.dispose(errors));
    slot.binding = null;
  }

  function retire(slot, errors) {
    watchSlotOwner(slot.element, null);
    watchSlotOwner(slot.text, null);
    stopBinding(slot, errors);
    userWork(() => releaseSlotNodes([slot.element, slot.text], errors));
    slot.element.remove();
  }

  function clear(errors) {
    const current = [...host.childNodes, ...detached];
    for (const slot of slots) retire(slot, errors);
    userWork(() => releaseSlotNodes(current, errors));
    for (const node of current) if (node.parentNode === host) node.remove();
    detached.clear();
  }

  function cancel() {
    closed = true;
    version++;
  }

  function dispose() {
    cancel();
    mutations(observer.takeRecords());
    observer.disconnect();
    const errors = [];
    clear(errors);
    slots = [];
    if (errors.length) throw new AggregateError(errors, "Slot window cleanup failed.");
  }

  function replace(nextFirst, records) {
    mutations(observer.takeRecords());
    const recover = dirty;
    const base = version;
    const plan = allocate(recover ? [] : slots, first, nextFirst, records.length, makeSlot);
    dirty = false;
    let bindings;
    try {
      for (let i = 0; i < records.length; i++) {
        const slot = plan.next[i], record = records[i];
        if (slot.record === record) continue;
        if (isScalarRecord(record) && descriptor.fields.every(field => Object.hasOwn(record, field))) continue;
        bindings ||= new Map();
        bindings.set(slot, prepareSlotBindings(slot.element, slot.text, renderRow, record, trackedWrite));
      }
      mutations(observer.takeRecords());
      if (base !== version || dirty) throw new Error("Slot window ownership changed during preparation.");
    } catch (error) {
      if (bindings) for (const binding of bindings.values()) binding.dispose([]);
      dirty ||= recover;
      throw error;
    }
    observer.disconnect();
    const errors = [];
    try {
      if (recover) clear(errors);
      for (const slot of plan.retired) retire(slot, errors);
      for (let i = 0; i < records.length; i++) {
        if (closed) return;
        const slot = plan.next[i], record = records[i];
        if (slot.record === record) continue;
        stopBinding(slot, errors);
        if (closed) return;
        const binding = bindings?.get(slot);
        if (binding) {
          slot.binding = binding;
          binding.commit();
        } else descriptor.write(slot.element, slot.text, record);
        slot.record = record;
      }
      if (closed) return;
      place(host, plan);
      slots = plan.next;
      first = nextFirst;
      version++;
      if (bindings) userWork(() => {
        for (const binding of bindings.values()) {
          if (closed) break;
          binding.activate();
        }
      });
    } finally {
      if (closed) {
        if (bindings) for (const binding of bindings.values()) binding.dispose(errors);
        for (const slot of plan.next) retire(slot, errors);
      } else observe();
    }
    if (errors.length) throw new AggregateError(errors, "Slot window cleanup failed.");
  }

  return {replace, dispose, cancel};
}

export function mountSlotWindow(host, renderRow) {
  if (!(host instanceof Element) || typeof renderRow !== "function") {
    throw new TypeError("mountSlotWindow expects a host element and a JSX row function.");
  }
  const direct = host.namespaceURI === "http://www.w3.org/1999/xhtml" && getSlotRow(renderRow);
  return checkedView(host, renderRow, direct ? scalarWindow : trackedWindow);
}
