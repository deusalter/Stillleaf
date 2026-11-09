// Saved page maps are keyed by layout. A change that cannot move a line (theme, the garden) keeps the book's counts;
// one that does (margins, the window) is a new layout, so an old map is never shown as exact for it.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {serve, launchBrowser, openReader, settle, MODES} from './surface-support.mjs';

const root = path.resolve(import.meta.dirname, '../dist');

test('page maps survive theme and garden changes and are dropped when margins or the window change the layout', {timeout: 180000}, async t => {
  const server = await serve(root), browser = await launchBrowser(process.env.READER_TEST_BROWSER === 'webkit' ? 'webkit' : 'chromium');
  t.after(async () => { await browser.close(); server.close(); });
  const keys = [];
  const {page, context} = await openReader(browser, server.url, {width: 1280, height: 800, preferences: MODES.facing, editionId: 'layout-key'});
  t.after(() => context.close());
  await page.exposeFunction('recordKey', key => keys.push(key));
  await page.evaluate(() => window.addEventListener('stillleaf-reader-event', e => { if (e.detail.type === 'pageMap') window.recordKey(e.detail.pageMap.key); }));
  const exact = () => page.waitForFunction(() => document.getElementById('position-label').dataset.pages === 'exact', null, {timeout: 60000});
  // Turning makes the footer adopt the finished count.
  const nudge = async () => { await page.evaluate(() => window.StillleafReader.next()); await page.waitForTimeout(400); await page.evaluate(() => window.StillleafReader.previous()); await page.waitForTimeout(400); };
  await settle(page, 600);
  await page.waitForFunction(() => true);
  for (let i = 0; i < 40 && !keys.length; i++) await page.waitForTimeout(250);
  assert.equal(keys.length, 1, 'the facing layout never finished a page map');
  const facing = JSON.parse(keys[0]);
  assert.equal(facing.width > 1100, true, `the key does not carry the facing width: ${facing.width}`);
  assert.equal(facing.settings.columnCount, 2);
  await nudge(); await exact();

  for (const change of [{theme: 'night'}, {theme: 'sepia'}, {vines: 'margins'}, {vines: 'off'}]) {
    await page.evaluate(value => window.StillleafReader.setPreferences(value), change);
    await page.waitForTimeout(500); await nudge();
    assert.equal(await page.evaluate(() => document.getElementById('position-label').dataset.pages), 'exact', `${JSON.stringify(change)} dropped the count`);
  }
  assert.equal(keys.length, 1, `a change that cannot move a line made a new layout: ${keys.length} maps`);

  // Wide margins, then a narrower window: each is its own layout with its own map.
  await page.evaluate(() => window.StillleafReader.setPreferences({margins: 'wide'}));
  for (let i = 0; i < 60 && keys.length < 2; i++) await page.waitForTimeout(250);
  assert.equal(keys.length, 2, 'wide margins reused the old layout');
  assert.notDeepEqual(JSON.parse(keys[1]).settings, facing.settings);
  await page.setViewportSize({width: 1000, height: 760});
  for (let i = 0; i < 80 && keys.length < 3; i++) await page.waitForTimeout(250);
  assert.equal(keys.length, 3, 'a narrower window reused an old layout');
  assert.ok(new Set(keys).size === 3, 'two layouts share a key');
});
