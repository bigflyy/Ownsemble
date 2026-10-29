// Prints which session cookies the test Edge profile holds (names and domains
// only, never values) and where vk.com/feed lands, to diagnose login detection.

import { chromium } from 'playwright-core';
import path from 'node:path';

const repoRoot = path.resolve(import.meta.dirname, '..', '..');
const profileDir = path.join(repoRoot, '.local', 'v2-test', 'edge-profile');

const context = await chromium.launchPersistentContext(profileDir, {
  executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  headless: true,
  args: ['--mute-audio'],
});
const cookies = await context.cookies();
const vkCookies = cookies.filter((c) => /vk\.(com|ru)$/.test(c.domain));
console.log('VK cookie names by domain:');
for (const c of vkCookies) console.log(`  ${c.domain}  ${c.name}  (value length ${c.value.length})`);
const page = await context.newPage();
for (const start of ['https://vk.com/feed', 'https://vk.ru/feed']) {
  await page.goto(start, { waitUntil: 'domcontentloaded' }).catch((e) => console.log(`  ${start}: ${e.message}`));
  const landed = new URL(page.url());
  console.log(`${start} -> ${landed.hostname}${landed.pathname}`);
}
await context.close();
