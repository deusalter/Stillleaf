const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const { pathToFileURL } = require('node:url');
const { Journal } = require('./journal.cjs');
app.setName('Stillleaf Journal Prototype');
app.setPath('userData', process.env.STILLLEAF_TEST_DATA || path.join(app.getPath('appData'), 'StillleafJournalPrototype'));
const page = pathToFileURL(path.join(__dirname, 'index.html')).href;
let journal;
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { const w = BrowserWindow.getAllWindows()[0]; if (w) { w.restore(); w.focus(); } });
  app.whenReady().then(() => {
    try { journal = new Journal(path.join(app.getPath('userData'), 'journal.json')); }
    catch (error) { dialog.showErrorBox('Journal could not be opened', `${error.message}\nYour file was not overwritten. Back up journal.json and journal.json.bak in ${app.getPath('userData')} before recovery.`); app.quit(); return; }
    ipcMain.handle('journal', async (event, action, input) => {
      if (event.senderFrame !== event.sender.mainFrame || event.senderFrame.url !== page) throw Error('Untrusted sender.');
      try {
        if (action === 'read') return {state:journal.state};
        if (action === 'export') {
          const result = await dialog.showSaveDialog({title:'Export reading journal', defaultPath:'stillleaf-journal.json', filters:[{name:'Journal JSON',extensions:['json']}]});
          if (!result.canceled) {
            if ([journal.file, journal.file+'.bak', journal.file+'.tmp'].some(p => path.resolve(p).toLowerCase() === path.resolve(result.filePath).toLowerCase())) throw Error('Choose a location outside the live journal files.');
            fs.writeFileSync(result.filePath, JSON.stringify(journal.state,null,2));
          }
          return {canceled:result.canceled};
        }
        return {state:journal.mutate(action,input)};
      } catch (error) { return {error:error.message}; }
    });
    const window = new BrowserWindow({width:1180,height:820,minWidth:760,minHeight:600,backgroundColor:'#DFECE7',webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true}});
    window.webContents.setWindowOpenHandler(() => ({action:'deny'}));
    window.webContents.on('will-navigate', event => event.preventDefault());
    window.webContents.session.setPermissionRequestHandler((_wc,_permission,callback) => callback(false));
    window.setMenuBarVisibility(false);
    window.loadFile(path.join(__dirname,'index.html'));
  });
  app.on('window-all-closed', () => app.quit());
}
