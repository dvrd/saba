// Load the browser runtime in Node without a bundler or a package.json.
// Each module becomes a data: URL with its sibling imports rewritten to the
// data: URLs of those siblings, so two importers share one instance.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

// SABA_RUNTIME_ROOT points the suite at another copy of src/ (for example an
// older checkout, to see which of these tests it fails).
const base = process.env.SABA_RUNTIME_ROOT
  ? pathToFileURL(process.env.SABA_RUNTIME_ROOT.replace(/\/?$/, '/'))
  : new URL('../../src/', import.meta.url);
const roots = [new URL('modules/', base), new URL('pages/', base)];
const urls = new Map();

function source(name) {
  for (const root of roots) {
    try { return readFileSync(new URL(name, root), 'utf8'); } catch { /* try the next root */ }
  }
  throw new Error('Unknown runtime module: ' + name);
}

export function moduleURL(name, suffix = '') {
  const key = name + suffix;
  if (urls.has(key)) return urls.get(key);
  const text = source(name).replace(
    /(\bfrom\s*|\bimport\s*)(["'])(?:\.\/|\/__saba\/)([\w.-]+\.js)\2/g,
    (_, lead, quote, dependency) => lead + quote + moduleURL(dependency) + quote,
  ) + suffix;
  const url = 'data:text/javascript;base64,' + Buffer.from(text).toString('base64');
  urls.set(key, url);
  return url;
}

export const load = name => import(moduleURL(name));

// A second evaluation of a module with top-level effects (the page entry).
let copies = 0;
export const loadFresh = name => import(moduleURL(name, '\n// copy ' + ++copies));

// Errors the runtime reports instead of throwing land here.
export const reported = [];
globalThis.reportError = error => { reported.push(error); };

// Fail a test on a rejection nobody handled.
export const unhandled = [];
process.on('unhandledRejection', error => { unhandled.push(error); });

export const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms));
export function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}

export function memoryStorage() {
  const map = new Map();
  return {
    map,
    get length() { return map.size; },
    key: index => [...map.keys()][index] ?? null,
    getItem: key => map.has(key) ? map.get(key) : null,
    setItem: (key, value) => { map.set(key, String(value)); },
    removeItem: key => { map.delete(key); },
  };
}

// A transport whose every call is held until the test settles it.
export function heldTransport(script) {
  const calls = [];
  const hold = kind => (item, ...args) => {
    const call = { kind, item, args, ...deferred() };
    calls.push(call);
    script?.(call);
    return call.promise;
  };
  return {
    calls, read: hold('read'), patch: hold('patch'), receipt: hold('receipt'),
    last: kind => calls.filter(call => call.kind === kind).at(-1),
    count: kind => calls.filter(call => call.kind === kind).length,
  };
}

// The page-level events the runtime listens for.
export function pageEvents() {
  const listeners = new Map();
  const add = (type, listener) => {
    if (!listeners.has(type)) listeners.set(type, new Set());
    listeners.get(type).add(listener);
  };
  const remove = (type, listener) => { listeners.get(type)?.delete(listener); };
  globalThis.addEventListener = add;
  globalThis.removeEventListener = remove;
  globalThis.window = { addEventListener: add, removeEventListener: remove };
  return {
    count: type => listeners.get(type)?.size ?? 0,
    dispatch(type, event = {}) { for (const listener of [...(listeners.get(type) ?? [])]) listener(event); },
  };
}
