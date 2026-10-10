(()=>{
  const tool="/data/adb/modules/dcimswitch/control.sh";
  let api=null,seq=0,busy=false,refreshTimer=null,refreshBusy=false,profileSeq=0;

  // ───── 语言配置 ─────
  const I18N={
    zh:{
      currentState:"当前状态",loading:"读取中…",
      checkingHealth:"正在检查 mount.conf 与挂载状态",
      fsType:"文件系统",device:"分区设备",mountPoint:"主挂载点",
      configWatch:"设置监听",eventDriven:"事件驱动",
      mountItems:"挂载项目",actions:"操作",
      reapply:"重新应用挂载",refresh:"重新整理",validate:"设置检查",
      startService:"启动服务",showLog:"查看日志",switchLang:"繁體",
      noItems:"没有启用项目",ok:"正常",notMounted:"未挂载",notVisible:"不可见",
      configError:"配置文件有错",mountOk:"挂载正常",
      partitionNotMounted:"主分区未挂载",partialFail:"部分挂载异常",
      itemsOk:(n,t)=>`${n}/${t} 项正常`,
      healthConfigErr:"新 mount.conf 验证失败；当前挂载保持最后有效设置",
      healthOk:"mount.conf 已应用；变更会由事件监听即时生效",
      healthHint:"请查看挂载项目或日志",
      readFail:"读取失败",parseFail:"解析失败",
      switching:(l)=>`切换中：${l}`,switched:(l)=>`已切换：${l}`,
      switchStartFail:(e)=>`切换启动失败：${e}`,switchFail:(rc)=>`切换失败：rc=${rc}`,
      switchBg:"切换仍在后台执行，稍后自动刷新",
      applying:"正在重新应用 mount.conf…",
      applied:"挂载已重新应用",applyFail:(e)=>`应用失败：${e}`,
      startingService:"正在启动/重启挂载服务…",
      serviceStarted:"挂载服务已启动",serviceFail:(e)=>`服务启动失败：${e}`,
      checkPassed:"设置检查通过",checkFail:(rc)=>`设置检查失败：rc=${rc}`,
      footNote:"当前生效设置固定为 /data/adb/dcimswitch/mount.conf；修改此文件后由 confwatch/inotify 即时应用。模块目录内的 mount.conf 只是范例/模板，不会被监听。"
    },
    zh_Hant:{
      currentState:"目前狀態",loading:"讀取中…",
      checkingHealth:"正在檢查 mount.conf 與掛載狀態",
      fsType:"檔案系統",device:"分區裝置",mountPoint:"主掛載點",
      configWatch:"設定監聽",eventDriven:"事件驅動",
      mountItems:"掛載項目",actions:"操作",
      reapply:"重新套用掛載",refresh:"重新整理",validate:"設定檢查",
      startService:"啟動服務",showLog:"查看日誌",switchLang:"简体",
      noItems:"沒有啟用項目",ok:"正常",notMounted:"未掛載",notVisible:"不可見",
      configError:"設定檔有錯",mountOk:"掛載正常",
      partitionNotMounted:"主分區未掛載",partialFail:"部分掛載異常",
      itemsOk:(n,t)=>`${n}/${t} 項正常`,
      healthConfigErr:"新 mount.conf 驗證失敗；目前掛載保持最後有效設定",
      healthOk:"mount.conf 已套用；變更會由事件監聽即時生效",
      healthHint:"請查看掛載項目或日誌",
      readFail:"讀取失敗",parseFail:"解析失敗",
      switching:(l)=>`切換中：${l}`,switched:(l)=>`已切換：${l}`,
      switchStartFail:(e)=>`切換啟動失敗：${e}`,switchFail:(rc)=>`切換失敗：rc=${rc}`,
      switchBg:"切換仍在背景執行，稍後自動重新整理",
      applying:"正在重新套用 mount.conf…",
      applied:"掛載已重新套用",applyFail:(e)=>`套用失敗：${e}`,
      startingService:"正在啟動/重啟掛載服務…",
      serviceStarted:"掛載服務已啟動",serviceFail:(e)=>`服務啟動失敗：${e}`,
      checkPassed:"設定檢查通過",checkFail:(rc)=>`設定檢查失敗：rc=${rc}`,
      footNote:"目前生效設定固定為 /data/adb/dcimswitch/mount.conf；修改此檔後由 confwatch/inotify 即時套用。模組目錄內的 mount.conf 只是範例/模板，不會被監聽。"
    }
  };
  const LANG_KEY="yaw_lang";
  function detectLang(){
    let saved; try { saved=localStorage.getItem(LANG_KEY); } catch (_) {}
    if(saved==="zh"||saved==="zh_Hant") return saved;
    const n=(navigator.language||"").toLowerCase();
    if(n.includes("tw")||n.includes("hk")||n.includes("mo")||n.includes("hant")) return "zh_Hant";
    return "zh";
  }
  let lang=detectLang(),lastStatus=null;
  const t=(k,...a)=>{const v=I18N[lang][k];return typeof v==="function"?v(...a):v};

  function applyStaticI18n(){
    document.documentElement.lang=lang==="zh_Hant"?"zh-Hant":"zh-CN";
    document.querySelectorAll("[data-i18n]").forEach(n=>{
      const k=n.getAttribute("data-i18n");
      const v=I18N[lang][k];
      if(typeof v==="string") n.textContent=v;
    });
    const lt=document.getElementById("lang-toggle");
    if(lt) lt.textContent=t("switchLang");
  }

  if(typeof ksu!=="undefined"&&typeof ksu.exec==="function") api=ksu;
  else if(typeof ap!=="undefined"&&typeof ap.exec==="function") api=ap;
  const $=id=>document.getElementById(id);
  const el={current:$("current"),source:$("source"),health:$("health"),dot:$("dot"),fs:$("fs-state"),device:$("device-state"),root:$("root-state"),conf:$("conf-state"),mounts:$("mount-list"),profiles:$("profile-sections"),apply:$("apply"),refresh:$("refresh"),showlog:$("showlog"),validate:$("validate"),service:$("service"),log:$("log"),toast:$("toast"),langToggle:$("lang-toggle")};

  function exec(cmd){return new Promise(resolve=>{if(!api){resolve({e:-1,s:"",err:"No KernelSU/APatch WebUI API"});return}const cb="_ym"+(seq++);window[cb]=(code,out,err)=>{delete window[cb];resolve({e:code||0,s:(out||"").replace(/\r/g,""),err:err||""})};try{api.exec(cmd,"{}",cb)}catch(e){delete window[cb];resolve({e:-2,s:"",err:String(e)})}})}
  function toast(msg){el.toast.textContent=msg;el.toast.classList.remove("hidden");clearTimeout(toast.t);toast.t=setTimeout(()=>el.toast.classList.add("hidden"),2200)}
  function esc(s){return String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
  function activeMounts(j){return (j.mounts||[]).filter(m=>m.enabled&&m.active)}

  function renderMounts(j){
    const rows=activeMounts(j);
    if(!rows.length){el.mounts.innerHTML=`<div class="kv"><span>${t("noItems")}</span><b>-</b></div>`;return}
    el.mounts.innerHTML=rows.map(m=>{
      const ok=m.mounted&&m.visible;
      const state=ok?t("ok"):(!m.mounted?t("notMounted"):t("notVisible"));
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
    lastStatus=j;
    const rows=activeMounts(j),goodRows=rows.filter(m=>m.mounted&&m.visible).length;
    const good=j.configValid!==false&&j.partitionMounted&&goodRows===rows.length;
    el.current.textContent=j.configValid===false?t("configError"):(good?t("mountOk"):(!j.partitionMounted?t("partitionNotMounted"):t("partialFail")));
    el.source.textContent=`${j.mountPoint||'-'} · ${t("itemsOk",goodRows,rows.length)}`;
    el.health.textContent=j.configValid===false?t("healthConfigErr"):(good?t("healthOk"):t("healthHint"));
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
    if(r.e!==0){el.current.textContent=t("readFail");el.health.textContent=r.err||r.s;el.dot.className="dot bad";return}
    try{render(JSON.parse(r.s||"{}"))}catch(e){el.current.textContent=t("parseFail");el.health.textContent=r.s;el.dot.className="dot bad"}
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
    el.health.textContent=t("switching",label);
    toast(t("switching",label));
    const r=await exec(`sh ${tool} profile_async ${g} ${v}`);
    if(r.e!==0){
      busy=false;
      old.forEach(([b,a])=>b.classList.toggle("active",a));
      toast(t("switchStartFail",((r.s||"").trim()||(r.err||"").trim()||`rc=${r.e}`)));
      await refresh(true);
      return;
    }
    const m=(r.s||"").trim().match(/^QUEUED\|(.+)$/);
    const token=m?m[1]:"";
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
        el.health.textContent=t("switched",label);
        toast(t("switched",label));
        scheduleRefresh(1200);
      }else{
        old.forEach(([b,a])=>b.classList.toggle("active",a));
        toast(t("switchFail",rc));
        await refresh(true);
      }
      return;
    }
    if(tryCount>=30){
      busy=false;
      toast(t("switchBg"));
      scheduleRefresh(800);
      return;
    }
    setTimeout(()=>pollProfile(token,label,old,tryCount+1),250);
  }

  async function apply(){
    if(busy)return;busy=true;
    el.health.textContent=t("applying");
    const r=await exec(`sh ${tool} apply_all`);
    busy=false;
    toast(r.e===0?t("applied"):t("applyFail",((r.s||"").trim()||(r.err||"").trim()||`rc=${r.e}`)));
    await refresh();
  }

  el.apply.addEventListener("click",apply);
  el.refresh.addEventListener("click",refresh);

  if(el.validate)el.validate.addEventListener("click",async()=>{
    const r=await exec(`sh ${tool} dryrun`);
    el.log.textContent=(r.s||"")+(r.err?"\n"+r.err:"");
    el.log.classList.remove("hidden");
    toast(r.e===0?t("checkPassed"):t("checkFail",r.e));
  });
  if(el.service)el.service.addEventListener("click",async()=>{
    if(busy)return;busy=true;
    el.health.textContent=t("startingService");
    const r=await exec(`sh ${tool} restart_service`);
    busy=false;
    toast(r.e===0?t("serviceStarted"):t("serviceFail",((r.s||"").trim()||(r.err||"").trim()||`rc=${r.e}`)));
    setTimeout(()=>refresh(true),800);
  });
  el.showlog.addEventListener("click",async()=>{
    const r=await exec(`sh ${tool} log`);
    el.log.textContent=(r.s||"")+(r.err?"\n"+r.err:"");
    el.log.classList.remove("hidden");
  });

  if(el.langToggle)el.langToggle.addEventListener("click",()=>{
    lang=lang==="zh"?"zh_Hant":"zh";
    try { localStorage.setItem(LANG_KEY,lang); } catch (_) {}
    applyStaticI18n();
    if(lastStatus && !busy) render(lastStatus);
    if(!busy && !refreshBusy) refresh(true);
  });

  applyStaticI18n();
  refresh();
})();
