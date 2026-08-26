(()=>{
  const tool="/data/adb/modules/dcimswitch/control.sh";
  let api=null,seq=0,busy=false,refreshTimer=null,refreshBusy=false,profileSeq=0;
  if(typeof ksu!=="undefined"&&typeof ksu.exec==="function") api=ksu;
  else if(typeof ap!=="undefined"&&typeof ap.exec==="function") api=ap;
  const $=id=>document.getElementById(id);
  const el={current:$("current"),source:$("source"),health:$("health"),dot:$("dot"),fs:$("fs-state"),device:$("device-state"),root:$("root-state"),conf:$("conf-state"),mounts:$("mount-list"),profiles:$("profile-sections"),apply:$("apply"),refresh:$("refresh"),showlog:$("showlog"),validate:$("validate"),service:$("service"),log:$("log"),toast:$("toast")};
  function exec(cmd){return new Promise(resolve=>{if(!api){resolve({e:-1,s:"",err:"No KernelSU/APatch WebUI API"});return}const cb="_ym"+(seq++);window[cb]=(code,out,err)=>{delete window[cb];resolve({e:code||0,s:(out||"").replace(/\r/g,""),err:err||""})};try{api.exec(cmd,"{}",cb)}catch(e){delete window[cb];resolve({e:-2,s:"",err:String(e)})}})}
  function toast(msg){el.toast.textContent=msg;el.toast.classList.remove("hidden");clearTimeout(toast.t);toast.t=setTimeout(()=>el.toast.classList.add("hidden"),2200)}
  function esc(s){return String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
  function activeMounts(j){return (j.mounts||[]).filter(m=>m.enabled&&m.active)}
  function renderMounts(j){
    const rows=activeMounts(j);
    if(!rows.length){el.mounts.innerHTML='<div class="kv"><span>沒有啟用項目</span><b>-</b></div>';return}
    el.mounts.innerHTML=rows.map(m=>{
      const ok=m.mounted&&m.visible;
      const state=ok?"正常":(!m.mounted?"未掛載":"不可見");
      return `<div class="mount-item"><div class="mount-head"><b>${esc(m.name)}</b><span class="mount-state ${ok?'good':'badstate'}">${state}</span></div><div class="mount-meta">User ${m.user} · ${esc(m.source)} → ${esc(m.target)}</div></div>`;
    }).join("");
  }
  function renderProfiles(j){
    const profiles=j.profiles||[];
    if(!profiles.length){el.profiles.innerHTML="";el.profiles.classList.add("hidden");return}
    el.profiles.classList.remove("hidden");
    el.profiles.innerHTML=profiles.map(p=>{
      const cards=(p.options||[]).map(o=>`<button class="profile card ${o.value===p.selected?'active':''}" data-g="${esc(p.group)}" data-v="${esc(o.value)}" type="button"><div class="profile-title">${esc(o.name||o.value)}</div><div class="profile-path mono">${esc(o.source)}</div><div class="profile-desc">${esc(o.target)} · ${esc(o.value)}</div></button>`).join("");
      return `<section class="profile-wrap"><div class="profile-heading">${esc(p.group)}</div><div class="grid">${cards}</div></section>`;
    }).join("");
    el.profiles.querySelectorAll("button[data-g]").forEach(b=>b.addEventListener("click",()=>selectProfile(b.dataset.g,b.dataset.v)));
  }
  function render(j){
    const rows=activeMounts(j),goodRows=rows.filter(m=>m.mounted&&m.visible).length;
    const good=j.configValid!==false&&j.partitionMounted&&goodRows===rows.length;
    el.current.textContent=j.configValid===false?"設定檔有錯":(good?"掛載正常":(!j.partitionMounted?"主分區未掛載":"部分掛載異常"));
    el.source.textContent=`${j.mountPoint||'-'} · ${goodRows}/${rows.length} 項正常`;
    el.health.textContent=j.configValid===false?"新 mount.conf 驗證失敗；目前掛載保持最後有效設定":(good?"mount.conf 已套用；變更會由事件監聽即時生效":"請查看掛載項目或日誌");
    el.dot.className="dot "+(good?"ok":(!j.partitionMounted?"bad":""));
    el.fs.textContent=j.fsType||"-";el.device.textContent=j.device||"-";el.root.textContent=j.mountPoint||"-";el.conf.textContent=j.config||"-";
    renderMounts(j);renderProfiles(j);
  }
  function scheduleRefresh(delay=3000){clearTimeout(refreshTimer);refreshTimer=setTimeout(()=>refresh(false),delay)}
  async function refresh(force=true){
    if(refreshBusy||busy){if(!force)scheduleRefresh(1200);return}
    refreshBusy=true;
    const mySeq=profileSeq;
    const r=await exec(`sh ${tool} status`);
    refreshBusy=false;
    if(!force&&mySeq!==profileSeq)return;
    if(r.e!==0){el.current.textContent="讀取失敗";el.health.textContent=r.err||r.s;el.dot.className="dot bad";return}
    try{render(JSON.parse(r.s||"{}"))}catch(e){el.current.textContent="解析失敗";el.health.textContent=r.s;el.dot.className="dot bad"}
  }
  async function selectProfile(g,v){
    if(busy)return;
    clearTimeout(refreshTimer);
    profileSeq++;
    busy=true;
    const btn=[...el.profiles.querySelectorAll("button[data-g]")].find(b=>b.dataset.g===g&&b.dataset.v===v);
    const label=btn?.querySelector(".profile-title")?.textContent||v;
    const old=[...el.profiles.querySelectorAll("button[data-g]")].map(b=>[b,b.classList.contains("active")]);
    if(btn){el.profiles.querySelectorAll(`button[data-g="${CSS.escape(g)}"]`).forEach(b=>b.classList.remove("active"));btn.classList.add("active")}
    el.health.textContent=`切換中：${label}`;
    toast(`切換中：${label}`);
    const r=await exec(`sh ${tool} profile_async ${g} ${v}`);
    if(r.e!==0){
      busy=false;
      old.forEach(([b,a])=>b.classList.toggle("active",a));
      toast("切換啟動失敗："+(((r.s||"").trim()||(r.err||"").trim()||`rc=${r.e}`)));
      await refresh(true);
      return;
    }
    const m=(r.s||"").trim().match(/^QUEUED\|(.+)$/);
    const token=m?m[1]:"";
    // The real mount runs in the background. Keep the UI optimistic and only
    // reconcile when the backend reports DONE. This avoids blocking the WebUI
    // on the 1-2s namespace bind/probe path.
    pollProfile(token,label,old,0);
  }
  async function pollProfile(token,label,old,tryCount){
    const r=await exec(`sh ${tool} profile_async_state`);
    const line=(r.s||"").trim().split(/\n/).pop()||"";
    const parts=line.split("|");
    if(parts[0]==="DONE" && (!token || parts[1]===token)){
      busy=false;
      const rc=parseInt(parts[4]||"1",10);
      if(rc===0){
        el.health.textContent=`已切換：${label}`;
        toast(`已切換：${label}`);
        scheduleRefresh(1200);
      }else{
        old.forEach(([b,a])=>b.classList.toggle("active",a));
        toast(`切換失敗：rc=${rc}`);
        await refresh(true);
      }
      return;
    }
    if(tryCount>=30){
      busy=false;
      toast("切換仍在背景執行，稍後自動刷新");
      scheduleRefresh(800);
      return;
    }
    setTimeout(()=>pollProfile(token,label,old,tryCount+1),250);
  }
  async function apply(){if(busy)return;busy=true;el.health.textContent="正在重新套用 mount.conf…";const r=await exec(`sh ${tool} apply_all`);busy=false;toast(r.e===0?"掛載已重新套用":"套用失敗："+(((r.s||"").trim()||(r.err||"").trim()||`rc=${r.e}`)));await refresh()}
  el.apply.addEventListener("click",apply);el.refresh.addEventListener("click",refresh);
  if(el.validate)el.validate.addEventListener("click",async()=>{const r=await exec(`sh ${tool} dryrun`);el.log.textContent=(r.s||"")+(r.err?"\n"+r.err:"");el.log.classList.remove("hidden");toast(r.e===0?"設定檢查通過":`設定檢查失敗：rc=${r.e}`)});
  if(el.service)el.service.addEventListener("click",async()=>{if(busy)return;busy=true;el.health.textContent="正在啟動/重啟掛載服務…";const r=await exec(`sh ${tool} restart_service`);busy=false;toast(r.e===0?"掛載服務已啟動":"服務啟動失敗："+(((r.s||"").trim()||(r.err||"").trim()||`rc=${r.e}`)));setTimeout(()=>refresh(true),800)});
  el.showlog.addEventListener("click",async()=>{const r=await exec(`sh ${tool} log`);el.log.textContent=(r.s||"")+(r.err?"\n"+r.err:"");el.log.classList.remove("hidden")});
  refresh();
})();
