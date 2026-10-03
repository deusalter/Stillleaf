"use strict";
const api = window.stillleafLibrary;
const $ = (id) => document.getElementById(id);
let state,
  view = "library",
  editor = null,
  baseline = "",
  guardPromise = null;
let noticeTimer,
  dismissedQueue = null,
  snapshotError = "";
function announce(text) {
  clearTimeout(noticeTimer);
  $("notice").textContent = text;
  noticeTimer = setTimeout(() => {
    $("notice").textContent = "";
  }, 4000);
}
function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = text;
  if (className) element.className = className;
  return element;
}
function button(text, action, className) {
  const b = node("button", text, className);
  b.type = "button";
  b.onclick = async () => {
    b.disabled = true;
    try {
      await action();
    } catch (e) {
      $("error").textContent = e.message;
    } finally {
      b.disabled = false;
    }
  };
  return b;
}
async function result(promise) {
  const response = await promise;
  if (response.error) throw Error(response.error);
  if (response.warning) $("error").textContent = response.warning;
  return response;
}
function stars(value) {
  return value === null ? "Not rated" : `${value} / 5 ★`;
}
function dateText(value) {
  return value
    ? new Intl.DateTimeFormat(undefined, {
        month: "long",
        day: "numeric",
        year: "numeric",
      }).format(new Date(value))
    : "Finish date unknown";
}
function coverFor(book) {
  const cover = node(
    book.cover ? "img" : "div",
    book.cover ? undefined : book.title,
    "cover" + (book.cover ? "" : " placeholder"),
  );
  if (book.cover) {
    cover.src = book.cover;
    cover.alt = "Cover of " + book.title;
  }
  return cover;
}
function actions(book) {
  const group = node("div", undefined, "book-actions");
  group.append(
    button(
      book.available ? "Read" : "Import to read",
      () => result(book.available ? api.read(book.editionId) : api.pick()),
      "primary-read",
    ),
  );
  const rating = button(
    stars(book.rating),
    () => openEditor("review", book),
    "compact-rating rating quiet",
  );
  rating.setAttribute("aria-label", "Rate & review");
  rating.title = "Rate & review";
  group.append(rating);
  const menu = node("details", undefined, "book-menu");
  const toggle = node("summary", "•••");
  toggle.setAttribute("aria-label", "More about " + book.title);
  toggle.title = "More book actions";
  const items = node("div", undefined, "book-menu-items");
  const finish = button(
    book.completion ? "Finished" : "Mark finished",
    async () => {
      const r = await result(api.journal("finish", { bookId: book.bookId }));
      announce(r.created ? "Marked finished." : "Already marked finished.");
    },
    "quiet",
  );
  finish.disabled = Boolean(book.completion);
  items.append(finish);
  if (book.completion)
    items.append(
      button(
        "Edit reading dates…",
        () => {
          menu.open = false;
          return openEditor("dates", book);
        },
        "quiet",
      ),
    );
  items.append(
    button(
      "Reading records",
      () => {
        menu.open = false;
        openRecords(book);
      },
      "quiet",
    ),
    button(
      "Log reading",
      () => {
        menu.open = false;
        return openEditor("manual", book);
      },
      "quiet",
    ),
  );
  if (book.available) {
    items.append(
      button(
        "Export notes and reading settings…",
        async () => {
          menu.open = false;
          const r = await result(api.exportReaderState(book.editionId));
          if (r.exported) announce("Notes and reading settings exported.");
        },
        "quiet",
      ),
      button(
        "Import notes and reading settings…",
        async () => {
          menu.open = false;
          const r = await result(api.importReaderState(book.editionId));
          if (r.imported) announce("Notes and reading settings imported.");
          else if (r.identical)
            announce("These notes and reading settings are already saved.");
        },
        "quiet",
      ),
    );
    const remove = button(
      "Remove EPUB…",
      () => {
        menu.open = false;
        return result(api.remove(book.editionId));
      },
      "remove quiet",
    );
    remove.setAttribute("aria-label", "Remove " + book.title);
    items.append(remove);
  }
  menu.append(toggle, items);
  group.append(menu);
  return group;
}
function openRecords(book) {
  $("records-title").textContent = "Reading records";
  $("records-book").textContent = book.title;
  const entries = state.entries
    .filter((e) => e.book_id === book.bookId)
    .slice()
    .reverse();
  $("records-list").replaceChildren();
  const intervals = (state.automaticEntries ?? []).filter(
    (entry) =>
      entry.bookId === book.bookId &&
      Number.isFinite(entry.duration) &&
      entry.duration > 0,
  );
  const duration = (seconds) =>
    seconds < 60
      ? `${new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(seconds)} ${seconds === 1 ? "second" : "seconds"}`
      : `${new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(seconds / 60)} ${seconds === 60 ? "minute" : "minutes"}`;
  for (const disposition of ["credited", "excluded"]) {
    const rows = intervals.filter((entry) => entry.disposition === disposition);
    if (!rows.length) continue;
    const group = node("section", undefined, "tracked-record-group");
    group.append(
      node(
        "h3",
        disposition === "credited"
          ? "Counted reading time"
          : "Excluded reading time",
      ),
    );
    group.append(
      node(
        "p",
        duration(rows.reduce((sum, row) => sum + row.duration, 0)) +
          (disposition === "excluded"
            ? " · Not counted toward goals"
            : " · Counted toward time goals"),
      ),
    );
    const detail = node("details"),
      summary = node(
        "summary",
        `${rows.length} recorded ${rows.length === 1 ? "interval" : "intervals"}`,
      );
    detail.append(summary);
    for (const interval of rows) {
      const formatter = new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
        timeZone: interval.timezoneId,
      });
      const line = node(
        "p",
        `${interval.mode === "manual" ? "Manual timer" : "Automatic"}: ${formatter.format(new Date(interval.start))} – ${formatter.format(new Date(interval.end))} (${interval.timezoneId}); ${duration(interval.duration)}`,
      );
      detail.append(line);
    }
    group.append(detail);
    $("records-list").append(group);
  }
  if (entries.length && intervals.length)
    $("records-list").append(node("h3", "Dated reading entries"));
  for (const entry of entries) {
    const row = node("article", undefined, "activity-row"),
      details = [];
    if (entry.pages !== null) details.push(`${entry.pages} pages`);
    if (entry.minutes !== null) details.push(`${entry.minutes} minutes`);
    if (entry.position !== null)
      details.push(`page position ${entry.position}`);
    row.append(node("time", entry.day), node("p", details.join(" · ")));
    if (entry.note) row.append(node("p", entry.note, "personal-text"));
    $("records-list").append(row);
  }
  if (!entries.length && !intervals.length)
    $("records-list").append(
      node(
        "p",
        "No reading records yet. Log a date, pages or minutes when you want to keep a record.",
      ),
    );
  $("records-log").onclick = () => {
    $("records").close();
    void openEditor("manual", book);
  };
  $("records").showModal();
}
function render(value) {
  if (value.error) {
    $("error").textContent = value.error;
    return;
  }
  state = value;
  $("heading").textContent = {
    library: "Library",
    timeline: "Timeline",
    reviews: "Reviews",
  }[view];
  document.title = "Stillleaf · " + $("heading").textContent;
  $("count").textContent =
    view === "library"
      ? `${state.books.length} ${state.books.length === 1 ? "book" : "books"} on this computer`
      : view === "timeline"
        ? "The books you finish, one chapter of your life at a time."
        : "Your thoughts, in your own words.";
  document.querySelectorAll("[data-view]").forEach((b) => {
    if (b.dataset.view === view) b.setAttribute("aria-current", "page");
    else b.removeAttribute("aria-current");
  });
  $("add-book").hidden = view !== "library";
  $("books").hidden = view !== "library";
  $("timeline").hidden = view !== "timeline";
  $("reviews").hidden = view !== "reviews";
  $("progress").hidden = view === "reviews";
  $("progress").replaceChildren(
    node(
      "span",
      `Today: ${state.daily.value} / ${state.daily.target} ${state.daily.unit}`,
    ),
    node(
      "span",
      `${state.annual.year}: ${state.annual.books}${state.annual.target ? " / " + state.annual.target : ""} books finished`,
    ),
  );
  $("books").replaceChildren();
  for (const book of state.books) {
    const card = node("article", undefined, "book");
    card.dataset.edition = book.editionId ?? "";
    card.dataset.book = book.bookId;
    const cover = coverFor(book);
    card.append(
      cover,
      node("h2", book.title),
      node("p", book.creators.join(", ") || "Unknown author"),
    );
    if (!book.available)
      card.append(node("p", "EPUB not stored here", "availability"));
    card.append(actions(book));
    $("books").append(card);
  }
  $("timeline").replaceChildren();
  const finished = state.books
    .filter((b) => b.completion)
    .sort(
      (a, b) =>
        (b.completion.payload.finishedAt ?? "").localeCompare(
          a.completion.payload.finishedAt ?? "",
        ) || a.title.localeCompare(b.title),
    );
  for (const book of finished) {
    const row = node("article", undefined, "timeline-row");
    row.append(coverFor(book));
    const detail = node("div");
    detail.append(
      node("time", dateText(book.completion.payload.finishedAt), "finish-date"),
      node("h2", book.title),
      node("p", book.creators.join(", ")),
      actions(book),
    );
    row.append(detail);
    $("timeline").append(row);
  }
  if (!finished.length)
    $("timeline").append(
      node("p", "Mark a book finished to begin your timeline.", "empty-copy"),
    );
  $("reviews").replaceChildren();
  const reviewed = state.books.filter(
    (b) => typeof b.review === "string" && b.review.trim().length > 0,
  );
  for (const book of reviewed) {
    const row = node("article", undefined, "review-row");
    row.append(
      node("h2", book.title),
      node("p", stars(book.rating), "rating"),
      node("p", book.review ?? "No written review yet.", "personal-text"),
      button("Edit review", () => openEditor("review", book), "quiet"),
    );
    $("reviews").append(row);
  }
  if (!reviewed.length)
    $("reviews").append(
      node(
        "p",
        "Choose Rate & review on a book to add your thoughts.",
        "empty-copy",
      ),
    );
  $("empty").hidden = view !== "library" || state.books.length > 0;
  const items = state.queue.items;
  const importing = items.some((x) =>
    ["queued", "importing"].includes(x.state),
  );
  const queueKey = JSON.stringify(items);
  $("queue").hidden =
    !items.length ||
    (view !== "library" && !importing) ||
    (!importing && dismissedQueue === queueKey);
  $("queue-details").open = importing;
  $("dismiss-queue").hidden = importing;
  $("cancel").hidden = !importing;
  $("dismiss-queue").onclick = () => {
    dismissedQueue = queueKey;
    $("queue").hidden = true;
  };
  document.querySelector(".queue-header h2").textContent = importing
    ? "Adding to your Library"
    : "Import results";
  const counts = {};
  for (const item of items) counts[item.state] = (counts[item.state] || 0) + 1;
  $("summary").textContent =
    Object.entries(counts)
      .map(([s, n]) => `${n} ${s}`)
      .join(" · ") +
    (state.queue.overflow ? ` · ${state.queue.overflow} over batch limit` : "");
  $("cancel").disabled = !items.some((x) => x.state === "queued");
  $("items").replaceChildren(
    ...items.map((i) =>
      node(
        "li",
        `${i.path.split(/[\\/]/).at(-1)} — ${i.state}${i.message ? ": " + i.message : ""}`,
      ),
    ),
  );
  const problem = [
    state.warnings.length
      ? `${state.warnings.length} saved book receipts could not be read. Their files were preserved.`
      : "",
    state.trackingError
      ? `Reading time could not be saved: ${state.trackingError}`
      : "",
  ]
    .filter(Boolean)
    .join(" ");
  if (problem || $("error").textContent === snapshotError)
    $("error").textContent = problem;
  snapshotError = problem;
}
function field(name, label, type, value, options = {}) {
  const container = node("label", label);
  let input;
  if (type === "select") {
    input = node("select");
    for (const [key, title] of options.choices) {
      const option = node("option", title);
      option.value = key;
      input.append(option);
    }
  } else input = node(type === "textarea" ? "textarea" : "input");
  input.setAttribute("aria-label", label);
  input.name = name;
  input.id = "field-" + name;
  if (type !== "select" && type !== "textarea") input.type = type;
  for (const [key, val] of Object.entries(options))
    if (key !== "choices") input[key] = val;
  input.value = value ?? "";
  container.append(input);
  $("editor-fields").append(container);
  return input;
}
function ratingControl(initial) {
  const group = node("div", undefined, "rating-control"),
    label = node("p", "Book rating", "field-label");
  const input = node("input");
  input.type = "hidden";
  input.name = "rating";
  input.value = initial ?? "";
  const rail = node("div", undefined, "rating-rail");
  rail.tabIndex = 0;
  rail.setAttribute("role", "slider");
  rail.setAttribute("aria-label", "Book rating");
  rail.setAttribute("aria-valuemin", "0");
  rail.setAttribute("aria-valuemax", "5");
  rail.setAttribute("aria-describedby", "rating-help");
  const starNodes = Array.from({ length: 5 }, () => {
    const star = node("span", undefined, "quarter-star");
    star.setAttribute("aria-hidden", "true");
    star.append(
      node("span", "☆", "star-empty"),
      node("span", "★", "star-fill"),
    );
    rail.append(star);
    return star;
  });
  const readout = node("output", undefined, "rating-value");
  readout.setAttribute("aria-live", "polite");
  const controls = node("div", undefined, "rating-controls");
  const zero = button("0", () => set(0), "quiet"),
    minus = button(
      "−",
      () => set(Math.max(0, Number(input.value) - 0.25)),
      "quiet",
    ),
    plus = button(
      "+",
      () => set(Math.min(5, Number(input.value) + 0.25)),
      "quiet",
    ),
    clear = button("Clear", () => set(null), "quiet");
  zero.setAttribute("aria-label", "Rate zero stars");
  minus.setAttribute("aria-label", "Decrease rating by a quarter star");
  plus.setAttribute("aria-label", "Increase rating by a quarter star");
  clear.setAttribute("aria-label", "Clear rating");
  function draw(value, preview = false) {
    starNodes.forEach((star, i) => {
      star.dataset.quarters = String(
        Math.round(Math.min(1, Math.max(0, (value ?? 0) - i)) * 4),
      );
    });
    if (!preview) {
      rail.setAttribute("aria-valuenow", String(value ?? 0));
      rail.setAttribute(
        "aria-valuetext",
        value === null ? "Not rated" : `${value} out of 5 stars`,
      );
      readout.textContent = value === null ? "Not rated" : `${value} / 5`;
      minus.disabled = value === null || value === 0;
      plus.disabled = value === 5;
      clear.disabled = value === null;
    }
  }
  function set(value) {
    input.value = value === null ? "" : String(value);
    draw(value);
  }
  function pick(event) {
    const x = event.clientX - rail.getBoundingClientRect().left;
    if (x <= 0) return 0;
    if (x >= 234) return 5;
    const index = Math.min(4, Math.floor(x / 48)),
      within = Math.min(42, Math.max(0, x - index * 48));
    return Math.min(5, index + Math.ceil((within / 42) * 4) / 4);
  }
  rail.onpointerdown = (event) => {
    if (event.button !== 0) return;
    rail.focus();
    rail.setPointerCapture(event.pointerId);
    set(pick(event));
  };
  rail.onpointermove = (event) => {
    if (rail.hasPointerCapture(event.pointerId)) set(pick(event));
    else draw(pick(event), true);
  };
  rail.onpointerup = (event) => {
    if (rail.hasPointerCapture(event.pointerId)) {
      set(pick(event));
      rail.releasePointerCapture(event.pointerId);
    }
  };
  rail.onpointerleave = () =>
    draw(input.value === "" ? null : Number(input.value));
  rail.onkeydown = (event) => {
    let value = Number(input.value);
    if (["ArrowLeft", "ArrowDown"].includes(event.key))
      value = Math.max(0, value - 0.25);
    else if (["ArrowRight", "ArrowUp"].includes(event.key))
      value = Math.min(5, value + 0.25);
    else if (event.key === "Home") value = 0;
    else if (event.key === "End") value = 5;
    else if (["Delete", "Backspace"].includes(event.key)) value = null;
    else return;
    event.preventDefault();
    set(value);
  };
  zero.onclick = () => set(0);
  minus.onclick = () => set(Math.max(0, Number(input.value) - 0.25));
  plus.onclick = () => set(Math.min(5, Number(input.value) + 0.25));
  clear.onclick = () => set(null);
  const help = node(
    "p",
    "Click or drag the stars. Fine-tune by a quarter. Zero is a rating; Clear leaves it unrated.",
    "rating-help",
  );
  help.id = "rating-help";
  controls.append(readout, zero, minus, plus, clear);
  group.append(label, input, rail, controls, help);
  $("editor-fields").append(group);
  draw(initial);
}
function values() {
  return Object.fromEntries(new FormData($("editor-form")));
}
function dirty() {
  return editor && JSON.stringify(values()) !== baseline;
}
async function openEditor(kind, book) {
  if (!(await prepareJournalClose())) return;
  editor = {
    kind,
    bookId: book?.bookId,
    completionId: book?.completion?.id,
    timeZone: state.timeZone,
  };
  $("editor-save").textContent =
    kind === "createBook"
      ? "Add book"
      : kind === "dates"
        ? "Save dates"
        : "Save changes";
  $("editor-cancel").textContent =
    kind === "dates" ? "Skip — keep saved dates" : "Cancel";
  $("editor-fields").replaceChildren();
  $("editor-error").textContent = "";
  $("editor-title").textContent =
    kind === "createBook"
      ? "Add book"
      : kind === "dates"
        ? "Reading dates"
        : kind === "review"
          ? book.title
          : kind === "manual"
            ? "Log reading"
            : "Reading goals";
  $("editor-description").textContent =
    kind === "createBook"
      ? "Keep a record of a book you read elsewhere. This adds its details to your Library without an EPUB."
      : kind === "dates"
        ? `${book.title} is marked as read. Dates are optional; an unknown start stays unknown. Removing the finish date keeps this book read but excludes it from yearly totals. Times use ${state.timeZone}.`
        : kind === "review"
          ? "Your rating and personal review."
          : kind === "manual"
            ? `Record pages or minutes for ${book.title}. Page position is separate from pages read.`
            : "Daily goals take effect today. Only the selected daily unit counts; the other target is kept for switching. Finished books count once in the year of their known finish date.";
  if (kind === "createBook") {
    field("title", "Title", "text", "", { required: true, maxLength: 4096 });
    field("author", "Author (optional)", "text", "", { maxLength: 4096 });
  }
  if (kind === "review") {
    ratingControl(book.rating);
    field("text", "Personal review", "textarea", book.review ?? "", {
      rows: 9,
      maxLength: 100000,
    });
  }
  if (kind === "dates") {
    const formatter = new Intl.DateTimeFormat("en-CA", {
      timeZone: state.timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    });
    for (const [name, label, key] of [
      ["startedDay", "Started", "startedAt"],
      ["finishedDay", "Finished", "finishedAt"],
    ]) {
      const original = book.completion.payload[key];
      const parts = original
        ? Object.fromEntries(
            formatter
              .formatToParts(new Date(original))
              .map((p) => [p.type, p.value]),
          )
        : null;
      const value = parts ? `${parts.year}-${parts.month}-${parts.day}` : "";
      const input = field(name, label, "date", value, {
        min: "1900-01-01",
        max: state.today,
      });
      const status = node("p", undefined, "date-evidence");
      const saved = original
        ? new Intl.DateTimeFormat(undefined, {
            dateStyle: "medium",
            timeStyle: "medium",
            timeZone: state.timeZone,
          }).format(new Date(original))
        : null;
      const update = () => {
        status.textContent = input.value
          ? input.value === value && saved
            ? `Saved: ${saved}. Keeping this day preserves its exact time.`
            : "New date selected. Save dates to apply."
          : "Unknown · optional";
      };
      input.addEventListener("input", update);
      update();
      const clear = button(
        "Clear",
        () => {
          input.value = "";
          update();
          clear.hidden = true;
        },
        "quiet",
      );
      clear.hidden = !input.value;
      input.addEventListener("input", () => {
        clear.hidden = !input.value;
      });
      clear.setAttribute(
        "aria-label",
        `Leave ${label.toLowerCase()} date unknown`,
      );
      const controls = node("div", undefined, "date-controls");
      controls.append(status, clear);
      $("editor-fields").append(controls);
    }
  }
  if (kind === "manual") {
    field("day", "Reading date", "date", state.today, {
      required: true,
      max: state.today,
      min: "1900-01-01",
    });
    field("pages", "Pages read", "number", "", {
      min: 0,
      max: 1000000,
      step: 1,
    });
    field("minutes", "Minutes read", "number", "", {
      min: 0,
      max: 1440,
      step: 0.1,
    });
    field("position", "Page position (optional)", "number", "", {
      min: 0,
      max: 1000000,
      step: 1,
    });
    field("note", "Note (optional)", "textarea", "", {
      rows: 3,
      maxLength: 50000,
    });
  }
  if (kind === "goals") {
    field("unit", "Daily goal", "select", state.daily.unit, {
      choices: [
        ["minutes", "Minutes"],
        ["pages", "Pages"],
      ],
    });
    field("minutes", "Daily minutes", "number", state.daily.minutesTarget, {
      required: true,
      min: 1,
      max: 1440,
      step: 1,
    });
    field("pages", "Daily pages", "number", state.daily.pagesTarget ?? 20, {
      min: 1,
      max: 1000000,
      step: 1,
    });
    field(
      "annualBooks",
      `Books in ${state.annual.year} (blank turns off goal)`,
      "number",
      state.annual.target ?? "",
      { min: 1, max: 10000, step: 1 },
    );
  }
  baseline = JSON.stringify(values());
  $("editor").showModal();
  $("editor-fields")
    .querySelector("[role=slider],input:not([type=hidden]),select,textarea")
    ?.focus();
}
async function saveEditor() {
  if (!editor || !$("editor-form").reportValidity()) return false;
  const data = values(),
    number = (x) => (x === "" ? null : Number(x));
  let payload;
  if (editor.kind === "createBook")
    payload = { title: data.title, author: data.author };
  if (editor.kind === "review")
    payload = {
      bookId: editor.bookId,
      rating: number(data.rating),
      text: data.text,
    };
  if (editor.kind === "dates")
    payload = {
      bookId: editor.bookId,
      startedDay: data.startedDay || null,
      finishedDay: data.finishedDay || null,
      completionId: editor.completionId,
      timeZone: editor.timeZone,
    };
  if (editor.kind === "manual")
    payload = {
      bookId: editor.bookId,
      day: data.day,
      pages: number(data.pages),
      minutes: number(data.minutes),
      position: number(data.position),
      note: data.note,
    };
  if (editor.kind === "goals")
    payload = {
      unit: data.unit,
      minutes: number(data.minutes),
      pages: number(data.pages),
      annualBooks: number(data.annualBooks),
    };
  $("editor-save").disabled = true;
  try {
    await result(api.journal(editor.kind, payload));
    editor = null;
    $("editor").close();
    announce("Changes saved.");
    return true;
  } catch (e) {
    $("editor-error").textContent = e.message;
    return false;
  } finally {
    $("editor-save").disabled = false;
  }
}
async function prepareJournalClose() {
  if (guardPromise) return guardPromise;
  if (!dirty()) {
    editor = null;
    $("editor").close();
    return true;
  }
  guardPromise = new Promise((resolve) => {
    const guard = $("draft-guard");
    guard.showModal();
    const finish = (value) => {
      guard.close();
      guardPromise = null;
      resolve(value);
    };
    $("draft-keep").onclick = () => finish(false);
    $("draft-discard").onclick = () => {
      editor = null;
      $("editor").close();
      finish(true);
    };
    $("draft-save").onclick = async () => {
      guard.close();
      const saved = await saveEditor();
      finish(saved);
    };
    guard.oncancel = (event) => {
      event.preventDefault();
      finish(false);
    };
  });
  return guardPromise;
}
window.prepareJournalClose = prepareJournalClose;
$("editor-form").onsubmit = (event) => {
  event.preventDefault();
  void saveEditor();
};
$("editor-cancel").onclick = () => prepareJournalClose();
$("editor").oncancel = (event) => {
  event.preventDefault();
  void prepareJournalClose();
};
document.querySelectorAll("[data-view]").forEach(
  (b) =>
    (b.onclick = async () => {
      if (await prepareJournalClose()) {
        view = b.dataset.view;
        render(state);
        window.scrollTo(0, 0);
      }
    }),
);
$("records-close").onclick = () => $("records").close();
$("goals").onclick = () => openEditor("goals");
$("add-book").onclick = () => openEditor("createBook");
$("import").onclick = () =>
  result(api.pick()).catch((e) => ($("error").textContent = e.message));
$("cancel").onclick = () => api.cancel();
api.onChanged(render);
api.snapshot().then(render);
window.addEventListener("dragover", (e) => {
  e.preventDefault();
  document.body.classList.add("dragging");
});
window.addEventListener("dragleave", () =>
  document.body.classList.remove("dragging"),
);
window.addEventListener("drop", async (e) => {
  e.preventDefault();
  document.body.classList.remove("dragging");
  try {
    await result(api.drop([...e.dataTransfer.files]));
  } catch (error) {
    $("error").textContent = error.message;
  }
});
