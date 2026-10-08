// Plain data for the reader's Contents, Bookmarks, Notes and Search panels. The web panels and the
// native host's panels are built from the same rows, so both show the same titles in the same order.

const SMALL_WORDS = new Set(['a', 'an', 'and', 'as', 'at', 'but', 'by', 'for', 'in', 'of', 'on', 'or', 'the', 'to', 'vs']);
const ROMAN = /^(?=[IVXLCDM])M{0,4}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$/;
const MAX_ROWS = 2000, MAX_DEPTH = 12;

/** Many books ship an all-caps table of contents. Show those as titles; leave any other casing alone. */
export function displayTitle(raw) {
  const text = typeof raw === 'string' ? raw.trim() : '';
  if (!/\p{L}/u.test(text)) return text;
  if (text !== text.toLocaleUpperCase() || text === text.toLocaleLowerCase()) return text;
  const words = text.split(/\s+/);
  // A lone short word is more likely an acronym or a numeral (USA, IV) than a heading.
  if (words.length === 1 && text.match(/\p{L}/gu).length <= 3) return text;
  let position = 0;
  return text.replace(/\p{L}[\p{L}\p{M}'’]*/gu, word => {
    const index = position++;
    if (index > 0 && ROMAN.test(word)) return word;
    const lower = word.toLocaleLowerCase();
    if (index > 0 && SMALL_WORDS.has(lower)) return lower;
    return lower.charAt(0).toLocaleUpperCase() + lower.slice(1);
  });
}

const clip = (text, limit) => {
  const value = typeof text === 'string' ? text : '';
  return value.length > limit ? value.slice(0, limit) + '…' : value;
};

/**
 * `entries` are `{title, locator, children}` from the book's navigation. Returns the rows to show and a
 * map from each row id to the locator it opens, so the host can send an id back instead of a locator.
 */
export function outlinePayload(entries, {isCurrent = () => false} = {}) {
  const targets = new Map();
  let count = 0;
  const walk = (list, depth) => {
    const rows = [];
    for (const entry of list) {
      if (count >= MAX_ROWS) break;
      const id = 'o' + count++;
      const row = {id, title: displayTitle(entry.title), current: Boolean(entry.locator && isCurrent(entry.locator)), openable: Boolean(entry.locator)};
      if (entry.group) row.group = true;
      if (entry.locator) targets.set(id, entry.locator);
      if (Array.isArray(entry.children) && entry.children.length && depth < MAX_DEPTH) row.children = walk(entry.children, depth + 1);
      rows.push(row);
    }
    return rows;
  };
  return {rows: walk(entries, 0), targets};
}

export const bookmarkRows = bookmarks => bookmarks.map(item => ({id: item.id, title: displayTitle(item.label), detail: item.createdAt}));

export const noteRows = (annotations, colors) => annotations.map(item => ({
  id: item.id, quote: clip(item.quote, 300), note: clip(item.note ?? '', 400), color: colors[item.color] ?? colors.gold,
}));

export const searchRow = (id, before, match, after, chapter) => ({id, before, match, after, chapter: displayTitle(chapter)});
