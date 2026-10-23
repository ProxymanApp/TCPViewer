// Sandboxed preload: hands the engine MessagePort to the page and exposes only the bench config/report calls.
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

const windowLoaded = new Promise((resolve) => {
  window.addEventListener('load', resolve, { once: true });
});

// Forward the port into the main world once the page's listener exists.
ipcRenderer.on('engine-port', async (event) => {
  await windowLoaded;
  window.postMessage('engine-port', '*', event.ports);
});

contextBridge.exposeInMainWorld('spike', {
  getConfig: () => ipcRenderer.invoke('spike:config'),
  reportResults: (results) => ipcRenderer.send('spike:results', results),
});
