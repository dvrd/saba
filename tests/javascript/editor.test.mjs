import test from 'node:test';
import assert from 'node:assert/strict';
import { heldTransport, load, memoryStorage, pageEvents, tick, unhandled } from './load.mjs';

pageEvents();
const { createMutationPartition } = await load('mutations.js');
const { createEditor } = await load('editor.js');

const record = (revision, title, extra = {}) => ({ status: 200, body: { id: '42', revision, title, ...extra } });
let ids = 0;
function rig({ script, storage = memoryStorage(), options = {}, editor = {} } = {}) {
  const transport = heldTransport(script);
  const partition = createMutationPartition({
    session: 'alice', tenant: 'acme', transport, storage, newId: () => 'op-' + ++ids, retryDelays: [], ...options,
  });
  const owner = new AbortController();
  const make = (extra = {}) => createEditor({ partition, item: '42', fields: ['title'], owner: owner.signal, ...editor, ...extra });
  return { transport, partition, storage, owner, make, form: make() };
}
async function opened(setup, reply = record(7, 'Lamp')) {
  const opening = setup.form.open();
  await tick();
  setup.transport.last('read').resolve(reply);
  await opening;
  return setup.form;
}

test('returning to the baseline does not close a conflict review that is still open', async () => {
  const setup = rig();
  const form = await opened(setup);
  form.edit('title', 'Desk');
  const saving = form.submit();
  await tick();
  setup.transport.last('patch').resolve({ status: 409, body: { revision: 9 } });
  await tick();
  // A lagging replica answers the conflict refresh with the revision already held.
  setup.transport.last('read').resolve(record(7, 'Lamp'));
  await saving; await tick();
  assert.equal(form.status(), 'review');
  assert.equal(form.resolveReview(7, ['title']), false, 'revision 9 has not been shown yet');

  form.edit('title', 'Lamp');
  form.edit('title', 'Desk again');
  assert.equal(form.canSave(), false, 'Save stays disabled until the review completes');
  assert.ok(form.review(), 'the review is still offered');
  assert.equal(setup.transport.count('patch'), 1);
  form.submit();
  assert.equal(setup.transport.count('patch'), 1, 'no write against the stale revision');

  const refreshing = form.refresh();
  await tick();
  setup.transport.last('read').resolve(record(9, 'Server title'));
  await refreshing;
  assert.equal(form.resolveReview(9, ['title']), true);
  assert.equal(form.canSave(), true);
  form.submit();
  await tick();
  assert.equal(JSON.parse(setup.transport.last('patch').args[0]).expectedRevision, 9);
});

test('restoration reports a failed identity check and can be tried again', async () => {
  let answer = null;
  const setup = rig({ editor: { verifyIdentity: async () => { if (!answer) throw new Error('offline'); return answer; } } });
  const form = await opened(setup);
  form.edit('title', 'draft');
  form.suspend();
  assert.equal(form.status(), 'suspended');
  assert.equal(await form.restore(), false);
  assert.equal(form.status(), 'unverified', 'a failed check is distinct from a suspension in progress');
  assert.equal(form.field('title'), '', 'nothing is shown before verification');

  answer = { session: 'alice', tenant: 'acme' };
  const restoring = form.restore();
  await tick();
  // The replica answers with an older revision than the one this editor holds.
  setup.transport.last('read').resolve(record(6, 'Older'));
  assert.equal(await restoring, true);
  assert.equal(form.status(), 'ready');
  assert.equal(form.editable(), true, 'ready means usable, not blank');
  assert.equal(form.field('title'), 'draft', 'the verified reader gets the preserved draft back');
});

test('an editor without a verifier says so instead of staying silently suspended', async () => {
  const setup = rig();
  const form = await opened(setup);
  form.suspend();
  assert.equal(await form.restore(), false);
  assert.equal(form.status(), 'unverified');
});

test('retry outside the retention window returns a result instead of throwing', async () => {
  const setup = rig({ script: call => { if (call.kind === 'receipt') call.resolve({ status: 200, body: { state: 'unknown' } }); } });
  const form = await opened(setup);
  form.edit('title', 'Desk');
  const saving = form.submit();
  await tick();
  setup.transport.last('patch').reject(new Error('connection lost'));
  await saving;
  assert.equal(form.status(), 'unknown');
  assert.equal(form.canRetry(), false);
  let result;
  assert.doesNotThrow(() => { result = form.retry(); });
  assert.deepEqual(await result, { kind: 'retry-unavailable', operationId: (await saving).operationId });
  assert.equal(form.status(), 'unknown', 'the open operation is still shown');
  assert.equal(setup.transport.count('patch'), 1);

  const inside = rig({
    options: { retentionMs: 60000 },
    script: call => { if (call.kind === 'receipt') call.resolve({ status: 200, body: { state: 'unknown' } }); },
  });
  const live = await opened(inside);
  live.edit('title', 'Desk');
  const first = live.submit();
  await tick();
  inside.transport.last('patch').reject(new Error('connection lost'));
  await first;
  assert.equal(live.canRetry(), true);
  const again = live.retry();
  await tick();
  assert.equal(inside.transport.count('patch'), 2);
  inside.transport.last('patch').resolve(record(8, 'Desk'));
  assert.equal((await again).kind, 'saved');
});

test('a record can be viewed, but not edited, when the journal is unreadable', async () => {
  const blocked = {
    get length() { throw new Error('SecurityError'); },
    key() { throw new Error('SecurityError'); }, getItem() { throw new Error('SecurityError'); },
    setItem() { throw new Error('SecurityError'); }, removeItem() {},
  };
  const setup = rig({ storage: blocked });
  const form = await opened(setup);
  assert.equal(form.status(), 'read-only');
  assert.equal(form.field('title'), 'Lamp', 'the authorized record is shown');
  assert.equal(form.editable(), false);
  form.edit('title', 'Desk');
  assert.equal(form.field('title'), 'Lamp');
  assert.equal(form.canSave(), false);
  assert.equal(setup.transport.count('patch'), 0);
});

test('an editor that cannot apply a sibling\'s reply reads the record instead of going stale', async () => {
  const setup = rig();
  const wide = setup.make({ fields: ['title', 'note'] });
  const full = record(7, 'Lamp', { note: 'n' });
  const openings = [setup.form.open(), wide.open()];
  await tick();
  for (const call of setup.transport.calls.filter(call => call.kind === 'read')) call.resolve(full);
  await Promise.all(openings);
  unhandled.length = 0;

  setup.form.edit('title', 'Desk');
  const saving = setup.form.submit();
  await tick();
  const reads = setup.transport.count('read');
  // The reply to the narrow editor omits a field the wide editor edits.
  setup.transport.last('patch').resolve(record(8, 'Desk'));
  assert.equal((await saving).kind, 'saved');
  assert.equal(setup.form.status(), 'saved');
  assert.equal(wide.status(), 'invalid-record');
  assert.equal(setup.transport.count('read'), reads + 1, 'the wide editor asked for the whole record');
  setup.transport.last('read').resolve(record(8, 'Desk', { note: 'n' }));
  await tick();
  assert.equal(wide.status(), 'ready');
  assert.equal(wide.field('title'), 'Desk');
  assert.equal(unhandled.length, 0);
});

test('a recovered update-required receipt ends in that state, not in loading', async () => {
  const storage = memoryStorage();
  storage.setItem('saba:mutation:["alice","acme"]:42:old', '1');
  const setup = rig({
    storage,
    script: call => {
      if (call.kind === 'receipt') call.resolve({ status: 200, body: { state: 'terminal', status: 409, body: { code: 'client_update_required' } } });
    },
  });
  assert.equal(await setup.form.open(), false);
  assert.equal(setup.form.status(), 'update-required');
});
