const { randomUUID } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const statuses = ['Want to read', 'Reading', 'Finished', 'Did not finish'];
function text(value, name, max, required = false) {
  if (typeof value !== 'string' || value.trim().length > max || (required && !value.trim())) throw Error(`${name} must ${required ? 'contain 1–' : 'contain at most '}${max} characters.`);
  return value.trim();
}
function number(value, name, max, integer = true) {
  if (value === '' || value === null || value === undefined) return null;
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > max || (integer && !Number.isInteger(value))) throw Error(`${name} must be ${integer ? 'a whole number' : 'a number'} between 0 and ${max}.`);
  return value;
}
function date(value, allowFuture = false) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value) || !Number.isFinite(Date.parse(value)) || new Date(value).toISOString().slice(0, 10) !== value) throw Error('Choose a valid reading date.');
  const now = new Date();
  const today = `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}`;
  if (!allowFuture && value > today) throw Error('Reading dates cannot be in the future.');
  return value;
}
function addBook(state, input) {
  const title = text(input.title, 'Title', 200, true);
  const author = text(input.author, 'Author', 200);
  const totalPages = number(input.totalPages, 'Total pages', 1000000);
  if (totalPages === 0) throw Error('Total pages must be greater than zero or left blank.');
  if (!statuses.includes(input.status)) throw Error('Choose a reading status.');
  const book = { id: randomUUID(), title, author, totalPages, status: input.status, createdAt: new Date().toISOString() };
  return { ...state, books: [...state.books, book] };
}
function addEntry(state, input, restoring = false) {
  const book = state.books.find(b => b.id === input.bookId);
  if (!book) throw Error('Select an existing book.');
  const position = number(input.position, 'Position', book.totalPages ?? 1000000);
  const pagesRead = number(input.pagesRead, 'Pages read', 1000000);
  const minutes = number(input.minutes, 'Minutes', 1440, false);
  const note = text(input.note, 'Note', 4000);
  if (position === null && pagesRead === null && minutes === null && !note) throw Error('Enter a position, pages read, minutes, or a note.');
  const entry = { id: randomUUID(), bookId: book.id, date: date(input.date, restoring), position, pagesRead, minutes, note, source: 'manual', createdAt: new Date().toISOString() };
  return { ...state, entries: [...state.entries, entry] };
}
function summary(state, bookId) {
  // Date defines reading chronology; insertion order breaks same-day ties.
  const entries = state.entries.filter(e => e.bookId === bookId).map((e, i) => ({...e, order:i})).sort((a,b) => a.date.localeCompare(b.date) || a.order - b.order);
  return { position: entries.filter(e => e.position !== null).at(-1)?.position ?? null, pagesRead: entries.reduce((n,e) => n+(e.pagesRead ?? 0),0), minutes: entries.reduce((n,e) => n+(e.minutes ?? 0),0), timedEntries: entries.filter(e => e.minutes !== null).length };
}
function validateArchive(state) {
  if (!state || state.format !== 'stillleaf-journal-prototype' || state.version !== 1 || !Array.isArray(state.books) || !Array.isArray(state.entries)) throw Error('Unsupported journal file. Your data has not been replaced.');
  const ids = new Set();
  for (const b of state.books) {
    if (typeof b.id !== 'string' || !b.id || ids.has(b.id)) throw Error('Invalid book identity.');
    ids.add(b.id); addBook({books:[]}, b);
  }
  const entries = new Set();
  for (const e of state.entries) {
    if (typeof e.id !== 'string' || !e.id || entries.has(e.id) || e.source !== 'manual') throw Error('Invalid entry identity or source.');
    entries.add(e.id); addEntry(state, e, true);
  }
  return state;
}
class Journal {
  constructor(file) {
    this.file = file;
    this.state = { format:'stillleaf-journal-prototype', version:1, books:[], entries:[] };
    if (fs.existsSync(file)) this.state = validateArchive(JSON.parse(fs.readFileSync(file, 'utf8')));
  }
  mutate(action, input) {
    let next;
    if (action === 'addBook') next = addBook(this.state, input);
    else if (action === 'addEntry') next = addEntry(this.state, input);
    else if (action === 'setStatus') {
      if (!statuses.includes(input.status) || !this.state.books.some(b => b.id === input.id)) throw Error('Invalid book or status.');
      next = {...this.state, books:this.state.books.map(b => b.id === input.id ? {...b,status:input.status} : b)};
    } else if (action === 'deleteEntry') {
      if (!this.state.entries.some(e => e.id === input.id)) throw Error('Entry no longer exists.');
      next = {...this.state, entries:this.state.entries.filter(e => e.id !== input.id)};
    } else throw Error('Unknown journal action.');
    fs.mkdirSync(path.dirname(this.file), {recursive:true});
    const temp = this.file + '.tmp';
    const fd = fs.openSync(temp, 'w', 0o600);
    try { fs.writeFileSync(fd, JSON.stringify(next, null, 2)); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    if (fs.existsSync(this.file)) fs.copyFileSync(this.file, this.file + '.bak');
    fs.renameSync(temp, this.file);
    this.state = next;
    return this.state;
  }
}
module.exports = {Journal, addBook, addEntry, summary, statuses, validateArchive};
