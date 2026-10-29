'use strict';

// The same muted browser-media test runs online and after the network-blocked
// restart. Only a local proof-audio URL may enter this function.
async function localPlayerProof(source, { createAudio = () => new Audio(), timeout = 12000 } = {}) {
  if (typeof source !== 'string' || !/^proof-audio:\/\/local\/-?\d+_\d+$/.test(source)) {
    return { passed: false, category: 'player_decode_failed' };
  }
  const audio = createAudio();
  let stage = 'metadata';
  const startPlayback = async () => {
    let timer;
    try {
      await Promise.race([audio.play(), new Promise((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error('player_timeout')), timeout);
      })]);
    } finally { clearTimeout(timer); }
  };
  const waitFor = (predicate, category) => new Promise((resolve, reject) => {
    const events = ['loadedmetadata', 'timeupdate', 'seeked', 'canplay', 'error'];
    const clean = () => { clearTimeout(timer); for (const event of events) audio.removeEventListener(event, changed); };
    const changed = () => {
      if (audio.error) { clean(); reject(new Error('player_decode_failed')); }
      else if (predicate()) { clean(); resolve(); }
    };
    const timer = setTimeout(() => { clean(); reject(new Error(category)); }, timeout);
    for (const event of events) audio.addEventListener(event, changed);
    changed();
  });
  try {
    audio.muted = true;
    audio.preload = 'auto';
    audio.src = source;
    audio.load();
    await waitFor(() => Number.isFinite(audio.duration) && audio.duration > 0, 'player_timeout');
    stage = 'start';
    await startPlayback();
    stage = 'advance';
    await waitFor(() => audio.currentTime >= Math.min(0.25, audio.duration / 4), 'player_did_not_advance');
    audio.pause();
    stage = 'seek';
    const target = Math.min(10, audio.duration / 2);
    audio.currentTime = target;
    await waitFor(() => !audio.seeking && Math.abs(audio.currentTime - target) < 0.5, 'player_seek_failed');
    stage = 'resume';
    await startPlayback();
    await waitFor(() => audio.currentTime > target + Math.min(0.2, audio.duration / 8), 'player_did_not_advance');
    return { passed: true, metadata: true, advanced: true, seeked: true,
      position: audio.currentTime, duration: audio.duration };
  } catch (error) {
    const category = ['player_timeout', 'player_decode_failed', 'player_did_not_advance', 'player_seek_failed']
      .includes(error.message) ? error.message : 'player_decode_failed';
    return { passed: false, category, stage,
      mediaError: [1, 2, 3, 4].includes(audio.error?.code) ? audio.error.code : 0,
      interruption: /background|save power/i.test(error.message) ? 'background' :
        /pause\(\)|call to pause/i.test(error.message) ? 'pause' :
        /new load|load request/i.test(error.message) ? 'load' :
          /removed from the document/i.test(error.message) ? 'removed' :
            /end of playback/i.test(error.message) ? 'ended' :
              /suspended|idle/i.test(error.message) ? 'suspended' :
                /requested by the browser/i.test(error.message) ? 'browser' :
                  /requested by the user/i.test(error.message) ? 'user' :
                    /media paused/i.test(error.message) ? 'paused' : 'other',
      rejection: ['NotAllowedError', 'NotSupportedError', 'AbortError'].includes(error.name) ? error.name : 'other' };
  } finally {
    audio.pause(); audio.removeAttribute('src'); audio.load();
  }
}

if (typeof module !== 'undefined') module.exports = { localPlayerProof };
