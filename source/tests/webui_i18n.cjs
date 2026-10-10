const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const root=path.resolve(__dirname,'../..');
const source=fs.readFileSync(path.join(root,'webroot/assets/index.js'),'utf8');
const html=fs.readFileSync(path.join(root,'webroot/index.html'),'utf8');
async function run(storageThrows) {
  const nodes=new Map(),calls=[];
  function node(id){if(!nodes.has(id))nodes.set(id,{textContent:'',className:'',innerHTML:'',classList:{add(){},remove(){}},addEventListener(e,fn){this[e]=fn},querySelectorAll(){return []}});return nodes.get(id)}
  const staticNodes=[];
  for(const m of html.matchAll(/<[^>]*id="([^"]+)"[^>]*data-i18n="([^"]+)"[^>]*>/g))staticNodes.push(Object.assign(node(m[1]),{getAttribute(){return m[2]}}));
  const ctx={navigator:{language:'zh-TW'},localStorage:{getItem(){if(storageThrows)throw Error('blocked');return null},setItem(){if(storageThrows)throw Error('blocked')}},document:{documentElement:{},getElementById:node,querySelectorAll(){return staticNodes}},setTimeout(){},clearTimeout(){},ksu:{exec(cmd,opts,cb){calls.push({cmd,cb})}}};ctx.window=ctx;
  vm.runInNewContext(source,ctx);
  ctx[calls[0].cb](0,JSON.stringify({configValid:true,partitionMounted:true,mounts:[],profiles:[]}),'');await Promise.resolve();
  assert.equal(node('current').textContent,'掛載正常');
  node('apply').click();const pending=node('health').textContent;
  node('lang-toggle').click();
  assert.equal(node('health').textContent,pending,'language toggle must preserve pending operation');
  assert.equal(node('current').textContent,'掛載正常');
  assert.equal(calls.length,2,'language toggle must not queue an extra root operation');
  ctx[calls[1].cb](1,'','simulated failure');await Promise.resolve();
  assert.match(node('toast').textContent,/应用失败/);
  ctx[calls[2].cb](0,JSON.stringify({configValid:true,partitionMounted:true,mounts:[{enabled:true,active:true,mounted:true,visible:false,name:'broken'}],profiles:[]}),'');await Promise.resolve();
  assert.equal(node('current').textContent,'部分挂载异常','failed visibility must never render healthy');
}
(async()=>{await run(false);await run(true);console.log('PASS: language toggle during operation, blocked storage, failed apply and unhealthy mount');})().catch(e=>{console.error(e);process.exitCode=1});
