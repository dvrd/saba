import test from 'node:test';
import assert from 'node:assert/strict';
import { deferred, load, pageEvents, reported, tick, unhandled } from './load.mjs';

const page = pageEvents();
const { effect, signal } = await load('dom.js');
const { createReadPartition } = await load('reads.js');

function heldLoader() {
  const requests = [];
  const loader = (key, abort) => {
    const request = { key, abort, ...deferred() };
    requests.push(request);
    return request.promise;
  };
  return { requests, loader };
}
const denied = status => Object.assign(new Error('denied'), { status });

test('a denied read retires only its own key unless the application declares families', async () => {
  const { requests, loader } = heldLoader();
  const partition = createReadPartition(loader);
  const owner = new AbortController();
  const lamp = partition.read(['item', '42'], owner.signal), desk = partition.read(['item', '43'], owner.signal);
  await tick();
  requests[1].resolve({ id: '43' });
  await tick();
  requests[0].reject(denied(404));
  await tick();
  assert.equal(lamp.state().status, 'forbidden');
  assert.equal(desk.state().status, 'ready', 'a sibling record of the same operation stayed readable');
  assert.deepEqual(desk.state().value, { id: '43' });
  partition.dispose();

  const shared = heldLoader();
  const families = createReadPartition(shared.loader, { familyFor: () => 'items' });
  const first = families.read(['item', '42'], owner.signal), second = families.read(['search', 'la'], owner.signal);
  await tick();
  shared.requests[1].resolve(['42']);
  await tick();
  shared.requests[0].reject(denied(403));
  await tick();
  assert.equal(first.state().status, 'forbidden');
  assert.equal(second.state().status, 'forbidden', 'a declared family is still retired together');
  families.dispose();
});

test('a failing subscriber cannot turn a publication into an unhandled rejection', async () => {
  const { requests, loader } = heldLoader();
  const partition = createReadPartition(loader);
  const owner = new AbortController();
  const handle = partition.read(['item', '1'], owner.signal);
  const loop = signal(0);
  reported.length = 0; unhandled.length = 0;
  // A non-settling flush is thrown to whoever wrote the signal: here, the read.
  const stop = effect(() => { const n = loop(); if (handle.state().status === 'ready') loop.set(n + 1); });
  await tick();
  requests[0].resolve('value');
  await tick(); await tick();
  assert.equal(handle.state().status, 'ready');
  assert.equal(unhandled.length, 0);
  assert.ok(reported.some(error => /pass limit/.test(error.message)), 'the failure was reported');
  stop();
  partition.dispose();
});

test('remembered revisions are bounded and watched keys are never forgotten', async () => {
  let answer = { revision: 5 };
  const partition = createReadPartition(async () => answer, { revisionOf: (_, value) => value.revision, revisionLimit: 2 });
  const owner = new AbortController();
  const watched = partition.read(['item', 'watched'], owner.signal);
  await tick();
  assert.equal(watched.state().status, 'ready');
  for (let n = 0; n < 50; n++) await partition.confirm(['item', 'closed-' + n], { revision: 9 });

  // A key nobody watches is eventually forgotten: its older answer is accepted again.
  const temporary = new AbortController();
  answer = { revision: 1 };
  const forgotten = partition.read(['item', 'closed-0'], temporary.signal);
  await tick();
  assert.equal(forgotten.state().status, 'ready', 'the oldest unwatched revision was dropped');
  temporary.abort();

  // The watched key still rejects a stale replica answer after all of that.
  answer = { revision: 4 };
  await watched.refresh();
  assert.equal(watched.state().status, 'error');
  assert.equal(watched.state().value.revision, 5);
  partition.dispose();
});

test('a restored document shows nothing until its identity is verified', async () => {
  const { requests, loader } = heldLoader();
  let who = { session: 'alice', tenant: 'acme' }, checks = 0, changed = null;
  const partition = createReadPartition(loader, {
    identity: { session: 'alice', tenant: 'acme' },
    verifyIdentity: async () => { checks++; if (!who) throw new Error('offline'); return who; },
    onIdentityChanged: next => { changed = next; },
  });
  const owner = new AbortController();
  const handle = partition.read(['item', '42'], owner.signal);
  await tick();
  requests[0].resolve('private');
  await tick();
  assert.equal(handle.state().value, 'private');

  page.dispatch('pagehide', { persisted: false });
  assert.equal(handle.state().status, 'ready', 'an ordinary exit is left to the owning scope');

  page.dispatch('pagehide', { persisted: true });
  assert.equal(handle.state().status, 'suspended');
  assert.equal(handle.state().value, undefined, 'the confirmed value is hidden while suspended');

  who = null;
  page.dispatch('pageshow', { persisted: true });
  await tick();
  assert.equal(handle.state().status, 'suspended', 'a failed check keeps the partition suspended');
  who = { session: 'alice', tenant: 'acme' };
  assert.equal(await partition.restore(), true, 'the check can be tried again');
  assert.equal(handle.state().status, 'refreshing');
  assert.equal(handle.state().value, 'private');
  assert.equal(requests.length, 2, 'the record is read again after restoration');
  requests[1].resolve('fresh');
  await tick();
  assert.equal(handle.state().value, 'fresh');

  partition.suspend();
  who = { session: 'bob', tenant: 'acme' };
  assert.equal(await partition.restore(), false);
  assert.equal(handle.state().status, 'closed', 'another identity never sees the previous values');
  assert.deepEqual(changed, who);
  assert.equal(requests.length, 2, 'no request was issued for the other identity');
  assert.equal(page.count('pagehide') + page.count('pageshow'), 0, 'a closed partition removes its page listeners');
  assert.ok(checks >= 3);
});

test('without a verifier a restored partition drops its values and reads again', async () => {
  const { requests, loader } = heldLoader();
  const partition = createReadPartition(loader);
  const owner = new AbortController();
  const handle = partition.read(['item', '42'], owner.signal);
  await tick();
  requests[0].resolve('before');
  await tick();
  page.dispatch('pagehide', { persisted: true });
  page.dispatch('pageshow', { persisted: true });
  await tick();
  assert.equal(handle.state().status, 'pending');
  assert.equal(requests.length, 2);
  partition.dispose();
});
