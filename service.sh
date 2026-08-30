#!/system/bin/sh
MODDIR=${0%/*}
DATA_DIR=/data/adb/dcimswitch
RUNTIME="$DATA_DIR/runtime"
LOG="$RUNTIME/service.log"
CONF="$DATA_DIR/mount.conf"
CONTROL="$MODDIR/control.sh"
MOUNT="$MODDIR/mount.sh"
CONFWATCH="$MODDIR/bin/confwatch"
PROPWAIT="$MODDIR/bin/propwait"
FILEWATCH="$MODDIR/bin/filewatch"
mkdir -p "$RUNTIME" 2>/dev/null

now(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date; }
log(){ printf '%s %s\n' "$(now)" "$*" >> "$LOG" 2>/dev/null; }
user_desired_count(){
  _usr=$1
  awk -F'|' -v u="$_usr" '$2==u{c++} END{print c+0}' "$RUNTIME/parsed/mounts.desired" 2>/dev/null
}
user_is_unlocked(){
  _usr=$1
  _x=$(cmd user is-user-unlocked "$_usr" 2>/dev/null | tr 'A-Z' 'a-z' | head -n1)
  case "$_x" in true|1|*' true'*) return 0;; false|0|*' false'*) return 1;; esac
  [ "$(getprop "sys.user.$_usr.ce_available" 2>/dev/null)" = true ] && return 0
  [ "$(getprop "sys.user.$_usr.ce_available" 2>/dev/null)" = 1 ] && return 0
  return 1
}

# Once-per-boot log rotation using /dev marker (cleared by reboot).
MARK=/dev/.yawasau_log_initialized_v170
if [ ! -e "$MARK" ]; then
  LOCK=/dev/.yawasau_log_init.lock_v170
  if mkdir "$LOCK" 2>/dev/null; then
    for _n in service mount dcim_switch; do
      _f="$RUNTIME/${_n}.log"; [ -f "$_f" ] && mv -f "$_f" "$_f.prev" 2>/dev/null || true
      : > "$_f" 2>/dev/null || true
    done
    : > "$MARK" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
  else
    _i=0; while [ ! -e "$MARK" ] && [ "$_i" -lt 40 ]; do sleep 0.05; _i=$((_i+1)); done
  fi
fi
printf '========== YAWAsau Mount v1.4.70｜本次開機日誌 ==========\n' >> "$LOG" 2>/dev/null
log '[資訊] 掛載服務啟動'
log "[資訊] 目前生效設定｜$CONF"
log "[資訊] 模組內建模板不會被監聽｜$MODDIR/mount.conf / mount.conf.default / mount.conf.example"

# v1.4.56: runtime mount state is not persistent across reboot.
# Bind mounts/FUSE mounts disappear at boot, so stale active_mounts.tsv must not
# make lifecycle retries report active=1/1 without performing a fresh mount.
if [ ! -e /dev/.yawasau_active_reset_v170 ]; then
  rm -f "$RUNTIME/active_mounts.tsv" "$RUNTIME"/active_mounts.tsv.next.* "$RUNTIME/config.state" "$RUNTIME/bindfs_policy.applied" "$RUNTIME"/media_provider_ns.*.cache 2>/dev/null || true
  rm -f "$RUNTIME"/notify.all_ready.* "$RUNTIME"/notify.incomplete.* "$RUNTIME"/notify.mount_summary.* 2>/dev/null || true
  : > /dev/.yawasau_active_reset_v170 2>/dev/null || true
  log '[資訊] 本次開機已清除非持久化 active_mounts / namespace cache，避免沿用上次開機掛載狀態'
fi

# Seed config and mount physical partition before user unlock.
sh "$MOUNT" pre_unlock >/dev/null 2>&1
_rc=$?
if [ "$_rc" -ne 0 ]; then
  log "[錯誤] 主分區初始化失敗｜rc=$_rc"
else
  log '[資訊] 主分區初始化完成'
fi
sh "$CONTROL" refresh_card >/dev/null 2>&1 || true

# Wait boot_completed event-first; polling only if propwait unavailable/fails.
if [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ]; then
  if [ -x "$PROPWAIT" ]; then
    log '[資訊] propwait 等待 sys.boot_completed=1'
    "$PROPWAIT" equals sys.boot_completed 1 >/dev/null 2>&1 || true
  fi
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ]; do sleep 2; done
fi
log '[資訊] 系統開機完成'
if [ "$(user_desired_count 0)" -gt 0 ] 2>/dev/null && ! user_is_unlocked 0; then
  log '[資訊] User 0 尚未解鎖，等待 CE 儲存解密後再套用完整掛載'
  sh "$MOUNT" notify_boot_wait_unlock >/dev/null 2>&1 || true
fi

# Initial config apply mounts all currently unlocked users; locked users are deferred.
if user_is_unlocked 0; then
  sh "$MOUNT" notify 'YAWAsau Mount' '檢測到儲存已解鎖，開始掛載' boot_unlocked_start >/dev/null 2>&1 || true
fi
sh "$CONTROL" reload boot_initial >/dev/null 2>&1
_birc=$?
log "[資訊] 初始 mount.conf 已套用｜rc=$_birc"
if [ "$_birc" -eq 0 ]; then
  _bidefer=$(config_defer_count); [ -n "$_bidefer" ] || _bidefer=0
  case "$_bidefer" in ''|*[!0-9]*) _bidefer=0;; esac
  # Locked users are a normal boot state. Do not show misleading 0/N incomplete.
  [ "$_bidefer" -eq 0 ] && sh "$MOUNT" notify_ready boot_initial >/dev/null 2>&1 || true
else
  sh "$MOUNT" notify_config_failed "$_birc" >/dev/null 2>&1 || true
fi
sh "$CONTROL" refresh_card >/dev/null 2>&1 || true

watch_pid_alive(){ case "$1" in ''|*[!0-9]*) return 1;; esac; [ -d "/proc/$1" ]; }
start_singleton(){
  _name=$1; shift; _pf="$RUNTIME/${_name}.pid"; _old=$(cat "$_pf" 2>/dev/null)
  if watch_pid_alive "$_old"; then return 0; fi
  rm -f "$_pf" 2>/dev/null
  ( "$@" ) & _p=$!; printf '%s\n' "$_p" > "$_pf" 2>/dev/null
}

wait_config_stable(){
  _wcs_prev=''; _wcs_same=0; _wcs_i=0
  while [ "$_wcs_i" -lt 16 ]; do
    # Content checksum detects same-size rewrites within the same second, which
    # mtime+size alone cannot distinguish on several Android stat builds.
    _wcs_sig=$(cksum "$CONF" 2>/dev/null | awk '{print $1":"$2}' | head -n1)
    if [ -n "$_wcs_sig" ] && [ "$_wcs_sig" = "$_wcs_prev" ]; then
      _wcs_same=$((_wcs_same+1))
      [ "$_wcs_same" -ge 2 ] && return 0
    else
      _wcs_same=0
      _wcs_prev=$_wcs_sig
    fi
    sleep 0.05
    _wcs_i=$((_wcs_i+1))
  done
  return 0
}

config_content_hash(){
  cksum "$CONF" 2>/dev/null | awk '{print $1":"$2}' | head -n1
}
config_defer_count(){
  sed -n 's/^DEFER=//p' "$RUNTIME/config.state" 2>/dev/null | head -n1
}

config_watch_loop(){
  log "[資訊] mount.conf 事件監聽啟動｜binary=confwatch｜path=$CONF"
  _cw_last_hash=$(config_content_hash)
  while true; do
    if [ -x "$CONFWATCH" ]; then
      "$CONFWATCH" --wait-change "$CONF" >/dev/null 2>&1
      _wrc=$?
      # Editors may emit close-write/rename/attrib as separate events. Wait only
      # until content is stable, then apply.  chmod/attrib emitted by our own
      # seed_config must not be reported as a real config reload.
      wait_config_stable
      _cw_hash=$(config_content_hash)
      if [ -n "$_cw_hash" ] && [ "$_cw_hash" = "$_cw_last_hash" ]; then
        log "[資訊] 偵測 mount.conf 非內容事件，已跳過｜watch_rc=$_wrc｜hash=$_cw_hash"
        continue
      fi
      _cw_last_hash=$_cw_hash
      log "[資訊] 偵測 mount.conf 內容變更｜watch_rc=$_wrc｜hash=$_cw_hash"
      _before_active="$RUNTIME/active.before.config.$$"
      cp -f "$RUNTIME/active_mounts.tsv" "$_before_active" 2>/dev/null || : > "$_before_active"
      sh "$CONTROL" reload config_event >/dev/null 2>&1
      _arc=$?
      if [ "$_arc" -eq 3 ]; then
        # A few editors briefly expose an incomplete replacement file. Retry once
        # after a short settle instead of treating the transient snapshot as final.
        sleep 0.15
        wait_config_stable
        _cw_hash=$(config_content_hash); _cw_last_hash=$_cw_hash
        sh "$CONTROL" reload config_event_retry >/dev/null 2>&1
        _arc=$?
      fi
      if [ "$_arc" -eq 0 ]; then
        log '[資訊] mount.conf 已即時套用'
        sh "$MOUNT" notify_config_result "$_before_active" config_event >/dev/null 2>&1 || true
      else
        log "[警告] mount.conf 即時套用失敗，已保留最後有效掛載｜rc=$_arc"
        if [ "$_arc" -eq 3 ]; then
          sh "$MOUNT" notify_config_failed "$_arc" >/dev/null 2>&1 || true
        else
          sh "$MOUNT" notify_config_failed "$_arc" >/dev/null 2>&1 || true
          sh "$MOUNT" notify_incomplete config_event >/dev/null 2>&1 || true
        fi
      fi
      rm -f "$_before_active" 2>/dev/null || true
      sh "$CONTROL" refresh_card >/dev/null 2>&1 || true
    else
      # Safety fallback only; packaged arm64 module should never use this branch.
      log '[警告] confwatch 遺失，退回每 2 秒檢查設定檔時間戳'
      _last=''
      while [ ! -x "$CONFWATCH" ]; do
        _now=$(stat -c '%Y:%s' "$CONF" 2>/dev/null)
        if [ -n "$_last" ] && [ "$_now" != "$_last" ]; then sh "$CONTROL" reload config_poll_fallback >/dev/null 2>&1; fi
        _last=$_now; sleep 2
      done
    fi
  done
}


user_storage_ready(){
  _usr=$1
  if [ "$_usr" = 0 ]; then
    user_is_unlocked 0 && return 0
    return 1
  fi
  [ -d "/data/media/$_usr" ] || [ -d "/storage/emulated/$_usr" ]
}
user_desired_count(){
  _usr=$1
  awk -F'|' -v u="$_usr" '$2==u{c++} END{print c+0}' "$RUNTIME/parsed/mounts.desired" 2>/dev/null
}
user_active_count(){
  _usr=$1
  awk -F'|' -v u="$_usr" '$2==u{c++} END{print c+0}' "$RUNTIME/active_mounts.tsv" 2>/dev/null
}
user_is_unlocked(){
  _usr=$1
  _x=$(cmd user is-user-unlocked "$_usr" 2>/dev/null | tr 'A-Z' 'a-z' | head -n1)
  case "$_x" in true|1|*' true'*) return 0;; false|0|*' false'*) return 1;; esac
  [ "$(getprop "sys.user.$_usr.ce_available" 2>/dev/null)" = true ] && return 0
  [ "$(getprop "sys.user.$_usr.ce_available" 2>/dev/null)" = 1 ] && return 0
  return 1
}
notify_unlock_start_once_service(){
  _usr=$1
  _mk="/dev/.yawasau_service_unlock_start_${_usr}_v170"
  mkdir "$_mk" 2>/dev/null || return 0
  sh "$MOUNT" notify_unlock_start "$_usr" >/dev/null 2>&1 || true
  return 0
}

user_reload_retry(){
  _usr=$1; _why=${2:-lifecycle}
  case "$_usr" in ''|*[!0-9]*) return 0;; esac
  _idx=0
  # Try immediately once, then back off. Private Space often emits the lifecycle
  # event before cmd user reports unlocked, but /data/media/<user> becomes ready
  # first; keep retrying until the desired rows for that user are actually active.
  for _delay in 0 0.5 1 2 4 6 10; do
    [ "$_delay" = 0 ] || sleep "$_delay"
    if user_storage_ready "$_usr"; then
      log "[資訊] User $_usr 儲存根目錄已就緒，重試掛載｜來源=$_why｜retry=$_idx"
      notify_unlock_start_once_service "$_usr"
      sh "$CONTROL" reload "user_${_usr}_storage_ready_retry${_idx}" >/dev/null 2>&1
      _rrc=$?
      if [ "$_rrc" -ne 0 ]; then
        sh "$MOUNT" notify_config_failed "$_rrc" >/dev/null 2>&1 || true
      fi
      sh "$CONTROL" refresh_card >/dev/null 2>&1 || true
      _want=$(user_desired_count "$_usr"); [ -n "$_want" ] || _want=0
      _have=$(user_active_count "$_usr"); [ -n "$_have" ] || _have=0
      log "[資訊] User $_usr 儲存路徑重試完成｜rc=$_rrc｜active=$_have/$_want｜retry=$_idx"
      if [ "$_want" -eq 0 ] || { [ "$_rrc" -eq 0 ] && [ "$_have" -ge "$_want" ]; }; then
        sh "$MOUNT" notify_ready "user_${_usr}_ready" >/dev/null 2>&1 || true
        return 0
      fi
    else
      log "[資訊] User $_usr 儲存根目錄尚未就緒，等待後重試｜來源=$_why｜retry=$_idx"
    fi
    _idx=$((_idx+1))
  done
  _want=$(user_desired_count "$_usr"); [ -n "$_want" ] || _want=0
  _have=$(user_active_count "$_usr"); [ -n "$_have" ] || _have=0
  log "[警告] User $_usr 儲存路徑等待逾時，已保留延後掛載｜來源=$_why｜active=$_have/$_want"
  sh "$MOUNT" notify_incomplete "user_${_usr}_timeout" >/dev/null 2>&1 || true
  return 0
}

user_reload_retry_once(){
  _usr=$1; _why=${2:-lifecycle}
  case "$_usr" in ''|*[!0-9]*) return 0;; esac
  _lk="/dev/.yawasau_user_reload_running_${_usr}_v170"
  if ! mkdir "$_lk" 2>/dev/null; then
    log "[資訊] User $_usr 解鎖掛載已由其他事件處理，略過重複觸發｜來源=$_why"
    return 0
  fi
  user_reload_retry "$_usr" "$_why"
  rmdir "$_lk" 2>/dev/null || true
  return 0
}

userstate_watch_loop(){
  command -v logcat >/dev/null 2>&1 || return 0
  log '[資訊] 多使用者 lifecycle 事件監聽啟動｜RUNNING_UNLOCKED/STOPPING/SHUTDOWN'
  while true; do
    logcat -v tag -T 1 UserController.UserState:I '*:S' 2>/dev/null | while IFS= read -r _line; do
      case "$_line" in
        *'User '*' to RUNNING_UNLOCKED'*|*'User '*'state changed from '*'to RUNNING_UNLOCKED'*)
          _u=$(printf '%s\n' "$_line" | sed -n 's/.*User \([0-9][0-9]*\) .*/\1/p' | head -n1)
          case "$_u" in ''|*[!0-9]*) continue;; esac
          log "[資訊] User 解鎖事件｜User=$_u｜準備套用對應掛載"
          user_reload_retry_once "$_u" lifecycle >/dev/null 2>&1 &
          ;;
        *'User '*' to STOPPING'*|*'User '*' to SHUTDOWN'*)
          _u=$(printf '%s\n' "$_line" | sed -n 's/.*User \([0-9][0-9]*\) .*/\1/p' | head -n1)
          case "$_u" in ''|*[!0-9]*) continue;; esac
          log "[資訊] User 停止事件｜User=$_u｜卸載該 User 映射"
          sh "$CONTROL" unmount_user "$_u" >/dev/null 2>&1
          sh "$CONTROL" refresh_card >/dev/null 2>&1 || true
          ;;
      esac
    done
    log '[警告] User lifecycle logcat 監聽意外結束，1 秒後重新建立'
    sleep 1
  done
}

# User 0 event fallbacks: they race with the lifecycle watcher and are one-shot.
user0_prop_once(){
  [ -x "$PROPWAIT" ] || return 0
  if sh "$MOUNT" status 2>/dev/null | grep -q '"user":0'; then
    _ce=$(getprop sys.user.0.ce_available 2>/dev/null)
    case "$_ce" in
      true|1) ;;
      *) "$PROPWAIT" equals sys.user.0.ce_available true >/dev/null 2>&1 || return 0; _ce=$(getprop sys.user.0.ce_available 2>/dev/null) ;;
    esac
    log "[資訊] User 0 CE 解鎖事件命中｜來源=propwait｜value=${_ce:-event}"
    user_reload_retry_once 0 propwait >/dev/null 2>&1
  fi
}
user0_file_once(){
  [ -x "$FILEWATCH" ] || return 0
  sh "$MOUNT" status 2>/dev/null | grep -q '"user":0' || return 0
  "$FILEWATCH" --wait-exists /data/media/0/Download >/dev/null 2>&1 || return 0
  log '[資訊] User 0 儲存路徑事件命中｜來源=filewatch'
  user_reload_retry_once 0 filewatch >/dev/null 2>&1
}

start_singleton confwatch config_watch_loop
start_singleton userstate userstate_watch_loop
start_singleton user0prop user0_prop_once
start_singleton user0file user0_file_once
log '[資訊] 背景事件監聽器已啟動｜mount.conf=event-driven｜user=lifecycle-driven'
exit 0
