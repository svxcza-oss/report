const fs=require('fs'),vm=require('vm'),assert=require('assert');
const s=fs.readFileSync(__dirname+'/../Resources/index.html','utf8');
const context=vm.createContext({weekDates:()=>Array.from({length:7},(_,i)=>new Date(2026,9,26+i)),key:d=>d.toISOString().slice(0,10),navigator:{language:'ko-KR'}});
vm.runInContext('let S={language:"ko"};'+s.slice(s.indexOf('const language='),s.indexOf('const key='))+s.slice(s.indexOf('function migrate('),s.indexOf('function load('))+s.slice(s.indexOf('const durText='),s.indexOf('function setDur('))+';this.api={migrate,hm,parseDur,durText,setLanguage:f=>S.language=f}',context);
const {migrate,hm,parseDur,durText,setLanguage}=context.api;
for(const [v,start,expected] of [[2,4,60],[3,20,60],[4,60,60]]){
 const oldLen=v===4?6:2;
 const input={v,blocks:[{id:'task',name:'Class',date:'2026-10-30',start,len:oldLen,done:true}],fixed:[{id:'fixed',name:'Lecture',wd:0,start,len:oldLen}],range:{from:8,to:24}};
 const result=migrate(input);assert.equal(result.blocks[0].start,expected);assert.equal(result.blocks[0].len,6);assert.equal(result.fixed[0].start,expected);assert.equal(result.blocks[0].done,true);assert.equal(result.blocks[0].id,'task');assert.equal(result.v,4);
 migrate(result);assert.equal(result.blocks[0].start,expected);assert.equal(result.blocks[0].len,6);
}
assert.equal(parseDur('50 min'),50);assert.equal(durText(Math.ceil(parseDur('50 min')/10)),'50분');assert.equal(durText(1),'10분');assert.equal(durText(144),'24시간');
assert.equal(hm(60),'10:00');assert.equal(hm(61),'10:10');assert.equal(hm(144),'24:00');setLanguage('en');assert.equal(hm(0),'12:00 AM');assert.equal(hm(72),'12:00 PM');assert.equal(hm(85),'2:10 PM');assert.equal(hm(144),'12:00 AM');
console.log('PASS: v2/v3/v4 migration preserves time, IDs, completion and repeats; migration idempotent; 10-minute duration and KO/EN midnight/noon formatting');

for(const locale of ['ko-KR','en-US']) {
 context.navigator.language=locale;
 const input={v:4,timeFormat:'us',blocks:[{id:'same',name:'내 일정',date:'2026-10-30',start:85,len:5,done:true}],fixed:[{id:'repeat',name:'Class',wd:2,start:60,len:5,fixed:true}],range:{from:0,to:24}};
 const before=JSON.stringify({blocks:input.blocks,fixed:input.fixed,range:input.range});const output=migrate(input);
 assert.equal(output.language,locale==='ko-KR'?'ko':'en');assert.equal(output.timeFormat,undefined);
 assert.equal(JSON.stringify({blocks:output.blocks,fixed:output.fixed,range:output.range}),before);
}
console.log('PASS: legacy region setting removed; KO/EN locale selection preserves exact block times, dates, lengths, completion, repeats and full 24-hour range');
