const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { validateImport, mediaURL, isMusicURL } = require('./music-policy.cjs');
const { readMusicPage } = require('./music-page.cjs');
const { musicPageAction } = require('./music-action.cjs');
const { inspectMusicDOM, sanitizeMusicStructure } = require('./music-dom.cjs');

const payload = () => ({ userId: 1, userAgent: 'test', tracks: [
  { id: '1_2', artist: 'Artist', title: 'Song', duration: 180, url: 'https://test.vkuseraudio.net/song.mp3' },
] });

test('current player source requires its exact recording identity, not a next-song prefetch', async () => {
  let current = [99,1,'https://test.vkuseraudio.net/next.mp3','Generated next','Fixture',240];
  let touched = 0;
  const invoke = (form=false) => vm.runInNewContext(`(${musicPageAction.toString()})('current-audio-source','1_2')`, {
    location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},
    window:{getAudioPlayer(){touched++;return {getCurrentAudio:()=>current};}},
    navigator:{userAgent:'Generated'}, document:{querySelector:()=>form?{}:null,querySelectorAll:()=>[]},
  });
  const wrong = await invoke(); assert.equal(wrong.source,undefined); assert.equal(wrong.matched,false);
  current=[2,1,'https://test.vkuseraudio.net/selected.mp3','Generated selected','Fixture',180];
  const correct=await invoke(); assert.equal(correct.matched,true); assert.equal(correct.source,current[2]);
  const before=touched; assert.ok((await invoke(true)).error); assert.equal(touched,before);
});

test('credential fields are rejected at every import boundary', () => {
  for (const field of ['password', 'cookies', 'token', 'access_token', 'authorization']) {
    const root = payload(); root[field] = 'synthetic';
    assert.throws(() => validateImport(root));
    const nested = payload(); nested.tracks[0][field] = 'synthetic';
    assert.throws(() => validateImport(nested));
  }
});
test('media links are restricted to HTTPS VK CDN destinations', () => {
  assert.equal(mediaURL(payload().tracks[0].url), payload().tracks[0].url);
  for (const url of ['http://test.vkuseraudio.net/song.mp3', 'https://127.0.0.1/file',
    'https://vkuseraudio.net.attacker.test/file', 'https://user:pass@test.vkuseraudio.net/file',
    'https://test.vkuseraudio.net:8443/file']) assert.throws(() => mediaURL(url));
});
test('encoded-link markers cannot bypass destination validation', () => {
  const body = payload(); body.tracks[0].url = 'https://attacker.test/audio_api_unavailable';
  assert.throws(() => validateImport(body));
  body.tracks[0].url = 'https://vk.com/mp3/audio_api_unavailable.mp3?extra=encoded';
  assert.equal(validateImport(body), body);
});
test('import size and request-header values are bounded', () => {
  const body = payload(); body.tracks = Array.from({ length: 50001 }, () => payload().tracks[0]);
  assert.throws(() => validateImport(body));
  const header = payload(); header.userAgent = 'browser\r\nCookie: synthetic';
  assert.throws(() => validateImport(header));
});
test('only recognized music pages permit extraction', () => {
  assert.equal(isMusicURL('https://vk.ru/audios123'), true);
  assert.equal(isMusicURL('https://vk.com/audio'), true);
  for (const url of ['https://vk.ru/login', 'https://id.vk.com/auth',
    'https://vk.ru.attacker.test/audio', 'http://vk.ru/audio']) assert.equal(isMusicURL(url), false);
});
test('login-page extraction stops before any DOM or network access', async () => {
  let touched = false;
  const context = { location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/login' },
    document: new Proxy({}, { get() { touched = true; throw new Error('Unexpected DOM access'); } }),
    fetch: () => { touched = true; throw new Error('Unexpected network access'); } };
  const result = await vm.runInNewContext(`(${readMusicPage.toString()})()`, context);
  assert.equal(typeof result.error, 'string');
  assert.equal(touched, false);
});
test('form detection does not read field values', async () => {
  const field = Object.defineProperty({}, 'value', { get() { throw new Error('Credential value read'); } });
  const result = await vm.runInNewContext(`(${readMusicPage.toString()})()`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => field, querySelectorAll: () => { throw new Error('Read music while signing in'); } },
  });
  assert.equal(typeof result.error, 'string');
});

test('music readiness reports only row count and loading presence', async () => {
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('readiness')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { readyState: 'complete',
      querySelector: selector => selector.startsWith('input') ? null : {},
      querySelectorAll: () => Array(30).fill(Object.defineProperty({}, 'textContent', {
        get() { throw new Error('Read row contents'); },
      })),
    },
  });
  assert.equal(result.count, 30);
  assert.equal(result.loading, true);
  assert.deepEqual(Object.keys(result).sort(), ['count', 'loading']);
});

async function readSyntheticRows(values, fetch = () => { throw new Error('Unexpected request'); }, modernRows = [], options = {}) {
  const rows = values.map((value) => ({ getAttribute(name) {
    assert.equal(name, 'data-audio');
    return typeof value === 'string' ? value : JSON.stringify(value);
  } }));
  return vm.runInNewContext(`(${readMusicPage.toString()})(undefined, ${JSON.stringify(options)})`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: {
      querySelector: () => null,
      querySelectorAll: (selector) => {
        if (selector === '[data-audio]') return rows;
        if (selector === '[data-audio-id]') return modernRows;
        if (selector === '.audio_row, .audio_item') return [];
        if (selector === '[data-full-id]:not([data-audio])') return [];
        throw new Error(`Unexpected selector: ${selector}`);
      },
      createElement: (tag) => {
        assert.equal(tag, 'textarea');
        return { set innerHTML(text) { this.value = text; } };
      },
    },
    window: { vk: { id: 1 } }, navigator: { userAgent: 'synthetic-browser' },
    fetch, URL, URLSearchParams, AbortSignal,
  });
}

test('music attributes work without legacy CSS classes and deduplicate array rows', async () => {
  const row = [2, 1, payload().tracks[0].url, 'Song', 'Artist', 180];
  const result = await readSyntheticRows([row, row]);
  assert.equal(result.tracks.length, 1);
  assert.equal(result.tracks[0].id, '1_2');
  assert.equal(result.diagnostics.legacyRows, 0);
  assert.equal(result.diagnostics.arrayRows, 2);
  assert.equal(result.diagnostics.duplicateRows, 1);
  const { diagnostics, resolutionFailed, structure, ...body } = result;
  assert.equal(validateImport(body), body);
});

test('object music rows project only track fields and refresh their audio links', async () => {
  const row = { id: 2, owner_id: 1, title: 'Song', artist: 'Artist', duration: 180,
    actionHash: 'synthetic-action', urlHash: 'synthetic-url',
    password: 'SYNTHETIC_IGNORED_VALUE', token: 'SYNTHETIC_IGNORED_VALUE' };
  let requests = 0;
  const result = await readSyntheticRows([row], async (endpoint, options) => {
    requests++;
    assert.equal(endpoint, '/al_audio.php');
    assert.equal(options.credentials, 'same-origin');
    assert.equal(options.body.get('ids'), '1_2_synthetic-action_synthetic-url');
    assert.equal(Object.keys(options.headers).some((key) => /cookie|authorization/i.test(key)), false);
    return { ok: true, text: async () => JSON.stringify({ payload: [[
      [2, 1, payload().tracks[0].url, 'Song', 'Artist', 180],
    ]] }) };
  });
  assert.equal(requests, 1);
  assert.equal(result.diagnostics.objectRows, 1);
  assert.equal(result.tracks[0].url, payload().tracks[0].url);
  assert.equal(JSON.stringify(result).includes('SYNTHETIC_IGNORED_VALUE'), false);
  const { diagnostics, resolutionFailed, structure, ...body } = result;
  assert.equal(validateImport(body), body);
});

test('unsupported rows produce count diagnostics without exposing attribute contents', async () => {
  const result = await readSyntheticRows(['{SYNTHETIC_BAD_JSON', null,
    { id: 2, owner_id: 1, title: 'Song', artist: 'Artist', duration: '180' }]);
  assert.equal(result.tracks, undefined);
  assert.equal(result.diagnostics.audioDataElements, 3);
  assert.equal(result.diagnostics.invalidRows, 3);
  assert.equal(result.diagnostics.validRows, 0);
  assert.equal(JSON.stringify(result).includes('SYNTHETIC_BAD_JSON'), false);
});

test('music collection includes tracks beyond the old thirty-track sample', async () => {
  const result = await readSyntheticRows(Array.from({ length: 35 }, (_, index) =>
    [index + 1, 1, '', 'Song', 'Artist', 180]));
  assert.equal(result.tracks.length, 35);
  assert.equal(result.diagnostics.validRows, 35);
  assert.equal(result.diagnostics.audioDataElements, 35);
});

test('structural diagnosis reads music class labels and counts without content or field access', () => {
  const trap = () => { throw new Error('Sensitive content read'); };
  const node = (tagName, classes, shadowRoot = null) => Object.defineProperties(
    { tagName, classList: classes, shadowRoot }, {
      innerHTML: { get: trap }, outerHTML: { get: trap }, textContent: { get: trap },
      value: { get: trap }, attributes: { get: trap },
    });
  const input = node('INPUT', []);
  Object.defineProperty(input, 'classList', { get: trap });
  const document = {
    querySelectorAll: (selector) => selector === '*' ? [input,
      node('DIV', ['AudioRow__root--abcdef', 'unrelated', 'track_item123456']),
      node('DIV', ['MusicCatalog'], { querySelectorAll: () => [node('DIV', ['AudioRow__root--xyz'])] }),
    ] : selector === 'iframe' ? [{ }] : [],
  };
  const result = vm.runInNewContext(`(${inspectMusicDOM.toString()})()`, { document });
  assert.equal(result.counts.frames, 1);
  assert.equal(result.counts.openShadowRoots, 1);
  assert.equal(result.components.AudioRow, 2);
  assert.equal(result.components.track_item, 1);
  assert.equal(JSON.stringify(result).includes('abcdef'), false);
  assert.equal(JSON.stringify(result).includes('123456'), false);
});

test('structural report drops unexpected fields, identifiers, URLs, and out-of-range counts', () => {
  const result = sanitizeMusicStructure({ counts: { frames: 1, cookie: 'synthetic',
    audioElements: -1, trackIds: Infinity }, components: {
    AudioRow: 3, 'https://synthetic.test/track': 1, track12345: 2,
    password: 2, MusicList: 'synthetic',
  }, html: 'SYNTHETIC_PRIVATE' });
  assert.deepEqual(result, { counts: { frames: 1 }, components: { AudioRow: 3 } });
});

test('login form prevents structural diagnosis as well as extraction', async () => {
  const result = await vm.runInNewContext(`(${readMusicPage.toString()})(() => {
    throw new Error('Inspected login structure');
  })`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => ({}), querySelectorAll: () => {
      throw new Error('Inspected login page');
    } },
  });
  assert.equal(typeof result.error, 'string');
  assert.equal(result.structure, undefined);
});

function modernRow(id, fields = {}) {
  const markers = { MusicTrackRow_Title: fields.title, MusicTrackRow_Authors: fields.artist,
    MusicTrackRow_Duration: fields.duration };
  return {
    getAttribute: (name) => { assert.equal(name, 'data-audio-id'); return id; },
    contains: () => false,
    querySelector: (selector) => {
      const match = /^\[data-testid="([A-Za-z_]+)"\]$/.exec(selector);
      assert.ok(match, 'Only explicit music text markers may be read');
      return markers[match[1]] === undefined ? null : { tagName: 'SPAN', textContent: markers[match[1]] };
    },
  };
}

test('modern music cells import displayed metadata without React or old attributes', async () => {
  const result = await readSyntheticRows([], undefined, [modernRow('1_2', {
    title: 'Song', artist: 'Artist', duration: '3:05',
  })]);
  assert.equal(result.tracks.length, 1);
  assert.equal(result.tracks[0].id, '1_2');
  assert.equal(result.tracks[0].duration, 185);
  assert.equal(result.tracks[0].url, '');
  assert.equal(result.diagnostics.modernDOMMetadata, 1);
});

test('modern row component audio props supply links without reading hook or session state', async () => {
  const row = modernRow('1_2');
  const audio = { id: 2, owner_id: 1, title: 'Song', performer: 'Artist', duration: 180,
    url: payload().tracks[0].url };
  const fail = () => { throw new Error('Session or hook state read'); };
  Object.defineProperty(audio, 'token', { get: fail });
  const props = { audio };
  Object.defineProperty(props, 'session', { get: fail });
  row.__reactFiber$synthetic = { memoizedProps: { children: null }, return:
    Object.defineProperties({ memoizedProps: props }, {
      memoizedState: { get: fail }, return: { get: fail },
    }) };
  const result = await readSyntheticRows([], undefined, [row]);
  assert.equal(result.tracks[0].url, payload().tracks[0].url);
  assert.equal(result.diagnostics.modernAudioMatched, 1);
  assert.equal(result.diagnostics.modernURLsFound, 1);
});

test('modern row ignores mismatched track props and rejects malformed DOM identifiers', async () => {
  const row = modernRow('1_2', { title: 'Song', artist: 'Artist', duration: '2:00' });
  row.__reactProps$synthetic = { audio: { id: 99, owner_id: 1,
    title: 'Other', artist: 'Other', duration: 999, url: payload().tracks[0].url } };
  const result = await readSyntheticRows([], undefined, [row, modernRow('SYNTHETIC_NOT_A_TRACK')]);
  assert.equal(result.tracks.length, 1);
  assert.equal(result.tracks[0].title, 'Song');
  assert.equal(result.tracks[0].url, '');
  assert.equal(result.diagnostics.modernInvalidRows, 1);
});

async function timingAction(action, since, entries, overrides = {}) {
  return vm.runInNewContext(`(${musicPageAction.toString()})(${JSON.stringify(action)},'',{since:boundary})`, {
    boundary: since, URL,
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => null },
    performance: { now: () => 100, getEntriesByType: () => entries,
      setResourceTimingBufferSize: size => assert.equal(size, 4096) }, ...overrides,
  });
}

test('timing capture includes approved cache hits and rejects old or malformed witnesses', async () => {
  const boundary = await timingAction('begin-audio-capture', undefined, Array(250).fill({}));
  assert.equal(boundary.since, 100);
  assert.equal(boundary.timingEntriesBefore, 250);
  const good = 'https://test.vkuseraudio.net/song.m3u8';
  const urls = [good, good, 'https://test.useraudio.com/other.mp3',
    'http://test.vkuseraudio.net/song.mp3', 'https://vkuseraudio.net.attacker.test/song.mp3',
    'https://user:pass@test.vkuseraudio.net/song.mp3', 'https://test.vkuseraudio.net:8443/song.mp3',
    'https://test.vkuseraudio.net/image.png', 'not-a-url'];
  const result = await timingAction('audio-resources', 100, [
    {name: 'https://test.vkuseraudio.net/old.mp3', startTime: 99},
    ...[undefined, NaN, Infinity, -Infinity, '101'].map(startTime => ({name:good, startTime})),
    ...urls.map(name => ({name, startTime:100})),
  ]);
  assert.deepEqual(Array.from(result.urls), [good, urls[2]]);
  for (const boundary of [undefined, NaN, Infinity, -1, '100']) {
    assert.equal(typeof (await timingAction('audio-resources', boundary, [])).error, 'string');
  }
  const capped = await timingAction('audio-resources', 0,
    Array.from({length:40}, (_, i) => ({name:`https://test.vkuseraudio.net/${i}.mp3`,startTime:1})));
  assert.equal(capped.urls.length, 32);
});

test('timing actions stop before performance access on login routes or forms', async () => {
  const performance = new Proxy({}, {get() {throw new Error('Timing read on login');}});
  for (const action of ['begin-audio-capture', 'audio-resources']) {
    assert.equal(typeof (await timingAction(action, 0, [], {performance,
      location:{protocol:'https:',hostname:'vk.ru',pathname:'/login'},
      document:new Proxy({}, {get(){throw new Error('Login DOM read');}})})).error, 'string');
    const field = Object.defineProperty({}, 'value', {get(){throw new Error('Field value read');}});
    assert.equal(typeof (await timingAction(action, 0, [], {performance,
      document:{querySelector:()=>field}})).error, 'string');
  }
});

test('trusted activation rechecks the exact track and original playback area', async () => {
  let obscured = false;
  const controls = {disabled:false, contains:hit=>hit===controls,
    getBoundingClientRect:()=>({left:0,top:0,width:100,height:60}),
    closest:selector=>selector==='[data-audio-id]'?row:null};
  const row = {getAttribute:()=> '1_2', querySelector:()=>controls};
  const run = (x=50, y=30, id='1_2') => vm.runInNewContext(
    `(${musicPageAction.toString()})('verify-play-hit',id,{x,y})`, {
      id,x,y, location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},
      window:{innerWidth:200,innerHeight:200}, document:{querySelector:()=>null,
        querySelectorAll:()=>[row], elementFromPoint:()=>obscured?null:controls},
    });
  assert.equal((await run()).ok,true);
  for(const [x,y,id] of [[150,30,'1_2'],[NaN,30,'1_2'],[50,30,'1_3']]) {
    assert.equal(typeof (await run(x,y,id)).error,'string');
  }
  obscured = true;
  assert.equal(typeof (await run()).error,'string');
});


test('segment timing witnesses retain the boundary, destination guard and a separate cap', async () => {
  const exact = 'https://test.vkuseraudio.net/selected.ts?key=fixture';
  const result = await timingAction('audio-resources', 100, [
    {name:exact,startTime:99}, {name:exact,startTime:101},
    {name:'https://attacker.test/selected.ts',startTime:101},
    {name:'https://test.vkuseraudio.net/not-music.png',startTime:101},
    ...Array.from({length:70},(_,i)=>({name:`https://test.vkuseraudio.net/${i}.m4s`,startTime:101})),
  ]);
  assert.equal(result.urls.length,0);
  assert.equal(result.segments.length,64);
  assert.equal(result.segments[0],exact);
});

test('playback state projects only recognized controls within the requested row', async () => {
  let icon = 'vkuiIcon--pause_24';
  const svg = {tagName:'svg',getAttribute:()=>null,get classList(){return [icon];}};
  Object.defineProperty(svg,'value',{get(){throw Error('Field read');}});
  const region = {tagName:'DIV',getAttribute:()=>null,querySelectorAll:s=>s==='*'?[svg]:[]};
  const row = {getAttribute:()=> '1_2',querySelector:()=>region};
  const run = () => vm.runInNewContext(`(${musicPageAction.toString()})('probe-playback','1_2')`, {
    location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},
    document:{querySelector:()=>null,querySelectorAll:s=>s==='[data-audio-id]'?[row]:[]},
  });
  let result = await run();
  assert.equal(result.counts.playingControls,1);assert.equal(result.counts.pausedControls,0);
  icon = 'vkuiIcon--play_24';result = await run();
  assert.equal(result.counts.playingControls,0);assert.equal(result.counts.pausedControls,1);
  icon = 'unrecognized';result = await run();
  assert.equal(result.counts.playingControls,0);assert.equal(result.counts.pausedControls,0);
});

test('native input targets the visible Play button rather than its surrounding container', async () => {
  const rect = {left:70,top:10,width:20,height:20};
  let preferred;
  const row = {getAttribute:()=> '1_2',querySelector:s=>s==='[data-testid="MusicTrackRow_PlaybackControls"]'?region:preferred};
  const button = {tagName:'BUTTON',getBoundingClientRect:()=>rect,scrollIntoView:()=>{},
    closest:s=>s==='[data-audio-id]'?row:null,contains:e=>e===button};
  const region = {getBoundingClientRect:()=>({left:0,top:0,width:100,height:40}),querySelectorAll:()=>[button]};
  preferred = {tagName:'DIV',getBoundingClientRect:region.getBoundingClientRect};
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('play-position','1_2')`, {
    location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},
    window:{innerWidth:200,innerHeight:200},setTimeout:f=>f(),
    document:{querySelector:()=>null,querySelectorAll:()=>[row],elementFromPoint:()=>button},
  });
  assert.equal(result.position.x,80);assert.equal(result.position.y,20);
});


// A selected VK track can use the vkuseraudio.ru CDN as well as .net.
test('VK audio CDN is accepted without permitting lookalikes or unsafe authorities', async () => {
  assert.ok(mediaURL('https://music.vkuseraudio.ru/audio/index.m3u8'));
  for (const url of ['https://vkuseraudio.ru.attacker.test/audio.mp3',
      'https://notvkuseraudio.ru/audio.mp3', 'http://music.vkuseraudio.ru/audio.mp3',
      'https://user:secret@music.vkuseraudio.ru/audio.mp3',
      'https://music.vkuseraudio.ru:8443/audio.mp3']) assert.throws(() => mediaURL(url));
  const result = await timingAction('audio-resources', 100, [
    {name:'https://music.vkuseraudio.ru/audio/index.m3u8',startTime:101},
    {name:'https://music.vkuseraudio.ru/audio/one.ts',startTime:102},
    {name:'https://vkuseraudio.ru.attacker.test/audio/index.m3u8',startTime:103},
  ]);
  assert.equal(result.urls.length,1);assert.equal(result.segments.length,1);
});

test('named nested API audio survives an intervening music wrapper without store traversal', async () => {
  for (const wrapper of ['entity', 'data']) {
    const row = modernRow('1_2');
    const audio = {id:2,owner_id:1,title:'Generated',artist:'Generated',duration:180,
      url:'https://music.vkuseraudio.net/selected.mp3'};
    const fail = () => { throw Error('Non-music state read'); };
    const music = {[wrapper]:{apiAudio:audio}};
    Object.defineProperty(music,'store',{get:fail});
    const host = {nodeType:1,tagName:'DIV',contains:item=>item===row};
    row.__reactFiber$synthetic = {memoizedProps:{},return:{stateNode:host,memoizedProps:{},return:
      Object.defineProperties({memoizedProps:{track:music}}, {memoizedState:{get:fail},return:{get:fail}})}};
    const result = await readSyntheticRows([], undefined, [row]);
    assert.equal(result.tracks[0].url,audio.url);
    assert.equal(result.diagnostics.modernAudioMatched,1);
  }
});

test('only an explicitly selected empty music row refreshes its source', async () => {
  const row = [2,1,'','Generated','Generated',180];row[24]='generated_music_key';
  let calls = 0;
  const fetch = async (path, options) => {
    calls++;assert.equal(path,'/al_audio.php');assert.equal(options.credentials,'same-origin');assert.equal(options.redirect,'error');
    assert.equal(options.body.get('act'),'reload_audio');assert.equal(options.body.get('ids'),'1_2');
    return {ok:true,headers:{get:()=> 'application/json'},text:async()=>JSON.stringify({payload:[0,[[[2,1,'https://music.vkuseraudio.ru/selected.mp3','Generated','Generated',180]]]]})};
  };
  const listing = await readSyntheticRows([row], fetch, [], {metadataOnly:true});
  assert.equal(calls,0);assert.equal(listing.tracks[0].url,'');
  const selected = await readSyntheticRows([row], fetch, [], {metadataOnly:true,targetId:'1_2',resolveTarget:true});
  assert.equal(calls,1);assert.equal(selected.tracks[0].url,'https://music.vkuseraudio.ru/selected.mp3');
  assert.equal(selected.diagnostics.targetReloadMatched,1);
  assert.equal(JSON.stringify(selected).includes('generated_music_key'),false);
});
test('selected music refresh rejects non-music content before reading its body', async () => {
  const row = [2,1,'','Generated','Generated',180];
  const result = await readSyntheticRows([row], async()=>({ok:true,headers:{get:()=> 'text/html'},text:()=>{throw Error('Non-music response read');}}), [], {metadataOnly:true,targetId:'1_2',resolveTarget:true});
  assert.equal(result.resolutionFailed,true);assert.equal(result.tracks[0].url,'');
});

test('selected music reference resolves without scrolling or reading account state', async () => {
  let requested = 0;
  const invoke = (id, form=false) => vm.runInNewContext(`(${musicPageAction.toString()})('resolve-reference',${JSON.stringify(id)})`, {
    location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},
    document:{querySelector:()=>form?{}:null,querySelectorAll:()=>{throw Error('Unexpected DOM traversal');}},
    fetch:async (path,options)=>{
      requested++;assert.equal(path,'/al_audio.php');assert.equal(options.credentials,'same-origin');assert.equal(options.redirect,'error');
      assert.equal(options.body.get('act'),'reload_audio');assert.equal(options.body.get('ids'),id);
      return {ok:true,headers:{get:()=> 'application/json'},text:async()=>JSON.stringify({payload:[0,[[[2,1,'https://music.vkuseraudio.ru/selected.mp3','Generated','Generated',180]]]]})};
    },URLSearchParams,AbortSignal,window:{vk:{id:1}},navigator:{userAgent:'Generated'},
  });
  const matching = await invoke('1_2');assert.equal(matching.counts.matched,1);assert.ok(matching.source.endsWith('/selected.mp3'));
  const wrong = await invoke('1_3');assert.equal(wrong.counts.matched,0);assert.equal(wrong.source,'');
  await invoke('1_2',true);assert.equal(requested,2);
});

test('music references are projected only for the app metadata path', async () => {
  const row = modernRow('1_2');
  row.__reactProps$synthetic={track:{entity:{apiAudio:{id:2,owner_id:1,title:'Generated',artist:'Generated',duration:180,url:'',access_key:'generated_track_reference'}}}};
  const normal=await readSyntheticRows([],undefined,[row],{metadataOnly:true});
  assert.equal(normal.musicReferences,undefined);assert.equal(JSON.stringify(normal).includes('generated_track_reference'),false);
  const metadata=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeReferences:true});
  assert.equal(metadata.musicReferences.length,0);
  row.__reactProps$synthetic.track.entity.apiAudio.actionHash='generated_action';
  row.__reactProps$synthetic.track.entity.apiAudio.urlHash='generated_url';
  const legacy=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeReferences:true});
  assert.equal(legacy.musicReferences[0].musicKey,'r1_generated_action_generated_url');
});

test('selected music response accepts bounded array wrappers but never mismatched audio', async () => {
  const row=[2,1,'https://music.vkuseraudio.ru/selected.mp3','Generated','Generated',180];
  for (const batch of [[[row]], [row], [[[row]]], [{audios:[row]}]]) {
    const result=await vm.runInNewContext(`(${musicPageAction.toString()})('resolve-reference','1_2')`,{
      location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},document:{querySelector:()=>null},
      fetch:async()=>({ok:true,headers:{get:()=> 'application/json'},text:async()=>JSON.stringify({payload:[0,batch]})}),
      URLSearchParams,AbortSignal,window:{vk:{id:1}},navigator:{userAgent:'Generated'},
    });
    assert.equal(result.counts.matched,1);assert.equal(result.source,row[2]);
  }
});

test('music search writes only the recognized music input without reading its value', async () => {
  let written,events=0;
  function Input() {}
  Object.defineProperty(Input.prototype,'value',{set:value=>{written=value;},get:()=>{throw Error('Input value read');}});
  const input={getAttribute:name=>name==='placeholder'?'Search music':name==='type'?'search':null,dispatchEvent:()=>events++};
  const result=await vm.runInNewContext(`(${musicPageAction.toString()})('search-track','1_2',{musicQuery:'Generated song'})`,{
    location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},document:{querySelector:()=>null,querySelectorAll:()=>[input]},
    HTMLInputElement:Input,Event:class{},
  });
  assert.equal(result.searched,true);assert.equal(written,'Generated song');assert.equal(events,2);
});


test('music search rejects sign-in, duplicate controls and a generic header without field reads', async () => {
  let writes=0;
  function Input() {}
  Object.defineProperty(Input.prototype,'value',{set:()=>writes++,get:()=>{throw Error('Field value read');}});
  const input=label=>({getAttribute:name=>name==='placeholder'?label:name==='type'?'search':null,dispatchEvent(){}});
  const invoke=(inputs,form=false)=>vm.runInNewContext(`(${musicPageAction.toString()})('search-track','1_2',{musicQuery:'Generated'})`,{
    location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},
    document:{querySelector:()=>form?{}:null,querySelectorAll:()=>{if(form)throw Error('Sign-in fields traversed');return inputs;}},
    HTMLInputElement:Input,Event:class{},
  });
  assert.ok((await invoke([input('Search music')],true)).error);
  assert.ok((await invoke([input('Search music'),input('Search music')])).error);
  assert.ok((await invoke([input('Search')])).error);
  assert.equal(writes,0);
});


test('an unavailable music row is explicit and does not mark another track unavailable', async () => {
  const blocked=modernRow('1_2'), playable=modernRow('1_3');
  blocked.__reactProps$generated={track:{entity:{apiAudio:{id:2,owner_id:1,title:'Generated blocked',artist:'Fixture',duration:180,content_restricted:1,content_restricted_message:'Restricted by rights holder',url:''}}}};
  playable.__reactProps$generated={track:{entity:{apiAudio:{id:3,owner_id:1,title:'Generated playable',artist:'Fixture',duration:180,is_available:true,url:'https://music.vkuseraudio.ru/generated.mp3'}}}};
  const result=await readSyntheticRows([],undefined,[blocked,playable],{metadataOnly:true,includeAvailability:true});
  assert.equal(result.tracks.find(track=>track.id==='1_2').unavailable,true);
  assert.equal(result.tracks.find(track=>track.id==='1_3').unavailable,false);
});


test('advisory capability flags do not reject an exact audio source or claim a provider restriction', async () => {
  const row=modernRow('1_2');
  row.__reactProps$generated={track:{entity:{apiAudio:{id:2,owner_id:1,title:'Generated',artist:'Fixture',duration:180,is_available:false,is_blocked:true,url:'https://music.vkuseraudio.ru/generated.mp3'}}}};
  const result=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeAvailability:true});
  assert.equal(result.tracks[0].unavailable,false);
  assert.equal(result.tracks[0].availabilityHints.availableFalse,true);
  assert.equal(result.tracks[0].restrictionReason,null);
  assert.ok(result.tracks[0].url.endsWith('/generated.mp3'));
});

test('restriction text produces only fixed categories, never the original message', async () => {
  for (const [message,expected] of [['Restricted by rights holder','copyright'],['Not available in your country','region'],['Subscription required','subscription'],['Age 18+','age'],['Unknown provider message generated_private_marker','unknown']]) {
    const row=modernRow('1_2');
    row.__reactProps$generated={track:{entity:{apiAudio:{id:2,owner_id:1,title:'Generated',artist:'Fixture',duration:180,content_restricted:1,content_restricted_message:message,url:''}}}};
    const result=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeAvailability:true});
    assert.equal(result.tracks[0].restrictionReason,expected);
    assert.equal(JSON.stringify(result).includes(message),false);
  }
});

test('an explicitly disabled exact-row Play control cannot be activated', async () => {
  let clicked=false;
  const button={disabled:true,click:()=>clicked=true};
  const row={getAttribute:name=>name==='data-audio-id'?'1_2':null,querySelector:()=>button};
  const result=await vm.runInNewContext(`(${musicPageAction.toString()})('play','1_2')`,{
    location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},document:{querySelector:()=>null,querySelectorAll:()=>[row]},
  });
  assert.equal(result.blocked,true);assert.equal(clicked,false);
});


test('old music age evidence exports a bucket, not the original date or unrelated fields', async () => {
  for (const [date,bucket] of [[1230768000,'before2010'],[1325376000,'2010to2014'],[1514764800,'2015to2019'],[1640995200,'2020plus'],[4102444800,'unknown'],[0,'unknown']]) {
    const row=modernRow('1_2');
    row.__reactProps$generated={track:{entity:{apiAudio:{id:2,owner_id:1,title:'Generated',artist:'Fixture',duration:180,date,url:''}}}};
    const result=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeAvailability:true});
    assert.equal(result.tracks[0].musicAgeBucket,bucket);
    assert.equal(Object.hasOwn(result.tracks[0],'date'),false);
    if(date>0)assert.equal(JSON.stringify(result).includes(String(date)),false);
  }
});

test('optional enrichment projects exact music fields and keeps upload date distinct from added date', async () => {
  const row=modernRow('1_2');
  const audio={id:2,owner_id:1,title:'Generated',artist:'Fixture',duration:180,date:1514764800,
    subtitle:'Live',is_explicit:true,main_artists:[{name:'Generated artist'}],
    album:{title:'Generated album',thumb:{photo_300:'https://test.userapi.com/generated.jpg'}},
    lyrics:{text:'Generated first line\nGenerated second line',lines:[{time_ms:0,text:'Generated first line'},{time_ms:1200,text:'Generated second line'}]}};
  Object.defineProperty(audio,'token',{get(){throw new Error('Inspected credential');}});
  row.__reactProps$generated={track:{entity:{apiAudio:audio}}};
  const options={metadataOnly:true,includeMetadata:true,includeLyrics:true,targetId:'1_2'};
  const result=await readSyntheticRows([],undefined,[row],options);
  const data=result.tracks[0].enrichment;
  assert.equal(data.album,'Generated album');assert.equal(data.subtitle,'Live');
  assert.equal(data.uploadedAt,1514764800);assert.equal(data.vkAddedAt,undefined);
  assert.equal(data.explicit,true);assert.equal(data.artworkURL,'https://test.userapi.com/generated.jpg');
  assert.equal(data.lyrics.text,audio.lyrics.text);assert.equal(data.lyrics.lines[1].time_ms,1200);
  const oldContract=await readSyntheticRows([],undefined,[row],{metadataOnly:true});
  assert.equal(oldContract.tracks[0].enrichment,undefined);
});

test('enrichment rejects unrelated recording props and unsafe artwork destinations', async () => {
  const row=modernRow('1_2',{title:'Generated',artist:'Fixture',duration:'3:00'});
  row.__reactProps$generated={audio:{id:99,owner_id:1,title:'Other',artist:'Other',duration:180,album:{title:'Wrong album',thumb:{photo_300:'https://test.userapi.com/other.jpg'}}}};
  let result=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeMetadata:true});
  assert.equal(result.tracks[0].enrichment.album,undefined);
  for(const url of ['https://userapi.com.attacker.test/image.jpg','http://test.userapi.com/a.jpg','https://user:pass@test.userapi.com/a.jpg','https://test.userapi.com:8443/a.jpg']) {
    row.__reactProps$generated={audio:{id:2,owner_id:1,title:'Generated',artist:'Fixture',duration:180,album:{thumb:{photo_300:url}}}};
    result=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeMetadata:true});
    assert.equal(result.tracks[0].enrichment.artworkURL,undefined);
  }
});

test('missing or advertised lyrics are not falsely reported as supplied text', async () => {
  const row=modernRow('1_2');
  row.__reactProps$generated={audio:{id:2,owner_id:1,title:'Generated',artist:'Fixture',duration:180,has_lyrics:true,lyrics_id:123}};
  const result=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeMetadata:true});
  assert.equal(result.tracks[0].enrichment.lyricsAvailable,true);
  assert.equal(result.tracks[0].enrichment.lyricsId,123);
  assert.equal(result.tracks[0].enrichment.lyrics,undefined);
});

test('background metadata never exports inline lyrics for an entire library page', async () => {
  const row=modernRow('1_2');
  row.__reactProps$generated={audio:{id:2,owner_id:1,title:'Generated',artist:'Fixture',duration:180,lyrics:{text:'Generated lyrics'}}};
  const result=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeMetadata:true});
  assert.equal(result.tracks[0].enrichment.lyrics,undefined);
  assert.equal(result.tracks[0].enrichment.lyricsAvailable,true);
});

test('album artwork supports a bounded 270-pixel music thumbnail', async () => {
  const row=modernRow('1_2');
  row.__reactProps$generated={audio:{id:2,owner_id:1,title:'Generated',artist:'Fixture',duration:180,album:{thumb:{photo_270:'https://test.userapi.com/generated.jpg'}}}};
  const result=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeMetadata:true});
  assert.equal(result.tracks[0].enrichment.artworkURL,'https://test.userapi.com/generated.jpg');
});

test('VK photo CDN artwork remains scoped to exact music metadata and rejects lookalikes', async () => {
  for(const [url,accepted] of [['https://sun1.vkuserphoto.ru/generated.jpg',true],['https://sun1.vkuserphoto.ru.attacker.test/generated.jpg',false]]) {
    const row=modernRow('1_2');row.__reactProps$generated={audio:{id:2,owner_id:1,title:'Generated',artist:'Fixture',duration:180,thumb:{photo_300:url}}};
    row.querySelectorAll=()=>[{getAttribute:name=>name==='aria-label'?'Show lyrics':null}];
    const result=await readSyntheticRows([],undefined,[row],{metadataOnly:true,includeMetadata:true});
    assert.equal(!!result.tracks[0].enrichment.artworkURL,accepted);
    assert.equal(result.diagnostics.metadataShape.lyricsButtons,1);
    if(accepted) assert.equal(result.diagnostics.metadataShape.imageVkuserphoto,1);
  }
});

test('lyrics control positioning is bound to the exact music row and never activates Play',async()=>{
  const button={disabled:false,getAttribute:name=>name==='aria-label'?'Show lyrics':null,getBoundingClientRect:()=>({left:20,top:20,width:20,height:20}),scrollIntoView(){},contains:()=>true};
  const row={getAttribute:name=>name==='data-audio-id'?'1_2':null,querySelectorAll:()=>[button],querySelector:()=>({textContent:'Generated'}),getBoundingClientRect:()=>({left:0,top:0,width:200,height:60}),scrollIntoView(){}};
  const context={location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},window:{innerWidth:800,innerHeight:600},document:{querySelector:()=>null,querySelectorAll:s=>s==='[data-audio-id]'?[row]:[],elementFromPoint:()=>button},setTimeout:fn=>fn()};
  const result=await vm.runInNewContext(`(${musicPageAction.toString()})('lyrics-position','1_2')`,context);
  assert.deepEqual(JSON.parse(JSON.stringify(result.position)),{x:30,y:30});
  const wrong=await vm.runInNewContext(`(${musicPageAction.toString()})('lyrics-position','1_99')`,context);
  assert.ok(wrong.error);
});

test('lyrics dialog text from another recording cannot be imported',async()=>{
  const dialog={getAttribute:name=>name==='data-audio-id'?'1_99':null,querySelector:()=>({textContent:'Wrong lyrics'})};
  const context={location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},window:{__ownsembleLyricsRequest:{id:'1_2',at:Date.now(),title:'Generated'}},document:{querySelector:()=>null,querySelectorAll:()=>[dialog]}};
  const result=await vm.runInNewContext(`(${musicPageAction.toString()})('read-lyrics','1_2')`,context);
  assert.equal(result.lyrics,undefined);
});

test('a recently requested exact-recording lyrics dialog supplies plain text only',async()=>{
  const dialog={getAttribute:name=>name==='data-audio-id'?'1_2':null,querySelector:()=>({textContent:'Generated lyrics'})};
  const result=await vm.runInNewContext(`(${musicPageAction.toString()})('read-lyrics','1_2')`,{
    location:{protocol:'https:',hostname:'vk.ru',pathname:'/audio'},window:{__ownsembleLyricsRequest:{id:'1_2',at:Date.now(),title:'Generated'}},
    document:{querySelector:()=>null,querySelectorAll:()=>[dialog]},
  });
  assert.equal(result.lyrics.text,'Generated lyrics');
});
