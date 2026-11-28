// Run with Node and Playwright's full Chromium. PLAYWRIGHT_PATH may point to
// a locally installed Playwright package, as in the scale benchmark driver.
'use strict';
const {readFileSync} = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.PLAYWRIGHT_PATH || 'playwright');

async function main() {
  const source = readFileSync(path.join(__dirname, 'text-band.js'), 'utf8');
  const browser = await chromium.launch({channel: 'chromium'});
  try {
    const page = await browser.newPage();
    await page.route('http://saba.test/', route => route.fulfill({
      contentType: 'text/html', body: '<!doctype html><body></body>',
    }));
    await page.route('http://saba.test/text-band.js', route => route.fulfill({
      contentType: 'text/javascript', body: source,
    }));
    await page.goto('http://saba.test/');
    await page.evaluate(async () => {
      const module = await import('/text-band.js');
      const record = (id, score, group = 0) => Object.freeze({id, group, score});
      const a = record(42, 1), b = record(-3, 2), c = record(7801, 3);
      const d = record(15, 4), e = record(90001, 5);

      for (const name of ['mountTextBand', 'mountDomBand']) {
        let step = 'mount';
        function check(condition, detail) {
          if (!condition) throw new Error(name + ' / ' + step + ': ' + detail);
        }
        const host = document.createElement('div');
        document.body.append(host);
        const mount = module[name];
        const band = mount(host, Object.freeze([a, b, c, d]));
        let previous = new Map();

        function verify(rows) {
          check(host.childNodes.length === rows.length, 'unexpected number of roots');
          const current = new Map();
          rows.forEach((row, i) => {
            const element = host.children[i];
            check(element?.matches('div.cell'), 'unexpected element at ' + i);
            check(element.getAttribute('data-id') === String(row.id), 'wrong key at ' + i);
            const text = element.firstChild;
            check(element.childNodes.length === 1 && text.nodeType === Node.TEXT_NODE, 'wrong child shape at ' + i);
            check(text.data === row.id + ' · ' + row.score, 'wrong value for ' + row.id);
            const old = previous.get(row.id);
            if (old) {
              check(element === old.element, 'replaced element for retained key ' + row.id);
              check(text === old.text, 'replaced text node for retained key ' + row.id);
            }
            current.set(row.id, {element, text});
          });
          for (const [id, old] of previous) {
            if (!current.has(id)) check(!old.element.isConnected, 'removed key still connected: ' + id);
          }
          previous = current;
        }
        function replace(label, rows) {
          step = label;
          band.replace(Object.freeze(rows));
          verify(rows);
        }

        verify([a, b, c, d]);
        const observer = new MutationObserver(() => {});
        observer.observe(host, {subtree: true, childList: true, characterData: true});
        replace('new records with the same visible values', [record(42, 1, 7), record(-3, 2), c, d]);
        check(observer.takeRecords().length === 0, 'rewrote unchanged text or children');
        observer.disconnect();

        replace('interior reorder with equal first key and length', [a, c, b, d]);
        const changed = record(c.id, c.score + 10);
        replace('simultaneous move, replacement, and text update', [d, changed, e, a]);
        replace('append and prepend', [b, d, changed, e, a, record(809, 6)]);
        replace('remove and move', [e, b]);
        replace('clear', []);
        replace('clear an empty band', []);
        replace('refill', [c, a]);
        step = 'dispose';
        band.dispose();
        verify([]);
        band.dispose();
        verify([]);

        step = 'initially empty';
        const emptyBand = mount(host, Object.freeze([]));
        verify([]);
        emptyBand.replace(Object.freeze([b]));
        verify([b]);
        emptyBand.dispose();
        verify([]);
        host.remove();
      }
    });
    console.log('Both text bands preserved keyed element and text identity, avoided equal-value writes, and disposed cleanly.');
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
