import test from 'node:test';
import assert from 'node:assert/strict';
import { load, reported } from './load.mjs';

const { batch, computed, effect, onCleanup, signal, untrack } = await load('dom.js');

test('each evaluation of an effect owns what it created', () => {
  const key = signal(0), other = signal(0);
  let innerRuns = 0, cleanups = 0, returned = 0, derived = 0;
  const stop = effect(() => {
    key();
    effect(() => { other(); innerRuns++; });
    const twice = computed(() => { derived++; return other() * 2; });
    effect(() => { twice(); });
    onCleanup(() => cleanups++);
    return () => returned++;
  });
  for (let n = 1; n <= 5; n++) key.set(n);
  assert.equal(cleanups, 5, 'onCleanup of every finished evaluation ran before the next one');
  assert.equal(returned, 5, 'the returned cleanup ran before the next evaluation');

  const before = innerRuns, derivedBefore = derived;
  other.set(1);
  assert.equal(innerRuns - before, 1, 'only the current nested effect is still subscribed');
  assert.equal(derived - derivedBefore, 1, 'only the current computed is still live');

  stop();
  assert.equal(cleanups, 6);
  assert.equal(returned, 6);
  other.set(2);
  assert.equal(innerRuns - before, 1, 'stopping the effect stops what its last evaluation created');
});

test('a cleanup does not subscribe the effect to what it reads', () => {
  const source = signal(0), incidental = signal(0);
  let runs = 0;
  const stop = effect(() => { source(); runs++; return () => { incidental(); }; });
  source.set(1);
  incidental.set(1);
  assert.equal(runs, 2);
  stop();
});

test('an effect error is reported and does not reach the writer', () => {
  const source = signal(0);
  let healthy = 0;
  reported.length = 0;
  const stopBroken = effect(() => { if (source() === 1) throw new Error('broken effect'); });
  const stopHealthy = effect(() => { source(); healthy++; });
  assert.doesNotThrow(() => source.set(1));
  assert.equal(healthy, 2, 'the other effect still ran');
  assert.deepEqual(reported.map(error => error.message), ['broken effect']);
  source.set(2);
  assert.equal(healthy, 3, 'the scheduler keeps working');
  stopBroken(); stopHealthy();
});

test('batch rethrows its own exception, not an effect error', () => {
  const source = signal(0);
  reported.length = 0;
  const stop = effect(() => { if (source()) throw new Error('effect error'); });
  assert.throws(() => batch(() => { source.set(1); throw new Error('original'); }), /original/);
  assert.deepEqual(reported.map(error => error.message), ['effect error']);
  stop();
});

test('a non-settling flush is reported and bystanders see the final values', () => {
  const value = signal(0), loop = signal(0);
  const seen = [];
  let armed = false;
  const stopReader = effect(() => { seen.push(value()); });
  const stopLoop = effect(() => {
    const n = loop();
    if (armed) { value.set(n); loop.set(n + 1); }
  });
  armed = true;
  assert.throws(() => loop.set(1), /pass limit/);
  armed = false;
  assert.equal(seen.at(-1), untrack(value), 'the reading effect was not left stale');

  const independent = signal(0);
  let runs = 0;
  const stopIndependent = effect(() => { independent(); runs++; });
  independent.set(1);
  assert.equal(runs, 2, 'later writes still flush');
  stopReader(); stopLoop(); stopIndependent();
});

test('writing the value a signal already holds wakes nothing', () => {
  const count = signal(1), missing = signal(NaN);
  let runs = 0;
  const stop = effect(() => { count(); missing(); runs++; });
  count.set(1);
  missing.set(NaN);
  assert.equal(runs, 1, 'an equal write, NaN included, is not a change');
  count.set(2);
  assert.equal(runs, 2);
  stop();
});

test('a computed that recomputes to the same value does not rerun its readers', () => {
  const count = signal(0);
  let derived = 0, runs = 0;
  const parity = computed(() => { derived++; return count() % 2; });
  const stop = effect(() => { parity(); runs++; });
  count.set(2);
  assert.equal(derived, 2, 'the computed saw the new input');
  assert.equal(runs, 1, 'its reader did not run for an unchanged result');
  count.set(3);
  assert.equal(runs, 2);
  stop();
});

test('an effect stops following a signal its latest evaluation did not read', () => {
  const useFirst = signal(true), first = signal(0), second = signal(0);
  let runs = 0;
  const stop = effect(() => { (useFirst() ? first : second)(); runs++; });
  useFirst.set(false);
  assert.equal(runs, 2);
  first.set(1);
  assert.equal(runs, 2, 'the branch it left no longer wakes it');
  second.set(1);
  assert.equal(runs, 3);
  stop();
});

test('a failing computed throws to every reader until its input recovers', () => {
  const input = signal(0);
  const checked = computed(() => {
    if (input() < 0) throw new RangeError('negative');
    return input();
  });
  input.set(-1);
  assert.throws(() => checked(), RangeError);
  assert.throws(() => checked(), RangeError, 'the cached failure is thrown again, not undefined');
  input.set(2);
  assert.equal(checked(), 2);
});

test('the cleanup of an evaluation that stopped its own effect still runs', () => {
  const go = signal(0);
  let cleaned = 0, stop;
  stop = effect(() => {
    if (!go()) return;
    stop();
    return () => cleaned++;
  });
  go.set(1);
  assert.equal(cleaned, 1);
});

test('cleanups run in the reverse of the order they were declared', () => {
  const key = signal(0);
  const order = [];
  const stop = effect(() => {
    key();
    onCleanup(() => order.push('first'));
    onCleanup(() => order.push('second'));
  });
  key.set(1);
  assert.deepEqual(order, ['second', 'first']);
  stop();
  assert.deepEqual(order, ['second', 'first', 'second', 'first']);
});
