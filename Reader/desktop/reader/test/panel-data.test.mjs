import test from 'node:test';
import assert from 'node:assert/strict';
import {displayTitle, outlinePayload, bookmarkRows, noteRows, searchRow} from '../src/panel-data.js';

test('all-caps titles read as titles; the author\'s own casing is kept', () => {
  const cases = {
    'PROLOGUE': 'Prologue', 'CHAPTER ONE': 'Chapter One', 'BOOK TWO': 'Book Two',
    'THE MAN IN THE IRON MASK': 'The Man in the Iron Mask', 'SELF-HELP AND OTHER LIES': 'Self-Help and Other Lies',
    'CHAPTER IV': 'Chapter IV', 'PART II': 'Part II', '1. INTRODUCTION': '1. Introduction', "DON'T LOOK BACK": "Don't Look Back",
    'ÉMILE': 'Émile', 'USA': 'USA', 'I': 'I', 'IV': 'IV', 'Notes on the Text': 'Notes on the Text',
    'Chapter One': 'Chapter One', 'Part II: THE SEA': 'Part II: THE SEA', 'iPhone': 'iPhone', '': '', '123': '123',
  };
  for (const [raw, shown] of Object.entries(cases)) assert.equal(displayTitle(raw), shown, raw);
  assert.equal(displayTitle(undefined), '');
});

test('the outline is a tree of ids the host can send back, with the current chapter marked', () => {
  const here = {href: 'b.html'};
  const entries = [
    {title: 'PROLOGUE', locator: {href: 'a.html'}},
    {title: 'BOOK ONE', locator: {href: 'b.html'}, children: [{title: 'CHAPTER ONE', locator: {href: 'b.html', fragment: 'x'}}, {title: 'No target', locator: null}]},
  ];
  const {rows, targets} = outlinePayload(entries, {isCurrent: l => l.href === here.href && !l.fragment});
  assert.deepEqual(rows.map(r => [r.id, r.title, r.current, r.openable]), [['o0', 'Prologue', false, true], ['o1', 'Book One', true, true]]);
  assert.deepEqual(rows[1].children.map(r => [r.id, r.title, r.openable]), [['o2', 'Chapter One', true], ['o3', 'No target', false]]);
  assert.deepEqual(targets.get('o2'), {href: 'b.html', fragment: 'x'});
  assert.equal(targets.has('o3'), false, 'an entry without a target cannot be opened');
});

test('very deep or very long outlines stay bounded', () => {
  let deep = {title: 'leaf', locator: {href: 'z'}};
  for (let i = 0; i < 40; i++) deep = {title: 'level ' + i, locator: {href: 'z'}, children: [deep]};
  let depth = 0, node = outlinePayload([deep]).rows[0];
  while (node.children) { depth++; node = node.children[0]; }
  assert.ok(depth <= 12);
  const many = Array.from({length: 5000}, (_, i) => ({title: 't' + i, locator: {href: 'z'}}));
  assert.equal(outlinePayload(many).rows.length, 2000);
});

test('bookmarks, notes and search results become plain rows', () => {
  assert.deepEqual(bookmarkRows([{id: 'b1', label: 'CHAPTER ONE', createdAt: '2026-10-01T10:00:00Z', locator: {href: 'x'}}]),
    [{id: 'b1', title: 'Chapter One', detail: '2026-10-01T10:00:00Z'}]);
  const colors = {gold: '#e4c778', sage: '#a7cbb0', rose: '#d7a9b4'};
  assert.deepEqual(noteRows([{id: 'n1', quote: 'q', note: 'n', color: 'sage', locator: {}}, {id: 'n2', quote: 'q2', color: 'unknown', locator: {}}], colors),
    [{id: 'n1', quote: 'q', note: 'n', color: '#a7cbb0'}, {id: 'n2', quote: 'q2', note: '', color: '#e4c778'}]);
  const long = 'x'.repeat(2000);
  const [row] = noteRows([{id: 'n3', quote: long, note: long, color: 'gold', locator: {}}], colors);
  assert.ok(row.quote.length <= 301 && row.note.length <= 401, 'long text is trimmed for the list');
  assert.deepEqual(searchRow('r0', 'a light', 'LIGHT', ' fell', 'CHAPTER ONE'), {id: 'r0', before: 'a light', match: 'LIGHT', after: ' fell', chapter: 'Chapter One'});
});
