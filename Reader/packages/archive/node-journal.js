// Preserve SQLite cell types and raw JSON/provenance, never derived effective rows.
const TABLES = {
  books: "book_id",
  editions: "edition_id",
  manual_entries: "entry_id",
  events: "seq",
  daily_goals: "seq",
  migration_sources: "digest",
  migration_records: "namespace,kind,source_id",
  tracking_intervals: "interval_id",
  sqlite_sequence: "name",
};
function cell(value) {
  if (typeof value === "bigint")
    return { sqliteType: "integer", decimal: value.toString() };
  if (value instanceof Uint8Array)
    return {
      sqliteType: "blob",
      base64: Buffer.from(value).toString("base64"),
    };
  if (typeof value === "number" && !Number.isFinite(value))
    throw Error("Nonfinite SQLite value");
  if (value === null || ["number", "string"].includes(typeof value))
    return value;
  throw Error("Unknown SQLite value type");
}
/** Host holds its operation lock and flushes companion reader state before collecting files. */
export function exportNodeJournal(
  database,
  { exportedAt = new Date().toISOString() } = {},
) {
  let transaction = false;
  try {
    database.exec("BEGIN DEFERRED");
    transaction = true;
    if (database.prepare("PRAGMA user_version").get().user_version !== 2)
      throw Error("Unsupported Node journal schema");
    if (
      database.prepare("PRAGMA integrity_check").get().integrity_check !==
        "ok" ||
      database.prepare("PRAGMA foreign_key_check").all().length
    )
      throw Error("Journal integrity check failed");
    const names = database
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      )
      .all()
      .map((x) => x.name);
    if (JSON.stringify(names) !== JSON.stringify(Object.keys(TABLES).sort()))
      throw Error(
        "Unrecognized journal tables; refusing an incomplete snapshot",
      );
    const tables = {};
    let serializedBytes = 0;
    for (const [name, order] of Object.entries(TABLES)) {
      const statement = database.prepare(
        `SELECT * FROM ${name} ORDER BY ${order}`,
      );
      statement.setReadBigInts(true);
      tables[name] = [];
      for (const row of statement.iterate()) {
        const record = Object.fromEntries(
          Object.entries(row).map(([key, value]) => [key, cell(value)]),
        );
        serializedBytes += Buffer.byteLength(JSON.stringify(record));
        if (serializedBytes > 32 * 1024 * 1024)
          throw Error("Node journal snapshot exceeds JSON budget");
        tables[name].push(record);
      }
    }
    // Diagnostic schema is preserved as data and MUST NEVER be executed on import.
    const schema = database
      .prepare(
        "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name",
      )
      .all()
      .map((x) => ({ ...x }));
    const bytes = Buffer.from(
      JSON.stringify(
        {
          format: "stillleaf-node-journal",
          version: 1,
          schemaVersion: 2,
          exportedAt,
          tables,
          schema,
        },
        null,
        2,
      ) + "\n",
    );
    if (bytes.length > 32 * 1024 * 1024)
      throw Error("Node journal snapshot exceeds JSON budget");
    database.exec("COMMIT");
    transaction = false;
    return bytes;
  } catch (error) {
    if (transaction) database.exec("ROLLBACK");
    throw error;
  }
}
