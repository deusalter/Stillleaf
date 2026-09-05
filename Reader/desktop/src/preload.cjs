const { contextBridge, ipcRenderer, webUtils } = require("electron");
contextBridge.exposeInMainWorld(
  "stillleafLibrary",
  Object.freeze({
    archive: (action, id) => ipcRenderer.invoke("library", "archive", { action, id }),
    journal: (action, input) =>
      ipcRenderer.invoke("library", "journal", { action, input }),
    snapshot: () => ipcRenderer.invoke("library", "snapshot"),
    pick: () => ipcRenderer.invoke("library", "pick"),
    drop: (files) =>
      ipcRenderer.invoke(
        "library",
        "drop",
        Array.from(files, (file) => webUtils.getPathForFile(file)),
      ),
    cancel: () => ipcRenderer.invoke("library", "cancel"),
    read: (id) => ipcRenderer.invoke("library", "read", id),
    exportReaderState: (id) =>
      ipcRenderer.invoke("library", "exportReaderState", id),
    importReaderState: (id) =>
      ipcRenderer.invoke("library", "importReaderState", id),
    remove: (id) => ipcRenderer.invoke("library", "remove", id),
    onChanged: (callback) => {
      const handler = (_event, value) => callback(value);
      ipcRenderer.on("library-changed", handler);
      return () => ipcRenderer.removeListener("library-changed", handler);
    },
  }),
);
