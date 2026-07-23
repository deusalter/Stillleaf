"use strict";
const earliest = Date.parse("1900-01-01T00:00:00.000Z"),
  latest = Date.parse("2200-01-01T00:00:00.000Z");
function identity(value, label = "identity") {
  if (
    typeof value !== "string" ||
    !value ||
    value.length > 256 ||
    /[\x00-\x1f\x7f]/.test(value)
  )
    throw Error("Invalid " + label);
  return value;
}
function text(value, max, label, required = false) {
  if (
    typeof value !== "string" ||
    value.length > max ||
    (required && !value.trim())
  )
    throw Error("Invalid " + label);
  return value;
}
function instant(value) {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?(?:Z|[+-]\d\d:\d\d)$/.test(
      value,
    )
  )
    throw Error("Supply an explicit timestamp with timezone");
  day(value.slice(0, 10));
  if (
    Number(value.slice(11, 13)) > 23 ||
    Number(value.slice(14, 16)) > 59 ||
    Number(value.slice(17, 19)) > 59
  )
    throw Error("Invalid timestamp clock");
  const n = Date.parse(value);
  if (!Number.isFinite(n) || n < earliest || n > latest)
    throw Error("Timestamp outside1900–2200");
  return new Date(n).toISOString();
}
function day(value) {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d\d-\d\d$/.test(value) ||
    value < "1900-01-01" ||
    value > "2200-01-01" ||
    !Number.isFinite(Date.parse(value + "T00:00:00Z")) ||
    new Date(value + "T00:00:00Z").toISOString().slice(0, 10) !== value
  )
    throw Error("Invalid reading day");
  return value;
}
function timezone(value) {
  if (typeof value !== "string" || value.length > 128)
    throw Error("Invalid timezone");
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value }).format(0);
  } catch {
    throw Error("Invalid timezone");
  }
  return value;
}
function dayAt(value, zone) {
  const values = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: timezone(zone),
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    })
      .formatToParts(new Date(instant(value)))
      .map((p) => [p.type, p.value]),
  );
  return `${values.year.padStart(4, "0")}-${values.month}-${values.day}`;
}
function number(value, min, max, label, integer = false) {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    value < min ||
    value > max ||
    (integer && !Number.isSafeInteger(value))
  )
    throw Error("Invalid " + label);
  return value;
}
function optional(value, min, max, label, integer = false) {
  return value == null ? null : number(value, min, max, label, integer);
}
function review(value) {
  if (value == null) return null;
  text(value, 1000000, "review");
  const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });
  let count = 0;
  for (const _ of segmenter.segment(value)) {
    if (++count > 50000) throw Error("Review exceeds50000 characters");
  }
  return value.trim() || null;
}
module.exports = {
  identity,
  text,
  instant,
  day,
  timezone,
  dayAt,
  number,
  optional,
  review,
};
