'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { audioResponse } = require('./audio-response.cjs');

test('cached audio serves exact full, seek, suffix and HEAD responses', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ownsemble-audio-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'synthetic.mp3');
  fs.writeFileSync(file, '0123456789');
  const request = (range, method = 'GET') => new Request('https://synthetic.invalid/', {
    method, headers: range ? { Range: range } : {} });
  const full = await audioResponse(request(), file);
  assert.equal(full.status, 200);
  assert.equal(full.headers.get('content-type'), 'audio/mpeg');
  assert.equal(full.headers.get('accept-ranges'), 'bytes');
  assert.equal(full.headers.get('content-length'), '10');
  assert.equal(await full.text(), '0123456789');
  for (const [range, text, contentRange] of [
    ['bytes=3-5', '345', 'bytes 3-5/10'], ['bytes=7-', '789', 'bytes 7-9/10'],
    ['bytes=-4', '6789', 'bytes 6-9/10'], ['bytes=8-100', '89', 'bytes 8-9/10'],
  ]) {
    const response = await audioResponse(request(range), file);
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('content-range'), contentRange);
    assert.equal(response.headers.get('content-length'), String(text.length));
    assert.equal(await response.text(), text);
  }
  const head = await audioResponse(request(undefined, 'HEAD'), file);
  assert.equal(head.headers.get('content-length'), '10');
  assert.equal(await head.text(), '');
  for (const range of ['bytes=10-', 'bytes=8-2', 'bytes=-0', 'bytes=-', 'bytes=1-2,4-5', 'invalid']) {
    const response = await audioResponse(request(range), file);
    assert.equal(response.status, 416);
    assert.equal(response.headers.get('content-range'), 'bytes */10');
  }
  assert.equal((await audioResponse(request(undefined, 'POST'), file)).status, 405);
});
