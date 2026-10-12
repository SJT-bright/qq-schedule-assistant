'use strict';
const {spawn}=require('node:child_process');const fs=require('node:fs');const path=require('node:path');const crypto=require('node:crypto');
class NativeDriver {
  constructor(){this.proc=null;this.pending=new Map();this.buffer='';}
  start(){if(this.proc)return;if(process.platform!=='win32')throw new Error('QQ 自动操作仅在 Windows 版运行；当前平台没有提交消息');const ps=path.join(process.env.SystemRoot||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');const p=spawn(ps,['-NoProfile','-STA','-EncodedCommand',Buffer.from("Invoke-Expression ([IO.File]::ReadAllText('"+path.join(__dirname,'../native/QQBridge.ps1').replaceAll("'","''")+"',[Text.Encoding]::UTF8))",'utf16le').toString('base64')],{windowsHide:true,stdio:['pipe','pipe','pipe']});this.proc=p;p.stdout.setEncoding('utf8');p.stdout.on('data',s=>{this.buffer+=s;let n;while((n=this.buffer.indexOf('\n'))>=0){const raw=this.buffer.slice(0,n);this.buffer=this.buffer.slice(n+1);try{const m=JSON.parse(raw);const waiter=this.pending.get(m.id);if(waiter){clearTimeout(waiter.timer);this.pending.delete(m.id);m.ok?waiter.resolve(m.result):waiter.reject(new Error(m.error||'Windows 原生操作失败'));}}catch{}}});p.on('exit',()=>{if(this.proc===p)this.proc=null;for(const w of this.pending.values()){clearTimeout(w.timer);w.reject(new Error('原生操作已停止，请核对实际结果'));}this.pending.clear();});p.on('error',e=>{for(const w of this.pending.values())w.reject(e);this.pending.clear();});}
  request(command,args={},timeout=45000){this.start();const id=crypto.randomUUID();return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.pending.delete(id);this.cancel();reject(new Error('Windows 原生操作超时；不自动重试'));},timeout);this.pending.set(id,{resolve,reject,timer});this.proc.stdin.write(JSON.stringify({id,command,args})+'\n','utf8');});}
  prepare(job,root,{probe=false}={}){const files=job.assets.map(a=>{const p=path.resolve(root,a.relativePath);if(!p.startsWith(path.resolve(root,'assets')+path.sep))throw new Error('素材路径越界');return {...a,path:p};});return this.request('prepare',{job:{...job,assets:files},probe});}
  submit(prepared,job){return this.request('submit',{token:prepared.token,job},20000);}
  inspect(){return this.request('inspect',{},10000);}
  minimize(channel){return this.request('minimize',{channel},5000);}
  cancel(){const p=this.proc;this.proc=null;p?.kill();}
}
module.exports={NativeDriver};
