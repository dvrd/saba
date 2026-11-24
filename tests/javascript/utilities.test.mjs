import { readFile } from 'node:fs/promises';
import test from 'node:test';
import assert from 'node:assert/strict';

const source = await readFile(new URL('../../src/modules/dom.js', import.meta.url), 'utf8');
const runtime = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

// No application modules or DOM globals are needed to load the shared runtime.
test('query parameters preserve fragment precedence and duplicate values', () => {
  globalThis.location = { search: '?token=search&tag=a&tag=b', hash: '#token=hash&tag=c' };
  assert.equal(runtime.queryParams().get('token'), 'hash');
  assert.deepEqual(runtime.queryParams().getAll('tag'), ['c', 'a', 'b']);
  assert.equal(runtime.queryParams('search').get('token'), 'search');
  assert.equal(runtime.queryParams('hash').get('token'), 'hash');
  assert.throws(() => runtime.queryParams('invalid'), TypeError);
});

test('session storage distinguishes missing state from valid falsy JSON values', () => {
  const values = new Map();
  globalThis.sessionStorage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };
  assert.equal(runtime.readSessionData('missing'), null);
  for (const value of [false, 0, '', { token: 'saved' }]) {
    runtime.writeSessionData('state', value);
    assert.deepEqual(runtime.readSessionData('state'), value);
  }
  values.set('state', '{broken');
  assert.equal(runtime.readSessionData('state'), null);
});

test('storage read failures are optional and required writes fail visibly', () => {
  globalThis.sessionStorage = {
    getItem() { throw new Error('blocked'); },
    setItem() { throw new Error('quota'); },
  };
  assert.equal(runtime.readSessionData('state'), null);
  assert.throws(() => runtime.writeSessionData('state', {}), /Allow site storage/);
});

test('password validation counts characters and limits encoded bytes', () => {
  assert.match(runtime.validatePassword('short', { newPassword: true }), /12/);
  assert.equal(runtime.validatePassword('😀'.repeat(12), { newPassword: true }), '');
  assert.equal(runtime.validatePassword('short'), '');
  assert.match(runtime.validatePassword('😀'.repeat(257)), /too long/);
});

test('JSON transport sends bodies and accepts empty or non-JSON replies', async () => {
  const original = globalThis.fetch;
  try {
    globalThis.fetch = async (path, options) => {
      assert.equal(path, '/example');
      assert.equal(options.credentials, 'same-origin');
      assert.equal(options.headers['Content-Type'], 'application/json');
      assert.equal(options.body, '{"value":1}');
      return Response.json({ saved: true });
    };
    assert.deepEqual(await runtime.api('/example', { method: 'POST', body: { value: 1 } }), { saved: true });
    globalThis.fetch = async () => new Response(null, { status: 204 });
    assert.equal(await runtime.api('/empty'), null);
    globalThis.fetch = async () => new Response('plain text');
    assert.equal(await runtime.api('/text'), null);
  } finally { globalThis.fetch = original; }
});

test('transport sends URLSearchParams without JSON encoding', async () => {
  const original = globalThis.fetch;
  const body = new URLSearchParams({ value: 'one two' });
  try {
    globalThis.fetch = async (path, options) => {
      assert.equal(options.body, body);
      assert.equal(options.headers['Content-Type'], 'application/x-www-form-urlencoded');
      return Response.json({});
    };
    await runtime.api('/example', { method: 'POST', body });
  } finally { globalThis.fetch = original; }
});

test('error messages belong to each caller while status and codes are preserved', async () => {
  const original = globalThis.fetch;
  try {
    globalThis.fetch = async () => Response.json({ error: 'denied' }, { status: 403 });
    await assert.rejects(runtime.api('/example', { messages: { denied: 'Project-specific message' } }),
      error => error.message === 'Project-specific message' && error.status === 403 && error.code === 'denied');
    await assert.rejects(runtime.api('/example'), /couldn’t complete/);
    globalThis.fetch = async () => new Response('not JSON', { headers: { 'Content-Type': 'application/json' } });
    await assert.rejects(runtime.api('/example'), /couldn’t read/);
    globalThis.fetch = async () => { throw new TypeError('network'); };
    await assert.rejects(runtime.api('/example'), /couldn’t connect/);
  } finally { globalThis.fetch = original; }
});

test('request cancellation retains the caller reason', async () => {
  const original = globalThis.fetch;
  const controller = new AbortController();
  const reason = new Error('component disposed');
  controller.abort(reason);
  try {
    globalThis.fetch = async (path, options) => {
      assert.equal(options.signal.aborted, true);
      throw options.signal.reason;
    };
    await assert.rejects(runtime.api('/example', { abort: controller.signal }), error => error === reason);
  } finally { globalThis.fetch = original; }
});
