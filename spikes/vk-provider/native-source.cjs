'use strict';
const { mediaURL } = require('./music-policy.cjs');

function audioCandidate(value) {
  try {
    const url = mediaURL(value);
    return /\.(?:mp3|m4a|m3u8)(?:$)/i.test(new URL(url).pathname) ? url : null;
  } catch { return null; }
}

function selectNativeSource(candidates) {
  const urls = [...new Set(candidates.map(audioCandidate).filter(Boolean))];
  if (!urls.length) throw new Error('VK did not expose a supported audio source for the selected track.');
  if (urls.length !== 1) throw new Error('VK produced multiple audio sources; association with the selected track is ambiguous.');
  return urls[0];
}

module.exports = { audioCandidate, selectNativeSource };
