const {contextBridge,ipcRenderer} = require('electron');
contextBridge.exposeInMainWorld('journal', {
  read: () => ipcRenderer.invoke('journal','read'),
  addBook: input => ipcRenderer.invoke('journal','addBook',input),
  addEntry: input => ipcRenderer.invoke('journal','addEntry',input),
  setStatus: input => ipcRenderer.invoke('journal','setStatus',input),
  deleteEntry: input => ipcRenderer.invoke('journal','deleteEntry',input),
  export: () => ipcRenderer.invoke('journal','export')
});
