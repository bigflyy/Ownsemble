'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const command = process.argv[2] || 'status';
const dataDir = path.resolve(__dirname, '../../.local/vk-proof');
if (command === 'status') {
  const file = path.join(dataDir, 'automation-status.json');
  if (!fs.existsSync(file)) { console.log('Automated proof has not started.'); process.exit(0); }
  const state = JSON.parse(fs.readFileSync(file, 'utf8'));
  const result = {};
  for (const key of ['state', 'stage', 'category', 'attempt', 'offline', 'updatedAt',
    'technicalChecksPassed', 'audibleConfirmed', 'identityConfirmed']) {
    if (Object.hasOwn(state, key)) result[key] = state[key];
  }
  console.log(JSON.stringify(result, null, 2));
} else if (['run', 'stop'].includes(command)) {
  fs.mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, 'automation-control.json');
  fs.writeFileSync(`${file}.tmp`, JSON.stringify({ command, nonce: randomUUID() }));
  fs.renameSync(`${file}.tmp`, file);
  console.log(`Automated proof command queued: ${command}`);
} else {
  console.error('Usage: node proof-control.cjs [status|run|stop]');
  process.exitCode = 2;
}
