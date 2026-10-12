'use strict';
const test=require('node:test');const assert=require('node:assert/strict');const C=require('../lib/core.cjs');const oracle=require('./swift-oracle.json');
const recipients=[{id:'A',name:'验收群A',enabled:true},{id:'B',name:'验收群B',enabled:true}];
for(const sample of oracle.cases)test('Swift oracle: '+sample.label,()=>{const p={id:'P',name:'隔离验收',text:'完整正文',assetIDs:[],recipientIDs:['A','B'],starts:sample.starts,days:sample.days,times:sample.times,intervalMinutes:30,mode:'automatic',scheduleOffsetSeconds:sample.offset};const jobs=C.expand(p,recipients,[],oracle.clock,sample.jitter);assert.deepEqual(jobs.map(j=>j.scheduled),sample.scheduled);assert.deepEqual(jobs.map(j=>j.recipient),sample.recipients);});
test('100 jitter outputs exactly match Swift FNV/MMIX implementation',()=>{for(const s of oracle.jitterSeeds)assert.equal(C.jitter(30,C.seed(s.text)),s.value);});
