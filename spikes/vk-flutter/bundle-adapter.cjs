'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { readMusicPage } = require('../vk-provider/music-page.cjs');
const { musicPageAction } = require('../vk-provider/music-action.cjs');
const { inspectMusicDOM } = require('../vk-provider/music-dom.cjs');
fs.mkdirSync(path.join(__dirname, 'assets'), { recursive: true });
fs.writeFileSync(path.join(__dirname, 'assets/vk_adapter.js'),
  `window.ownsembleMusic = Object.freeze({\n` +
  `read: async (options) => (${readMusicPage.toString()})(` +
  `${inspectMusicDOM.toString()}, {...options, metadataOnly: true, quiet: true}),\n` +
  `action: ${musicPageAction.toString()}\n});\n`);
console.log('Bundled the existing guarded music readers; no session data read.');
