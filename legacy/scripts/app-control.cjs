'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {randomUUID}=require('node:crypto');
const root=path.resolve(__dirname,'../.local/ownsemble');
const command=process.argv[2]||'status';
// Collect a passive safe report through the same fixed control boundary as the app.
if(command==='diagnose') {
  // Reject extra arguments so this command cannot select paths or browser operations.
  if(process.argv.length!==3){console.error('This command accepts no extra arguments.');process.exit(2);}
  require('./diagnose-vk.cjs').collectDiagnostics(root)
    .then(report=>console.log(JSON.stringify(report,null,2)))
    .catch(()=>{console.error('Diagnostic collection failed; the app may be stopped or unresponsive.');process.exitCode=1;});
} else if(['inspect-recording','check-recording'].includes(command)) {
  // Accept only user-supplied display metadata for an exact local lookup, never paths or browser commands.
  if(process.argv.length!==5 || process.argv.slice(3).some(value=>!value.trim()||value.length>160)) {
    console.error('Supply one title and one artist, each at most 160 characters.');process.exit(2);
  }
  // Keep metadata in the app control request; terminal evidence contains only counts and flags.
  const file=path.join(root,'control.json');
  fs.mkdirSync(root,{recursive:true});
  fs.writeFileSync(file+'.tmp',JSON.stringify({command,nonce:randomUUID(),title:process.argv[3],artist:process.argv[4]}),'utf8');
  fs.renameSync(file+'.tmp',file);
  console.log('Ownsemble named-recording diagnostic queued.');
} else if(command==='status') {
  const file=path.join(root,'status.json');
  if(!fs.existsSync(file)){console.log('Ownsemble has not written status yet.');process.exit(0);}
  const input=JSON.parse(fs.readFileSync(file,'utf8')),safe={};
  for(const key of ['category','count','updatedAt'])if(Object.hasOwn(input,key))safe[key]=input[key];
  console.log(JSON.stringify(safe,null,2));
} else if(['restart','check','play','play-current','play-uncached','play-deep','play-last','play-old-1','play-old-10','play-old-25','play-old-50','play-old-100','play-old-250','play-cached','audible','mute','pause','resume','seek-middle','stop','next','refresh-head','refresh-full','metadata-summary','inspect-current','inspect-old','inspect-lyrics','repair-mismatched-cache','check-repaired','check-current','check-old','check-queue-normal','check-queue-shuffle','check-queue-sequence'].includes(command)) {
  if(process.argv.length!==3){console.error('This command accepts no extra arguments.');process.exit(2);}
  fs.mkdirSync(root,{recursive:true});
  const file=path.join(root,'control.json');
  fs.writeFileSync(file+'.tmp',JSON.stringify({command,nonce:randomUUID()}));
  fs.renameSync(file+'.tmp',file);
  console.log('Ownsemble command queued: '+command);
} else {console.error('Use status, restart, check, play, play-current, play-uncached, play-cached, audible, pause, resume, seek-middle, stop or next.');process.exitCode=2;}
