import test from 'node:test';
import assert from 'node:assert/strict';
import { load, loadFresh, pageEvents, tick } from './load.mjs';

pageEvents();
const { observeRowWindow } = await load('sliding-window.js');

function viewportOf(height) {
  const listeners = {};
  return {
    listeners, clientHeight: height, scrollTop: 0,
    ownerDocument: { defaultView: {
      requestAnimationFrame: callback => setTimeout(callback, 0), cancelAnimationFrame: clearTimeout,
      ResizeObserver: class { observe() {} disconnect() {} },
    } },
    addEventListener(type, listener) { listeners[type] = listener; }, removeEventListener() {},
  };
}

test('a dataset taller than the browser can lay out is scaled, not cut off', async () => {
  const rowCount = 2_000_000, rowHeight = 24, height = 600, limit = 16_000_000;
  const viewport = viewportOf(height), spacer = { style: {} }, band = { style: {} };
  let range, layout;
  const controller = observeRowWindow(viewport, { rowCount, rowHeight, spacer, band, maxScrollHeight: limit },
    (first, end, where) => { range = [first, end]; layout = where; });
  assert.equal(spacer.style.height, limit + 'px', 'the spacer is sized to what the browser can lay out');
  assert.deepEqual(range, [0, 33]);
  assert.equal(band.style.transform, 'translateY(0px)');

  // The furthest the browser lets the reader scroll.
  viewport.scrollTop = limit - height;
  viewport.listeners.scroll();
  await tick();
  assert.equal(range[1], rowCount, 'the last row is reachable');
  const offset = Number(/translateY\((.+)px\)/.exec(band.style.transform)[1]);
  assert.equal(offset, layout.offset);
  // The last row's bottom edge sits at the bottom of the physical scroll area.
  const lastRowBottom = offset + (rowCount - range[0]) * rowHeight;
  assert.ok(Math.abs(lastRowBottom - limit) < 1, 'the band sits under the viewport: ' + lastRowBottom);

  // Half way down the scrollbar is half way through the dataset.
  viewport.scrollTop = (limit - height) / 2;
  viewport.listeners.scroll();
  await tick();
  const middle = (range[0] + range[1]) / 2;
  assert.ok(Math.abs(middle - rowCount / 2) < 50, 'proportional position: ' + middle);
  const top = viewport.scrollTop;
  const visibleFirst = (top - Number(/translateY\((.+)px\)/.exec(band.style.transform)[1])) / rowHeight + range[0];
  assert.ok(visibleFirst >= range[0] && visibleFirst + height / rowHeight <= range[1], 'the viewport is covered by mounted rows');
  controller.dispose();
});

test('a dataset the browser can lay out keeps one pixel per pixel', async () => {
  const viewport = viewportOf(600), spacer = { style: {} };
  let range, layout;
  const controller = observeRowWindow(viewport, { rowCount: 1000, rowHeight: 24, spacer, maxScrollHeight: 16_000_000 },
    (first, end, where) => { range = [first, end]; layout = where; });
  assert.equal(spacer.style.height, '24000px');
  viewport.scrollTop = 12000;
  viewport.listeners.scroll();
  await tick();
  assert.deepEqual(range, [492, 533]);
  assert.equal(layout.offset, 492 * 24);

  // An owner that sizes its own spacer is never compressed.
  const legacy = viewportOf(600);
  let legacyRange;
  observeRowWindow(legacy, { rowCount: 2_000_000, rowHeight: 24 }, (first, end) => { legacyRange = [first, end]; }).dispose();
  assert.deepEqual(legacyRange, [0, 33]);
  controller.dispose();
});

// Gecko does not clamp an element taller than its cap: it lays it out with no
// height. The measured limit must come from the tallest height it keeps.
test('a cap that collapses taller elements is still measured', () => {
  const cap = 17_895_696;
  const viewport = viewportOf(600), spacer = { style: {} };
  const probe = { style: {}, remove() {}, getBoundingClientRect() {
    const height = parseFloat(this.style.height);
    return { height: height > cap ? 0 : height };
  } };
  viewport.ownerDocument.createElement = () => probe;
  viewport.ownerDocument.documentElement = { appendChild() {} };
  let range;
  observeRowWindow(viewport, { rowCount: 2_000_000, rowHeight: 24, spacer }, (first, end) => { range = [first, end]; }).dispose();
  assert.equal(spacer.style.height, Math.floor(cap * 0.95) + 'px');
  assert.deepEqual(range, [0, 33]);
});

function documentOf({ recover = false, route, page } = {}) {
  const app = {
    childNodes: [], attributes: new Map([['aria-busy', 'true'], ['data-saba-pending', ''], ['inert', '']]),
    dataset: { generation: 'g1', route: '/items/:id' }, inert: true,
    append(node) { this.childNodes.push(node); },
    removeAttribute(name) { this.attributes.delete(name); },
  };
  const recovery = recover ? { hidden: recover === 'hidden' } : null;
  const entry = page === null ? null : { dataset: { page, route } };
  globalThis.document = {
    app, recovery, title: '', documentElement: { lang: 'en' },
    querySelector: selector => selector.includes('data-saba-recover') ? recovery : entry,
    getElementById: () => app,
    createElement: () => ({ attributes: {}, setAttribute(name, value) { this.attributes[name] = value; } }),
  };
  globalThis.location = { pathname: '/items/42' };
  return globalThis.document;
}

test('the append-style entry leaves a reload link when its page cannot start', async () => {
  const missing = documentOf({ page: 'data:text/javascript,throw new Error("expired module")' });
  await assert.rejects(loadFresh('page-entry.js'), /expired module/);
  assert.equal(missing.app.childNodes.length, 1);
  assert.equal(missing.app.childNodes[0].href, '');
  assert.equal(missing.app.childNodes[0].textContent, 'Reload');
  assert.ok('data-saba-recover' in missing.app.childNodes[0].attributes);

  const served = documentOf({ recover: 'hidden', page: 'data:text/javascript,export default 1; export const title = "x"' });
  await assert.rejects(loadFresh('page-entry.js'), /default component/);
  assert.equal(served.recovery.hidden, false, 'a recovery link the document already has is revealed');
  assert.equal(served.app.childNodes.length, 0);

  const malformed = documentOf({ route: '/items/:id', page: 'data:text/javascript,export default 1' });
  globalThis.location = { pathname: '/items/%E0%A4%A' };
  await assert.rejects(loadFresh('page-entry.js'), URIError);
  assert.equal(malformed.app.childNodes.length, 1);
});

test('the template entry clears every pending marker and reveals recovery on failure', async () => {
  const { startPage } = await load('template-entry.js');
  const ok = documentOf({ recover: true });
  let received;
  startPage('g1', '/items/:id', 'en', (host, props) => { received = props; return () => {}; });
  assert.equal(received.params.id, '42');
  assert.equal(ok.app.inert, false);
  assert.equal(ok.app.attributes.has('aria-busy'), false);
  assert.equal(ok.app.attributes.has('data-saba-pending'), false);
  assert.equal(ok.recovery.hidden, true);

  const failed = documentOf({ recover: 'hidden' });
  assert.throws(() => startPage('g1', '/items/:id', 'en', () => { throw new Error('attach failed'); }), /attach failed/);
  assert.equal(failed.recovery.hidden, false);
  assert.equal(failed.app.attributes.has('aria-busy'), false, 'a failed page is not announced as busy forever');
});
