import test from 'node:test';
import assert from 'node:assert/strict';
import { heldTransport, load, memoryStorage, reported, tick, unhandled } from './load.mjs';

const { createMutationPartition, itemTransport } = await load('mutations.js');
const saved = { status: 200, body: { id: '42', revision: 8, title: 'Desk' } };
let ids = 0;
function partitionOf(extra = {}) {
  const transport = extra.transport || heldTransport(extra.script);
  const storage = extra.storage || memoryStorage();
  const partition = createMutationPartition({
    session: 'alice', tenant: 'acme', transport, storage, newId: () => 'op-' + ++ids, retryDelays: [], ...extra.options,
  });
  return { partition, transport, storage };
}

test('one failing observer does not hide an outcome from the others', async () => {
  const { partition, transport } = partitionOf();
  const seen = [];
  reported.length = 0;
  partition.observe(() => { throw new Error('observer bug'); });
  partition.observe((item, event) => seen.push(event.kind));
  const { outcome } = partition.submit('42', { title: 'Desk' }, 7);
  transport.last('patch').resolve(saved);
  assert.equal((await outcome).kind, 'saved');
  assert.deepEqual(seen, ['saved']);
  assert.deepEqual(reported.map(error => error.message), ['observer bug']);
  assert.equal(transport.count('receipt'), 0, 'an observer failure is not treated as a lost reply');
});

test('a throwing onCommitted still lets observers learn about the commit', async () => {
  const { partition, transport, storage } = partitionOf({ options: { onCommitted() { throw new Error('reader rejected'); } } });
  const seen = [];
  reported.length = 0;
  partition.observe((item, event) => seen.push(event.kind));
  const { outcome } = partition.submit('42', { title: 'Desk' }, 7);
  transport.last('patch').resolve(saved);
  assert.equal((await outcome).kind, 'saved');
  assert.deepEqual(seen, ['saved']);
  assert.deepEqual(reported.map(error => error.message), ['reader rejected']);
  assert.equal(storage.length, 0, 'the settled pointer was removed');
});

test('an exhausted receipt budget is announced and can be rechecked without writing', async () => {
  let answer = { status: 202, body: { state: 'pending' } };
  const { partition, transport, storage } = partitionOf({
    script: call => { if (call.kind === 'receipt') call.resolve(answer); },
    options: { retryDelays: [1, 1] },
  });
  const seen = [];
  partition.observe((item, event) => seen.push([item, event.kind, event.operationId]));
  const { operationId, outcome } = partition.submit('42', { title: 'Desk' }, 7);
  transport.last('patch').reject(new Error('connection lost'));
  assert.equal((await outcome).kind, 'pending');
  assert.equal(transport.count('receipt'), 3);
  assert.deepEqual(seen, [['42', 'pending', operationId]], 'observers were told the operation is still open');
  assert.equal(storage.length, 1, 'the pointer is kept');

  answer = { status: 200, body: { state: 'terminal', ...saved } };
  const later = await partition.recheck('42', operationId);
  assert.equal(later.kind, 'saved');
  assert.equal(transport.count('patch'), 1, 'rechecking reads the receipt; it never writes again');
  assert.deepEqual(seen.at(-1), ['42', 'saved', operationId]);
  assert.equal(storage.length, 0);
  assert.equal((await partition.recheck('42', 'never-submitted')).kind, 'unknown');
});

test('opening as another session removes the previous session\'s journal', () => {
  const storage = memoryStorage();
  const alice = createMutationPartition({ session: 'alice', tenant: 'acme', transport: heldTransport(), storage, newId: () => 'a1' });
  alice.submit('secret-item', { title: 'x' }, 1);
  const otherTenant = createMutationPartition({ session: 'alice', tenant: 'globex', transport: heldTransport(), storage, newId: () => 'a2' });
  otherTenant.submit('7', { title: 'y' }, 1);
  storage.setItem('unrelated', 'kept');
  storage.setItem('saba:mutation:not-json', 'kept');
  assert.equal(storage.length, 4);

  createMutationPartition({ session: 'alice', tenant: 'acme', transport: heldTransport(), storage });
  assert.equal(storage.length, 4, 'the same session keeps its pointers, in every tenant');

  createMutationPartition({ session: 'bob', tenant: 'acme', transport: heldTransport(), storage });
  assert.deepEqual([...storage.map.keys()].sort(), ['saba:mutation:not-json', 'unrelated']);
});

test('an unreadable journal is reported as such instead of rejecting', async () => {
  const errors = [];
  const blocked = {
    get length() { throw new Error('SecurityError'); },
    key() { throw new Error('SecurityError'); }, getItem() { throw new Error('SecurityError'); },
    setItem() { throw new Error('SecurityError'); }, removeItem() {},
  };
  const { partition } = partitionOf({ storage: blocked, options: { onJournalError: error => errors.push(error.message) } });
  assert.deepEqual(await partition.reconcile('42'), [{ kind: 'journal-unavailable' }]);
  assert.throws(() => partition.submit('42', { title: 'x' }, 1), /SecurityError/);
  assert.ok(errors.length >= 1);
});

test('retryable reflects the retention window and retry outside it throws nothing unexpected', async () => {
  const { partition, transport } = partitionOf({ options: { retentionMs: 60000 } });
  const { operationId, outcome } = partition.submit('42', { title: 'Desk' }, 7);
  transport.last('patch').reject(new Error('lost'));
  transport.last('receipt')?.resolve({ status: 200, body: { state: 'unknown' } });
  await tick();
  transport.last('receipt').resolve({ status: 200, body: { state: 'unknown' } });
  assert.equal((await outcome).kind, 'unknown');
  assert.equal(partition.retryable('42', operationId), true);

  const none = partitionOf();
  const pending = none.partition.submit('42', { title: 'Desk' }, 7);
  assert.equal(none.partition.retryable('42', pending.operationId), false, 'the default window is closed');
});

test('operation identifiers and deadlines work without the newest platform APIs', async () => {
  const cryptoDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'crypto');
  const any = AbortSignal.any, timeout = AbortSignal.timeout, fetchBefore = globalThis.fetch;
  const realCrypto = globalThis.crypto;
  unhandled.length = 0;
  try {
    Object.defineProperty(globalThis, 'crypto', {
      configurable: true, value: { getRandomValues: array => realCrypto.getRandomValues(array) },
    });
    AbortSignal.any = undefined;
    AbortSignal.timeout = undefined;
    const requests = [];
    globalThis.fetch = (url, options) => new Promise((resolve, reject) => {
      requests.push({ url, options });
      options.signal.addEventListener('abort', () => reject(options.signal.reason));
      if (!url.endsWith('/slow')) resolve(Response.json({ id: '42', revision: 1 }));
    });
    const storage = memoryStorage();
    const partition = createMutationPartition({ session: 'alice', tenant: 'acme', storage, transport: itemTransport('/api/items', 20) });
    const { operationId } = partition.submit('42', { title: 'x' }, 0);
    assert.match(operationId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    const reply = await partition.read('42');
    assert.equal(reply.status, 200);

    const transport = itemTransport('/api/items', 20);
    await assert.rejects(transport.read('slow'), error => error.name === 'TimeoutError');
    const caller = new AbortController();
    const cancelled = transport.read('slow', caller.signal);
    caller.abort(new Error('caller left'));
    await assert.rejects(cancelled, /caller left/);
    partition.retire();
  } finally {
    Object.defineProperty(globalThis, 'crypto', cryptoDescriptor);
    AbortSignal.any = any;
    AbortSignal.timeout = timeout;
    globalThis.fetch = fetchBefore;
  }
  await tick(30);
  assert.equal(unhandled.length, 0);
});
