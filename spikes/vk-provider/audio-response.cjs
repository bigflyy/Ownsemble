'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { Readable } = require('node:stream');

// Only main-process cache lookup supplies file paths. No URL or renderer path
// is passed through to the filesystem.
async function audioResponse(request, file) {
  if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405 });
  const { size } = await fs.promises.stat(file);
  const types = { '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.webm': 'audio/webm', '.flac': 'audio/flac' };
  const headers = { 'Content-Type': types[path.extname(file).toLowerCase()] || 'application/octet-stream',
    'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' };
  let start = 0, end = size - 1, status = 200;
  const range = request.headers.get('range');
  if (range && request.method !== 'HEAD') {
    const match = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!match || (!match[1] && !match[2])) {
      return new Response(null, { status: 416, headers: { ...headers, 'Content-Range': `bytes */${size}` } });
    }
    if (!match[1]) start = Math.max(0, size - Number(match[2]));
    else start = Number(match[1]);
    end = match[1] && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) {
      return new Response(null, { status: 416, headers: { ...headers, 'Content-Range': `bytes */${size}` } });
    }
    status = 206;
    headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
  }
  headers['Content-Length'] = String(Math.max(0, end - start + 1));
  const body = request.method === 'HEAD' || !size ? null : Readable.toWeb(fs.createReadStream(file, { start, end }));
  return new Response(body, { status, headers });
}

module.exports = { audioResponse };
