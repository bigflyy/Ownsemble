"use strict";

// Runs inside the VK window only after the user clicks Import my music.
// It returns music fields, never login values or session cookies.
async function readMusicPage(inspectDOM = () => null, options = {}) {
  const limit = 50000;
  const allowed = ['vk.ru', 'vk.com'];
  if (location.protocol !== 'https:' || !allowed.includes(location.hostname) ||
      !/^\/(?:audios\d*|audio|music)(?:\/|$)/.test(location.pathname) ||
      document.querySelector('input[type="password"], input[autocomplete="one-time-code"], input[autocomplete="username"], form[action*="login"], form[action*="auth"]')) {
    return { error: 'Open the VK music page after completing sign-in. Music import does not run on login forms.' };
  }
  // data-audio is the music boundary; presentation classes vary by VK layout.
  const rows = [...document.querySelectorAll('[data-audio]')];
  const diagnostics = { audioDataElements: rows.length, arrayRows: 0, objectRows: 0,
    invalidRows: 0, duplicateRows: 0, validRows: 0,
    legacyRows: document.querySelectorAll('.audio_row, .audio_item').length,
    idOnlyRows: document.querySelectorAll('[data-full-id]:not([data-audio])').length };
  const raw = [];
  const seen = new Set();
  const normalize = (value) => {
    if (Array.isArray(value)) return value;
    if (!value || typeof value !== 'object') return null;
    // Project only known music fields. Do not traverse page state or other keys.
    const result = [value.id, value.owner_id ?? value.ownerId, value.url ?? '',
      value.title, value.artist ?? value.performer, value.duration];
    result[13] = typeof value.actionHash === 'string' && typeof value.urlHash === 'string'
      ? `//${value.actionHash}///${value.urlHash}` : '';
    return result;
  };
  for (const row of rows) {
    try {
      const encoded = row.getAttribute('data-audio');
      if (typeof encoded !== 'string' || encoded.length > 65536) throw new Error('Invalid row.');
      const value = JSON.parse(encoded);
      const data = normalize(value);
      if (!data || !Number.isSafeInteger(data[0]) || data[0] <= 0 ||
          !Number.isSafeInteger(data[1]) || data[1] === 0 || typeof data[3] !== 'string' ||
          typeof data[4] !== 'string' || !Number.isFinite(data[5]) || data[5] < 0 ||
          data[5] > 86400 || typeof data[2] !== 'string') throw new Error('Invalid row.');
      if (Array.isArray(value)) diagnostics.arrayRows++;
      else diagnostics.objectRows++;
      const id = `${data[1]}_${data[0]}`;
      if (options.targetId && options.targetId !== id) continue;
      if (seen.has(id)) { diagnostics.duplicateRows++; continue; }
      raw.push(data); seen.add(id);
      if (raw.length === limit) break;
    } catch { diagnostics.invalidRows++; }
  }
  function readModernMusicRows() {
    const rows = [...document.querySelectorAll('[data-audio-id]')];
    const diagnostics = { modernRows: rows.length, modernPropsFound: 0,
      modernAudioMatched: 0, modernURLsFound: 0, modernDOMMetadata: 0, modernInvalidRows: 0 };
    const tracks = [];
    const seen = new Set();
    const numeric = (value) => typeof value === 'number' ? value :
      typeof value === 'string' && /^-?\d{1,16}$/.test(value) ? Number(value) : NaN;
    const project = (audio, id) => {
      if (!audio || typeof audio !== 'object') return null;
      const array = Array.isArray(audio);
      const aid = numeric(array ? audio[0] : audio.id);
      const owner = numeric(array ? audio[1] : audio.owner_id ?? audio.ownerId);
      if (!Number.isSafeInteger(aid) || !Number.isSafeInteger(owner) || `${owner}_${aid}` !== id) return null;
      const result = [aid, owner, array ? audio[2] : audio.url,
        array ? audio[3] : audio.title, array ? audio[4] : audio.artist ?? audio.performer,
        array ? audio[5] : audio.duration];
      if (typeof result[4] !== 'string' && Array.isArray(audio.artists)) {
        result[4] = audio.artists.slice(0, 10).map((artist) =>
          typeof artist?.name === 'string' ? artist.name : '').filter(Boolean).join(', ');
      }
      result[2] = typeof result[2] === 'string' ? result[2] : '';
      result[13] = array && typeof audio[13] === 'string' ? audio[13] :
        typeof audio.actionHash === 'string' && typeof audio.urlHash === 'string'
          ? `//${audio.actionHash}///${audio.urlHash}` : '';
      return result;
    };
    const fromProps = (props, id) => {
      if (!props || typeof props !== 'object') return null;
      // These are explicit music props, not arbitrary recursive object traversal.
      for (const name of ['audio', 'track', 'audioData', 'audioItem', 'audioTrack', 'item']) {
        const result = project(props[name], id);
        if (result) return result;
      }
      return null;
    };
    const text = (row, selector) => {
      const element = row.querySelector(selector);
      return element && !['INPUT', 'TEXTAREA', 'SELECT'].includes(element.tagName)
        ? String(element.textContent || '').trim().slice(0, 1000) : '';
    };
    for (const row of rows) {
      if (tracks.length >= limit) break;
      try {
        const id = row.getAttribute('data-audio-id');
        if (typeof id !== 'string' || !/^-?\d+_\d+$/.test(id)) { diagnostics.modernInvalidRows++; continue; }
        if (options.targetId && options.targetId !== id) continue;
        if (seen.has(id)) continue;
        seen.add(id);
        let data = null;
        const propsKey = Object.keys(row).find((key) => /^__react(?:Props|EventHandlers)\$/.test(key));
        if (propsKey) { diagnostics.modernPropsFound++; data = fromProps(row[propsKey], id); }
        const fiberKey = Object.keys(row).find((key) => /^__react(?:Fiber|InternalInstance)\$/.test(key));
        let fiber = fiberKey ? row[fiberKey] : null;
        const boundary = row.closest?.('[class*="AudioCellCompositeRowsLayout"]') || row;
        // Read only named music props on nearby component ancestors. Do not follow
        // child/sibling links, memoizedState, context, or application/store props.
        for (let depth = 0; !data && fiber && depth < 8; depth++, fiber = fiber.return) {
          if (depth > 0 && fiber.stateNode?.nodeType === 1 &&
              fiber.stateNode !== boundary && !boundary.contains(fiber.stateNode)) break;
          data = fromProps(fiber.memoizedProps, id);
          if (data) break;
        }
        if (data) diagnostics.modernAudioMatched++;
        const title = text(row, '[data-testid="MusicTrackRow_Title"]');
        const artist = text(row, '[data-testid="MusicTrackRow_Authors"]');
        const duration = text(row, '[data-testid="MusicTrackRow_Duration"]');
        const parts = /^\d{1,3}:\d{2}(?::\d{2})?$/.test(duration) ? duration.split(':').map(Number) : [];
        const seconds = parts.length ? parts.reduce((total, part) => total * 60 + part, 0) : null;
        if (!data && title && artist && seconds !== null) {
          const [owner, aid] = id.split('_').map(numeric);
          data = [aid, owner, '', title, artist, seconds];
          diagnostics.modernDOMMetadata++;
        }
        if (data) {
          if (typeof data[3] !== 'string' || !data[3]) data[3] = title;
          if (typeof data[4] !== 'string' || !data[4]) data[4] = artist;
          if (!Number.isFinite(data[5]) && seconds !== null) data[5] = seconds;
          if (data[2]) diagnostics.modernURLsFound++;
          tracks.push(data);
        } else diagnostics.modernInvalidRows++;
      } catch { diagnostics.modernInvalidRows++; }
    }
    return { tracks, diagnostics };
  }
  if (raw.length < limit) {
    const modern = readModernMusicRows();
    Object.assign(diagnostics, modern.diagnostics);
    for (const data of modern.tracks) {
      const id = `${data[1]}_${data[0]}`;
      if (options.targetId && options.targetId !== id) continue;
      if (seen.has(id)) continue;
      if (!Number.isSafeInteger(data[0]) || data[0] <= 0 || !Number.isSafeInteger(data[1]) ||
          !data[1] || typeof data[3] !== 'string' || typeof data[4] !== 'string' ||
          !Number.isFinite(data[5]) || data[5] < 0 || data[5] > 86400 || typeof data[2] !== 'string') {
        diagnostics.invalidRows++; continue;
      }
      raw.push(data); seen.add(id);
      if (raw.length === limit) break;
    }
  }
  diagnostics.validRows = raw.length;
  if (!raw.length) return { diagnostics, structure: inspectDOM(),
    error: 'Music format is unsupported. A sanitized component report has been saved for adapter diagnosis.' };
  const resolved = new Map();
  let resolutionFailed = false;
  // Refresh only audio links for the visible rows. The browser attaches its own
  // same-origin session internally; no cookie-reading API is used.
  for (let offset = 0; !options.metadataOnly && offset < raw.length; offset += 10) {
    const group = raw.slice(offset, offset + 10);
    const ids = group.flatMap((data) => {
      const hashes = String(data[13] || '').split('/');
      return hashes[2] && hashes[5] ? [`${data[1]}_${data[0]}_${hashes[2]}_${hashes[5]}`] : [];
    });
    if (!ids.length) continue;
    try {
      const response = await fetch('/al_audio.php', {
        method: 'POST', credentials: 'same-origin', redirect: 'error',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest' },
        body: new URLSearchParams({ al: '1', act: 'reload_audio', ids: ids.join(',') }),
        signal: AbortSignal.timeout(20000),
      });
      if (!response.ok) throw new Error('Music response unavailable.');
      const body = JSON.parse((await response.text()).replace(/^\s*<!--/, ''));
      const visit = (value, depth = 0) => {
        if (depth > 7 || !Array.isArray(value)) return;
        if (value.length >= 6 && Number.isSafeInteger(value[0]) && Number.isSafeInteger(value[1]) &&
            typeof value[2] === 'string' && typeof value[3] === 'string') {
          resolved.set(`${value[1]}_${value[0]}`, value); return;
        }
        value.forEach((child) => visit(child, depth + 1));
      };
      visit(body.payload);
      visit(body.data);
    } catch { resolutionFailed = true; }
    if (offset + 10 < raw.length) await new Promise((resolve) => setTimeout(resolve, 1700));
  }
  const plainText = (value) => {
    const textarea = document.createElement('textarea');
    textarea.innerHTML = String(value || '').replace(/<[^>]*>/g, '');
    return textarea.value;
  };
  return {
    userId: Number(window.vk && window.vk.id) || 0,
    userAgent: navigator.userAgent,
    resolutionFailed,
    diagnostics,
    structure: raw.every((data) => !data[2]) ? inspectDOM() : null,
    tracks: raw.map((original) => {
      const data = resolved.get(`${original[1]}_${original[0]}`) || original;
      return { id: `${data[1]}_${data[0]}`, title: plainText(data[3]), artist: plainText(data[4]),
        duration: Number(data[5]) || 0, url: typeof data[2] === 'string' ? data[2] : '' };
    }),
  };
}

module.exports = { readMusicPage };
