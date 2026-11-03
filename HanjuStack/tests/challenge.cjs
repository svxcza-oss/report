// 챌린지: 붙여넣은 글 나누기와 "오늘의 Day" 규칙 (날짜 고정 / 밀기)
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync(__dirname+'/../Resources/index.html','utf8');
const part=source.slice(source.indexOf('const VESSELS='),source.indexOf('function makeChallenge('));
const ctx=vm.createContext({});
vm.runInContext(`let n=0;const uid=()=>'i'+(++n),T=(ko,en)=>ko,validDate=d=>/^\\d{4}-\\d{2}-\\d{2}$/.test(String(d||''));
const key=d=>d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');
const today=()=>{const d=new Date();d.setHours(0,0,0,0);return d};let S={challenges:[]};`+part+';this.parse=parseChallenge;this.now=chNow;this.pct=chDayPct;this.svg=vesselSVG;',ctx);
const plan=`Day 1 워밍업 (C++ 손풀기)
하샤드 수, 같은 숫자는 싫어, K번째수, 문자열 내 마음대로 정렬하기, [PCCP 기출문제] 1번 / 붕대 감기
→ vector, sort 커스텀 비교, string 다루는 감을 되찾는 날이에요.

Day 2 구현/시뮬레이션
키패드 누르기, 신규 아이디 추천, 공원 산책, 주차 요금 계산, [PCCP 기출문제] 1번 / 동영상 재생기

Day 9 실전 ①
PCCP 모의고사 #1을 120분 재고 풀기. 외톨이 알파벳, 체육대회, 유전법칙, 운영체제 4문제예요. 끝나면 [PCCP 기출문제] 3번 / 충돌위험 찾기도 풀어보세요. [github](https://github.com/gilbutITbook/080337)`;
const p=ctx.parse(plan);
assert.equal(p.days.length,3);
assert.equal(p.days[0].t,'워밍업 (C++ 손풀기)');
assert.deepEqual(p.days[0].items.map(x=>x.text),['하샤드 수','같은 숫자는 싫어','K번째수','문자열 내 마음대로 정렬하기','[PCCP 기출문제] 1번 / 붕대 감기']);
assert.equal(p.days[2].items.length,3);
assert.equal(p.days[2].items[2].url,'https://github.com/gilbutITbook/080337');
const w=ctx.parse('Day 1: 스쿼트 20개, 플랭크 30초\nDay 2: 쉬는 날');
assert.deepEqual(w.days.map(d=>d.items.map(x=>x.text)),[['스쿼트 20개','플랭크 30초'],['쉬는 날']]);
assert.equal(ctx.parse('매일: 물 2L, 스트레칭\n기간: 21일').days.length,21);
const ex=ctx.parse('범위: 1단원, 2단원, 3단원\n마지막 날: 총복습',{start:'2026-11-01',end:'2026-11-08'});
assert.equal(ex.days.length,7);assert.equal(ex.days[6].items[0].text,'총복습');
assert.equal(ctx.parse('a, b\nc').days.length,2);
// 날짜 고정: 셋째 날, 첫날 하나 못 함 → 밀린 1개, 지난 날 그릇은 그날까지만
const c={start:'2026-11-01',mode:'fixed',days:[{t:'',items:[{id:'a'},{id:'b'}]},{t:'',items:[{id:'c'}]},{t:'',items:[{id:'d'},{id:'e'}]}],checks:{a:'2026-11-01',b:'2026-11-03',c:'2026-11-02',d:'2026-11-03'}};
let r=ctx.now(c,'2026-11-03');assert.equal(r.idx,2);assert.equal(r.pct,.5);assert.equal(r.behind,0);
assert.equal(ctx.pct(c,0,'2026-11-03'),.5);
delete c.checks.b;r=ctx.now(c,'2026-11-03');assert.equal(r.behind,1);
assert.equal(ctx.now(c,'2026-11-09').state,'finished');assert.equal(ctx.now(c,'2026-10-30').state,'upcoming');
// 밀기: 첫날을 못 끝냈으면 아직 Day 1, 오늘 끝내면 오늘은 Day 1 100%, 내일은 Day 2
c.mode='shift';delete c.checks.c;r=ctx.now(c,'2026-11-05');assert.equal(r.idx,0);
c.checks.b='2026-11-05';r=ctx.now(c,'2026-11-05');assert.equal(r.idx,0);assert.equal(r.pct,1);
r=ctx.now(c,'2026-11-06');assert.equal(r.idx,1);assert.equal(r.eta,'2026-11-07');
assert.ok(ctx.svg('pot',1).includes('<svg')&&ctx.svg('beaker',.5).includes('clip-path'));
console.log('PASS: challenge parsing (Day headers, links, daily, exam units) and today rules (keep dates / wait)');
