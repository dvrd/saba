// Run with node --test benchmarks/frameworks/experiments/sliding-window-test.mjs.
import assert from 'node:assert/strict';
import test from 'node:test';
import {observeRowWindow} from '../../../src/modules/sliding-window.js';

function fixture({rowCount = 100, height = 100, top = 0, ...options} = {}) {
  const frames = new Map();
  const listeners = new Map();
  const observations = new Map();
  const ranges = [];
  let frameId = 0;
  let time = 0;
  const view = {
    requestAnimationFrame(callback) {
      frames.set(++frameId, callback);
      return frameId;
    },
    cancelAnimationFrame(id) { frames.delete(id); },
    ResizeObserver: class {
      constructor(callback) { this.callback = callback; }
      observe(element) { observations.set(this, element); }
      disconnect() { observations.delete(this); }
    },
  };
  const viewport = {
    ownerDocument: {defaultView: view},
    scrollTop: top,
    clientHeight: height,
    addEventListener(type, callback, settings) {
      assert.equal(type, 'scroll');
      assert.equal(settings.passive, true);
      listeners.set(type, callback);
    },
    removeEventListener(type, callback) {
      if (listeners.get(type) === callback) listeners.delete(type);
    },
  };
  const controller = observeRowWindow(viewport, {rowCount, rowHeight: 20, ...options},
    (first, end) => ranges.push([first, end]));
  return {
    controller, ranges, frames, listeners, observations,
    scroll(value) {
      viewport.scrollTop = value;
      listeners.get('scroll')?.({type: 'scroll', target: viewport});
    },
    resize(value) {
      viewport.clientHeight = value;
      for (const [observer, element] of observations) {
        observer.callback([{target: element, contentRect: {height: value}}], observer);
      }
    },
    flushFrame() {
      time += 16;
      for (const [id, callback] of Array.from(frames)) {
        if (frames.delete(id)) callback(time);
      }
    },
  };
}

test('initial window, clipped head and tail, and immediate recovery after a jump', () => {
  const f = fixture();
  assert.deepEqual(f.ranges, [[0, 13]]);
  f.scroll(10);
  f.scroll(60);
  f.flushFrame();
  assert.equal(f.ranges.length, 1);
  f.scroll(1000);
  assert.deepEqual(f.ranges.at(-1), [42, 63]);
  f.scroll(1900);
  assert.deepEqual(f.ranges.at(-1), [87, 100]);
  const atTail = f.ranges.length;
  f.scroll(1899.5);
  f.scroll(1900);
  f.flushFrame();
  assert.equal(f.ranges.length, atTail);
  f.scroll(-8);
  assert.deepEqual(f.ranges.at(-1), [0, 13]);
  f.controller.dispose();
});

test('low-water refill coalesces scrolls while the old window covers the view', () => {
  const f = fixture();
  for (const top of [40, 80, 100, 110, 120]) f.scroll(top);
  assert.deepEqual(f.ranges, [[0, 13]]);
  assert.equal(f.frames.size, 1);
  f.flushFrame();
  assert.deepEqual(f.ranges, [[0, 13], [0, 19]]);
  assert.equal(f.frames.size, 0);
  f.controller.dispose();
});

test('custom buffer and threshold refill both edges with fractional row heights', () => {
  const f = fixture({rowCount: 1_000_000, height: 42, rowHeight: 10.5, overscanRows: 4, thresholdRows: 1});
  assert.deepEqual(f.ranges, [[0, 8]]);
  f.scroll(21);
  assert.equal(f.frames.size, 0);
  f.scroll(31.5);
  assert.equal(f.frames.size, 1);
  f.flushFrame();
  assert.deepEqual(f.ranges.at(-1), [0, 11]);
  f.scroll(10_500);
  assert.deepEqual(f.ranges.at(-1), [996, 1008]);
  f.scroll(10_500 - 2 * 10.5);
  assert.equal(f.frames.size, 0);
  f.scroll(10_500 - 3 * 10.5);
  assert.equal(f.frames.size, 1);
  f.flushFrame();
  assert.deepEqual(f.ranges.at(-1), [993, 1005]);
  f.controller.dispose();
});

test('reversing or jumping before a queued frame never publishes an obsolete window', () => {
  const f = fixture();
  f.scroll(80);
  f.scroll(100);
  assert.equal(f.frames.size, 1);
  f.scroll(0);
  f.flushFrame();
  assert.deepEqual(f.ranges, [[0, 13]]);
  f.scroll(80);
  f.scroll(100);
  f.scroll(1800);
  assert.deepEqual(f.ranges.at(-1), [82, 100]);
  const afterJump = f.ranges.length;
  f.flushFrame();
  assert.equal(f.ranges.length, afterJump);
  f.controller.dispose();
});

test('a fast continuous step refills while the old range still covers the visible rows', () => {
  const f = fixture();
  f.scroll(60);
  f.scroll(120);
  // Two rows remain, but another three-row step would expose an unmounted row.
  assert.deepEqual(f.ranges, [[0, 13], [0, 19]]);
  f.scroll(180);
  assert.equal(f.ranges.length, 2);
  f.controller.dispose();
});

test('fractional geometry includes a partially visible last row and resize needs no scroll', () => {
  const f = fixture({height: 101, top: 799.5});
  assert.deepEqual(f.ranges, [[31, 54]]);
  f.resize(501);
  f.flushFrame();
  assert.deepEqual(f.ranges.at(-1), [31, 74]);
  f.resize(0);
  f.flushFrame();
  const hidden = f.ranges.at(-1);
  assert.equal(hidden[0], hidden[1]);
  f.resize(101);
  f.flushFrame();
  assert.deepEqual(f.ranges.at(-1), [31, 54]);
  f.controller.dispose();
});

test('empty, shorter-than-viewport, grown and truncated data all stay in bounds', () => {
  const f = fixture({rowCount: 0});
  assert.deepEqual(f.ranges, [[0, 0]]);
  f.controller.setRowCount(3);
  assert.deepEqual(f.ranges.at(-1), [0, 3]);
  f.controller.setRowCount(100);
  f.flushFrame();
  assert.deepEqual(f.ranges.at(-1), [0, 13]);
  f.scroll(1900);
  f.controller.setRowCount(6);
  assert.deepEqual(f.ranges.at(-1), [0, 6]);
  f.controller.setRowCount(0);
  assert.deepEqual(f.ranges.at(-1), [0, 0]);
  f.controller.dispose();
});

test('disposed owners release the scroll listener, resize observer and frame', () => {
  const f = fixture();
  f.scroll(80);
  f.scroll(100);
  assert.equal(f.frames.size, 1);
  assert.equal(f.observations.size, 1);
  f.controller.dispose();
  f.controller.dispose();
  assert.equal(f.listeners.size, 0);
  assert.equal(f.observations.size, 0);
  assert.equal(f.frames.size, 0);
  f.scroll(1900);
  f.resize(500);
  f.flushFrame();
  assert.deepEqual(f.ranges, [[0, 13]]);
});

test('invalid dimensions and buffers fail before mounting', () => {
  for (const options of [
    {rowCount: -1}, {rowCount: 0.5}, {rowHeight: 0}, {rowHeight: Infinity},
    {overscanRows: -1}, {overscanRows: 2.5}, {thresholdRows: -1},
    {overscanRows: 2, thresholdRows: 3}, {overscanRows: 3, thresholdRows: 3},
  ]) {
    assert.throws(() => fixture(options), undefined, JSON.stringify(options));
  }
  const f = fixture();
  assert.throws(() => f.controller.setRowCount(-1));
  assert.deepEqual(f.ranges, [[0, 13]]);
  f.controller.dispose();
});
