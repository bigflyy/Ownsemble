'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const root = path.resolve(__dirname, '../../.local/flutter-proof');
const command = process.argv[2] || 'status';
if (command === 'status') {
  const file = path.join(root, 'status.json');
  if (!fs.existsSync(file)) { console.log('Flutter probe has not written status yet.'); process.exit(0); }
  const status = JSON.parse(fs.readFileSync(file, 'utf8'));
  const safe = {};
  for (const key of ['stage','passed','category','platform','updatedAt']) if (Object.hasOwn(status,key)) safe[key]=status[key];
  console.log(JSON.stringify(safe,null,2));
} else if (['run','selftest','stop','restart'].includes(command)) {
  fs.mkdirSync(root,{recursive:true});
  const file=path.join(root,'control.json');
  fs.writeFileSync(file+'.tmp',JSON.stringify({command,nonce:randomUUID()}));
  fs.renameSync(file+'.tmp',file);
  console.log('Flutter probe command queued: '+command);
} else { console.error('Use status, run, selftest, stop or restart.');process.exitCode=2; }
