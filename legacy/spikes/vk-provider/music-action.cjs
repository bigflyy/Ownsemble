'use strict';

async function musicPageAction(action, id, options = {}) {
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

module.exports = { musicPageAction };
