const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { validateImport, mediaURL, isMusicURL } = require('./music-policy.cjs');
const { readMusicPage } = require('./music-page.cjs');
const { inspectMusicDOM, sanitizeMusicStructure } = require('./music-dom.cjs');

const payload = () => ({ userId: 1, userAgent: 'test', tracks: [
  { id: '1_2', artist: 'Artist', title: 'Song', duration: 180, url: 'https://test.vkuseraudio.net/song.mp3' },
] });

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

async function readSyntheticRows(values, fetch = () => { throw new Error('Unexpected request'); }, modernRows = []) {
  const rows = values.map((value) => ({ getAttribute(name) {
    assert.equal(name, 'data-audio');
    return typeof value === 'string' ? value : JSON.stringify(value);
  } }));
  return vm.runInNewContext(`(${readMusicPage.toString()})()`, {
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
    fetch, URLSearchParams, AbortSignal,
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
