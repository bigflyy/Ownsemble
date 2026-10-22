const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('proof', {
  state: () => ipcRenderer.invoke('proof:state'),
  connect: () => ipcRenderer.invoke('proof:connect'),
  importMusic: () => ipcRenderer.invoke('proof:import'),
  automaticSync: (enabled) => ipcRenderer.invoke('proof:auto-sync', enabled),
  download: (id) => ipcRenderer.invoke('proof:download', id),
  verify: (id) => ipcRenderer.invoke('proof:verify', id),
  restartOffline: () => ipcRenderer.invoke('proof:restart-offline'),
  playback: (event) => ipcRenderer.invoke('proof:playback', event),
  onPlayerTest: (callback) => ipcRenderer.on('proof:player-test', (_event, request) => callback(request)),
  completePlayerTest: (result) => ipcRenderer.invoke('proof:player-test-result', result),
  onUpdate: (callback) => ipcRenderer.on('proof:update', (_event, state) => callback(state)),
});
