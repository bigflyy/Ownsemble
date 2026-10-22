const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { parseControl, failureCategory, onlineProof } = require('./automation.cjs');
const { installAutomation } = require('./automation-host.cjs');
const { localPlayerProof } = require('./player-proof.js');
const nonce = '01234567-0123-4123-8123-012345678901';
const candidates = Array.from({ length: 5 }, (_, index) => ({ id: `1_${index + 1}` }));
const noop = async () => {};

test('control schema admits run/stop only and rejects scripts, URLs, credentials and track arguments', () => {
  assert.deepEqual(parseControl({ command: 'run', nonce }), { command: 'run', nonce });
  for (const value of [{ command: 'eval', nonce }, { command: 'run', nonce, script: 'synthetic' },
    { command: 'run', nonce, url: 'https://synthetic.test' }, { command: 'run', nonce, cookies: 'synthetic' },
    { command: 'run', nonce, trackId: '1_2' }, { command: 'run', nonce: '../private' }]) {
    assert.equal(parseControl(value), null);
  }
});
test('raw failure details become fixed categories without URL leakage', () => {
  assert.equal(failureCategory(new Error('HTTP error https://synthetic.test?private=value')), 'operation_failed');
  assert.equal(failureCategory(new Error('VK did not expose a supported audio source.')), 'audio_source_unavailable');
  assert.equal(failureCategory(new Error('Full offline audio decoding failed; cache was not marked complete.')), 'audio_full_decode_failed');
  assert.equal(failureCategory(new Error('Saved response is not a readable audio file.')), 'audio_container_unreadable');
  assert.equal(failureCategory(new Error('Retrieved audio is shorter than VK metadata.')), 'audio_incomplete_or_preview');
});
test('online automation is bounded to three attempts and does not verify failed downloads', async () => {
  let downloads = 0;
  const events = [];
  const result = await onlineProof({ candidates,
    download: async () => { downloads++; throw new Error('VK did not expose audio source.'); },
    verify: async () => { throw new Error('Unexpected verification'); }, player: noop,
    emit: (...event) => events.push(event) });
  assert.equal(downloads, 3);
  assert.equal(result.category, 'audio_source_unavailable');
  assert.equal(events.filter(([name]) => name === 'automated_proof_attempt_failed').length, 3);
});
test('online automation stops immediately when private sign-in is required', async () => {
  let attempts = 0;
  const result = await onlineProof({ candidates, emit: () => {}, player: noop, verify: noop,
    download: async () => { attempts++; throw new Error('Sign-in is required.'); } });
  assert.equal(attempts, 1);
  assert.equal(result.category, 'private_signin_or_music_page_required');
});
test('automation verifies the selected saved file before asking the player to seek', async () => {
  const stages = [];
  const result = await onlineProof({ candidates, emit: () => {},
    download: async (track) => stages.push(['save', track.id]),
    verify: async (track) => stages.push(['decode', track.id]),
    player: async (track) => { stages.push(['play', track.id]); return { passed: true }; } });
  assert.deepEqual(stages, [['save', '1_1'], ['decode', '1_1'], ['play', '1_1']]);
  assert.equal(result.attempts, 1);
});
test('stop request prevents automatic downloads and additional candidates', async () => {
  const result = await onlineProof({ candidates, emit: () => {}, shouldStop: () => true,
    download: async () => { throw new Error('Download after cancellation'); }, verify: noop, player: noop });
  assert.equal(result.category, 'cancelled');
});

class FakeAudio {
  constructor(mode) { this.mode = mode; this.listeners = new Map(); this._time = 0; this.paused = true; }
  addEventListener(name, fn) { if (!this.listeners.has(name)) this.listeners.set(name, new Set()); this.listeners.get(name).add(fn); }
  removeEventListener(name, fn) { this.listeners.get(name)?.delete(fn); }
  emit(name) { for (const fn of [...this.listeners.get(name) || []]) fn(); }
  load() {
    if (!this.src) return;
    queueMicrotask(() => {
      if (this.mode === 'decode') { this.error = {}; this.emit('error'); }
      else { this.duration = 180; this.emit('loadedmetadata'); }
    });
  }
  play() {
    assert.equal(this.muted, true);
    if (this.mode === 'hung') return new Promise(() => {});
    this.paused = false;
    if (this.mode !== 'stuck') setTimeout(() => { this._time += 0.5; this.emit('timeupdate'); }, 0);
    return Promise.resolve();
  }
  pause() { this.paused = true; }
  removeAttribute(name) { assert.equal(name, 'src'); this.src = ''; }
  get currentTime() { return this._time; }
  set currentTime(value) {
    this.seeking = true;
    if (this.mode === 'seek') return;
    this._time = value;
    queueMicrotask(() => { this.seeking = false; this.emit('seeked'); });
  }
}
const player = (mode) => localPlayerProof('proof-audio://local/1_2', { timeout: 25, createAudio: () => new FakeAudio(mode) });
test('local player automation checks advancing time, seeking and advancing after the seek', async () => {
  const result = await player('good');
  assert.equal(result.passed, true);
  assert.equal(result.seeked, true);
  assert.ok(result.position > 10);
});
test('player automation rejects remote or arbitrary local sources before creating media', async () => {
  const result = await localPlayerProof('https://synthetic.test/song.mp3', {
    createAudio: () => { throw new Error('Remote media created'); } });
  assert.equal(result.passed, false);
});
test('player diagnostics retain only a stage, fixed rejection category and media error code', async () => {
  const audio = new FakeAudio('good');
  audio.play = async () => {
    const error = new Error('The play() request was interrupted by a call to pause(). https://private.invalid/signed');
    error.name = 'AbortError';
    throw error;
  };
  const result = await localPlayerProof('proof-audio://local/1_2', { createAudio: () => audio });
  assert.deepEqual(result, { passed: false, category: 'player_decode_failed', stage: 'start',
    mediaError: 0, interruption: 'pause', rejection: 'AbortError' });
  assert.equal(JSON.stringify(result).includes('private.invalid'), false);
});
test('decode failure, stalled playback, stalled seeking and hung play have distinct sanitized outcomes', async () => {
  assert.equal((await player('decode')).category, 'player_decode_failed');
  assert.equal((await player('stuck')).category, 'player_did_not_advance');
  assert.equal((await player('seek')).category, 'player_seek_failed');
  assert.equal((await player('hung')).category, 'player_timeout');
});

function fixture(offline, files = new Map()) {
  const events = [], launches = [], calls = [];
  const host = { enabled: true, offline, dataDir: '/synthetic-ownsemble', args: ['main.cjs', '--automated-proof'],
    app: { relaunch: (options) => launches.push(options), exit: () => {} },
    readJSON: (file, fallback) => files.get(file) ?? fallback,
    writeJSON: (file, value) => files.set(file, value),
    record: (...event) => events.push(event), update: () => {}, isBusy: () => false,
    operation: (action) => action(), prepareMusic: async () => calls.push('prepare'),
    candidates: () => candidates,
    download: async (track) => calls.push(`download:${track.id}`),
    verify: async (id) => calls.push(`verify:${id}`),
    player: async (id) => { calls.push(`player:${id}`); return { passed: true }; } };
  const fsAPI = { existsSync: (file) => files.has(file), statSync: () => ({ size: 100 }), watchFile: () => {}, unwatchFile: () => {} };
  return { host, fsAPI, files, events, launches, calls };
}
test('host automatically restarts offline and resumes only local verify/player checks', async () => {
  const online = fixture(false);
  const runner = installAutomation(online.host, online.fsAPI);
  try { await runner.tick(); } finally { runner.dispose(); }
  assert.equal(online.launches.length, 1);
  assert.ok(online.launches[0].args.includes('--offline'));
  const offline = fixture(true, online.files);
  offline.host.prepareMusic = async () => { throw new Error('VK accessed offline'); };
  offline.host.download = async () => { throw new Error('Download attempted offline'); };
  const resumed = installAutomation(offline.host, offline.fsAPI);
  try { await resumed.tick(); } finally { resumed.dispose(); }
  assert.deepEqual(offline.calls, ['verify:1_1', 'player:1_1']);
  const status = offline.files.get(path.join(offline.host.dataDir, 'automation-status.json'));
  assert.equal(status.technicalChecksPassed, true);
  assert.equal(status.audibleConfirmed, false);
  assert.equal(status.identityConfirmed, false);
  assert.equal(JSON.stringify(status).includes('1_1'), false);
});
test('preexisting stop command prevents startup execution and is consumed once', async () => {
  const data = fixture(false);
  data.files.set(path.join(data.host.dataDir, 'automation-control.json'), { command: 'stop', nonce });
  const runner = installAutomation(data.host, data.fsAPI);
  try { await runner.tick(); await runner.tick(); } finally { runner.dispose(); }
  assert.equal(data.calls.length, 0);
  assert.equal(data.files.get(path.join(data.host.dataDir, 'automation-status.json')).state, 'stopped');
});
test('run command from finished offline mode relaunches online without touching VK in that process', async () => {
  const data = fixture(true);
  data.files.set(path.join(data.host.dataDir, 'automation-resume.json'), { phase: 'finished' });
  data.files.set(path.join(data.host.dataDir, 'automation-control.json'), { command: 'run', nonce });
  const runner = installAutomation(data.host, data.fsAPI);
  try { await runner.tick(); } finally { runner.dispose(); }
  assert.equal(data.calls.length, 0);
  assert.equal(data.launches.length, 1);
  assert.equal(data.launches[0].args.includes('--offline'), false);
});
