const $ = (id) => document.getElementById(id);
let currentState;
let currentTrack;
let played = false;
const player = $('player');

function duration(seconds) {
  const value = Math.max(0, Math.floor(Number(seconds) || 0));
  return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, '0')}`;
}
function cell(text, className) {
  const td = document.createElement('td');
  td.textContent = text;
  if (className) td.className = className;
  return td;
}
async function run(action) {
  try { const result = await action(); if (result) render(result); }
  catch (error) { $('status').textContent = error.message; }
}
async function play(track) {
  if (!track.audioUrl) return;
  currentTrack = track;
  played = false;
  $('now-title').textContent = track.title;
  $('now-artist').textContent = `${track.artist} · Complete local audio`;
  player.src = `${track.audioUrl}?v=${Date.now()}`;
  render(currentState);
  try { await player.play(); }
  catch { $('status').textContent = 'Player could not start. Check the saved file with Verify.'; }
}
function actionButton(label, action, disabled) {
  const button = document.createElement('button');
  button.textContent = label;
  button.className = 'track-action';
  button.disabled = disabled;
  button.addEventListener('click', () => run(action));
  return button;
}
function render(state) {
  currentState = state;
  $('status').textContent = state.message;
  $('mode').textContent = state.offline ? 'NETWORK BLOCKED IN APP' : 'ONLINE TEST';
  $('mode').classList.toggle('offline', state.offline);
  $('connect').disabled = state.offline || state.busy;
  $('import').disabled = state.offline || state.busy || !state.vkWindowOpen;
  $('auto-sync').textContent = state.syncEnabled ? 'Disable automatic sync' : '2 · Enable automatic sync';
  $('auto-sync').disabled = !state.syncEnabled && (state.busy || state.offline || !state.vkWindowOpen);
  $('offline').disabled = state.offline || state.busy || !state.tracks.some((track) => track.cached);
  $('count').textContent = state.tracks.length ? `· ${state.tracks.length} loaded` : '';
  $('step-auth').classList.toggle('done', state.connected || state.tracks.length > 0);
  $('step-list').classList.toggle('done', state.tracks.length > 0);
  $('step-cache').classList.toggle('done', state.tracks.some((track) => track.cached));
  $('step-offline').classList.toggle('done', state.offline);
  $('empty').hidden = state.tracks.length > 0;
  $('tracks').replaceChildren();
  for (const track of state.tracks) {
    const row = document.createElement('tr');
    row.classList.toggle('active', currentTrack?.id === track.id);
    const name = cell(track.title);
    const artist = document.createElement('span');
    artist.className = 'artist';
    artist.textContent = track.artist;
    name.append(artist);
    const actions = cell('');
    if (track.cached) {
      actions.append(actionButton('Play', () => play(track), false));
      actions.append(actionButton('Verify', () => window.proof.verify(track.id), state.busy));
    } else {
      actions.append(actionButton(track.sourceReady ? 'Play & cache' : 'Resolve, play & cache', async () => {
        const next = await window.proof.download(track.id);
        render(next);
        const saved = next.tracks.find((item) => item.id === track.id);
        if (saved?.cached) await play(saved);
      }, state.busy || state.offline || !state.vkWindowOpen));
    }
    row.append(name, cell(duration(track.duration)),
      cell(track.cached ? 'Ready offline' : track.sourceReady ? 'Not saved' : 'Audio source pending', track.cached ? 'available' : 'artist'), actions);
    $('tracks').append(row);
  }
  $('evidence').textContent = state.evidence.map((item) =>
    `${item.at.slice(11, 19)}  ${item.offline ? '[offline] ' : ''}${item.event}` +
    (item.count !== undefined ? ` · ${item.count} tracks` : '') +
    (item.bytes ? ` · ${(item.bytes / 1048576).toFixed(2)} MB` : '') +
    (item.reason ? ` · ${item.reason}` : '')).join('\n');
}
$('connect').addEventListener('click', () => run(() => window.proof.connect()));
$('import').addEventListener('click', () => run(() => window.proof.importMusic()));
$('auto-sync').addEventListener('click', () => run(() => window.proof.automaticSync(!currentState.syncEnabled)));
$('offline').addEventListener('click', () => run(() => window.proof.restartOffline()));
function report(kind) {
  if (currentTrack) window.proof.playback({ kind, id: currentTrack.id, position: player.currentTime }).catch(() => {});
}
player.addEventListener('playing', () => { if (!played) { played = true; report('started'); } });
player.addEventListener('ended', () => report('ended'));
player.addEventListener('seeked', () => report('seeked'));
player.addEventListener('error', () => {
  if (currentTrack) {
    report('error');
    $('status').textContent = 'Audio player error. Use Verify to distinguish file decoding from player support.';
  }
});
window.proof.onUpdate(render);
window.proof.onPlayerTest(async ({ testId, source }) => {
  const result = await localPlayerProof(source);
  await window.proof.completePlayerTest({ testId, ...result });
});
run(() => window.proof.state());
