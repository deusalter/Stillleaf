"use strict";
function probe() {
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE TABLE probe(value TEXT) STRICT");
  db.prepare("INSERT INTO probe VALUES(?)").run("verified");
  const result = {
    node: process.versions.node,
    electron: process.versions.electron || null,
    platform: process.platform,
    sqlite: db.prepare("SELECT sqlite_version() AS v").get().v,
    roundTrip: db.prepare("SELECT value FROM probe").get().value,
  };
  db.close();
  console.log(JSON.stringify(result));
}
if (process.versions.electron && !process.env.ELECTRON_RUN_AS_NODE) {
  const { app } = require("electron");
  app.whenReady().then(() => {
    try {
      probe();
      app.quit();
    } catch (error) {
      console.error(error);
      app.exit(1);
    }
  });
} else probe();
