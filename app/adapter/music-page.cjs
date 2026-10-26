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
  const unavailableIds = new Set();
  const availabilityHints = new Map();
  const restrictionReasons = new Map();
  const musicAgeBuckets = new Map();
  const enrichment = new Map();
  const enrichmentShape = {};
  const enrich = (audio, id) => {
    if (options.includeMetadata !== true || !audio || Array.isArray(audio)) return;
    const out = {};
    const text = value => typeof value === 'string' ? value.replace(/<[^>]*>/g,'').trim().slice(0,1000) : '';
    const album = audio.album;
    if (text(album?.title)) out.album = text(album.title);
    if (text(audio.subtitle)) out.subtitle = text(audio.subtitle);
    const artists = [...(Array.isArray(audio.main_artists) ? audio.main_artists : []),
      ...(Array.isArray(audio.featured_artists) ? audio.featured_artists : [])]
      .slice(0,20).map(a=>text(a?.name)).filter(Boolean);
    if (artists.length) out.artists = artists;
    if (typeof audio.is_explicit === 'boolean') out.explicit = audio.is_explicit;
    if (Number.isSafeInteger(audio.date) && audio.date>0 && audio.date<=Date.now()/1000) out.uploadedAt=audio.date;
    if (Number.isInteger(audio.release_year) && audio.release_year>=1900 && audio.release_year<=new Date().getUTCFullYear()+1) out.releaseYear=audio.release_year;
    if (typeof audio.has_lyrics==='boolean') out.lyricsAvailable=audio.has_lyrics;
    if (Number.isSafeInteger(audio.lyrics_id) && audio.lyrics_id>0) out.lyricsId=audio.lyrics_id;
    const thumb = album?.thumb ?? audio.thumb;
    const shape=enrichmentShape;
    const note=(key,value)=>{if(value) shape[key]=(shape[key]||0)+1;};
    note('albumThumb',!!album?.thumb);note('audioThumb',!!audio.thumb);
    note('lyricsInfo',!!audio.lyrics_info);note('lyricsInfoText',typeof audio.lyrics_info?.text==='string');
    for (const name of ['photo_34','photo_68','photo_135','photo_270','photo_300','photo_600','photo_1200']) note(name,typeof thumb?.[name]==='string');
    for (const size of ['photo_300','photo_270','photo_600','photo_135','photo_68','photo_1200','photo_34']) {
      const value=thumb?.[size];
      if (typeof value!=='string' || value.length>4096) continue;
      try {
        const uri=new URL(value);
        note('imageHTTPS',uri.protocol==='https:');note('imageUserapi',uri.hostname.endsWith('.userapi.com') || uri.hostname==='userapi.com');
        note('imageVkuseraudio',uri.hostname.split('.').some(p=>p.startsWith('vkuseraudio')));
        note('imageVkuserphoto',uri.hostname==='vkuserphoto.ru' || uri.hostname.endsWith('.vkuserphoto.ru'));
        if(uri.protocol==='https:' && !uri.username && !uri.password && !uri.port &&
          ['userapi.com','vkuserphoto.ru','vk-cdn.net','vk-cdn.me'].some(host=>uri.hostname===host || uri.hostname.endsWith('.'+host))) {
          out.artworkURL=uri.href; break;
        }
      } catch {}
    }
    const rawLyrics=audio.lyrics;
    const lyricsText=typeof rawLyrics==='string' ? rawLyrics : rawLyrics?.text;
    if (typeof lyricsText==='string' && lyricsText.trim() && lyricsText.length<=100000) out.lyricsAvailable=true;
    if (options.includeLyrics===true && options.targetId===id && typeof lyricsText==='string' && lyricsText.trim() && lyricsText.length<=100000) {
      const lines=Array.isArray(rawLyrics?.lines) ? rawLyrics.lines.slice(0,2000).filter(line=>
        Number.isSafeInteger(line?.time_ms) && line.time_ms>=0 && line.time_ms<=86400000 &&
        typeof line.text==='string' && line.text.length<=2000).map(line=>({time_ms:line.time_ms,text:text(line.text)})) : [];
      out.lyrics={text:lyricsText.replace(/<[^>]*>/g,''),lines:lines.sort((a,b)=>a.time_ms-b.time_ms)};
    }
    enrichment.set(id,out);
  };
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
      enrich(value,id);
      if (seen.has(id)) { diagnostics.duplicateRows++; continue; }
      raw.push(data); seen.add(id);
      if (raw.length === limit) break;
    } catch { diagnostics.invalidRows++; }
  }
  function readModernMusicRows() {
    const rows = [...document.querySelectorAll('[data-audio-id]')];
    const diagnostics = { modernRows: rows.length, modernPropsFound: 0,
      modernAudioMatched: 0, modernURLsFound: 0, modernDOMMetadata: 0, modernInvalidRows: 0,
      musicUnavailable: 0, musicReloadHashes: 0, musicObjects: 0, musicArrays: 0, musicId: 0, musicOwner: 0, musicFullId: 0, musicURL: 0 };
    const tracks = [];
    const seen = new Set();
    const numeric = (value) => typeof value === 'number' ? value :
      typeof value === 'string' && /^-?\d{1,16}$/.test(value) ? Number(value) : NaN;
    const project = (audio, id) => {
      if (!audio || typeof audio !== 'object') return null;
      const array = Array.isArray(audio);
      diagnostics.musicObjects++;
      if (array) diagnostics.musicArrays++;
      if (audio.id != null) diagnostics.musicId++;
      if (audio.owner_id != null || audio.ownerId != null) diagnostics.musicOwner++;
      if (audio.fullId != null) diagnostics.musicFullId++;
      if (typeof audio.url === 'string' && audio.url) diagnostics.musicURL++;
      const aid = numeric(array ? audio[0] : audio.id);
      const owner = numeric(array ? audio[1] : audio.owner_id ?? audio.ownerId);
      if (!Number.isSafeInteger(aid) || !Number.isSafeInteger(owner) || `${owner}_${aid}` !== id) return null;
      enrich(audio,id);
      if (!array) {
        const date=typeof audio.date==='number' ? audio.date : NaN;
        if (Number.isFinite(date) && date>0 && date<=Date.now()/1000) {
          const year=new Date(date*1000).getUTCFullYear();
          musicAgeBuckets.set(id,year<2010?'before2010':year<2015?'2010to2014':year<2020?'2015to2019':'2020plus');
        }
        const hints = {availableFalse:audio.is_available===false,deleted:audio.is_deleted===true,blocked:audio.is_blocked===true,unavailable:audio.is_unavailable===true,restricted:audio.content_restricted===1};
        availabilityHints.set(id,hints);
        if (hints.restricted) {
          diagnostics.musicUnavailable++; unavailableIds.add(id);
          // Only a named music restriction message; never return its text.
          const message=typeof audio.content_restricted_message==='string' ? audio.content_restricted_message.slice(0,2000) : '';
          const reason=/copyright|rights holder|правооблад/i.test(message) ? 'copyright' :
            /country|region|territor|стран|регион|территор/i.test(message) ? 'region' :
            /subscription|premium|подписк/i.test(message) ? 'subscription' :
            /\bage\b|18\+|возраст/i.test(message) ? 'age' : 'unknown';
          restrictionReasons.set(id,reason);
        }
      }
      if (!array && typeof audio.actionHash === 'string' && typeof audio.urlHash === 'string') diagnostics.musicReloadHashes++;
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
        const music = props[name];
        // Modern music components wrap their API audio in a named entity/data
        // field. Never inspect stores, hooks, context or unrelated properties.
        for (const audio of [music, music?.entity?.apiAudio, music?.data?.apiAudio]) {
          const result = project(audio, id);
          if (result) return result;
        }
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
        if(options.includeMetadata===true) {
          for(const button of row.querySelectorAll?.('button, [role="button"]') || []) {
            const label=String(button.getAttribute?.('aria-label') || button.getAttribute?.('title') || '');
            const marker=String(button.getAttribute?.('data-testid') || '');
            for(const [key,matched] of [['lyricsButtons',/lyrics|текст песни|показать текст/i.test(label+' '+marker)],['menuButtons',/MusicAudio_MenuButton|more|ещ[её]|действия/i.test(label+' '+marker)]]) {
              if(matched) enrichmentShape[key]=(enrichmentShape[key]||0)+1;
            }
          }
        }
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
        for (let depth = 0; !data && fiber && depth < 12; depth++, fiber = fiber.return) {
          if (depth > 0 && fiber.stateNode?.nodeType === 1 &&
              (fiber.stateNode === document.body || fiber.stateNode.tagName === 'HTML' ||
              fiber.stateNode !== boundary && !boundary.contains(fiber.stateNode) &&
              !fiber.stateNode.contains?.(row))) break;
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
  if(options.includeMetadata===true) diagnostics.metadataShape=enrichmentShape;
  if (!raw.length) return { diagnostics, structure: inspectDOM(),
    error: 'Music format is unsupported. A sanitized component report has been saved for adapter diagnosis.' };
  const resolved = new Map();
  const reloadReference = data => {
    const hashes=String(data[13] || '').split('/');
    const key=hashes[2] && hashes[5] ? 'r1_'+hashes[2]+'_'+hashes[5] : '';
    return typeof key==='string' && /^[A-Za-z0-9_-]{1,256}$/.test(key) ? key : '';
  };
  diagnostics.reloadReferences=raw.filter(data=>String(data[13] || '').split('/')[5]).length;
  let resolutionFailed = false;
  diagnostics.targetReloadAttempted = 0;
  diagnostics.targetReloadMatched = 0;
  diagnostics.targetReloadURLFound = 0;
  if (options.resolveTarget === true && typeof options.targetId === 'string') {
    const original = raw.find(data => `${data[1]}_${data[0]}` === options.targetId);
    if (original && !String(original[2] || '').trim()) {
      diagnostics.targetReloadAttempted = 1;
      const key = reloadReference(original).replace(/^r1_/,'');
      const identity = `${original[1]}_${original[0]}${key ? '_' + key : ''}`;
      try {
        const response = await fetch('/al_audio.php', {
          method: 'POST', credentials: 'same-origin', redirect: 'error',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest' },
          body: new URLSearchParams({al:'1',act:'reload_audio',ids:identity}),
          signal: AbortSignal.timeout(10000),
        });
        if (!response.ok || !/^(?:application\/json|text\/plain)(?:;|$)/i.test(response.headers?.get('content-type') || '') ||
            document.querySelector('input[type="password"], input[autocomplete="one-time-code"], input[autocomplete="username"], form[action*="login"], form[action*="auth"]')) throw new Error('Music source refresh unavailable.');
        const text = await response.text();
        if (text.length > 2 * 1024 * 1024) throw new Error('Music response budget.');
        const reply = JSON.parse(text.replace(/^\s*<!--/, ''));
        // Reject a failed legacy envelope before an ID-matching nested row can supply audio.
        if (![0, '0'].includes(reply?.payload?.[0])) throw new Error('Music source status unsupported.');
        const music = reply?.payload?.[1]?.[0];
        if (Array.isArray(music) && music.length <= 100) {
          for (const candidate of music) {
            const data = normalize(candidate);
            if (!data || `${data[1]}_${data[0]}` !== options.targetId) continue;
            diagnostics.targetReloadMatched++;
            if (typeof data[2] === 'string' && data[2].trim()) {
              const refreshed = original.slice();refreshed[2] = data[2];
              resolved.set(options.targetId, refreshed);
              diagnostics.targetReloadURLFound++;
            }
          }
        }
      } catch { resolutionFailed = true; }
    }
  }

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
      // Preserve known data-only replies, but never bypass a failed payload through another slot.
      if (body.payload !== undefined && ![0, '0'].includes(body.payload?.[0])) throw new Error('Music source status unsupported.');
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
    ...(options.includeReferences === true ? { musicReferences: raw.filter(data => reloadReference(data)).map(data => ({id:`${data[1]}_${data[0]}`,musicKey:reloadReference(data)})) } : {}),
    userId: Number(window.vk && window.vk.id) || 0,
    userAgent: navigator.userAgent,
    resolutionFailed,
    diagnostics,
    structure: raw.every((data) => !data[2]) ? inspectDOM() : null,
    tracks: raw.map((original) => {
      const data = resolved.get(`${original[1]}_${original[0]}`) || original;
      return { id: `${data[1]}_${data[0]}`, ...(options.includeMetadata === true ? {enrichment:enrichment.get(`${data[1]}_${data[0]}`) || {}} : {}), ...(options.includeAvailability === true ? {musicAgeBucket:musicAgeBuckets.get(`${data[1]}_${data[0]}`) || 'unknown',unavailable:unavailableIds.has(`${data[1]}_${data[0]}`),restrictionReason:restrictionReasons.get(`${data[1]}_${data[0]}`) || null,availabilityHints:availabilityHints.get(`${data[1]}_${data[0]}`) || {}} : {}), title: plainText(data[3]), artist: plainText(data[4]),
        duration: Number(data[5]) || 0, url: typeof data[2] === 'string' ? data[2] : '' };
    }),
  };
}

module.exports = { readMusicPage };
