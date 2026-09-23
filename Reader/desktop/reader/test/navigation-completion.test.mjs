import {test} from 'node:test';
import assert from 'node:assert/strict';
import {NavigationCompletion} from '../src/navigation-completion.js';

test('disposing a stalled navigator settles waits and ignores all late callbacks', async () => {
  const completion = new NavigationCompletion(), old = {}, fresh = {};
  let callback, completions = 0, starts = 0;
  const pending = completion.wait(old, done => { callback = done; }, () => { completions++; });
  completion.dispose(old);
  assert.equal(await pending, false);
  callback(true); callback(false);
  assert.equal(completions, 0);
  assert.equal(await completion.wait(old, () => { starts++; }), false);
  assert.equal(starts, 0);
  assert.equal(await completion.wait(fresh, done => done(true), () => { completions++; }), true);
  assert.equal(completions, 1);
  assert.equal(completion.pending.size, 0);
});

test('engine completion runs once; a synchronous navigation error releases its wait', async () => {
  const completion = new NavigationCompletion(), owner = {};
  let callback, completions = 0;
  const pending = completion.wait(owner, done => { callback = done; }, () => { completions++; });
  callback(true); callback(true);
  assert.equal(await pending, true); assert.equal(completions, 1);
  await assert.rejects(completion.wait(owner, () => { throw Error('navigation failed'); }), /navigation failed/);
  assert.equal(completion.pending.size, 0);
});
