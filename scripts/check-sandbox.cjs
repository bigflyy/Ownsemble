// Only synthetic test data is touched. Never point this at a credential store.
const fs = require('node:fs');
const path = require('node:path');

async function main() {
  const base = path.resolve('.local/sandbox-proof');
  const privateDir = path.join(base, 'private');
  const results = {};
  for (const [name, action] of [
    ['private_read_blocked', () => fs.readFileSync(path.join(privateDir, 'sentinel.txt'))],
    ['private_listing_blocked', () => fs.readdirSync(privateDir)],
    ['private_write_blocked', () => fs.writeFileSync(path.join(privateDir, 'must-not-exist.txt'), 'test')],
  ]) {
    try { action(); results[name] = false; }
    catch (error) { results[name] = ['EACCES', 'EPERM', 'ENOENT'].includes(error.code); }
  }
  const publicFile = path.join(base, 'public', 'write-check.txt');
  fs.writeFileSync(publicFile, 'NORMAL_WORKSPACE_WRITE');
  results.workspace_read_write = fs.readFileSync(publicFile, 'utf8') === 'NORMAL_WORKSPACE_WRITE';
  try {
    const response = await fetch('https://example.com/', { signal: AbortSignal.timeout(15000) });
    results.internet = response.ok;
    await response.body?.cancel();
  } catch { results.internet = false; }
  console.log(JSON.stringify(results));
  if (Object.values(results).some((passed) => !passed)) process.exitCode = 1;
}
main().catch(() => { console.error('Synthetic sandbox check failed.'); process.exitCode = 1; });
