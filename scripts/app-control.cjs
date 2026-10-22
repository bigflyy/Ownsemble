'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {randomUUID}=require('node:crypto');
const root=path.resolve(__dirname,'../.local/ownsemble');
const command=process.argv[2]||'status';
if(command==='status') {
  const file=path.join(root,'status.json');
  if(!fs.existsSync(file)){console.log('Ownsemble has not written status yet.');process.exit(0);}
  const input=JSON.parse(fs.readFileSync(file,'utf8')),safe={};
  for(const key of ['category','count','updatedAt'])if(Object.hasOwn(input,key))safe[key]=input[key];
  console.log(JSON.stringify(safe,null,2));
} else if(['restart','check','play','play-current','play-uncached','play-deep','play-last','play-old-1','play-old-10','play-old-25','play-old-50','play-old-100','play-old-250','play-cached','audible','pause','resume','seek-middle','stop','next','refresh-head','refresh-full','metadata-summary','inspect-current','inspect-old','inspect-lyrics','repair-mismatched-cache','check-repaired','check-current','check-old'].includes(command)) {
  if(process.argv.length!==3){console.error('This command accepts no extra arguments.');process.exit(2);}
  fs.mkdirSync(root,{recursive:true});
  const file=path.join(root,'control.json');
  fs.writeFileSync(file+'.tmp',JSON.stringify({command,nonce:randomUUID()}));
  fs.renameSync(file+'.tmp',file);
  console.log('Ownsemble command queued: '+command);
} else {console.error('Use status, restart, check, play, play-current, play-uncached, play-cached, audible, pause, resume, seek-middle, stop or next.');process.exitCode=2;}
