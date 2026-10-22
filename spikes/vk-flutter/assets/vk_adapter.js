window.ownsembleMusic = Object.freeze({
read: async (options) => (async function readMusicPage(inspectDOM = () => null, options = {}) {
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
})(function inspectMusicDOM() {
  const selectors = {
    frames: 'iframe', audioElements: 'audio', listItems: '[role="listitem"]',
    audioIds: '[data-audio-id]', trackIds: '[data-track-id]',
    testIds: '[data-testid]', testIdsAlternate: '[data-test-id]',
    busyRegions: '[aria-busy="true"]',
  };
  const counts = {};
  for (const [name, selector] of Object.entries(selectors)) {
    counts[name] = document.querySelectorAll(selector).length;
  }
  counts.elementsExamined = 0;
  counts.openShadowRoots = 0;
  const components = {};
  for (const marker of ['MusicTrackRow_Title', 'MusicTrackRow_Authors', 'MusicTrackRow_Duration']) {
    const count = document.querySelectorAll(`[data-testid="${marker}"]`).length;
    if (count) components[marker] = count;
  }
  for (const row of document.querySelectorAll('[data-audio-id]')) {
    for (const element of row.querySelectorAll('[data-testid]')) {
      const marker = element.getAttribute('data-testid');
      if (typeof marker === 'string' && marker.length <= 64 &&
          /^Music(?:TrackRow|Audio)_[A-Za-z_]+$/.test(marker) && !Object.hasOwn(components, marker) &&
          Object.keys(components).length < 60) components[marker] = 1;
    }
  }
  const visit = (root, depth = 0) => {
    if (depth > 3 || counts.elementsExamined >= 20000) return;
    for (const element of root.querySelectorAll('*')) {
      if (counts.elementsExamined >= 20000) break;
      counts.elementsExamined++;
      if (['INPUT', 'TEXTAREA', 'SELECT', 'SCRIPT', 'STYLE', 'IFRAME'].includes(element.tagName)) continue;
      // Only public music-related CSS component names, stripped of hashes/IDs.
      for (const token of element.classList || []) {
        const component = token.split(/__|--/)[0].replace(/[0-9].*$/, '');
        if (component.length <= 64 && /^[a-zA-Z_-]+$/.test(component) &&
            /audio|music|track|song|catalog/i.test(component)) {
          if (Object.hasOwn(components, component)) components[component]++;
          else if (Object.keys(components).length < 60) components[component] = 1;
        }
      }
      if (element.shadowRoot) {
        counts.openShadowRoots++;
        visit(element.shadowRoot, depth + 1);
      }
    }
  };
  visit(document);
  return { counts, components };
}, {...options, metadataOnly: true, quiet: true}),
action: async function musicPageAction(action, id, options = {}) {
  if (location.protocol !== 'https:' || !['vk.ru', 'vk.com'].includes(location.hostname) ||
      !/^\/(?:audios\d*|audio|music)(?:\/|$)/.test(location.pathname) ||
      document.querySelector('input[type="password"], input[autocomplete="one-time-code"], input[autocomplete="username"], form[action*="login"], form[action*="auth"]')) {
    return { error: 'Sign-in is required; automatic music access is paused.' };
  }
  if (['open-my-music', 'verify-my-music'].includes(action)) {
    const isMyMusic = (element) => /^(?:моя музыка|мои аудиозаписи|my music)(?:\s*\d+)?$/i
      .test(String(element.textContent || '').replace(/\s+/g, ' ').trim());
    const targets = [...document.querySelectorAll('a, button, [role="tab"]')]
      .filter((element) => !element.closest('form, [data-audio-id], [data-audio]') && isMyMusic(element))
      .filter((element) => {
        const href = element.getAttribute('href');
        if (!href) return true;
        try {
          const url = new URL(href, location.href);
          return url.origin === location.origin && /^\/(?:audios\d*|audio|music)(?:\/|$)/.test(url.pathname);
        } catch { return false; }
      });
    const headingMatch = [...document.querySelectorAll('h1, [role="heading"][aria-level="1"]')].some(isMyMusic);
    const selected = targets.filter((element) => element.getAttribute('aria-selected') === 'true' ||
      element.getAttribute('aria-current') === 'page' || [...element.classList]
        .some((name) => /(?:^|[_-])(?:active|selected)(?:$|[_-])/i.test(name)));
    const personalURLMatch = targets.some((element) => {
      const href = element.getAttribute('href');
      if (!href) return false;
      const url = new URL(href, location.href);
      const distinct = /^\/audios\d+$/.test(url.pathname) ||
        ['all', 'my', 'library', 'my_music'].includes(url.searchParams.get('section'));
      return distinct && url.pathname === location.pathname && url.search === location.search;
    });
    const personal = headingMatch || selected.length > 0 || personalURLMatch;
    const counts = { myMusicTargets: targets.length, selectedTargets: selected.length,
      headingMatch: Number(headingMatch), personalURLMatch: Number(personalURLMatch) };
    if (personal || action === 'verify-my-music') return { personal, counts };
    if (!targets.length) return { personal: false, counts, error: 'My music navigation is not ready.' };
    targets[0].click();
    return { navigationAttempted: true, personal: false, counts };
  }
  if (action === 'probe-pagination') {
    const scroller = document.scrollingElement;
    const containers = new Set();
    const rows = [...document.querySelectorAll('[data-audio-id], [data-audio]')];
    for (const row of [rows[0], rows[rows.length - 1]]) {
      let parent = row?.parentElement;
      for (let depth = 0; parent && depth < 12; depth++, parent = parent.parentElement) {
        if (parent.scrollHeight > parent.clientHeight + 1 && parent.clientHeight > 0 &&
            /^(?:auto|scroll)$/.test(getComputedStyle(parent).overflowY)) containers.add(parent);
      }
    }
    return { counts: { documentScrollHeight: Math.round(scroller?.scrollHeight || 0),
      documentClientHeight: Math.round(scroller?.clientHeight || 0),
      documentScrollTop: Math.round(scroller?.scrollTop || 0),
      scrollableMusicAncestors: containers.size, visibleDocument: Number(document.visibilityState === 'visible') } };
  }
  if (action === 'reset') {
    window.scrollTo(0, 0);
    const first = document.querySelector('[data-audio-id], [data-audio]');
    first?.scrollIntoView({ block: 'start' });
    return { ok: true };
  }
  if (action === 'advance' || action === 'retry-pagination') {
    const waitMs = Number.isSafeInteger(options.waitMs) ? Math.min(30000, Math.max(0, options.waitMs)) : 0;
    const rowKey = (row) => row.getAttribute('data-audio-id') || row.getAttribute('data-audio');
    const initialRows = [...document.querySelectorAll('[data-audio-id], [data-audio]')];
    const known = waitMs ? new Set(initialRows.map(rowKey)) : null;
    // Observe only recognized music identifiers and loading/form presence.
    // A changed row identity also detects progress in a virtualized list.
    let observer, timer, finish, interrupted = false;
    const started = Date.now();
    const waiting = waitMs ? new Promise((resolve) => {
      let settled = false;
      finish = (result) => {
        if (settled) return;
        settled = true;
        observer?.disconnect(); clearTimeout(timer);
        resolve({ ...result, waitedMs: Date.now() - started });
      };
      const changed = () => {
        if (location.protocol !== 'https:' || !['vk.ru', 'vk.com'].includes(location.hostname) ||
            !/^\/(?:audios\d*|audio|music)(?:\/|$)/.test(location.pathname) ||
            document.querySelector('input[type="password"], input[autocomplete="one-time-code"], input[autocomplete="username"], form[action*="login"], form[action*="auth"]')) {
          interrupted = true;
          finish({ error: 'Sign-in is required; automatic music access is paused.' }); return;
        }
        const progressed = [...document.querySelectorAll('[data-audio-id], [data-audio]')]
          .some((row) => !known.has(rowKey(row)));
        if (progressed) finish({ ok: true, progressed: true });
      };
      observer = new MutationObserver(changed);
      observer.observe(document.body, { childList: true, subtree: true, attributes: true,
        attributeFilter: ['data-audio-id', 'data-audio', 'aria-busy'] });
      timer = setTimeout(() => finish({ ok: true, progressed: false,
        loading: Boolean(document.querySelector('[aria-busy="true"]')) }), waitMs);
    }) : null;
    try {
    if (action === 'retry-pagination') {
      // Re-enter the bottom loading region after a stalled lazy-load boundary.
      window.scrollBy(0, -Math.max(600, window.innerHeight));
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (interrupted) return await waiting;
    const rows = document.querySelectorAll('[data-audio-id], [data-audio]');
    rows[rows.length - 1]?.scrollIntoView({ block: 'end' });
    window.scrollBy(0, Math.max(600, window.innerHeight));
    return waiting ? await waiting : { ok: true };
    } finally { observer?.disconnect(); if (timer !== undefined) clearTimeout(timer); }
  }
  if (action === 'pause') {
    for (const audio of document.querySelectorAll('audio')) audio.pause();
    return { ok: true };
  }
  if (!['play', 'play-position', 'probe-playback'].includes(action) || typeof id !== 'string' || !/^-?\d+_\d+$/.test(id)) {
    return { error: 'Unsupported music action.' };
  }
  const row = [...document.querySelectorAll('[data-audio-id]')]
    .find((item) => item.getAttribute('data-audio-id') === id);
  if (!row) return { error: 'Track is not in the current music viewport.' };
  if (action === 'probe-playback') {
    const region = row.querySelector('[data-testid="MusicTrackRow_PlaybackControls"]');
    const counts = { regionPresent: Number(Boolean(region)), regionClickHandlers: 0,
      rowClickHandlers: 0, clickHandlers: 0, mouseDownHandlers: 0, pointerDownHandlers: 0,
      doubleClickHandlers: 0, buttons: 0, descendants: 0, nativeMediaElements: document.querySelectorAll('audio').length };
    const props = (element) => {
      const key = Object.keys(element).find((name) => /^__react(?:Props|EventHandlers)\$/.test(name));
      return key ? element[key] : null;
    };
    counts.rowClickHandlers = Number(typeof props(row)?.onClick === 'function');
    if (region) {
      counts.regionClickHandlers = Number(typeof props(region)?.onClick === 'function');
      const children = [...region.querySelectorAll('*')].slice(0, 100);
      counts.descendants = children.length;
      counts.buttons = region.querySelectorAll('button, [role="button"]').length;
      for (const element of [region, ...children]) {
        const value = props(element);
        if (typeof value?.onClick === 'function') counts.clickHandlers++;
        if (typeof value?.onMouseDown === 'function') counts.mouseDownHandlers++;
        if (typeof value?.onPointerDown === 'function') counts.pointerDownHandlers++;
        if (typeof value?.onDoubleClick === 'function') counts.doubleClickHandlers++;
      }
    }
    return { counts };
  }
  // VK reveals some playback controls only after the music row is hovered.
  if (typeof MouseEvent === 'function' && typeof row.dispatchEvent === 'function') {
    row.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, view: window }));
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  // Only a play control inside the exact requested music row may be activated.
  // Never click a generic row, a menu, a like/delete control, or a login form.
  let button = row.querySelector('[data-testid="MusicTrackRow_Play"], [data-testid="MusicTrackRow_PlayButton"], [data-testid="MusicTrackRow_PlayPauseButton"], [data-testid="MusicAudio_Play"], [data-testid="MusicAudio_PlayPause"]');
  if (!button) {
    // Observed in the live structural report. This specific playback region is
    // safe to activate; a generic row click could hit another music action.
    const controls = row.querySelector('[data-testid="MusicTrackRow_PlaybackControls"]');
    if (controls) {
      const buttons = [...controls.querySelectorAll('button, [role="button"]')];
      if (buttons.length > 1) return { error: 'VK playback region has multiple controls; activation is ambiguous.' };
      if (buttons.length) button = buttons[0];
      else {
        // Some VK controls are non-button React elements nested in the observed
        // playback region. Inspect only their own click-handler presence.
        const clickable = [...controls.querySelectorAll('*')].filter((element) => {
          const key = Object.keys(element).find((name) => /^__react(?:Props|EventHandlers)\$/.test(name));
          return key && typeof element[key]?.onClick === 'function';
        });
        if (clickable.length > 1) return { error: 'VK playback region has multiple controls; activation is ambiguous.' };
        button = clickable[0] || controls;
      }
    }
  }
  if (!button) button = [...row.querySelectorAll('button')].find((item) =>
    /^(?:play|воспроизвести)(?:\s|$)/i.test(item.getAttribute('aria-label') || ''));
  if (!button || button.disabled) return { error: 'VK play control is unsupported; music-control diagnostics are needed.' };
  if (action === 'play-position') {
    // Native input must hit the rendered playback area, not an invisible React
    // click proxy nested inside it. Chromium then selects the actual hit target.
    const nativeTarget = row.querySelector('[data-testid="MusicTrackRow_PlaybackControls"]') || button;
    nativeTarget.scrollIntoView({ block: 'center', inline: 'center' });
    await new Promise((resolve) => setTimeout(resolve, 100));
    if (row.getAttribute('data-audio-id') !== id) return { error: 'Track viewport changed during activation.' };
    const rect = nativeTarget.getBoundingClientRect();
    const x = Math.round(rect.left + rect.width / 2), y = Math.round(rect.top + rect.height / 2);
    const hit = document.elementFromPoint(x, y);
    const hitRow = hit?.closest?.('[data-audio-id]');
    const sameTrackHit = hitRow?.getAttribute('data-audio-id') === id;
    const blockedHit = Boolean(hit?.closest?.('a, input, textarea, select, [data-testid="MusicAudio_OpenSnippet"], [data-testid="MusicAudio_ToggleDislike"], [data-testid="MusicAudio_ToggleOwning"], [data-testid="MusicAudio_MenuButton"]'));
    // A pointer-events:none playback wrapper can route a real hit through its
    // own track row. Keep the coordinate in the observed playback area and
    // require that exact track; navigation/mutation controls stay excluded.
    const hitAllowed = !blockedHit && (hit === nativeTarget || nativeTarget.contains(hit) || sameTrackHit);
    if (rect.width <= 0 || rect.height <= 0 || x < 0 || y < 0 ||
        x >= window.innerWidth || y >= window.innerHeight ||
        !hitAllowed) return {
      error: 'VK play control is obscured or outside the viewport.',
      counts: { targetWidth: Math.max(0, Math.round(rect.width)), targetHeight: Math.max(0, Math.round(rect.height)),
        viewportWidth: Math.round(window.innerWidth), viewportHeight: Math.round(window.innerHeight),
        visibleDocument: Number(document.visibilityState === 'visible'), hitPresent: Number(Boolean(hit)),
        hitInsideTarget: Number(hit === nativeTarget || nativeTarget.contains(hit)),
        hitSameTrack: Number(sameTrackHit), hitBlockedControl: Number(blockedHit) },
    };
    return { position: { x, y } };
  }
  button.click();
  return { ok: true, activated: true };
}
});
