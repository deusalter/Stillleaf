"use strict";
const { day, instant } = require("./journal/validation.cjs");
function localDay(date) {
  return `${String(date.getFullYear()).padStart(4, "0")}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
function clock(date) {
  return date.getHours() * 3600 + date.getMinutes() * 60 + date.getSeconds();
}
// Mirrors ReadingCompletionDates.selecting: no inference for null, exact identity
// for the same day, retained wall clock for another day, next valid time in DST gaps.
function selectLocalDay(selected, original, now) {
  const current = new Date(instant(now));
  if (selected === null) return null;
  day(selected);
  if (selected > localDay(current))
    throw Error("Reading dates cannot be in the future.");
  const saved = original === null ? null : new Date(instant(original));
  if (saved && localDay(saved) === selected) return original;
  const [year, month, date] = selected.split("-").map(Number),
    hour = saved?.getHours() ?? 0,
    minute = saved?.getMinutes() ?? 0,
    second = saved?.getSeconds() ?? 0;
  let result = new Date(year, month - 1, date, hour, minute, second, 0);
  if (localDay(result) !== selected)
    throw Error("This calendar day does not exist in the current timezone.");
  const requested = hour * 3600 + minute * 60 + second;
  if (clock(result) !== requested) {
    // Date's compatible disambiguation carries minutes through a gap; Foundation
    // Calendar.nextTime instead chooses the first existing clock after the gap.
    const lower = result.getTime() - 4 * 3600000,
      upper = result.getTime();
    for (let candidate = lower; candidate <= upper; candidate += 1000) {
      const trial = new Date(candidate);
      if (localDay(trial) === selected && clock(trial) >= requested) {
        result = trial;
        break;
      }
    }
  }
  return instant(
    new Date(Math.min(result.getTime(), current.getTime())).toISOString(),
  );
}
function resolveCompletionDays({ startedDay, finishedDay }, previous, now) {
  if (
    (startedDay !== null && typeof startedDay !== "string") ||
    (finishedDay !== null && typeof finishedDay !== "string")
  )
    throw Error("Choose a date or explicitly leave it unknown.");
  const startedAt = selectLocalDay(startedDay, previous.startedAt, now),
    finishedAt = selectLocalDay(finishedDay, previous.finishedAt, now);
  if (startedAt && finishedAt && startedAt > finishedAt)
    throw Error("The start date must be on or before the finish date.");
  return { startedAt, finishedAt };
}
module.exports = { localDay, selectLocalDay, resolveCompletionDays };
