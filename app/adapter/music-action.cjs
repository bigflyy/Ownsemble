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
  if (action === 'current-audio-source') {
    if(typeof id!=='string' || !/^-?\d+_\d+$/.test(id)) return {error:'Invalid music identity.'};
    // A named music-player getter only. Never inspect framework stores, session
    // objects, request headers, or arbitrary page state. The outer form guard
    // executes before even looking up this optional music API.
    if(typeof window.getAudioPlayer!=='function') return {supported:false,matched:false};
    try {
      const player=window.getAudioPlayer();
      if(typeof player?.getCurrentAudio!=='function') return {supported:false,matched:false};
      const audio=player.getCurrentAudio();
      const array=Array.isArray(audio);
      const aid=array?audio[0]:audio?.id,owner=array?audio[1]:audio?.owner_id??audio?.ownerId;
      if(!Number.isSafeInteger(Number(aid)) || !Number.isSafeInteger(Number(owner)) || `${owner}_${aid}`!==id) return {supported:true,matched:false};
      const source=array?audio[2]:audio?.url;
      if(typeof source!=='string' || !source.trim() || source.length>16000) return {supported:true,matched:true};
      return {supported:true,matched:true,source,userId:Number(window.vk?.id)||0,userAgent:navigator.userAgent};
    } catch {return {supported:false,matched:false};}
  }
  if (action === 'readiness') {
    return { count: document.querySelectorAll('[data-audio-id], [data-audio]').length,
      loading: document.readyState === 'loading' || Boolean(document.querySelector('[aria-busy="true"], [role="progressbar"]')) };
  }
  if (['lyrics-position','verify-lyrics-hit','lyrics-hover-position','verify-lyrics-hover','read-lyrics'].includes(action)) {
    if(typeof id!=='string' || !/^-?\d+_\d+$/.test(id)) return {error:'Invalid music identity.'};
    if(action==='read-lyrics') {
      const request=window.__ownsembleLyricsRequest;
      if(!request || request.id!==id || Date.now()-request.at>15000) return {supported:false};
      const dialogs=[...document.querySelectorAll('[role="dialog"], [data-testid="MusicLyricsModal"]')];
      for(const dialog of dialogs) {
        const identity=dialog.getAttribute?.('data-audio-id') || dialog.querySelector?.('[data-audio-id]')?.getAttribute?.('data-audio-id');
        if(identity && identity!==id) continue;
        const heading=String(dialog.querySelector?.('h1,h2,[role="heading"]')?.textContent || '').trim();
        if(!identity && (!request.title || heading!==request.title)) continue;
        const element=dialog.querySelector?.('[data-testid="MusicLyricsText"], [data-testid="AudioLyricsText"], [class*="LyricsText"], .audio_lyrics_text');
        if(!element || ['INPUT','TEXTAREA','SELECT'].includes(element.tagName)) continue;
        const text=String(element.textContent || '').trim();
        if(text && text.length<=100000) return {lyrics:{text,lines:[]},counts:{lyricsDialogs:dialogs.length,lyricsIdentity:1}};
      }
      return {supported:false,counts:{lyricsDialogs:dialogs.length}};
    }
    const row=[...document.querySelectorAll('[data-audio-id]')].find(r=>r.getAttribute('data-audio-id')===id);
    if(!row) return {error:'Track is not in the current music viewport.'};
    const buttons=[...(row.querySelectorAll?.('button, [role="button"]') || [])].filter(button=>
      !button.disabled && /lyrics|текст песни|показать текст/i.test(String(button.getAttribute?.('aria-label') || button.getAttribute?.('title') || '')+' '+String(button.getAttribute?.('data-testid') || '')));
    const hover=action.includes('hover');
    if(!hover && buttons.length!==1) return {supported:false,counts:{lyricsButtons:buttons.length}};
    const target=hover?row:buttons[0];
    if(action.endsWith('position')) target.scrollIntoView({block:'center',inline:'center'});
    const rect=target.getBoundingClientRect();
    const verifying=action.startsWith('verify-');
    const x=verifying?options.x:Math.round(rect.left+rect.width/2),y=verifying?options.y:Math.round(rect.top+rect.height/2);
    const hit=document.elementFromPoint(x,y);
    if(rect.width<=0 || rect.height<=0 || x<0 || y<0 || x>=window.innerWidth || y>=window.innerHeight || x<rect.left || x>=rect.left+rect.width || y<rect.top || y>=rect.top+rect.height || !(hit===target || target.contains?.(hit))) return {error:'Lyrics control is obscured or moved.'};
    if(!hover) window.__ownsembleLyricsRequest={id,at:Date.now(),title:String(row.querySelector?.('[data-testid="MusicTrackRow_Title"]')?.textContent || '').trim()};
    return verifying?{ok:true}:{position:{x,y},counts:{lyricsButtons:buttons.length}};
  }
  if (action === 'search-track') {
    if (typeof options.musicQuery !== 'string' || !options.musicQuery.trim() || options.musicQuery.length > 500) return {error:'Invalid music search.'};
    const inputs = [...document.querySelectorAll('input')].filter(input => {
      const type = (input.getAttribute('type') || 'text').toLowerCase();
      if (!['text','search'].includes(type) || input.disabled || input.readOnly) return false;
      const label = String(input.getAttribute('placeholder') || input.getAttribute('aria-label') || '').trim();
      if (/^(?:\u043f\u043e\u0438\u0441\u043a \u043c\u0443\u0437\u044b\u043a\u0438|\u043f\u043e\u0438\u0441\u043a \u0432 \u043c\u043e\u0435\u0439 \u043c\u0443\u0437\u044b\u043a\u0435|\u043f\u043e\u0438\u0441\u043a \u0430\u0443\u0434\u0438\u043e\u0437\u0430\u043f\u0438\u0441\u0435\u0439|search music|search my music)$/i.test(label)) return true;
      if (!/^(?:\u043f\u043e\u0438\u0441\u043a|search)$/i.test(label)) return false;
      let node = input.parentElement;
      for (let depth=0;node && depth<12;depth++,node=node.parentElement) {
        const testId=node.getAttribute?.('data-testid') || '';
        if (/(?:Music|Audio)(?:Catalog|Page|Library|Section)/i.test(testId) ||
            [...(node.classList || [])].some(name=>/(?:Music|Audio)(?:Catalog|Page|Library|Section)/i.test(name))) return true;
        if (node.tagName==='BODY' || node.tagName==='HTML') break;
      }
      return false;
    });
    const counts={musicSearchInputs:inputs.length};
    if (inputs.length!==1) return {error:'Music search control unsupported or ambiguous.',counts};
    const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value')?.set;
    if (!set) return {error:'Music search input unsupported.',counts};
    set.call(inputs[0],options.musicQuery.replace(/\s+/g,' ').trim().slice(0,160));
    const input=inputs[0];
    input.dispatchEvent(new Event('input',{bubbles:true}));
    input.dispatchEvent(new Event('change',{bubbles:true}));
    const propsKey=Object.keys(input).find(name=>/^__react(?:Props|EventHandlers)\$/.test(name));
    const props=propsKey && input[propsKey];
    counts.musicSearchChangeHandler=Number(typeof props?.onChange==='function');
    if (typeof props?.onChange==='function') props.onChange({target:input,currentTarget:input,type:'change',preventDefault(){},stopPropagation(){}});
    if (typeof KeyboardEvent==='function') {
      input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
      input.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
    }
    return {searched:true,counts};
  }
  if (action === 'resolve-reference') {
    if (typeof id !== 'string' || !/^-?\d+_\d+$/.test(id)) return {error:'Invalid music reference.'};
    try {
      const response = await fetch('/al_audio.php', {
        method:'POST',credentials:'same-origin',redirect:'error',
        headers:{'Content-Type':'application/x-www-form-urlencoded','X-Requested-With':'XMLHttpRequest'},
        body:new URLSearchParams({al:'1',act:'reload_audio',ids:id + (typeof options.musicKey === 'string' && /^[A-Za-z0-9_-]{1,256}$/.test(options.musicKey) ? '_' + options.musicKey : '')}),
        signal:AbortSignal.timeout(6000),
      });
      if (!response.ok || !/^(?:application\/json|text\/plain)(?:;|$)/i.test(response.headers?.get('content-type') || '') ||
          document.querySelector('input[type="password"], input[autocomplete="one-time-code"], input[autocomplete="username"], form[action*="login"], form[action*="auth"]')) return {error:'Music source response unavailable.'};
      const text = await response.text();
      if (text.length > 2 * 1024 * 1024) return {error:'Music response budget.'};
      const reply = JSON.parse(text.replace(/^\s*<!--/,''));
      const music = reply?.payload?.[1];
      if (!Array.isArray(music) || music.length > 100) return {error:'Music response format unsupported.'};
      const sources = new Set();let matched = 0, visited = 0;
      // Only bounded music response arrays and explicit audio collections. Do
      // not recurse through arbitrary objects, page stores or account fields.
      const visit = (audio, depth) => {
        if (!audio || typeof audio !== 'object' || depth > 5 || ++visited > 256) return;
        const array = Array.isArray(audio);
        const owner = array ? audio[1] : audio.owner_id;
        const aid = array ? audio[0] : audio.id;
        if (`${owner}_${aid}` === id) {
          matched++;
          const source = array ? audio[2] : audio.url;
          if (typeof source === 'string' && source.trim() && source.length <= 16000) sources.add(source);
          return;
        }
        if (array && audio.length <= 100) audio.forEach(child => visit(child, depth + 1));
        else if (!array && Array.isArray(audio.audios)) visit(audio.audios, depth + 1);
      };
      visit(music,0);
      if (sources.size > 1) return {error:'Music source response ambiguous.'};
      return {source:[...sources][0] || '',userId:Number(window.vk && window.vk.id) || 0,
        userAgent:navigator.userAgent,counts:{matched,urlsFound:sources.size,responseNodes:visited,responseBatch:music.length}};
    } catch { return {error:'Music source request unavailable.'}; }
  }
  if (action === 'begin-audio-capture') {
    const existing = performance.getEntriesByType('resource').length;
    performance.setResourceTimingBufferSize(4096);
    return { since: performance.now(), timingEntriesBefore: existing };
  }
  if (action === 'audio-resources') {
    const since = options.since;
    if (!Number.isFinite(since) || since < 0) return { error: 'Invalid capture boundary.' };
    const suffixes = ['vkuseraudio.net', 'vkuseraudio.com', 'vkuseraudio.ru', 'useraudio.com', 'userapi.com', 'vk-cdn.net', 'vk-cdn.me'];
    // This is an in-app media result, never a diagnostic/log payload. Timing
    // entries include cache hits that need not reach request interception.
    const urls = new Set(), segments = new Set();
    for (const entry of performance.getEntriesByType('resource')) {
      if (!Number.isFinite(entry.startTime) || entry.startTime < since) continue;
      try {
        const url = new URL(entry.name);
        if (url.protocol !== 'https:' || url.username || url.password || url.port ||
            !suffixes.some(host => url.hostname === host || url.hostname.endsWith('.' + host)) ||
            !/\.(?:mp3|m4a|m3u8|ts|aac|m4s)$/i.test(url.pathname)) continue;
        if (/\.(?:ts|aac|m4s)$/i.test(url.pathname)) {
          if (segments.size < 64) segments.add(url.href);
        } else if (urls.size < 32) urls.add(url.href);
        if (urls.size >= 32 && segments.size >= 64) break;
      } catch { /* Invalid media destination. */ }
    }
    return { urls: [...urls], segments: [...segments] };
  }
  // Read or diagnose a guarded personal-library page using only known music fields.
  if (action === 'probe-library-page' || action === 'read-library-page') {
    // Separate optional diagnostics from the app's bounded personal-list import.
    const importing = action === 'read-library-page';
    // Accept only forward cursors owned by the application scanner.
    const offset = importing ? options.libraryOffset : 0;
    // Reject malformed cursors before any network or response access.
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > 50000) return { supported: false };
    // Require the approved music route and absence of private sign-in forms.
    function musicRequestAllowed() {
      return location.protocol === 'https:' && ['vk.ru', 'vk.com'].includes(location.hostname) &&
        /^\/(?:audios\d*|audio|music)(?:\/|$)/.test(location.pathname) &&
        !document.querySelector('input[type="password"], input[autocomplete="one-time-code"], input[autocomplete="username"], form[action*="login"], form[action*="auth"]');
    }
    // Reuse the numeric music owner already exposed to the guarded music adapter.
    const ownerId = Number(window.vk?.id);
    // Avoid guessing an owner or consulting authentication/session objects.
    if (!Number.isSafeInteger(ownerId) || ownerId <= 0) return { counts: { libraryOwnerUnavailable: 1 } };
    // Locate failures without retaining request URLs, response text or exception messages.
    let failureStage = 0;
    // Distinguish the initial page from its single permitted continuation.
    let requestPage = -1;
    // Retain only the latest response length for bounded parsing diagnostics.
    let responseCharacters = 0;
    // Observe the existing shared deadline without exporting a signal or native error.
    let deadlineSignal;
    // Read a bounded music-list envelope using the current consent checks.
    async function readLibraryPlaylist(offset, signal) {
      // Recheck consent before every request, including any continuation.
      if (!musicRequestAllowed()) return { error: 'Sign-in is required; automatic music access is paused.' };
      failureStage = 1;
      requestPage++;
      // Request only the account's own music; the session remains in the browser.
      const response = await fetch('/al_audio.php', {
        method: 'POST', credentials: 'same-origin', redirect: 'error',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest' },
        body: new URLSearchParams({ al: '1', act: 'load_section', owner_id: String(ownerId),
          playlist_id: '-1', offset: String(offset), type: 'playlist', is_loading_all: importing && options.newestOnly === true ? '0' : '1' }), signal,
      });
      // Recheck the music route and form guard before examining any response body.
      if (!musicRequestAllowed()) {
        return { error: 'Sign-in is required; automatic music access is paused.' };
      }
      // Reject HTML, redirects and failures without reading their response bodies.
      // Classify the response format without forwarding its header text.
      const contentType = response.headers?.get('content-type') || '';
      // Validate the declared body type independently of its text encoding.
      const jsonResponse = /^(?:application\/json|text\/plain)(?:;|$)/i.test(contentType);
      // Retain only a bounded HTTP status code for transport troubleshooting.
      const httpStatus = Number.isInteger(response.status) && response.status >= 100 && response.status <= 599 ? response.status : 0;
      // Stop before body access when transport or response format is unsupported.
      if (!response.ok || !jsonResponse) {
        return { counts: { libraryResponseUnsupported: 1, libraryHTTPStatus: httpStatus,
          libraryJSONResponse: Number(jsonResponse) } };
      }
      // Bound the known music-list JSON before decoding it.
      failureStage = 2;
      // Fetch text() always assumes UTF-8, while VK can explicitly send Windows-1251.
      const charset = /;\s*charset\s*=\s*["']?([^;\s"']+)/i.exec(contentType)?.[1]?.toLowerCase() || 'utf-8';
      // Accept only known encodings, never guess from already damaged display text.
      const windows1251 = ['windows-1251', 'cp1251', 'x-cp1251'].includes(charset);
      // Reject unknown encodings before reading their bodies.
      if (!windows1251 && !['utf-8', 'utf8'].includes(charset)) {
        return { counts: { libraryEncodingUnsupported: 1 } };
      }
      // Read raw bytes once so invalid text cannot silently replace good saved metadata.
      const bytes = await response.arrayBuffer();
      // Recheck private-login consent before decoding any transferred bytes.
      if (!musicRequestAllowed()) return { error: 'Sign-in is required; automatic music access is paused.' };
      // Bound byte allocation before text decoding; retain the existing decoded-character cap below.
      if (bytes.byteLength > 16 * 1024 * 1024) return { counts: { libraryResponseTooLarge: 1, libraryResponseBytes: bytes.byteLength } };
      // Keep decoded text internal to the guarded music-list projection.
      let body;
      try {
        body = new TextDecoder(windows1251 ? 'windows-1251' : 'utf-8', { fatal: true }).decode(bytes);
      } catch {
        // Report only the encoding category, never raw bytes or decoder exception text.
        return { counts: { libraryEncodingFailed: 1, libraryWindows1251: Number(windows1251) } };
      }
      responseCharacters = body.length;
      // Discard a completed body if private sign-in began during its transfer.
      if (!musicRequestAllowed()) {
        return { error: 'Sign-in is required; automatic music access is paused.' };
      }
      // Stop on oversized replies rather than inspecting unrelated response fields.
      if (body.length > 8 * 1024 * 1024) return { counts: { libraryResponseTooLarge: 1,
        libraryResponseCharacters: body.length } };
      // Decode only the documented music-list envelopes.
      failureStage = 3;
      const reply = JSON.parse(body.replace(/^\s*<!--/, ''));
      failureStage = 4;
      // Select the named playlist slot without recursively traversing the reply.
      const playlist = reply?.payload?.[1]?.[0] ?? reply?.data?.[0];
      // Require a bounded music list before projecting its pagination counters.
      if (!playlist || !Array.isArray(playlist.list) || playlist.list.length > 5000) {
        return { counts: { libraryRequestOK: 1, libraryShapeUnsupported: 1 } };
      }
      return { playlist, characters: body.length, windows1251, bytes: bytes.byteLength };
    }
    // Extract a recording identity internally without exporting its value.
    function recordingIdentity(record) {
      // Read only the documented audio and owner identity fields.
      const audioId = Array.isArray(record) ? record[0] : record?.id;
      // Accept both known owner spellings without traversing unrelated state.
      const owner = Array.isArray(record) ? record[1] : record?.owner_id ?? record?.ownerId;
      return Number.isSafeInteger(audioId) && audioId > 0 && Number.isSafeInteger(owner) && owner !== 0
        ? `${owner}_${audioId}` : null;
    }
    try {
      // Bound both explicit diagnostic requests, including their large response bodies.
      const signal = deadlineSignal = AbortSignal.timeout(20000);
      // Read the first page before considering a bounded membership comparison.
      const first = await readLibraryPlaylist(offset, signal);
      // Preserve fixed failure categories and private-login rejection unchanged.
      if (!first.playlist) return importing ? { supported: false, ...first } : first;
      // Keep the actual music content inside this function until only counts remain.
      const playlist = first.playlist;
      // Keep only fixed numeric counters for import failures and pagination diagnostics.
      const importCounts = { libraryRequestOK: 1, libraryShapeSupported: 1,
        libraryRows: playlist.list.length, libraryResponseCharacters: first.characters,
        libraryWindows1251: Number(first.windows1251), libraryResponseBytes: first.bytes };
      // Project typed provider counters without retaining server strings or music identities.
      for (const [key, value] of [['libraryNextOffset', playlist.nextOffset], ['libraryTotal', playlist.totalCount]]) {
        // Omit malformed counters rather than guessing their meaning.
        if (Number.isSafeInteger(value) && value >= 0 && value <= 1000000000) importCounts[key] = value;
      }
      // Retain an explicit typed continuation flag for diagnosis.
      if ([true, false, 0, 1].includes(playlist.hasMore)) importCounts.libraryHasMore = Number(playlist.hasMore);
      // Project only validated music fields; never forward server URLs or unrelated state.
      if (importing) {
        // Require explicit pagination with a consistent end, including an empty library.
        const total = playlist.totalCount;
        // Keep the cursor within the bounded account-list size.
        const nextOffset = playlist.nextOffset;
        // Normalize only a terminal fixed-width cursor after all advertised rows were received.
        const consumed = offset + playlist.list.length;
        // Read only the provider's explicit continuation flag.
        const hasMore = playlist.hasMore === true || playlist.hasMore === 1;
        // Reject contradictory totals, gaps and ambiguous termination.
        if (![true, false, 0, 1].includes(playlist.hasMore) ||
            !Number.isSafeInteger(total) || total < 0 || total > 50000 ||
            !Number.isSafeInteger(nextOffset) || nextOffset > 50000 ||
            (hasMore ? nextOffset !== consumed || nextOffset >= total : consumed !== total || nextOffset < consumed) ||
            (hasMore && playlist.list.length === 0)) return { supported: false, counts: { ...importCounts, libraryPaginationUnsupported: 1 } };
        // Decode entities using the same text-only primitive as rendered music rows.
        function plainText(value) {
          // Reject non-text metadata instead of coercing server objects.
          if (typeof value !== 'string' || value.length > 1000) return null;
          // Use a detached textarea; its content is never inserted into the page.
          const element = document.createElement('textarea');
          element.innerHTML = value;
          return typeof element.value === 'string' && !element.value.includes(String.fromCharCode(65533)) ? element.value : null;
        }
        // Validate every row before exposing a page for merging.
        const tracks = [];
        // Detect duplicate recordings within this page before persisting any of them.
        const identities = new Set();
        // Read only the known array slots or named music fields.
        for (const record of playlist.list) {
          // Keep identity independent of the row's order or display metadata.
          const identity = recordingIdentity(record);
          // Extract known title, artist and duration fields without traversing other state.
          const title = plainText(Array.isArray(record) ? record[3] : record?.title);
          // Preserve exact artist spelling after the ordinary HTML-entity decode.
          const artist = plainText(Array.isArray(record) ? record[4] : record?.artist);
          // Require finite seconds and reject null instead of turning it into zero.
          const duration = Array.isArray(record) ? record[5] : record?.duration;
          // Fail the entire page when any recording cannot be safely identified.
          if (!identity || identities.has(identity) || title === null || artist === null ||
              !Number.isFinite(duration) || duration < 0 || duration > 86400) return { supported: false, counts: { ...importCounts, libraryMetadataUnsupported: 1 } };
          identities.add(identity);
          tracks.push({ id: identity, title, artist, duration, url: '' });
        }
        return { supported: true, counts: importCounts, userId: ownerId, userAgent: navigator.userAgent,
          tracks, pagination: { offset, nextOffset: hasMore ? nextOffset : consumed, total, hasMore } };
      }
      // Return numeric diagnostics only; retain no track objects or response body.
      const counts = { libraryRequestOK: 1, libraryShapeSupported: 1,
        libraryRows: playlist.list.length, libraryResponseCharacters: first.characters,
        libraryWindows1251: Number(first.windows1251), libraryResponseBytes: first.bytes };
      // Preserve only explicit, well-typed continuation flags.
      if ([true, false, 0, 1].includes(playlist.hasMore)) counts.libraryHasMore = Number(playlist.hasMore);
      // Read only named pagination offsets and totals within the numeric budget.
      for (const [key, value] of [['libraryNextOffset', playlist.nextOffset], ['libraryTotal', playlist.totalCount]]) {
        // Ignore missing or malformed counters rather than guessing their meaning.
        if (Number.isSafeInteger(value) && value >= 0 && value <= 1000000000) counts[key] = value;
      }
      // Keep the ordinary shape probe to one request unless comparison is explicit.
      if (options.compareMembership !== true) return { counts };
      // Reject an oversized single page before allocating comparison collections.
      if (playlist.list.length > 4000) return { counts: { ...counts, libraryComparisonUnavailable: 1 } };
      // Accumulate at most two pages and four thousand recording entries.
      const recordings = [...playlist.list];
      // Require an explicit provider end flag before treating the listing as complete.
      let ended = playlist.hasMore === false || playlist.hasMore === 0;
      // Follow only one validated forward continuation for a bounded library.
      if (!ended && [true, 1].includes(playlist.hasMore) &&
          Number.isSafeInteger(playlist.totalCount) && playlist.totalCount <= 4000 &&
          Number.isSafeInteger(playlist.nextOffset) && playlist.nextOffset > 0 && playlist.nextOffset <= 4000) {
        // Read the continuation using the same consent checks and shared deadline.
        const continuation = await readLibraryPlaylist(playlist.nextOffset, signal);
        // Stop immediately if private sign-in began between requests.
        if (continuation.error) return continuation;
        // Reject changed totals, oversized lists and unsupported continuation replies.
        if (!continuation.playlist || continuation.playlist.totalCount !== playlist.totalCount ||
            recordings.length + continuation.playlist.list.length > 4000) {
          return { counts: { ...counts, libraryComparisonUnavailable: 1 } };
        }
        recordings.push(...continuation.playlist.list);
        ended = continuation.playlist.hasMore === false || continuation.playlist.hasMore === 0;
      }
      // Never compare a partial listing with the rendered document as complete.
      if (!ended || recordings.length !== playlist.totalCount) {
        return { counts: { ...counts, libraryComparisonUnavailable: 1 } };
      }
      // Validate every music identity before constructing the membership set.
      const identities = recordings.map(recordingIdentity);
      // Reject malformed recordings instead of manufacturing membership evidence.
      if (identities.some(identity => identity === null)) return { counts: { ...counts, libraryComparisonUnavailable: 1 } };
      // Deduplicate membership without persisting or exporting recording identifiers.
      const library = new Set(identities);
      // Reject overlapping pages or duplicate identities instead of treating raw row counts as coverage.
      if (library.size !== playlist.totalCount) {
        return { counts: { ...counts, libraryComparisonUnavailable: 1 } };
      }
      // Collect one rendered DOM row per recognized recording identity.
      const rendered = new Map();
      // Examine only known music-row attributes, excluding page text and field values.
      for (const row of document.querySelectorAll('[data-audio-id], [data-audio]')) {
        // Read the modern identity without parsing unrelated element attributes.
        const identity = row.getAttribute('data-audio-id');
        // Keep only valid recording identities in the internal comparison.
        if (typeof identity === 'string' && /^-?\d+_\d+$/.test(identity)) rendered.set(identity, row);
      }
      // Identify rendered entries outside the completed personal-library listing.
      const outside = [...rendered].filter(([identity]) => !library.has(identity));
      counts.libraryComparedComplete = 1;
      counts.libraryUniqueRecordings = library.size;
      counts.libraryDOMUniqueRecordings = rendered.size;
      counts.libraryDOMOutsideListing = outside.length;
      counts.libraryListedOutsideDOM = [...library].filter(identity => !rendered.has(identity)).length;
      counts.libraryOutsideRecommendationRows = outside.filter(([, row]) => row.closest?.(
        '[class*="Recommendation"], [class*="recommendation"], [data-testid*="Recommendation"]')).length;
      return { counts };
    } catch (error) {
      // Report a fixed category without logging native errors or response contents.
      return { ...(importing ? { supported: false } : {}), counts: { libraryProbeFailed: 1,
        libraryProbeFailureStage: failureStage, libraryProbePage: Math.max(0, requestPage),
        libraryResponseCharacters: responseCharacters,
        libraryJSONDecodeFailed: Number(error?.name === 'SyntaxError'),
        libraryDeadlineExpired: Number(deadlineSignal?.aborted === true) } };
    }
  }
  // Locate rendered music rows and the scroll pane containing the largest group.
  function musicViewport() {
    // Collect only recognized recording elements, without exporting their IDs.
    const allRows = [...document.querySelectorAll('[data-audio-id], [data-audio]')];
    // Exclude hidden player duplicates; offscreen rendered rows still have rectangles.
    const rows = allRows.filter(row => !row.getClientRects || row.getClientRects().length > 0);
    // Count the rendered rows belonging to each nearest scrollable ancestor.
    const candidates = new Map();
    // Count clipped ancestors separately to diagnose unsupported layouts.
    const clipped = new Set();
    // Record the largest ancestor content height in CSS pixels.
    let tallest = 0;
    // Inspect each rendered row without reading titles or arbitrary page state.
    for (const row of rows) {
      // Bound the ancestor walk to twelve elements per row.
      for (let parent = row.parentElement, depth = 0; parent && depth < 12;
        parent = parent.parentElement, depth++) {
        tallest = Math.max(tallest, parent.scrollHeight || 0);
        // Skip ancestors whose content fits or whose viewport is hidden.
        if (parent.clientHeight <= 0 || parent.scrollHeight <= parent.clientHeight + 1) continue;
        // Read only the vertical overflow mode needed to select a scroll target.
        const overflow = getComputedStyle(parent).overflowY;
        // Keep clipped-container counts without treating them as ordinary scrollers.
        if (/^(?:hidden|clip)$/.test(overflow)) clipped.add(parent);
        // Require a browser-managed vertical scrollbar for ordinary scrolling.
        if (!/^(?:auto|scroll)$/.test(overflow)) continue;
        // Retain the last row and total membership for this candidate pane.
        const candidate = candidates.get(parent) || { count: 0, lastRow: row };
        candidate.count++; candidate.lastRow = row; candidates.set(parent, candidate);
        break;
      }
    }
    // Fall back to document scrolling when no music pane owns a scrollbar.
    let musicScroller = null;
    // Use the last rendered recording, excluding hidden player copies.
    let lastRow = rows[rows.length - 1];
    // Prefer the pane containing the largest observed recording group.
    let mostRows = 0;
    // Select a music pane without consulting unrelated navigation/sidebar elements.
    for (const [element, candidate] of candidates) {
      // Replace the current target only when this pane contains more rows.
      if (candidate.count > mostRows) {
        musicScroller = element; lastRow = candidate.lastRow; mostRows = candidate.count;
      }
    }
    return { allRows, rows, musicScroller, lastRow, candidates, clipped, tallest };
  }
  // Return bounded layout diagnostics without row identities or page text.
  if (action === 'probe-pagination') {
    // Read document geometry for the document-scrolling fallback.
    const scroller = document.scrollingElement;
    // Describe music-specific geometry using the same selection as pagination.
    const layout = musicViewport();
    return { counts: { documentScrollHeight: Math.round(scroller?.scrollHeight || 0),
      documentClientHeight: Math.round(scroller?.clientHeight || 0),
      documentScrollTop: Math.round(scroller?.scrollTop || 0),
      musicRows: layout.allRows.length, visibleMusicRows: layout.rows.length,
      tallestMusicAncestor: Math.round(layout.tallest), clippedMusicAncestors: layout.clipped.size,
      scrollableMusicAncestors: layout.candidates.size, visibleDocument: Number(document.visibilityState === 'visible') } };
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
    // Ignore hidden duplicate/player rows and choose the scroll pane containing
    // the largest recognized row group, rather than the last node in the DOM.
    // Resolve the pane and its final rendered row from the current layout.
    const { musicScroller, lastRow } = musicViewport();
    // Move by at least 600 CSS pixels to enter the next lazy-loading region.
    const step = Math.max(600, musicScroller?.clientHeight || window.innerHeight);
    // Apply both retry and forward movements to the same scroll target.
    const scroll = delta => (musicScroller || window).scrollBy(0, delta);
    try {
    if (action === 'retry-pagination') {
      // Re-enter the bottom loading region after a stalled lazy-load boundary.
      scroll(-step);
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (interrupted) return await waiting;
    lastRow?.scrollIntoView({ block: 'end' });
    scroll(step);
    return waiting ? await waiting : { ok: true };
    } finally { observer?.disconnect(); if (timer !== undefined) clearTimeout(timer); }
  }
  if (action === 'pause') {
    for (const audio of document.querySelectorAll('audio')) audio.pause();
    return { ok: true };
  }
  if (!['play', 'play-position', 'verify-play-hit', 'probe-playback'].includes(action) || typeof id !== 'string' || !/^-?\d+_\d+$/.test(id)) {
    return { error: 'Unsupported music action.' };
  }
  const row = [...document.querySelectorAll('[data-audio-id]')]
    .find((item) => item.getAttribute('data-audio-id') === id);
  if (!row) return { error: 'Track is not in the current music viewport.' };
  if (action === 'probe-playback') {
    const region = row.querySelector('[data-testid="MusicTrackRow_PlaybackControls"]');
    const counts = { regionPresent: Number(Boolean(region)), regionClickHandlers: 0,
      rowClickHandlers: 0, clickHandlers: 0, mouseDownHandlers: 0, pointerDownHandlers: 0,
      doubleClickHandlers: 0, buttons: 0, descendants: 0, playingControls: 0, pausedControls: 0, nativeMediaElements: document.querySelectorAll('audio').length };
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
        if (!['INPUT', 'TEXTAREA', 'SELECT'].includes(element.tagName)) {
          const label = element.getAttribute?.('aria-label') || '';
          const tokens = [...(element.classList || [])];
          const icon = element.tagName?.toLowerCase() === 'svg';
          if (/^(?:pause|\u043f\u0430\u0443\u0437\u0430|\u043f\u0440\u0438\u043e\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u044c)(?:\s|$)/i.test(label) ||
              icon && tokens.some(name => /(?:^|[-_])pause(?:[-_]|$)/i.test(name))) counts.playingControls++;
          if (/^(?:play|\u0432\u043e\u0441\u043f\u0440\u043e\u0438\u0437\u0432\u0435\u0441\u0442\u0438)(?:\s|$)/i.test(label) ||
              icon && tokens.some(name => /(?:^|[-_])play(?:[-_]|$)/i.test(name))) counts.pausedControls++;
        }
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
  if (!button) return { error: 'VK play control is unsupported; music-control diagnostics are needed.' };
  if (button.disabled || button.getAttribute?.('aria-disabled')==='true' || row.getAttribute('aria-disabled')==='true') return {blocked:true,error:'The selected music Play control is disabled.'};
  if (action === 'play-position' || action === 'verify-play-hit') {
    // Native input must hit the rendered playback area, not an invisible React
    // click proxy nested inside it. Chromium then selects the actual hit target.
    const playbackRegion = row.querySelector('[data-testid="MusicTrackRow_PlaybackControls"]');
    const renderedButtons = [...(playbackRegion?.querySelectorAll?.('button, [role="button"]') || [])]
      .filter(item => !item.disabled && item.getBoundingClientRect?.().width > 0 && item.getBoundingClientRect?.().height > 0);
    if (renderedButtons.length > 1) return { error: 'VK playback region has multiple visible controls.' };
    const buttonRect = button.getBoundingClientRect?.();
    // Once VK renders a real Play button, hit that button rather than the
    // surrounding image/selection wrapper. Keep the wrapper for invisible
    // React click proxies used before the control appears.
    const visibleButton = button.tagName?.toLowerCase() === 'button' &&
      buttonRect?.width > 0 && buttonRect?.height > 0;
    const nativeTarget = renderedButtons[0] || (visibleButton ? button : playbackRegion || button);
    if (action === 'play-position') {
      nativeTarget.scrollIntoView({ block: 'center', inline: 'center' });
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (row.getAttribute('data-audio-id') !== id) return { error: 'Track viewport changed during activation.' };
    const rect = nativeTarget.getBoundingClientRect();
    const x = action === 'verify-play-hit' ? options.x : Math.round(rect.left + rect.width / 2);
    const y = action === 'verify-play-hit' ? options.y : Math.round(rect.top + rect.height / 2);
    if (!Number.isFinite(x) || !Number.isFinite(y) || x < rect.left || y < rect.top ||
        x >= rect.left + rect.width || y >= rect.top + rect.height) return { error: 'Playback target moved.' };
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
    return action === 'verify-play-hit' ? { ok: true } : { position: { x, y } };
  }
  button.click();
  return { ok: true, activated: true };
}

module.exports = { musicPageAction };
