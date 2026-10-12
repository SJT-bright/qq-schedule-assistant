'use strict';
const crypto = require('node:crypto');
const EPOCH = 978307200;
const id = () => crypto.randomUUID().toUpperCase();
const now = () => Date.now() / 1000 - EPOCH;
const toDate = x => new Date((Number(x) + EPOCH) * 1000);
const fromDate = x => new Date(x).getTime() / 1000 - EPOCH;
const clone = x => structuredClone(x);
const statuses = {queued:'待执行', running:'发送中', draft:'未发送', submitted:'待核对', verified:'界面已核验', uncertain:'待核对', blocked:'已拦截', cancelled:'已取消', manual:'人工标记已发'};
const clean = j => j.status === 'queued' && !j.oneOff && j.started == null && j.submittedAt == null && !j.evidence && j.qqVerification == null;
const inBatch = (j,p) => j.planID === p.id && !j.oneOff && (j.dispatchBatchID ?? null) === (p.dispatchBatchID ?? null);
const activity = j => j.submittedAt ?? (!['blocked','cancelled','queued'].includes(j.status) ? (['verified','manual'].includes(j.status) ? j.finished ?? j.started : j.started) : null);
const last = jobs => Math.max(-Infinity,...jobs.map(activity).filter(x=>x != null));
const pace = p => Math.max(1,Math.min(1440,p.intervalMinutes,...Object.values(p.recipientGaps||{}).filter(x=>Number.isInteger(x)&&x>=1&&x<=1440)));
function assert(ok,message) { if(!ok) throw new Error(message); }
function integer(n,min,max,label) { n=Number(n); assert(Number.isInteger(n)&&n>=min&&n<=max,`${label}须在 ${min} 到 ${max} 之间`); return n; }
function finite(n,label) { assert(Number.isFinite(n),`${label}无效`); return n; }
function seed(text) { let h=0xcbf29ce484222325n; for(const b of Buffer.from(text)) h=BigInt.asUintN(64,(h^BigInt(b))*0x100000001b3n); return h; }
function jitter(minutes,s) {const low=Math.max(5,minutes),high=Math.max(low,minutes+Math.max(1,Math.floor(minutes/5))); let n=BigInt.asUintN(64,BigInt(s)); for(let i=0;i<2;i++) n=BigInt.asUintN(64,n*6364136223846793005n+1442695040888963407n); return low+Number((n>>16n)%BigInt(high-low+1));}
function parseTimes(input) {
  const values=(Array.isArray(input)?input:input.split(/[,，;；\s]+/)).filter(Boolean);
  const result=values.map(s=>{ assert(/^\d{1,2}:\d{2}$/.test(s),'轮次格式应为 HH:mm');const [h,m]=s.split(':').map(Number);assert(h<24&&m<60,'轮次时间无效');return `${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}`;});
  assert(new Set(result).size===result.length,'轮次不能重复'); return result.sort();
}
// Match the Swift scheduler's fixed Asia/Shanghai calendar regardless of Windows locale.
function localParts(stamp){const d=new Date((stamp+EPOCH+28800)*1000);return {y:d.getUTCFullYear(),m:d.getUTCMonth(),d:d.getUTCDate(),h:d.getUTCHours(),minute:d.getUTCMinutes(),s:d.getUTCSeconds()};}
function localStamp(p){return Date.UTC(p.y,p.m,p.d,p.h||0,p.minute||0,p.s||0)/1000-EPOCH-28800;}
function expand(p,recipients,assets,clock=now(),useJitter=false){
  assert(['draft','automatic'].includes(p.mode),'未知发送模式'); finite(p.starts,'开始日期');
  const offset=finite(p.scheduleOffsetSeconds||0,'排期偏移'); integer(p.days,1,30,'天数');integer(p.intervalMinutes,1,1440,'间隔');
  assert(Array.isArray(p.recipientIDs)&&p.recipientIDs.length,'请至少选择一个群');assert(p.text.trim()||p.assetIDs.length,'文案和附件不能都为空'); assert([...p.text].length<=5000,'单条文案请控制在 5000 字以内');
  assert(new Set(p.recipientIDs).size===p.recipientIDs.length,'收件人重复');assert(p.recipientIDs.length*p.days*Math.max(1,p.times.length)<=10000,'本计划超过 10000 条任务');
  const rs=p.recipientIDs.map(i=>{const r=recipients.find(x=>x.id===i);assert(r&&r.enabled,'收件人不存在或已停用');return r;});
  assert(new Set(rs.map(x=>x.name)).size===rs.length,'收件人重复');
  const selected=p.assetIDs.map(i=>{const a=assets.find(x=>x.id===i);assert(a,'附件不存在');return a;});
  assert(p.mode!=='draft'||selected.every(x=>x.isImage),'草稿模式只支持文字和图片');
  const times=parseTimes(p.times);const base=localParts(p.starts); const offsets=[0];
  for(let i=1;i<rs.length;i++){const gap=integer(p.recipientGaps?.[rs[i].id]??p.intervalMinutes,1,1440,'逐群间隔'); offsets.push(offsets[i-1]+(useJitter?jitter(gap,seed(p.id+'#offset#'+i)):gap));}
  const slots=[];
  for(let d=0;d<p.days;d++) for(const t of times.length?times:[null]){const part={...base,d:base.d+d};if(t){[part.h,part.minute]=t.split(':').map(Number);part.s=0;}slots.push(localStamp(part)+offset);}
  const minGap=Math.min(p.intervalMinutes,...rs.slice(1).map(r=>p.recipientGaps?.[r.id]??p.intervalMinutes));let end=-Infinity; const result=[];
  for(const slot of slots.sort((a,b)=>a-b)) {assert(slot-end>=minGap*60-1,'轮次有重叠，或下一轮离末群太近'); for(let i=0;i<rs.length;i++){const scheduled=slot+offsets[i]*60;assert(scheduled>=clock-60,'计划包含已经过去的时间');const r=rs[i];result.push({id:id(),planID:p.id,planName:p.name,recipient:r.name,recipientID:r.id,text:p.text,assets:clone(selected),scheduled,mode:p.mode,status:'queued',detail:'等待执行',evidence:'',channel:r.channel||'qq',scheduleOffsetSeconds:p.scheduleOffsetSeconds??null,dispatchBatchID:p.dispatchBatchID??null});}end=slot+(offsets.at(-1)||0)*60;}
  return result;
}
function due(j,jobs,plans,gap){const p=plans.find(x=>x.id===j.planID);return Math.max(j.scheduled,last(jobs)+gap*60,last(jobs.filter(x=>x.planID===j.planID))+(p?pace(p):gap)*60);}
function next(jobs,plans,active,gap,selection=new Map()) {
  return jobs.map((j,index)=>({j,index,due:due(j,jobs,plans,gap),last:last(jobs.filter(x=>x.planID===j.planID))})).filter(x=>clean(x.j)&&active.has(x.j.planID)&&(!selection.has(x.j.planID)||selection.get(x.j.planID).has(x.j.id))).sort((a,b)=>a.due-b.due||a.last-b.last||a.j.scheduled-b.j.scheduled||a.index-b.index)[0]||null;
}
function reorder(p,jobs,clock,gap,useJitter=false){const result=clone(jobs);let cursor=clock;const ordered=result.filter(j=>inBatch(j,p)&&clean(j)).sort((a,b)=>due(a,jobs,[p],gap)-due(b,jobs,[p],gap)||a.scheduled-b.scheduled);for(const j of ordered){j.scheduled=cursor;const m=Math.max(gap,pace(p));cursor+=(useJitter?jitter(m,seed(j.id)):m)*60;}return result;}
function reschedule(p,jobs,requested,clock,gap){finite(requested,'开始日期');assert(requested>=clock-60,'首群时间已过，请选择当前或未来的时间');assert(!p.queueCancelledAt,'此队列已取消，请先重新开始新一轮');assert(!jobs.some(j=>j.planID===p.id&&j.status==='running'),'当前队列正在处理任务');assert(new Set(jobs.map(x=>x.id)).size===jobs.length,'任务编号重复');const selected=jobs.filter(j=>inBatch(j,p)&&clean(j)).sort((a,b)=>a.scheduled-b.scheduled);assert(selected.length,'当前队列没有尚未尝试的待执行任务');const first=Math.max(requested,clock,last(jobs)+gap*60,last(jobs.filter(j=>j.planID===p.id))+pace(p)*60);const delta=first-selected[0].scheduled;const plan=clone(p);plan.scheduleOffsetSeconds=(plan.scheduleOffsetSeconds||0)+delta;const ids=new Set(selected.map(x=>x.id));const updated=jobs.map(j=>ids.has(j.id)?{...j,scheduled:j.scheduled+delta,scheduleOffsetSeconds:plan.scheduleOffsetSeconds}:clone(j));let finish=first;for(const j of selected.slice(1))finish=Math.max(j.scheduled+delta,finish+Math.max(gap,pace(p))*60);return {plan,jobs:updated,remaining:selected.length,nextDate:first,finishDate:finish};}
function replay(p,jobs,clock,gap,useJitter=false){
  const current=jobs.filter(j=>inBatch(j,p));assert(current.length,'没有可重开的原始批次');const latest=new Map();for(const j of current){const old=latest.get(j.recipientID||j.recipient);if(!old||j.scheduled>old.scheduled)latest.set(j.recipientID||j.recipient,j);}
  const plan={...clone(p),dispatchBatchID:id(),queueCancelledAt:null,created:clock};let cursor=clock;const attempts=[...latest.values()].filter(j=>!j.recipientID||p.recipientIDs.includes(j.recipientID)).sort((a,b)=>a.scheduled-b.scheduled).map(j=>{const r={id:id(),planID:p.id,planName:p.name,recipient:j.recipient,recipientID:j.recipientID,text:j.text,assets:clone(j.assets),channel:j.channel||'qq',scheduled:cursor,mode:j.mode,status:'queued',detail:'新一轮完整队列',evidence:'',dispatchBatchID:plan.dispatchBatchID,scheduleOffsetSeconds:plan.scheduleOffsetSeconds??null};const m=Math.max(gap,pace(p));cursor+=(useJitter?jitter(m,seed(r.id)):m)*60;return r;});assert(attempts.length,'当前计划没有可重开的群');return {plan,jobs:attempts};
}
function reviewed(j,jobs,clock){assert(['draft','uncertain','submitted','blocked'].includes(j.status)||(j.status==='queued'&&!clean(j)),'这条记录不需要核对重发');const existing=jobs.find(x=>x.cloneOf===j.id&&x.status!=='cancelled');if(existing)return {existing:existing.id};const job={id:id(),planID:j.planID,planName:j.planName,recipient:j.recipient,recipientID:j.recipientID,text:j.text,assets:clone(j.assets),channel:j.channel||'qq',scheduled:clock,mode:'automatic',status:'queued',detail:'人工确认未发出且草稿已清空后新建的一次性尝试',evidence:'',oneOff:true,cloneOf:j.id};return {job};}
function defaultArchive(){return {version:1,recipients:[],assets:[],plans:[],deliveries:[],settings:{globalGapMinutes:30,savedText:'',guestMode:true,broadcastWorkspaces:[{id:'legacy',name:'默认群发',draft:{text:'',name:'新一轮图文发送',recipientIDs:[],assetIDs:[],starts:now()+300,days:1,interval:30,times:'09:00,14:00,19:00',multiRound:false,mode:'automatic',customGaps:false,recipientGaps:{}},templates:[],stagingText:'',stagingFiles:[]}],activeWorkspaceID:'legacy'}};}
module.exports={EPOCH,id,now,toDate,fromDate,clone,statuses,clean,inBatch,activity,last,pace,assert,integer,finite,seed,jitter,parseTimes,expand,due,next,reorder,reschedule,replay,reviewed,defaultArchive};
