// Login helper for the SECOND test VK account (plan stage E). Not product code.
//
// Opens Edge with its own empty profile, waits for the user to log in, and saves
// the session to .local/v2-test/session-2.json. It never reads or writes the
// first test session (.local/v2-test/session.json) or that session's profile,
// and it refuses to replace a session-2.json that already exists.
//
// Prints only progress and a cookie count: never a cookie value.
//
// Run from the repo root:
//   node experiments/vk-web/login-second.mjs

import { chromium } from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(import.meta.dirname, '..', '..');
const dataDir = path.join(repoRoot, '.local', 'v2-test');
const profileDir = path.join(dataDir, 'edge-profile-2');
const sessionFile = path.join(dataDir, 'session-2.json');
const edgePath = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';

if (fs.existsSync(sessionFile)) {
  console.error('session-2.json already exists: delete it first to log in again.');
  process.exit(1);
}

const context = await chromium.launchPersistentContext(profileDir, {
  executablePath: edgePath,
  headless: false,
  args: ['--mute-audio'],
  viewport: null,
});
const page = context.pages()[0] ?? (await context.newPage());

const hasSession = async () =>
  (await context.cookies('https://vk.ru')).some((c) => c.name === 'remixsid' && c.value);

await page.goto('https://vk.ru/');
if (!(await hasSession())) {
  console.log('Log in to the SECOND test VK account in the Edge window (waiting up to 10 minutes).');
  const deadline = Date.now() + 10 * 60 * 1000;
  while (!(await hasSession())) {
    if (Date.now() > deadline) throw new Error('Login was not completed within 10 minutes.');
    await page.waitForTimeout(2000);
  }
}

// The music page sets the rest of the cookies the web token needs.
console.log('Logged in. Opening the music page...');
await page.goto('https://vk.ru/audio', { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(5000);

const cookies = await context.cookies([
  'https://vk.ru',
  'https://login.vk.ru',
  'https://api.vk.ru',
  'https://vk.com',
]);
fs.writeFileSync(sessionFile, JSON.stringify(cookies, null, 2), 'utf8');
console.log(`Saved ${cookies.length} session cookies to session-2.json (values not shown).`);
await context.close();
