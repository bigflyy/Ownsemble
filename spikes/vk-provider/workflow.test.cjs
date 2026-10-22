const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { mergeLibrary, scanLibrary } = require('./library-sync.cjs');
const { musicPageAction } = require('./music-action.cjs');
const { audioCandidate, selectNativeSource } = require('./native-source.cjs');
const { validateImport } = require('./music-policy.cjs');
const track = (index) => ({ id: `1_${index}`, title: `Synthetic ${index}`, artist: 'Artist', duration: 180, url: '' });
const page = (tracks) => ({ tracks, userId: 1, userAgent: 'synthetic' });
const noop = async () => {};

test('virtualized pagination retains earlier viewports and discovers more than thirty tracks', async () => {
  let viewport = 0;
  const result = await scanLibrary({ reset: noop,
    read: async () => page(Array.from({ length: 20 }, (_, index) => track(viewport * 20 + index + 1))),
    advance: async () => { viewport = Math.min(2, viewport + 1); }, idlePages: 2 });
  assert.equal(result.tracks.length, 60);
  assert.equal(new Set(result.tracks.map((item) => item.id)).size, 60);
  assert.equal(result.stopReason, 'no_new_rows');
  assert.equal(result.complete, false);
});
test('scan respects page budgets and never claims completeness after stalled loading', async () => {
  let index = 0;
  const result = await scanLibrary({ reset: noop, advance: noop, maxPages: 3,
    read: async () => page([track(++index)]) });
  assert.equal(result.tracks.length, 3);
  assert.equal(result.stopReason, 'page_budget');
  assert.equal(result.complete, false);
});
test('pagination reports idle state so a stalled provider can retry and discover later rows', async () => {
  let recovered = false;
  const progress = [];
  const result = await scanLibrary({ reset: noop, idlePages: 3,
    read: async () => page(recovered ? [track(1), track(2)] : [track(1)]),
    advance: async ({ idle, pages, count }) => {
      progress.push({ idle, pages, count });
      if (idle === 2) recovered = true;
    } });
  assert.equal(result.tracks.length, 2);
  assert.ok(progress.some(({ idle }) => idle === 2));
  assert.equal(result.complete, false);
});
test('slow data arrival resets the quiet deadline instead of ending after a few unchanged reads', async () => {
  let time = 0;
  const result = await scanLibrary({ reset: noop, idlePages: 2, idleTimeoutMs: 60000,
    now: () => time, read: async () => page(time < 50000 ? [track(1)] : [track(1), track(2)]),
    advance: async () => { time += 10000; } });
  assert.equal(result.tracks.length, 2);
  assert.equal(result.stopReason, 'no_new_rows');
  assert.ok(time >= 110000);
  assert.equal(result.complete, false);
});
test('a stuck loading indicator ends at a time budget and retains partial data', async () => {
  let time = 0;
  const result = await scanLibrary({ reset: noop, idlePages: 2, maxDurationMs: 30000,
    now: () => time, read: async () => page([track(1)]),
    advance: async () => { time += 10000; return { loading: true }; } });
  assert.equal(result.stopReason, 'time_budget');
  assert.equal(result.tracks.length, 1);
  assert.equal(result.complete, false);
});
test('incremental sync refreshes additions without losing older tracks', async () => {
  const result = await scanLibrary({ reset: noop, advance: noop, incremental: true,
    read: async () => page([track(3), { ...track(1), title: 'Updated' }]) });
  const library = mergeLibrary([track(1), track(2)], result.tracks);
  assert.deepEqual(library.map((item) => item.id), ['1_3', '1_1', '1_2']);
  assert.equal(library[1].title, 'Updated');
  assert.equal(result.stopReason, 'incremental');
});
test('partial scans, duplicates and empty scans cannot delete the existing library', () => {
  const existing = [track(1), track(2), track(3)];
  assert.deepEqual(mergeLibrary(existing, []), existing);
  assert.equal(mergeLibrary(existing, [track(1), track(1)]).length, 3);
});
test('disable request stops a running scan at its next boundary', async () => {
  let cancelled = false;
  const result = await scanLibrary({ reset: noop, shouldStop: () => cancelled,
    read: async () => page([track(1)]), advance: async () => { cancelled = true; } });
  assert.equal(result.stopReason, 'cancelled');
  assert.equal(result.tracks.length, 1);
});
test('sign-in interruption stops pagination instead of publishing an empty replacement', async () => {
  await assert.rejects(scanLibrary({ reset: noop, advance: noop,
    read: async () => ({ error: 'Sign-in is required.' }) }), /Sign-in/);
});
test('large metadata payloads pass validation beyond the old sample cap', () => {
  const payload = { tracks: Array.from({ length: 1500 }, (_, index) => track(index + 1)), userId: 1, userAgent: 'synthetic' };
  assert.equal(validateImport(payload), payload);
});
test('native resolution allows audio CDNs but excludes auth endpoints and individual segments', () => {
  assert.ok(audioCandidate('https://test.vkuseraudio.net/a/index.m3u8?synthetic=1'));
  for (const url of ['https://id.vk.com/auth', 'https://test.vkuseraudio.net/a/segment.ts',
    'https://attacker.test/music.mp3', 'file:///song.mp3']) assert.equal(audioCandidate(url), null);
});
test('native resolution deduplicates identical requests and rejects competing sources', () => {
  const first = 'https://test.vkuseraudio.net/one.mp3';
  const second = 'https://test.vkuseraudio.net/two.mp3';
  assert.equal(selectNativeSource([first, first]), first);
  assert.throws(() => selectNativeSource([first, second]), /ambiguous/);
  assert.throws(() => selectNativeSource([]), /did not expose/);
});
test('native source errors never include temporary audio URLs', () => {
  const privateURL = 'https://test.vkuseraudio.net/one.mp3?synthetic_private=123';
  try { selectNativeSource([privateURL, 'https://test.vkuseraudio.net/two.mp3']); }
  catch (error) { assert.equal(error.message.includes('synthetic_private'), false); }
});
test('native music action refuses login pages before DOM access', async () => {
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('play', '1_2')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/login' },
    document: new Proxy({}, { get() { throw new Error('Login DOM accessed'); } }) });
  assert.ok(result.error);
});
test('pagination diagnostics inspect only music ancestors and return numeric geometry', async () => {
  const parent = { scrollHeight: 2000, clientHeight: 600, parentElement: null };
  const row = { parentElement: parent };
  Object.defineProperty(row, 'textContent', { get() { throw new Error('Track text read'); } });
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('probe-pagination')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    getComputedStyle: () => ({ overflowY: 'auto' }),
    document: { querySelector: () => null, querySelectorAll: () => [row], visibilityState: 'visible',
      scrollingElement: { scrollHeight: 4000, clientHeight: 800, scrollTop: 3200 } },
  });
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { counts: {
    documentScrollHeight: 4000, documentClientHeight: 800, documentScrollTop: 3200,
    scrollableMusicAncestors: 1, visibleDocument: 1 } });
});
test('pagination diagnostics reject a sign-in form before examining music rows', async () => {
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('probe-pagination')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => ({}), querySelectorAll: () => { throw new Error('Sign-in DOM examined'); } },
  });
  assert.ok(result.error);
});
test('stalled pagination leaves and re-enters the loading region without clicking controls', async () => {
  const actions = [];
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('retry-pagination')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    setTimeout: (callback) => callback(),
    window: { innerHeight: 800, scrollBy: (x, y) => actions.push([x, y]) },
    document: { querySelector: () => null, querySelectorAll: () => [{
      scrollIntoView: ({ block }) => actions.push(block),
      click: () => { throw new Error('Pagination clicked a control'); },
    }] },
  });
  assert.equal(result.ok, true);
  assert.deepEqual(actions, [[0, -800], 'end', [0, 800]]);
});
test('pagination wakes on a new identity even when a virtualized list keeps the same row count', async () => {
  let callback, disconnected = 0;
  const row = (id) => ({ getAttribute: (name) => name === 'data-audio-id' ? id : null,
    scrollIntoView() {}, get textContent() { throw new Error('Track text read'); } });
  let rows = [row('1_1')];
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('advance', '', {waitMs: 1000})`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' }, setTimeout, clearTimeout,
    MutationObserver: class {
      constructor(changed) { callback = changed; }
      observe() {}
      disconnect() { disconnected++; }
    },
    window: { innerHeight: 800, scrollBy() { queueMicrotask(() => { rows = [row('1_2')]; callback(); }); } },
    document: { body: {}, querySelector: () => null, querySelectorAll: () => rows },
  });
  assert.equal(result.progressed, true);
  assert.ok(disconnected > 0);
});
test('pagination aborts when a sign-in form appears while waiting, without reading fields', async () => {
  let callback, login = false;
  const field = { get value() { throw new Error('Sign-in value read'); } };
  const row = { getAttribute: () => '1_1', scrollIntoView() {} };
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('advance', '', {waitMs: 1000})`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' }, setTimeout, clearTimeout,
    MutationObserver: class { constructor(changed) { callback = changed; } observe() {} disconnect() {} },
    window: { innerHeight: 800, scrollBy() { queueMicrotask(() => { login = true; callback(); }); } },
    document: { body: {}, querySelector: () => login ? field : null,
      querySelectorAll: () => { if (login) throw new Error('Music queried after sign-in'); return [row]; } },
  });
  assert.match(result.error, /Sign-in/);
});
test('an unchanged loading page returns a bounded pending result rather than claiming completion', async () => {
  let disconnected = false;
  const row = { getAttribute: () => '1_1', scrollIntoView() {} };
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('advance', '', {waitMs: 5})`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' }, setTimeout, clearTimeout,
    MutationObserver: class { observe() {} disconnect() { disconnected = true; } },
    window: { innerHeight: 800, scrollBy() {} },
    document: { body: {}, querySelector: (selector) => selector === '[aria-busy="true"]' ? {} : null,
      querySelectorAll: () => [row] },
  });
  assert.equal(result.progressed, false);
  assert.equal(result.loading, true);
  assert.equal(disconnected, true);
  assert.equal(result.complete, undefined);
});
test('native action clicks only the requested track play control', async () => {
  let selected = 0;
  const row = (id) => ({ getAttribute: () => id, querySelector: () => ({
    click() { assert.equal(id, '1_2'); selected++; }, disabled: false }) });
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('play', '1_2')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => null, querySelectorAll: (selector) => {
      assert.equal(selector, '[data-audio-id]'); return [row('1_1'), row('1_2')]; } } });
  assert.equal(result.activated, true);
  assert.equal(selected, 1);
});
test('unknown VK controls fail without clicking a generic row or a library mutation', async () => {
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('play', '1_2')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => null, querySelectorAll: () => [{
      getAttribute: () => '1_2', querySelector: () => null,
      querySelectorAll: () => [{ getAttribute: () => 'Delete', click() { throw new Error('Mutation clicked'); } }],
      click() { throw new Error('Generic row clicked'); } }] } });
  assert.match(result.error, /play control is unsupported/);
});

test('observed VK PlaybackControls region is activated within the exact selected row', async () => {
  let activated = 0;
  const controls = { querySelectorAll: () => [], click: () => activated++ };
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('play', '1_2')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => null, querySelectorAll: () => [{
      getAttribute: () => '1_2',
      querySelector: (selector) => selector === '[data-testid="MusicTrackRow_PlaybackControls"]' ? controls : null,
      click() { throw new Error('Generic row activated'); },
    }] },
  });
  assert.equal(result.activated, true);
  assert.equal(activated, 1);
});

test('PlaybackControls delegates to its sole button without activating the wrapper', async () => {
  let activated = 0;
  const controls = { querySelectorAll: () => [{ click: () => activated++ }],
    click() { throw new Error('Wrapper activated instead of the button'); } };
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('play', '1_2')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => null, querySelectorAll: () => [{ getAttribute: () => '1_2',
      querySelector: (selector) => selector === '[data-testid="MusicTrackRow_PlaybackControls"]' ? controls : null }] },
  });
  assert.equal(result.activated, true);
  assert.equal(activated, 1);
});

test('multiple buttons in PlaybackControls fail without clicking any of them', async () => {
  const controls = { querySelectorAll: () => Array.from({ length: 2 }, () => ({
    click() { throw new Error('Ambiguous control activated'); },
  })) };
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('play', '1_2')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => null, querySelectorAll: () => [{ getAttribute: () => '1_2',
      querySelector: (selector) => selector === '[data-testid="MusicTrackRow_PlaybackControls"]' ? controls : null }] },
  });
  assert.match(result.error, /ambiguous/);
});

test('nested non-button React click target is used instead of an inert playback wrapper', async () => {
  let clicks = 0;
  const child = { __reactProps$synthetic: { onClick: () => {} }, click: () => clicks++ };
  const controls = { querySelectorAll: (selector) => selector === '*' ? [child] : [],
    click() { throw new Error('Inert wrapper clicked'); } };
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('play', '1_2')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => null, querySelectorAll: () => [{ getAttribute: () => '1_2',
      querySelector: (selector) => selector === '[data-testid="MusicTrackRow_PlaybackControls"]' ? controls : null }] },
  });
  assert.equal(result.activated, true);
  assert.equal(clicks, 1);
});

test('playback diagnosis reports handler counts without invoking them or reading unrelated state', async () => {
  const fail = () => { throw new Error('Handler invoked or unrelated state read'); };
  const props = Object.defineProperty({ onClick: fail }, 'session', { get: fail });
  const child = { __reactProps$synthetic: { onPointerDown: fail } };
  const region = { __reactProps$synthetic: props,
    querySelectorAll: (selector) => selector === '*' ? [child] : [] };
  const row = { getAttribute: () => '1_2', querySelector: () => region };
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('probe-playback', '1_2')`, {
    location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    document: { querySelector: () => null,
      querySelectorAll: (selector) => selector === 'audio' ? [] : [row] },
  });
  assert.equal(result.counts.clickHandlers, 1);
  assert.equal(result.counts.pointerDownHandlers, 1);
  assert.equal(result.counts.descendants, 1);
});

function musicNavigationContext({ selected = false, href = '/audio?section=all', heading = false } = {}) {
  let clicked = 0;
  const target = { textContent: 'Моя музыка', classList: [], closest: () => null,
    getAttribute: (name) => name === 'href' ? href : name === 'aria-selected' && selected ? 'true' : null,
    click: () => clicked++ };
  const context = { URL,
    location: { protocol: 'https:', hostname: 'vk.ru', origin: 'https://vk.ru',
      href: 'https://vk.ru/audio?section=general', pathname: '/audio', search: '?section=general' },
    document: { querySelector: () => null, querySelectorAll: (selector) =>
      selector === 'a, button, [role="tab"]' ? [target] : heading ? [{ textContent: 'Моя музыка' }] : [] } };
  return { context, clicks: () => clicked };
}
test('automatic navigation opens personal My music instead of accepting the general music page', async () => {
  const data = musicNavigationContext();
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('open-my-music')`, data.context);
  assert.equal(result.personal, false);
  assert.equal(result.navigationAttempted, true);
  assert.equal(data.clicks(), 1);
});
test('verification requires a personal view witness and never clicks navigation', async () => {
  const data = musicNavigationContext();
  const initial = await vm.runInNewContext(`(${musicPageAction.toString()})('verify-my-music')`, data.context);
  assert.equal(initial.personal, false);
  assert.equal(data.clicks(), 0);
  data.context.location.search = '?section=all';
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('verify-my-music')`, data.context);
  assert.equal(result.personal, true);
  assert.equal(data.clicks(), 0);
});
test('My music label on an external destination is never activated', async () => {
  const data = musicNavigationContext({ href: 'https://synthetic.test/audio?section=all' });
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('open-my-music')`, data.context);
  assert.equal(result.personal, false);
  assert.equal(data.clicks(), 0);
});

test('native playback coordinates are limited to an unobscured control of the matching music row', async () => {
  const control = { scrollIntoView: () => {}, getBoundingClientRect: () => ({ left: 20, top: 30, width: 20, height: 20 }),
    contains: () => false, click() { throw new Error('Scripted click used instead of native coordinates'); } };
  const context = { location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    window: { innerWidth: 800, innerHeight: 600 }, setTimeout: (fn) => { fn(); return 0; },
    document: { querySelector: () => null, elementFromPoint: () => control,
      querySelectorAll: () => [{ getAttribute: () => '1_2', querySelector: () => control }] } };
  const result = await vm.runInNewContext(`(${musicPageAction.toString()})('play-position', '1_2')`, context);
  assert.equal(result.position.x, 30);
  assert.equal(result.position.y, 40);
  context.document.elementFromPoint = () => ({});
  const obscured = await vm.runInNewContext(`(${musicPageAction.toString()})('play-position', '1_2')`, context);
  assert.match(obscured.error, /obscured/);
});

test('pointer-transparent playback area permits only its own track hit and rejects another row', async () => {
  let hitID = '1_2';
  const control = { scrollIntoView: () => {}, getBoundingClientRect: () => ({ left: 20, top: 30, width: 40, height: 40 }), contains: () => false };
  const hit = { closest: (selector) => selector === '[data-audio-id]' ? { getAttribute: () => hitID } : null };
  const context = { location: { protocol: 'https:', hostname: 'vk.ru', pathname: '/audio' },
    window: { innerWidth: 800, innerHeight: 600 }, setTimeout: (fn) => { fn(); return 0; },
    document: { querySelector: () => null, elementFromPoint: () => hit,
      querySelectorAll: () => [{ getAttribute: () => '1_2', querySelector: () => control }] } };
  assert.ok((await vm.runInNewContext(`(${musicPageAction.toString()})('play-position', '1_2')`, context)).position);
  hitID = '1_3';
  assert.match((await vm.runInNewContext(`(${musicPageAction.toString()})('play-position', '1_2')`, context)).error, /obscured/);
});
