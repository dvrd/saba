function check(value, message) {
  if (!value) throw new Error(message);
}

// A served host waits for its module. It announces that with data-saba-pending;
// a document built before that marker existed is inert instead.
const waiting = host => host.hasAttribute('data-saba-pending') || host.inert;
const active = host => !host.hasAttribute('data-saba-pending') && !host.inert && !host.hasAttribute('aria-busy');

function loaded(frame, action) {
  const next = new Promise(resolve => frame.addEventListener('load', resolve, {once: true}));
  action();
  return next;
}

async function publish() {
  const response = await fetch('/publish', {method: 'POST'});
  check(response.ok, 'Could not publish the next fixture build');
}

function release(doc) {
  const entry = doc.querySelector('script[type="text/plain"]');
  const script = doc.createElement('script');
  script.type = 'module';
  script.src = entry.src;
  const done = new Promise(resolve => {
    script.onload = () => resolve(true);
    script.onerror = () => resolve(false);
  });
  entry.replaceWith(script);
  return done;
}

function nextClick(doc) {
  const done = new Promise(resolve => doc.addEventListener('details-settled', resolve, {once: true}));
  doc.querySelector('button').click();
  return done;
}

async function verify() {
  const frame = document.createElement('iframe');
  await loaded(frame, () => { frame.src = '/product'; document.body.append(frame); });
  let doc = frame.contentDocument;
  const host = doc.getElementById('app'), heading = doc.querySelector('h1');
  const preloads = [...doc.querySelectorAll('link[rel="modulepreload"]')].map(link => new URL(link.href).pathname);
  const entry = new URL(doc.querySelector('script').src).pathname;
  check(waiting(host) && heading.textContent === 'Product A' && !doc.querySelector('[data-saba-recover]').hidden, 'Release A must be readable before its entry runs');
  check(preloads.length > 2 && !preloads.some(url => /details|nested/.test(url)), 'Optional modules must stay outside the startup preloads');
  let transfers = await (await fetch('/requests')).json();
  check(transfers[entry] === 0 && preloads.every(url => transfers[url] === 1), 'Held A must preload each startup dependency once without fetching its entry');
  await publish();
  check(await release(doc), 'Retained A entry failed to load after B published');
  check(doc.querySelector('h1') === heading && active(host) && doc.querySelector('[data-saba-recover]').hidden && doc.querySelector('#version').textContent === 'A', 'A document attached with a different release or replaced its heading');
  await nextClick(doc);
  check(doc.querySelector('output').textContent === 'details A', 'Delayed optional import or nested import came from a different release');
  transfers = await (await fetch('/requests')).json();
  check(preloads.every(url => transfers[url] === 1) && transfers[entry] === 1, 'Activation fetched a startup dependency twice');
  const prefix = '/__saba/build/' + host.dataset.generation;
  check(transfers[prefix + '/ui/details.js'] === 1 && transfers[prefix + '/ui/nested.js'] === 1, 'Expected both delayed requests against retained A');

  await loaded(frame, () => { frame.src = '/product'; });
  doc = frame.contentDocument;
  check(doc.querySelector('h1').textContent === 'Product B' && waiting(doc.getElementById('app')), 'Expected delayed B document');
  await publish();
  check(!await release(doc), 'Retired B entry must fail to load');
  const recover = doc.querySelector('[data-saba-recover]');
  check(waiting(doc.getElementById('app')) && !recover.hidden && doc.querySelector('h1').textContent === 'Product B', 'Missing startup module lost the readable B document or its recovery link');
  await loaded(frame, () => recover.click());
  doc = frame.contentDocument;
  const c = doc.getElementById('app');
  check(active(c) && doc.querySelector('#version').textContent === 'C', 'Native recovery navigation failed to activate C');
  const output = doc.querySelector('output');
  const message = output.textContent;
  await publish();
  await nextClick(doc);
  const retry = doc.querySelector('[data-saba-recover]');
  check(!retry.hidden && active(c) && doc.querySelector('output') === output && output.textContent === message, 'Expired optional import changed the previous value or omitted recovery');
  await loaded(frame, () => retry.click());
  check(frame.contentDocument.querySelector('#version').textContent === 'D', 'Native recovery after an optional feature failure did not activate D');
}

try {
  await verify();
  document.getElementById('result').textContent = 'PASS';
} catch (error) {
  document.getElementById('result').textContent = error.stack?.includes(error.message) ? error.stack : error.message + '\n' + error.stack;
}
