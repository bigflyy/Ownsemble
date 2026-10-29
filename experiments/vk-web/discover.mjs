// Discovery tool for the VK experiment (step 1). Throwaway, not product code.
//
// Opens Edge with a dedicated test profile, waits for the user to log in to the
// TEST VK account, opens the music page, scrolls, starts one track (muted) and
// records which requests vk.com makes. The printed report contains request
// shapes only: hosts, paths, parameter names and response structure. Cookie
// values, tokens and audio URLs are never printed. Raw bodies and the session
// are saved under .local/v2-test/ (git-ignored) for offline analysis.

import { chromium } from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(import.meta.dirname, '..', '..');
const dataDir = path.join(repoRoot, '.local', 'v2-test');
const profileDir = path.join(dataDir, 'edge-profile');
const rawDir = path.join(dataDir, 'discovery-raw');
const edgePath = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
fs.mkdirSync(rawDir, { recursive: true });

// Parameter values kept in the report because they name an action, not data.
const keepValueKeys = new Set(['act', 'al', 'method', 'v', 'section', 'type', 'block', 'is_layer']);
const vkHost = /(^|\.)(vk\.com|vk\.ru|vkuser\.net|userapi\.com|vk-cdn\.net|mycdn\.me|okcdn\.ru)$/;

/** Describe a value's structure without its content. */
function shapeOf(value, depth = 0) {
  if (value === null) return 'null';
  if (Array.isArray(value)) {
    if (depth > 4) return `array(${value.length})`;
    return value.length ? [`array(${value.length}) of`, shapeOf(value[0], depth + 1)] : 'array(0)';
  }
  if (typeof value === 'object') {
    if (depth > 4) return `object(${Object.keys(value).length} keys)`;
    const out = {};
    for (const [key, inner] of Object.entries(value).slice(0, 40)) out[key] = shapeOf(inner, depth + 1);
    return out;
  }
  if (typeof value === 'string') return `str(${value.length})`;
  return typeof value;
}

/** Parameter names, with values only for action-like keys. */
function describeParams(searchParams) {
  const out = {};
  for (const [key, value] of searchParams) out[key] = keepValueKeys.has(key) ? value : `<${value.length}>`;
  return out;
}

const records = [];
let rawCounter = 0;

const context = await chromium.launchPersistentContext(profileDir, {
  executablePath: edgePath,
  headless: false,
  args: ['--mute-audio'],
  viewport: null,
});
const page = context.pages()[0] ?? (await context.newPage());

page.on('request', (request) => {
  const url = new URL(request.url());
  if (!vkHost.test(url.hostname)) return;
  const isMedia = /\.(m3u8|ts|mp3|m4a|aac)$/.test(url.pathname) || request.resourceType() === 'media';
  const record = {
    id: records.length,
    method: request.method(),
    host: url.hostname,
    path: isMedia ? `<media ${path.extname(url.pathname) || request.resourceType()}>` : url.pathname,
    type: request.resourceType(),
    query: isMedia ? '<redacted>' : describeParams(url.searchParams),
  };
  const body = request.postData();
  if (body && !isMedia) {
    try {
      record.body = describeParams(new URLSearchParams(body));
    } catch {
      record.body = `<${body.length} bytes>`;
    }
  }
  records.push(record);
  request._ownsembleRecord = record;
});

page.on('response', async (response) => {
  const record = response.request()._ownsembleRecord;
  if (!record) return;
  record.status = response.status();
  record.contentType = (response.headers()['content-type'] || '').split(';')[0];
  if (!['xhr', 'fetch', 'document'].includes(record.type)) return;
  try {
    const text = await response.text();
    record.bytes = text.length;
    const rawName = `${String(rawCounter++).padStart(3, '0')}-${record.path.replace(/[^a-z0-9]+/gi, '_')}.txt`;
    fs.writeFileSync(path.join(rawDir, rawName), text, 'utf8');
    record.raw = rawName;
    const jsonStart = text.search(/[[{]/);
    if (jsonStart >= 0 && jsonStart < 16) record.shape = shapeOf(JSON.parse(text.slice(jsonStart)));
  } catch {
    // Non-JSON or unreadable body: status and size are enough for the report.
  }
});

const hasSession = async () => (await context.cookies('https://vk.ru')).some((c) => c.name === 'remixsid' && c.value);

await page.goto('https://vk.ru/');
if (!(await hasSession())) {
  console.log('LOGIN NEEDED: log in to the TEST VK account in the Edge window (waiting up to 10 minutes).');
  const deadline = Date.now() + 10 * 60 * 1000;
  while (!(await hasSession())) {
    if (Date.now() > deadline) throw new Error('Login was not completed within 10 minutes.');
    await page.waitForTimeout(2000);
  }
}
console.log('Logged in. Recording the music page...');
records.length = 0;

await page.goto('https://vk.ru/audio', { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(6000);
for (let i = 0; i < 6; i++) {
  await page.mouse.wheel(0, 4000);
  await page.waitForTimeout(1500);
}
console.log(`Music page URL path: ${new URL(page.url()).pathname}`);

// Try to start the first track so the stream-resolution request shows up.
const playCandidates = ['[data-testid*="play"]', '.audio_row', '[class*="AudioRow"]', '[data-audio]', '[class*="audio_row"]'];
let clicked = null;
for (const selector of playCandidates) {
  const element = page.locator(selector).first();
  if (await element.count()) {
    await element.hover().catch(() => {});
    await element.click({ timeout: 3000 }).catch(() => {});
    clicked = selector;
    break;
  }
}
console.log(clicked ? `Clicked first track via ${clicked}` : 'No track row found to click.');
await page.waitForTimeout(8000);

const cookies = await context.cookies(['https://vk.ru', 'https://login.vk.ru', 'https://api.vk.ru', 'https://vk.com']);
fs.writeFileSync(path.join(dataDir, 'session.json'), JSON.stringify(cookies, null, 2), 'utf8');
fs.writeFileSync(path.join(dataDir, 'discovery.json'), JSON.stringify(records, null, 2), 'utf8');
await page.screenshot({ path: path.join(dataDir, 'music-page.png') });
console.log(`Saved ${records.length} request records and ${cookies.length} session cookies (values not shown).`);
await context.close();
