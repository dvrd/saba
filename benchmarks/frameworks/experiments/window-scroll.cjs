// Run from the checkout with Node and Playwright's full Chromium:
// node benchmarks/frameworks/experiments/window-scroll.cjs /tmp/window-scroll.json
'use strict';
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const {readFileSync, writeFileSync} = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {chromium} = require(process.env.PLAYWRIGHT_PATH || 'playwright');

const count = 1_000_000;
const rounds = 4;
const origin = 'http://saba.test';
const assets = {
  '/': '../rich/scale.html', '/scale.js': '../rich/scale.js',
  '/reactivity.js': '../rich/reactivity.js', '/sliding-window.js': '../../../src/modules/sliding-window.js',
};
const repeat = (value, length) => Array(length).fill(value);
const motion = [...repeat(13, 16), ...repeat(26, 32), ...repeat(-26, 12),
  ...repeat(78, 8), ...repeat(-52, 14)];
const wheels = [26, 52, 78, 208, 416, 832, -52, -208, -416, 52, 78, -26];

// Install after mount. This sampler only reads the committed range. It never
// requests a refill. Listen during capture to inspect coverage before the
// fixture's target scroll listener can change that range.
function installProbe(count) {
  const viewport = document.querySelector('#viewport');
  const band = viewport.querySelector('.band');
  const rowHeight = 26, columns = 8;
  let active;
  let requested;
  let updated = false;
  const frame = () => new Promise(resolve => requestAnimationFrame(resolve));
  const settle = async () => { await frame(); await frame(); };
  const stats = () => window.scale.windowStats();
  function covered(range) {
    const first = Math.floor(viewport.scrollTop / rowHeight) * columns;
    const end = Math.min(count, Math.ceil((viewport.scrollTop + viewport.clientHeight) / rowHeight) * columns);
    return range.first <= first && range.end >= end;
  }
  function hits() {
    const rect = viewport.getBoundingClientRect();
    // Use centers of the visible portions of the first and last rows, so
    // fractional viewport origins do not round a hit onto an adjacent row.
    const top = viewport.scrollTop, height = viewport.clientHeight;
    const firstHeight = Math.min(height, rowHeight - (top % rowHeight));
    const lastHeight = Math.min(height, (top + height) % rowHeight || rowHeight);
    for (const y of [firstHeight / 2, height - lastHeight / 2]) {
      for (const col of [0, columns - 1]) {
        const x = rect.left + (col + 0.5) * viewport.clientWidth / columns;
        const node = document.elementFromPoint(x, rect.top + y);
        const id = Math.floor((viewport.scrollTop + y) / rowHeight) * columns + col;
        const score = (id * 37 + (id % 23) * 13) % 1000 +
          (updated && (id % 97 === 0 || id === count - 1) ? 7 : 0);
        if (node?.getAttribute('data-id') !== String(id) || node.textContent !== id + ' · ' + score) {
          window.probe.missed = {id, actual: node?.getAttribute('data-id'), text: node?.textContent?.slice(0, 80), x, y, top: viewport.scrollTop, rectTop: rect.top};
          return false;
        }
      }
    }
    return true;
  }
  function sample(time) {
    const range = stats();
    active.frames++;
    const mounted = band.childElementCount;
    if (range.end - range.first !== mounted ||
      Number(band.firstElementChild.dataset.id) !== range.first ||
      Number(band.lastElementChild.dataset.id) !== range.end - 1) {
      active.invalidRanges++;
    }
    active.maxMounted = Math.max(active.maxMounted, mounted);
    if (!covered(range) || !hits()) active.uncoveredFrames++;
    if (active.lastTime !== null) active.gaps.push(time - active.lastTime);
    active.lastTime = time;
    requested = requestAnimationFrame(sample);
  }
  document.addEventListener('scroll', event => {
    if (!active || event.target !== viewport) return;
    active.events++;
    if (!covered(stats())) active.uncoveredBeforeScrollHandler++;
  }, {capture: true, passive: true});
  viewport.addEventListener('wheel', event => {
    if (active && event.isTrusted) active.trustedWheels++;
  }, {passive: true});
  function begin() {
    const {reconciles, reconcileMs} = stats();
    active = {reconciles, reconcileMs, events: 0, trustedWheels: 0, frames: 0,
      invalidRanges: 0, uncoveredBeforeScrollHandler: 0, uncoveredFrames: 0,
      lastTime: null, maxMounted: 0, gaps: []};
    requested = requestAnimationFrame(sample);
  }
  function end() {
    cancelAnimationFrame(requested);
    const {gaps, lastTime, ...result} = active;
    const now = stats();
    result.reconciles = now.reconciles - result.reconciles;
    result.reconcileMs = now.reconcileMs - result.reconcileMs;
    gaps.sort((a, b) => a - b);
    result.p95RafIntervalMs = gaps[Math.ceil(gaps.length * 0.95) - 1] ?? null;
    result.maxRafIntervalMs = gaps.at(-1) ?? null;
    active = undefined;
    return result;
  }
  async function move(deltas) {
    begin();
    const misses = [];
    for (const delta of deltas) {
      viewport.scrollTop += delta;
      const range = stats();
      if (!covered(range)) misses.push({delta, top: viewport.scrollTop, first: range.first, end: range.end});
      await frame();
    }
    await settle();
    return {...end(), uncoveredBeforeEvent: misses.length, misses};
  }
  async function resize(height) {
    viewport.style.height = height + 'px';
    const before = covered(stats());
    await settle();
    return {before, after: covered(stats()) && hits(), mounted: band.childElementCount};
  }
  async function overlap() {
    const old = new Map(Array.from(band.children, node => [node.getAttribute('data-id'), node]));
    viewport.scrollTop += rowHeight * 8;
    await settle();
    let retained = 0;
    for (const node of band.children) {
      const previous = old.get(node.getAttribute('data-id'));
      if (previous) {
        if (previous !== node) throw Error('Overlapping cell replaced during scroll');
        retained++;
      }
    }
    if (!retained || !hits()) throw Error('Unverified partial window overlap');
    return retained;
  }
  window.probe = {begin, end, settle, hits, move, resize, overlap, markUpdated() { updated = true; }};
}

async function visit(files, scenario) {
  const browser = await chromium.launch({channel: 'chromium'});
  try {
    const page = await browser.newPage({viewport: {width: 1200, height: 900}});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route(origin + '/**', route => {
      const pathname = new URL(route.request().url()).pathname;
      return files[pathname] ? route.fulfill({body: files[pathname],
        contentType: pathname === '/' ? 'text/html' : 'text/javascript'}) : route.abort();
    });
    await page.goto(origin + '/?mode=saba-planned&scenario=' + scenario + '&count=' + count);
    await page.waitForFunction(() => window.scale);
    await page.evaluate(() => { window.scale.start(); window.scale.allowUpdates(); });
    await page.evaluate(installProbe, count);
    await page.evaluate(() => window.probe.settle());
    assert.deepEqual(await page.evaluate(() => window.probe.hits() ? null : window.probe.missed), null);
    await page.locator('#mutate').click();
    const update = await page.evaluate(() => {
      window.probe.markUpdated();
      return window.scale.verifyUpdate();
    });
    assert.equal(update.changed, 10311);
    assert.equal(update.checksum, 499566514);
    const moves = await page.evaluate(motion => window.probe.move(motion), motion);
    assert.equal(moves.events, motion.length);
    assert.equal(moves.invalidRanges, 0);
    assert.equal(moves.uncoveredFrames, 0);
    if (scenario === 'buffered') {
      assert.deepEqual(moves.misses, [], 'Scripted movement outran the buffered window');
      assert.ok(moves.reconciles < motion.length / 2, 'Buffered window still reconciled on most scroll events');
    }
    const retainedAfterScroll = await page.evaluate(() => window.probe.overlap());

    const center = await page.locator('#viewport').boundingBox();
    await page.mouse.move(center.x + center.width / 2, center.y + center.height / 2);
    await page.evaluate(() => window.probe.begin());
    for (const delta of wheels) {
      const previous = await page.locator('#viewport').evaluate(node => node.scrollTop);
      await page.mouse.wheel(0, delta);
      await page.waitForFunction(top => document.querySelector('#viewport').scrollTop !== top, previous);
    }
    await page.evaluate(() => window.probe.settle());
    const wheel = await page.evaluate(() => window.probe.end());
    assert.equal(wheel.trustedWheels, wheels.length);
    assert.ok(wheel.frames > 0 && wheel.events > 0);
    assert.equal(wheel.invalidRanges, 0);
    assert.equal(wheel.uncoveredFrames, 0);

    const resized = await page.evaluate(() => window.probe.resize(728));
    if (scenario === 'buffered') assert.ok(resized.after, 'Resize left visible cells uncovered');
    await page.evaluate(() => window.probe.resize(416));
    await page.evaluate(() => window.probe.begin());
    await page.locator('#jump').click();
    await page.waitForFunction(() => document.querySelector('#status').textContent === 'Final row');
    await page.evaluate(() => window.probe.settle());
    const jumpFrames = await page.evaluate(() => window.probe.end());
    assert.equal(jumpFrames.uncoveredFrames, 0);
    const final = await page.evaluate(() => window.scale.verifyEnd());
    assert.equal(final.lastId, count - 1);
    assert.equal(final.lastText, '999999 · 35');
    for (const segment of [moves, wheel, jumpFrames]) {
      assert.ok(segment.maxMounted <= (scenario === 'buffered' ? 33 : 21) * 8);
      assert.ok(Number.isFinite(segment.reconcileMs) && segment.reconcileMs >= 0);
    }
    assert.deepEqual(errors, []);
    return {scenario, chromium: browser.version(), moves, wheel, resized, retainedAfterScroll,
      jump: {frames: jumpFrames, ...final}, update};
  } finally {
    await browser.close();
  }
}

async function main() {
  assert.ok(process.argv[2], 'Pass an output JSON path');
  const files = Object.fromEntries(Object.entries(assets).map(([url, file]) =>
    [url, readFileSync(path.resolve(__dirname, file))]));
  const sha = data => createHash('sha256').update(data).digest('hex');
  const result = {method: 'Fresh full headless Chromium per visit. Four alternating paired rounds, same planned Saba cell and one million local records. Continuous movement by one scrollTop assignment per animation frame, then native wheels through Playwright. A capture listener samples coverage before the fixture scroll handler. A requestAnimationFrame observer checks range against actual DOM and hit-tests first and last visible rows. Reconciliation time counts the fixture synchronous window work. rAF intervals include the observer and represent main-thread sampling, not compositor presentation or input-to-paint latency.',
    count, cpu: os.cpus()[0].model, motion, wheels, sourceSha256: Object.fromEntries(
      Object.entries({...files, driver: readFileSync(__filename)}).map(([name, bytes]) => [name, sha(bytes)])), visits: []};
  for (let round = 0; round < rounds; round++) {
    for (const scenario of round % 2 ? ['buffered', 'virtual'] : ['virtual', 'buffered']) {
      result.visits.push({round: round + 1, ...await visit(files, scenario)});
      console.log('Completed round', round + 1, scenario);
    }
  }
  writeFileSync(process.argv[2], JSON.stringify(result, null, 2) + '\n');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
