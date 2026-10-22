'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { parseControl, failureCategory, onlineProof } = require('./automation.cjs');

function installAutomation(host, fsAPI = fs) {
  if (!host.enabled) return { get running() { return false; } };
  const stateFile = path.join(host.dataDir, 'automation-resume.json');
  const statusFile = path.join(host.dataDir, 'automation-status.json');
  const controlFile = path.join(host.dataDir, 'automation-control.json');
  const consumedFile = path.join(host.dataDir, 'automation-consumed.json');
  let lastNonce = host.readJSON(consumedFile, {}).nonce;
  let running = false;
  let queued = !host.offline || host.readJSON(stateFile, {}).phase === 'offline_pending';
  let stopped = false;
  let restartPending = false;
  let changedTimer;
  const status = (state, stage, details = {}) => {
    host.writeJSON(statusFile, { state, stage, offline: host.offline,
      updatedAt: new Date().toISOString(), audibleConfirmed: false, identityConfirmed: false, ...details });
    host.update(`Automated test: ${stage.replaceAll('_', ' ')} (${state}).`);
  };
  const emit = (event, details) => {
    host.record(event, details);
    if (details.stage) status('running', details.stage, details.attempt ? { attempt: details.attempt } : {});
  };
  const restart = (offline, resume) => {
    host.writeJSON(stateFile, resume);
    const args = host.args.filter((arg) => !['--offline', '--automated-proof'].includes(arg));
    args.push('--automated-proof');
    if (offline) args.push('--offline');
    host.app.relaunch({ args });
    host.app.exit(0);
  };
  const cancelled = () => stopped || restartPending;
  async function execute() {
    try {
      if (host.offline) {
        const resume = host.readJSON(stateFile, {});
        if (resume.phase !== 'offline_pending') {
          restart(false, { phase: 'online_pending' });
          return;
        }
        status('running', 'offline_decode');
        await host.verify(resume.trackId);
        if (cancelled()) throw new Error('cancelled');
        status('running', 'player_offline');
        const result = await host.player(resume.trackId);
        if (!result.passed) throw new Error(result.category || 'player_failed');
        host.writeJSON(stateFile, { phase: 'finished' });
        host.record('automated_proof_finished', { technicalChecksPassed: true,
          onlinePlayerPassed: true, offlinePlayerPassed: true,
          audibleConfirmed: false, identityConfirmed: false });
        status('passed', 'technical_checks_finished', { technicalChecksPassed: true });
        return;
      }
      status('running', 'waiting_for_music');
      await host.prepareMusic(cancelled);
      if (cancelled()) throw new Error('cancelled');
      const outcome = await onlineProof({ candidates: host.candidates(),
        download: host.download, verify: (track) => host.verify(track.id),
        player: (track) => host.player(track.id), emit, shouldStop: cancelled });
      if (outcome.failed) {
        host.record('automated_proof_finished', { technicalChecksPassed: false, category: outcome.category });
        status('failed', 'online_checks', { category: outcome.category, technicalChecksPassed: false });
        return;
      }
      if (cancelled()) throw new Error('cancelled');
      status('running', 'offline_restart');
      restart(true, { phase: 'offline_pending', trackId: outcome.track.id });
    } catch (error) {
      const category = failureCategory(error);
      host.record('automated_proof_finished', { technicalChecksPassed: false, category });
      status('failed', 'technical_checks', { category, technicalChecksPassed: false });
    }
  }
  async function pump() {
    if (running || host.isBusy()) return;
    if (restartPending) { restart(false, { phase: 'online_pending' }); return; }
    if (!queued) return;
    queued = false; stopped = false; running = true;
    try { await host.operation(execute); }
    finally { running = false; }
  }
  function control() {
    try {
      if (!fsAPI.existsSync(controlFile) || fsAPI.statSync(controlFile).size > 1024) return;
      const command = parseControl(host.readJSON(controlFile, null));
      if (!command || command.nonce === lastNonce) return;
      lastNonce = command.nonce;
      host.writeJSON(consumedFile, { nonce: lastNonce });
      if (command.command === 'stop') {
        queued = false; stopped = true; restartPending = false;
        status('stopped', 'stop_requested');
      } else {
        queued = true;
        host.record('automated_proof_requested');
      }
    } catch { host.record('automated_control_unavailable'); }
  }
  // A fixed command schema and fixed source list replace a general debug port,
  // arbitrary JavaScript execution, and access to the private browser profile.
  const watchers = [];
  for (const file of ['main.cjs', 'preload.cjs', 'renderer.js', 'index.html', 'player-proof.js',
    'music-page.cjs', 'music-action.cjs', 'music-dom.cjs', 'native-source.cjs',
    'provider.py', 'automation.cjs', 'automation-host.cjs', 'library-sync.cjs', 'music-policy.cjs', 'audio-response.cjs']) {
    const sourcePath = path.join(__dirname, file);
    const changed = (current, previous) => {
      if (current.mtimeMs === previous.mtimeMs && current.size === previous.size) return;
      clearTimeout(changedTimer);
      changedTimer = setTimeout(() => {
        restartPending = true; stopped = true;
        host.record('automated_proof_source_changed');
      }, 2000);
      changedTimer.unref();
    };
    fsAPI.watchFile(sourcePath, { interval: 1000, persistent: false }, changed);
    watchers.push([sourcePath, changed]);
  }
  control();
  const timer = setInterval(() => { control(); pump().catch(() => host.record('automated_runner_failed')); }, 500);
  timer.unref();
  if (queued) status('queued', host.offline ? 'offline_resume' : 'online_start');
  return { get running() { return running; },
    tick: async () => { control(); await pump(); },
    dispose: () => {
      clearInterval(timer); clearTimeout(changedTimer);
      for (const [file, listener] of watchers) fsAPI.unwatchFile(file, listener);
    } };
}

module.exports = { installAutomation };
