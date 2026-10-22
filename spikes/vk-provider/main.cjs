const { app, BrowserWindow, ipcMain, session, protocol } = require('electron');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { audioResponse } = require('./audio-response.cjs');
const { randomUUID } = require('node:crypto');
const { validateImport, mediaURL, isMusicURL } = require('./music-policy.cjs');
const { sanitizeMusicStructure } = require('./music-dom.cjs');
const { mergeLibrary, scanLibrary } = require('./library-sync.cjs');
const { audioCandidate, selectNativeSource } = require('./native-source.cjs');
const { installAutomation } = require('./automation-host.cjs');

const root = path.resolve(__dirname, '../..');
const dataDir = path.join(root, '.local', 'vk-proof');
const audioDir = path.join(dataDir, 'audio');
fs.mkdirSync(audioDir, { recursive: true });
app.setPath('userData', path.join(dataDir, 'app-profile'));
protocol.registerSchemesAsPrivileged([
  { scheme: 'proof-audio', privileges: { standard: true, secure: true, stream: true, supportFetchAPI: true } },
]);

const offline = process.argv.includes('--offline');
const automatedMode = process.argv.includes('--automated-proof');
const runId = randomUUID();
let mainWindow, vkWindow, vkSession;
let sourceUserAgent = 'Ownsemble/0.1';
let busy = false;
let message = offline ? 'Offline mode: this app blocks all remote requests.' : 'Connect VK, sign in privately, then enable automatic sync once.';
let tracks = [];
const sources = new Map();
const evidencePath = path.join(dataDir, 'evidence.json');
const libraryPath = path.join(dataDir, 'library.json');
const indexPath = path.join(dataDir, 'cache-index.json');
const syncSettingsPath = path.join(dataDir, 'sync-settings.json');
const libraryScopePath = path.join(dataDir, 'library-scope.json');
const readJSON = (file, fallback) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
};
let cache = readJSON(indexPath, {});
let syncEnabled = readJSON(syncSettingsPath, {}).enabled === true;
let personalLibraryConfirmed = readJSON(libraryScopePath, {}).personal === true;
let lastScan = null;
let pendingAudio = null;
let cancelScan = false;
const playerTests = new Map();
tracks = readJSON(libraryPath, []);
let evidence = readJSON(evidencePath, { events: [] });
const writeJSON = (file, data) => {
  fs.writeFileSync(`${file}.tmp`, JSON.stringify(data, null, 2));
  fs.renameSync(`${file}.tmp`, file);
};
function record(event, details = {}) {
  evidence.events.push({ at: new Date().toISOString(), runId, offline, event, ...details });
  writeJSON(evidencePath, evidence);
  // This status stream contains no cookies, audio URLs, names, or account IDs.
  console.log(JSON.stringify({ event, offline, ...details }));
}
function safeID(value) {
  if (typeof value !== 'string' || !/^-?\d+_\d+$/.test(value)) throw new Error('Invalid track ID.');
  return value;
}
function cachedPath(id) {
  const entry = cache[id];
  if (!entry || path.basename(entry.filename) !== entry.filename) return null;
  const file = path.join(audioDir, entry.filename);
  return fs.existsSync(file) ? file : null;
}
function state() {
  return {
    offline, connected: tracks.length > 0, busy, message, syncEnabled, lastScan,
    vkWindowOpen: Boolean(vkWindow && !vkWindow.isDestroyed()),
    tracks: tracks.map((track) => ({ ...track, sourceReady: sources.has(track.id), cached: Boolean(cachedPath(track.id)),
      audioUrl: cachedPath(track.id) ? `proof-audio://local/${track.id}` : null })),
    evidence: evidence.events.slice(-16),
  };
}
function update(text) {
  if (text) message = text;
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('proof:update', state());
}
function helper(payload) {
  const python = path.join(root, '.venv-vk', 'Scripts', 'python.exe');
  return new Promise((resolve, reject) => {
    const child = spawn(python, [path.join(__dirname, 'provider.py')], {
      windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'],
      env: { ...process.env, PYTHONIOENCODING: 'utf-8' },
    });
    let output = '';
    const timeout = setTimeout(() => { child.kill(); reject(new Error('Provider operation timed out.')); }, 360000);
    child.stdout.on('data', (chunk) => { output += chunk.toString('utf8'); });
    child.on('error', () => { clearTimeout(timeout); reject(new Error('Could not start the isolated Python provider.')); });
    child.on('close', (code) => {
      clearTimeout(timeout);
      try {
        const result = JSON.parse(output);
        if (!result.ok) reject(new Error(result.error));
        else if (code !== 0) reject(new Error('Provider process failed.'));
        else resolve(result);
      } catch { reject(new Error('Provider did not return a supported response.')); }
    });
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(payload));
  });
}
async function operation(action) {
  if (busy) return state();
  busy = true;
  update();
  try { await action(); }
  catch (error) { record('operation_failed', { reason: error.message }); update(error.message); }
  finally { busy = false; update(); }
  return state();
}

function isVKAddress(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password && !url.port &&
      /(^|\.)(vk\.ru|vk\.com|vk\.id)$/.test(url.hostname);
  } catch { return false; }
}
function secureVKWindow(window) {
  window.setMenu(null);
  const navigationGuard = (event, url) => { if (!isVKAddress(url)) event.preventDefault(); };
  window.webContents.on('will-navigate', navigationGuard);
  window.webContents.on('will-redirect', navigationGuard);
  window.webContents.setWindowOpenHandler(({ url }) => isVKAddress(url) ? {
    action: 'allow', overrideBrowserWindowOptions: {
      autoHideMenuBar: true,
      webPreferences: { session: vkSession, nodeIntegration: false, contextIsolation: true,
        sandbox: true, webSecurity: true, devTools: false },
    },
  } : { action: 'deny' });
  window.webContents.on('did-create-window', (child) => secureVKWindow(child));
}
function openVK(background = false) {
  if (offline) throw new Error('VK connection is disabled in offline mode.');
  if (vkWindow && !vkWindow.isDestroyed()) {
    if (!background) { vkWindow.show(); vkWindow.focus(); }
    return Promise.resolve();
  }
  vkWindow = new BrowserWindow({
    show: !background,
    width: 1040, height: 820, title: 'VK — sign in privately, then open My music',
    webPreferences: { session: vkSession, nodeIntegration: false, contextIsolation: true,
      sandbox: true, webSecurity: true, devTools: false,
      backgroundThrottling: !automatedMode },
  });
  secureVKWindow(vkWindow);
  // No preload or authentication inspection. Music actions have their own
  // path/form gate and never read sign-in field values or session credentials.
  vkWindow.on('closed', () => { vkWindow = null; update(); });
  const loading = vkWindow.loadURL('https://vk.ru/audios');
  loading.then(() => {
    if (background && syncEnabled && !busy && !automatedMode) operation(() => syncLibrary(false));
  }).catch(() =>
    update('VK could not load. Check the VK window for a connection error.'));
  update('Complete sign-in privately, open My music, then enable automatic sync once.');
  return loading;
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function ensureMyMusic() {
  let navigationAttempted = false;
  let lastCounts = {};
  for (let attempt = 0; attempt < 30; attempt++) {
    const result = await pageAction(navigationAttempted ? 'verify-my-music' : 'open-my-music');
    if (result.error && result.error !== 'My music navigation is not ready.') throw new Error(result.error);
    lastCounts = result.counts || {};
    if (result.personal) {
      record('personal_music_view_confirmed', { navigationAttempted, ...lastCounts });
      return;
    }
    if (result.navigationAttempted) navigationAttempted = true;
    await delay(500);
  }
  record('personal_music_view_unconfirmed', lastCounts);
  throw new Error('My music view could not be confirmed; extraction is paused.');
}
function adoptPersonalMetadata(incoming) {
  const correcting = !personalLibraryConfirmed;
  if (!personalLibraryConfirmed) {
    // Earlier scans started on a general music view. Preserve that metadata,
    // but do not mix it into a newly confirmed personal library.
    const backup = path.join(dataDir, 'unverified-library.json');
    if (!fs.existsSync(backup)) writeJSON(backup, tracks);
    record('library_source_corrected', { previousUnverifiedCount: tracks.length, currentPersonalCount: incoming.length });
    tracks = [];
    sources.clear();
  }
  tracks = mergeLibrary(tracks, incoming);
  writeJSON(libraryPath, tracks);
  if (correcting) {
    writeJSON(libraryScopePath, { personal: true, confirmedAt: new Date().toISOString() });
    personalLibraryConfirmed = true;
  }
}
async function readReadyPage(options = {}) {
  for (let attempt = 0; attempt < 30; attempt++) {
    try { return await readPage({ ...options, quiet: true }); }
    catch (error) {
      if (!/Music format is unsupported/.test(error.message)) throw error;
      await delay(500);
    }
  }
  return readPage(options);
}
function musicWindowReady() {
  return !offline && vkWindow && !vkWindow.isDestroyed() && isMusicURL(vkWindow.webContents.getURL());
}
async function pageAction(action, id, options = {}) {
  if (!musicWindowReady()) throw new Error('Open My music; automatic access is paused outside music pages.');
  delete require.cache[require.resolve('./music-action.cjs')];
  const { musicPageAction } = require('./music-action.cjs');
  try {
    return await vkWindow.webContents.executeJavaScript(
      `(${musicPageAction.toString()})(${JSON.stringify(action)}, ${JSON.stringify(id || '')}, ${JSON.stringify(options)})`, action === 'play');
  } catch { throw new Error('VK music action did not complete.'); }
}
async function readPage(options = {}) {
  if (!musicWindowReady()) throw new Error('Open My music; automatic access is paused outside music pages.');
  for (const file of ['./music-page.cjs', './music-dom.cjs']) delete require.cache[require.resolve(file)];
  const { readMusicPage } = require('./music-page.cjs');
  const { inspectMusicDOM } = require('./music-dom.cjs');
  let extracted;
  try {
    extracted = await vkWindow.webContents.executeJavaScript(
      `(${readMusicPage.toString()})(${inspectMusicDOM.toString()}, ${JSON.stringify(options)})`);
  } catch { throw new Error('VK music adapter did not complete.'); }
  if (extracted?.structure && !options.quiet) record('music_dom_diagnosed', sanitizeMusicStructure(extracted.structure));
  if (extracted?.error) throw new Error(extracted.error);
  const { resolutionFailed, diagnostics, structure, ...data } = extracted;
  validateImport(data);
  return extracted;
}
async function syncLibrary(incremental, shouldStop = () => false) {
  if (!musicWindowReady()) throw new Error('Open My music; automatic access is paused outside music pages.');
  update(incremental ? 'Checking for newly added VK music…' : 'Loading music beyond the first page…');
  cancelScan = false;
  await ensureMyMusic();
  await readReadyPage({ metadataOnly: true });
  if (automatedMode && !incremental) {
    // Lazy pagination can pause in a hidden provider window. The personal music
    // gate has already passed; sign-in windows are never shown by this action.
    vkWindow.show();
    vkWindow.focus();
  }
  let recentLoadMs = 1200;
  const checkedAction = async (action, idle = 0) => {
    const waitMs = action === 'reset' ? 0 :
      Math.min(30000, Math.max(1500, Math.ceil(recentLoadMs * 2)) * 2 ** Math.min(idle, 4));
    const result = await pageAction(action, undefined, { waitMs });
    if (result.error) throw new Error(result.error);
    if (result.progressed && Number.isFinite(result.waitedMs)) {
      recentLoadMs = Math.max(250, recentLoadMs * 0.5 + result.waitedMs * 0.5);
    }
    if (action === 'reset') await delay(400);
    return result;
  };
  const result = await scanLibrary({
    read: () => readReadyPage({ metadataOnly: true }),
    reset: () => checkedAction('reset'),
    advance: ({ idle }) => checkedAction(idle ? 'retry-pagination' : 'advance', idle), incremental,
    idleTimeoutMs: incremental ? 0 : 60000,
    maxDurationMs: automatedMode ? 300000 : 600000,
    shouldStop: () => cancelScan || shouldStop(),
    onProgress: ({ count, pages, idle, quietMs, loading }) => {
      update(`Reading VK music: ${count} tracks across ${pages} viewports…`);
      if (automatedMode && (pages === 1 || pages % 10 === 0 || quietMs >= 30000)) {
        record('library_scan_progress', { count, pages, idle, quietMs, loading });
      }
    },
  });
  if (!result.tracks.length) { update('Music sync stopped. Existing library retained.'); return; }
  const decoded = await helper({ operation: 'decode', tracks: result.tracks, userId: result.userId });
  const incoming = decoded.tracks.map((track) => ({ ...track, url: track.url ? mediaURL(track.url) : '' }));
  sourceUserAgent = result.userAgent;
  const metadata = incoming.map(({ url, ...track }) => {
    if (url) sources.set(track.id, url);
    return track;
  });
  adoptPersonalMetadata(metadata);
  for (const item of incoming) if (item.url) sources.set(item.id, item.url);
  writeJSON(libraryPath, tracks);
  lastScan = { count: result.tracks.length, pages: result.pages,
    stopReason: result.stopReason, complete: result.complete };
  record('library_synced', { count: tracks.length, observed: result.tracks.length,
    playableURLs: sources.size, pages: result.pages, stopReason: result.stopReason,
    complete: result.complete, automatic: incremental });
  if (automatedMode && !incremental) {
    const probe = await pageAction('probe-pagination');
    const counts = {};
    for (const key of ['documentScrollHeight', 'documentClientHeight', 'documentScrollTop',
      'scrollableMusicAncestors', 'visibleDocument']) {
      const value = probe.counts?.[key];
      if (Number.isSafeInteger(value) && value >= 0 && value <= 100000000) counts[key] = value;
    }
    record('music_pagination_diagnosed', counts);
  }
  update(`${tracks.length} tracks retained locally. ${sources.size} audio links ready; other tracks resolve when played. ` +
    'Provider total is not yet verified.' + (syncEnabled ? ' Automatic refresh is on.' : ''));
}
async function resolveNativeSource(id) {
  if (!musicWindowReady()) throw new Error('Connect VK to resolve audio for this track.');
  update('Asking VK to resolve the selected track…');
  await ensureMyMusic();
  sourceUserAgent = vkWindow.webContents.getUserAgent();
  await pageAction('pause');
  const reset = await pageAction('reset');
  if (reset.error) throw new Error(reset.error);
  await delay(400);
  // Native input requires a visible, focused window. Confirm personal music
  // first so this never focuses a sign-in page for an automated interaction.
  const initialWitness = await pageAction('verify-my-music');
  if (!initialWitness.personal) throw new Error('My music view changed before activation.');
  const muted = vkWindow.webContents.isAudioMuted();
  vkWindow.webContents.setAudioMuted(true);
  const capture = { urls: new Set(), webContentsId: vkWindow.webContents.id,
    windowRequests: 0, mediaRequests: 0, unassociatedRequests: 0, audioLikeRequests: 0,
    allowedCDNRequests: 0, unassociatedAudioRequests: 0, audioMethodRequests: 0 };
  let activated = false;
  try {
    vkWindow.show(); vkWindow.focus(); vkWindow.webContents.focus();
    await delay(200);
    for (let page = 0; page < 80; page++) {
      pendingAudio = capture;
      const result = await pageAction('play-position', id);
      if (result.counts) {
        const counts = {};
        for (const key of ['targetWidth', 'targetHeight', 'viewportWidth', 'viewportHeight',
          'visibleDocument', 'hitPresent', 'hitInsideTarget', 'hitSameTrack', 'hitBlockedControl']) {
          const value = result.counts[key];
          if (Number.isSafeInteger(value) && value >= 0 && value <= 100000) counts[key] = value;
        }
        record('native_control_geometry', counts);
      }
      if (result.position) {
        const { x, y } = result.position;
        if (!Number.isSafeInteger(x) || !Number.isSafeInteger(y) || x < 0 || y < 0 || x > 10000 || y > 10000) {
          throw new Error('VK playback control position is unsupported.');
        }
        const witness = await pageAction('verify-my-music');
        if (!witness.personal) throw new Error('My music view changed before activation.');
        vkWindow.show(); vkWindow.focus(); vkWindow.webContents.focus();
        await delay(150);
        // Native input is restricted to an unobscured known playback control
        // returned by the guarded music reader. The control file accepts no coordinates.
        vkWindow.webContents.sendInputEvent({ type: 'mouseMove', x, y });
        vkWindow.webContents.sendInputEvent({ type: 'mouseDown', button: 'left', clickCount: 1, x, y });
        vkWindow.webContents.sendInputEvent({ type: 'mouseUp', button: 'left', clickCount: 1, x, y });
        activated = true;
        break;
      }
      if (result.activated) { activated = true; break; }
      pendingAudio = null;
      if (result.error !== 'Track is not in the current music viewport.' || page === 79) {
        const report = await readPage({ metadataOnly: true });
        if (report.structure) record('music_dom_diagnosed', sanitizeMusicStructure(report.structure));
        throw new Error(result.error || 'VK play control could not be activated.');
      }
      const advanced = await pageAction('advance');
      if (advanced.error) throw new Error(advanced.error);
      await delay(700);
    }
    for (let attempt = 0; !capture.urls.size && attempt < 30; attempt++) await delay(500);
    await delay(1000); // Allow competing/preload sources to surface; reject ambiguity.
    if (!capture.urls.size) {
      const result = await pageAction('probe-playback', id);
      const counts = {};
      for (const key of ['regionPresent', 'regionClickHandlers', 'rowClickHandlers', 'clickHandlers',
        'mouseDownHandlers', 'pointerDownHandlers', 'doubleClickHandlers', 'buttons', 'descendants', 'nativeMediaElements']) {
        const value = result.counts?.[key];
        if (Number.isSafeInteger(value) && value >= 0 && value <= 100000) counts[key] = value;
      }
      record('native_playback_diagnosed', counts);
    }
    const url = selectNativeSource([...capture.urls]);
    sources.set(id, url);
    record('native_audio_candidate', { candidateCount: capture.urls.size,
      association: 'target_row_play_control', sourceKind: new URL(url).pathname.endsWith('.m3u8') ? 'hls' : 'direct' });
    return url;
  } finally {
    pendingAudio = null;
    record('native_audio_resolution_finished', { candidateCount: capture.urls.size, activated,
      windowRequests: capture.windowRequests, mediaRequests: capture.mediaRequests,
      unassociatedRequests: capture.unassociatedRequests, audioLikeRequests: capture.audioLikeRequests,
      allowedCDNRequests: capture.allowedCDNRequests, unassociatedAudioRequests: capture.unassociatedAudioRequests,
      audioMethodRequests: capture.audioMethodRequests });
    if (musicWindowReady()) await pageAction('pause').catch(() => {});
    if (vkWindow && !vkWindow.isDestroyed()) vkWindow.webContents.setAudioMuted(muted);
  }
}

async function ensureCachedTrack(value) {
  const id = safeID(value);
  const track = tracks.find((item) => item.id === id);
  if (!track) throw new Error('Track was not found in this library.');
  if (cachedPath(id)) return;
  if (offline) throw new Error('Downloading is disabled in offline mode.');
  const url = sources.get(id) || await resolveNativeSource(id);
  update('Saving the full track and verifying every audio frame…');
  let result;
  try {
    result = await helper({ operation: 'download', userAgent: sourceUserAgent, url,
      expectedDuration: track.duration, outputBase: path.join(audioDir, id) });
  } catch (error) { sources.delete(id); throw error; }
  const { ok, ...entry } = result;
  cache[id] = entry;
  writeJSON(indexPath, cache);
  record('audio_saved_and_decoded', { bytes: entry.bytes, duration: entry.duration,
    codec: entry.codec, sourceKind: entry.sourceKind, sha256: entry.sha256 });
  update('Full audio saved and decoded.');
}
async function verifyCachedTrack(value) {
  const id = safeID(value);
  const file = cachedPath(id);
  if (!file) throw new Error('This song has no complete cached audio.');
  const result = await helper({ operation: 'verify', path: file });
  if (result.sha256 !== cache[id].sha256) throw new Error('Local audio hash differs from the completed download.');
  record('local_audio_verified', { duration: result.duration, bytes: result.bytes,
    sha256: result.sha256, fullDecode: result.fullDecode });
}
function playerProof(value) {
  const id = safeID(value);
  if (!cachedPath(id)) throw new Error('No cached audio for player test.');
  // Muted background media can be automatically paused by Chromium. Bring the
  // local proof window forward; this never touches the private sign-in window.
  mainWindow.show();
  mainWindow.focus();
  return new Promise((resolve) => {
    const testId = randomUUID();
    const timer = setTimeout(() => {
      playerTests.delete(testId);
      resolve({ passed: false, category: 'player_timeout' });
    }, 90000);
    playerTests.set(testId, (result) => { clearTimeout(timer); playerTests.delete(testId); resolve(result); });
    mainWindow.webContents.send('proof:player-test', { testId, source: `proof-audio://local/${id}` });
  });
}
async function prepareAutomatedMusic(shouldStop = () => false) {
  await openVK(true);
  await ensureMyMusic();
  for (let attempt = 0; attempt < 30; attempt++) {
    try {
      const result = await readPage({ metadataOnly: true, quiet: true });
      const decoded = await helper({ operation: 'decode', tracks: result.tracks, userId: result.userId });
      const incoming = decoded.tracks.map(({ url, ...track }) => {
        if (url) sources.set(track.id, mediaURL(url));
        return track;
      });
      sourceUserAgent = result.userAgent;
      adoptPersonalMetadata(incoming);
      // Adopt resets sources only when correcting the old unverified scope.
      for (const item of decoded.tracks) if (item.url) sources.set(item.id, mediaURL(item.url));
      writeJSON(libraryPath, tracks);
      // Exercise personal pagination in the same unattended feasibility run.
      // This does not change the user's persisted automatic-sync preference.
      if (shouldStop()) throw new Error('cancelled');
      await syncLibrary(false, shouldStop);
      if (shouldStop()) throw new Error('cancelled');
      const prior = new Set(tracks.map((track) => track.id));
      await syncLibrary(true, shouldStop);
      record('incremental_refresh_checked', { beforeCount: prior.size, afterCount: tracks.length,
        priorRowsRetained: [...prior].every((id) => tracks.some((track) => track.id === id)),
        providerAdditionObserved: tracks.some((track) => !prior.has(track.id)) });
      return;
    } catch (error) {
      if (/sign.in|login|outside music|Open My music/i.test(error.message)) throw error;
      if (!/Music format is unsupported/.test(error.message)) throw error;
      await delay(1000);
    }
  }
  await readPage({ metadataOnly: true });
  throw new Error('Music page timed out.');
}

app.whenReady().then(async () => {
  // The local UI stays separate from the VK browser session.
  session.defaultSession.webRequest.onBeforeRequest(
    { urls: ['http://*/*', 'https://*/*', 'ws://*/*', 'wss://*/*'] },
    (_details, callback) => { record('remote_renderer_request_blocked'); callback({ cancel: true }); });
  vkSession = session.fromPartition('persist:vk-music');
  vkSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  vkSession.setPermissionCheckHandler(() => false);
  vkSession.webRequest.onBeforeRequest(
    { urls: ['http://*/*', 'https://*/*', 'ws://*/*', 'wss://*/*'] },
    (details, callback) => {
      if (!offline && pendingAudio && musicWindowReady()) {
        // Observe only media destinations while the selected row's native play
        // action is pending. No headers, cookies, POST bodies, or responses.
        if (details.webContentsId === undefined) {
          pendingAudio.unassociatedRequests++;
          if (audioCandidate(details.url)) pendingAudio.unassociatedAudioRequests++;
        }
        if (details.webContentsId === pendingAudio.webContentsId) {
          pendingAudio.windowRequests++;
          if (details.resourceType === 'media') pendingAudio.mediaRequests++;
          if (/\.(?:mp3|m4a|m3u8)(?:[?#]|$)/i.test(details.url)) pendingAudio.audioLikeRequests++;
          if (/\/method\/audio\.[A-Za-z]+(?:\?|$)/.test(details.url)) pendingAudio.audioMethodRequests++;
          try { mediaURL(details.url); pendingAudio.allowedCDNRequests++; } catch { /* Count only approved destinations. */ }
          const candidate = audioCandidate(details.url);
          if (candidate) pendingAudio.urls.add(candidate);
        }
      }
      callback({ cancel: offline });
    });
  protocol.handle('proof-audio', async (request) => {
    try {
      const address = new URL(request.url);
      if (address.hostname !== 'local') return new Response(null, { status: 400 });
      const id = safeID(address.pathname.slice(1));
      const file = cachedPath(id);
      if (!file) return new Response('No complete cached audio', { status: 404 });
      const response = await audioResponse(request, file);
      if (automatedMode) record('local_audio_served', { status: response.status });
      return response;
    } catch { return new Response('Invalid audio request', { status: 400 }); }
  });
  // Every renderer entry point is restricted to the local proof window.
  const handle = (name, action) => ipcMain.handle(name, (event, ...args) => {
    if (!mainWindow || event.sender !== mainWindow.webContents ||
        event.senderFrame !== mainWindow.webContents.mainFrame) throw new Error('Unsupported caller.');
    return action(...args);
  });
  handle('proof:state', () => state());
  handle('proof:connect', () => { openVK(); return state(); });
  handle('proof:import', () => operation(() => syncLibrary(false)));
  handle('proof:auto-sync', (enabled) => {
    if (typeof enabled !== 'boolean') throw new Error('Invalid sync preference.');
    if (!enabled) {
      syncEnabled = false;
      cancelScan = true;
      writeJSON(syncSettingsPath, { enabled: false });
      record('automatic_sync_disabled');
      update('Automatic music sync is off. Any active scan is stopping.');
      return state();
    }
    return operation(async () => {
      if (!musicWindowReady()) throw new Error('Open My music before enabling sync.');
      await readPage({ metadataOnly: true });
      syncEnabled = true;
      writeJSON(syncSettingsPath, { enabled: true });
      record('automatic_sync_enabled');
      await syncLibrary(false);
    });
  });
  handle('proof:download', (value) => operation(() => ensureCachedTrack(value)));
  handle('proof:verify', (value) => operation(async () => {
    await verifyCachedTrack(value);
    update(offline ? 'Offline full-file decode passed, with matching bytes.' : 'Local full-file decode passed.');
  }));
  handle('proof:player-test-result', (result) => {
    if (!result || typeof result.testId !== 'string' || !playerTests.has(result.testId)) return;
    const passed = result.passed === true && result.metadata === true &&
      result.advanced === true && result.seeked === true && Number.isFinite(result.position) &&
      result.position >= 0 && result.position <= 86400 && Number.isFinite(result.duration) &&
      result.duration > 0 && result.duration <= 86400;
    const categories = ['player_timeout', 'player_decode_failed', 'player_did_not_advance', 'player_seek_failed'];
    const normalized = passed ? { passed: true, position: result.position, duration: result.duration } :
      { passed: false, category: categories.includes(result.category) ? result.category : 'player_decode_failed' };
    if (!passed) {
      normalized.stage = ['metadata', 'start', 'advance', 'seek', 'resume'].includes(result.stage) ? result.stage : 'unknown';
      normalized.mediaError = [1, 2, 3, 4].includes(result.mediaError) ? result.mediaError : 0;
      normalized.interruption = ['background', 'pause', 'load', 'removed', 'ended', 'suspended', 'browser', 'user', 'paused']
        .includes(result.interruption) ? result.interruption : 'other';
      normalized.rejection = ['NotAllowedError', 'NotSupportedError', 'AbortError'].includes(result.rejection) ? result.rejection : 'other';
    }
    record('automated_player_checked', { ...normalized, phase: offline ? 'offline' : 'online' });
    playerTests.get(result.testId)(normalized);
  });
  handle('proof:playback', (event) => {
    if (!event || !['started', 'ended', 'seeked', 'error'].includes(event.kind)) return;
    safeID(event.id);
    record(`player_${event.kind}`, { position: Number(event.position) || 0 });
  });
  handle('proof:restart-offline', () => {
    if (!tracks.some((track) => cachedPath(track.id))) throw new Error('Save a track before the offline restart.');
    app.relaunch({ args: [...process.argv.slice(1).filter((arg) => arg !== '--offline'), '--offline'] });
    app.exit(0);
  });
  mainWindow = new BrowserWindow({
    width: 1160, height: 820, minWidth: 820, minHeight: 620, backgroundColor: '#101319',
    title: 'Ownsemble — VK feasibility test',
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, nodeIntegration: false, sandbox: true,
      backgroundThrottling: !automatedMode },
  });
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (event) => event.preventDefault());
  await mainWindow.loadFile(path.join(__dirname, 'index.html'));
  record('app_started');
  installAutomation({ enabled: automatedMode, offline, app, dataDir, args: process.argv.slice(1),
    readJSON, writeJSON, record, update, operation, isBusy: () => busy,
    prepareMusic: prepareAutomatedMusic, candidates: () => {
      const saved = tracks.filter((track) => cachedPath(track.id));
      return (saved.length ? saved : tracks).slice(0, 3);
    },
    download: (track) => ensureCachedTrack(track.id), verify: verifyCachedTrack, player: playerProof });
  if (!offline && syncEnabled && !automatedMode) openVK(true);
  else if (!offline && process.argv.includes('--connect')) openVK();
  const refresh = setInterval(() => {
    if (automatedMode || !syncEnabled || busy || !musicWindowReady()) return;
    operation(async () => {
      update('Refreshing the connected music page…');
      await new Promise((resolve, reject) => {
        const contents = vkWindow.webContents;
        const finished = () => { clearTimeout(timeout); resolve(); };
        const timeout = setTimeout(() => {
          contents.removeListener('did-finish-load', finished);
          reject(new Error('VK music refresh timed out.'));
        }, 20000);
        contents.once('did-finish-load', finished);
        contents.reload();
      });
      await delay(1500);
      if (!syncEnabled) return;
      await syncLibrary(true);
    });
  }, 120000);
  refresh.unref();
});
app.on('window-all-closed', () => app.quit());
