const CDN_SUFFIXES = ['vkuseraudio.net', 'vkuseraudio.com', 'useraudio.com', 'userapi.com', 'vk-cdn.net', 'vk-cdn.me'];
function mediaURL(value) {
  if (typeof value !== 'string' || value.length > 16000) throw new Error('Invalid audio link.');
  let url;
  try { url = new URL(value); } catch { throw new Error('Invalid audio link.'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.port ||
      !CDN_SUFFIXES.some((suffix) => url.hostname === suffix || url.hostname.endsWith(`.${suffix}`))) {
    throw new Error('Audio link is outside the allowed VK audio CDNs.');
  }
  return url.href;
}
function exactFields(object, allowed) {
  if (!object || typeof object !== 'object' || Array.isArray(object) ||
      Object.keys(object).some((key) => !allowed.includes(key))) throw new Error('Unexpected import fields.');
}
function validateImport(body) {
  exactFields(body, ['tracks', 'userAgent', 'userId']);
  if (!Array.isArray(body.tracks) || body.tracks.length < 1 || body.tracks.length > 50000) {
    throw new Error('Import must contain 1 to 50000 tracks.');
  }
  if (typeof body.userAgent !== 'string' || body.userAgent.length > 512 || /[\r\n]/.test(body.userAgent)) {
    throw new Error('Invalid browser user agent.');
  }
  if (!Number.isSafeInteger(body.userId) || body.userId < 0) throw new Error('Invalid account identifier.');
  for (const track of body.tracks) {
    exactFields(track, ['id', 'artist', 'title', 'duration', 'url']);
    if (typeof track.id !== 'string' || !/^-?\d+_\d+$/.test(track.id) ||
        typeof track.title !== 'string' || track.title.length > 1000 ||
        typeof track.artist !== 'string' || track.artist.length > 1000 ||
        !Number.isFinite(track.duration) || track.duration < 0 || track.duration > 86400) {
      throw new Error('Invalid track metadata.');
    }
    // Accept only VK's exact encoded-link shape before local decoding.
    if (typeof track.url !== 'string' || track.url.length > 16000) throw new Error('Invalid audio link.');
    if (track.url) {
      let encoded;
      try { encoded = new URL(track.url); } catch { throw new Error('Invalid audio link.'); }
      if (!(encoded.protocol === 'https:' && ['vk.com', 'vk.ru'].includes(encoded.hostname) &&
          !encoded.username && !encoded.password && !encoded.port &&
          encoded.pathname === '/mp3/audio_api_unavailable.mp3')) mediaURL(track.url);
    }
  }
  return body;
}
function isMusicURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && ['vk.ru', 'vk.com'].includes(url.hostname) &&
      !url.username && !url.password && !url.port &&
      /^\/(?:audios\d*|audio|music)(?:\/|$)/.test(url.pathname);
  } catch { return false; }
}
module.exports = { validateImport, mediaURL, isMusicURL };
