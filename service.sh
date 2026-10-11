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
. "$MODDIR/user-state.sh" || exit 90
. "$MODDIR/watchers.sh" || exit 90
mkdir -p "$RUNTIME" 2>/dev/null
# v1.4.76 self-heal: older installers could unpack bin/mounttx without +x.
# Profile native transaction is intentionally native-only, so repair the bit at boot.
[ -f "$MODDIR/bin/mounttx" ] && chmod 0755 "$MODDIR/bin/mounttx" 2>/dev/null || true
[ -f "$MODDIR/bin/confwatch" ] && chmod 0755 "$MODDIR/bin/confwatch" 2>/dev/null || true

now(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date; }
log(){ printf '%s %s\n' "$(now)" "$*" >> "$LOG" 2>/dev/null; }
# Transactions have an independent session and do not inherit the supervisor,
# boot, or per-user locks. Event-reader recovery must not kill an active mount.
control_run() ( watch_detach "$CONTROL" "$@" 7>&- 8>&- 9>&-; )
mount_run() ( watch_detach "$MOUNT" "$@" 7>&- 8>&- 9>&-; )
user_desired_count(){
  _usr=$1
  awk -F'|' -v u="$_usr" '$2==u{c++} END{print c+0}' "$RUNTIME/parsed/mounts.desired" 2>/dev/null
}
user_is_unlocked(){
  yaw_user_unlocked "$1"
}

run_boot_initial(){
# Once-per-boot log rotation using /dev marker (cleared by reboot).
MARK=/dev/.yawasau_log_initialized_v170
if [ ! -e "$MARK" ]; then
  LOCK=/dev/.yawasau_log_init.lock_v170
  if mkdir "$LOCK" 2>/dev/null; then
    for _n in service mount dcim_switch watchers.stderr; do
      _f="$RUNTIME/${_n}.log"; [ -f "$_f" ] && mv -f "$_f" "$_f.prev" 2>/dev/null || true
      : > "$_f" 2>/dev/null || true
    done
    : > "$MARK" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
  else
    _i=0; while [ ! -e "$MARK" ] && [ "$_i" -lt 40 ]; do sleep 0.05; _i=$((_i+1)); done
  fi
fi
printf '========== YAWAsau Mount v1.4.95 Rust RC1｜本次開機日誌 ==========\n' >> "$LOG" 2>/dev/null
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
mount_run pre_unlock >/dev/null 2>&1
_rc=$?
if [ "$_rc" -ne 0 ]; then
  log "[錯誤] 主分區初始化失敗｜rc=$_rc"
else
  log '[資訊] 主分區初始化完成'
fi
control_run refresh_card >/dev/null 2>&1 || true

# Property-specific native wait; no healthy-state fallback polling.
"$PROPWAIT" equals sys.boot_completed 1 >/dev/null 2>&1 || return 1
log '[資訊] 系統開機完成'
if [ "$(user_desired_count 0)" -gt 0 ] 2>/dev/null && ! user_is_unlocked 0; then
  log '[資訊] User 0 尚未解鎖，等待 CE 儲存解密後再套用完整掛載'
  mount_run notify_boot_wait_unlock >/dev/null 2>&1 || true
fi

# Initial config apply mounts all currently unlocked users; locked users are deferred.
if user_is_unlocked 0; then
  mount_run notify 'YAWAsau Mount' '檢測到儲存已解鎖，開始掛載' boot_unlocked_start >/dev/null 2>&1 || true
fi
control_run reload boot_initial >/dev/null 2>&1
_birc=$?
log "[資訊] 初始 mount.conf 已套用｜rc=$_birc"
if [ "$_birc" -eq 0 ]; then
  _bidefer=$(config_defer_count); [ -n "$_bidefer" ] || _bidefer=0
  case "$_bidefer" in ''|*[!0-9]*) _bidefer=0;; esac
  # Locked users are a normal boot state. Do not show misleading 0/N incomplete.
  [ "$_bidefer" -eq 0 ] && mount_run notify_ready boot_initial >/dev/null 2>&1 || true
else
  mount_run notify_config_failed "$_birc" >/dev/null 2>&1 || true
fi
control_run refresh_card >/dev/null 2>&1 || true
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
  if [ -x "$CONFWATCH" ]; then
    "$CONFWATCH" --hash "$CONF" 2>/dev/null && return 0
  fi
  cksum "$CONF" 2>/dev/null | awk '{print $1":"$2}' | head -n1
}
config_defer_count(){
  sed -n 's/^DEFER=//p' "$RUNTIME/config.state" 2>/dev/null | head -n1
}

config_event(){
  _cw_hash=$(config_content_hash) || return 1
  _wrc=0
      _cw_last_hash=$_cw_hash
      # v1.4.81: Profile switching writes mount.conf internally after it has
      # already committed parsed/active/APPLIED_HASH.  confwatch will still see
      # that rename.  If the new file hash is already the applied profile_change
      # hash, do not run another config transaction or emit a misleading
      # "新增/移除 日常/工作" config notification.
      _cw_applied_hash=$(cat "$RUNTIME/config.applied.cksum" 2>/dev/null)
      _cw_state_reason=$(sed -n 's/^REASON=//p' "$RUNTIME/config.state" 2>/dev/null | head -n1)
      _cw_profile_marker_hash=$(sed -n 's/^HASH=//p' "$RUNTIME/profile_internal.conf_event" 2>/dev/null | head -n1)
      _cw_profile_internal=0
      if [ -n "$_cw_hash" ] && [ "$_cw_hash" = "$_cw_applied_hash" ] && [ "$_cw_state_reason" = profile_change ]; then
        _cw_profile_internal=1
      elif [ -n "$_cw_hash" ] && [ -n "$_cw_profile_marker_hash" ] && [ "$_cw_hash" = "$_cw_profile_marker_hash" ]; then
        # v1.4.87: confwatch may see the profile-published mount.conf before
        # profile_switch finishes committing APPLIED_HASH/config.state.  Wait a
        # short bounded window for the foreground transaction to finish; only run
        # a normal config reload if the matching profile commit never appears.
        _cw_wait=0
        while [ "$_cw_wait" -lt 10 ]; do
          sleep 0.10
          _cw_applied_hash=$(cat "$RUNTIME/config.applied.cksum" 2>/dev/null)
          _cw_state_reason=$(sed -n 's/^REASON=//p' "$RUNTIME/config.state" 2>/dev/null | head -n1)
          if [ "$_cw_hash" = "$_cw_applied_hash" ] && [ "$_cw_state_reason" = profile_change ]; then
            _cw_profile_internal=1
            break
          fi
          _cw_wait=$((_cw_wait + 1))
        done
      fi
      if [ "$_cw_profile_internal" -eq 1 ]; then
        log "[資訊] 偵測 Profile 內部 mount.conf 發佈事件，已跳過重複 config 套用與通知｜watch_rc=$_wrc｜reason=profile_internal｜hash=$_cw_hash"
        control_run refresh_card >/dev/null 2>&1 || true
        return 0
      fi
      log "[資訊] 偵測 mount.conf 內容變更｜watch_rc=$_wrc｜reason=confwatch_stable｜hash=$_cw_hash"
      _before_active="$RUNTIME/active.before.config.$$"
      cp -f "$RUNTIME/active_mounts.tsv" "$_before_active" 2>/dev/null || : > "$_before_active"
      control_run reload config_event >/dev/null 2>&1
      _arc=$?
      if [ "$_arc" -eq 3 ]; then
        sleep 0.15
        _cw_hash=$(config_content_hash); _cw_last_hash=$_cw_hash
        control_run reload config_event_retry >/dev/null 2>&1
        _arc=$?
      fi
      if [ "$_arc" -eq 0 ]; then
        log '[資訊] mount.conf 已即時套用'
        _after_reason=$(sed -n 's/^REASON=//p' "$RUNTIME/config.state" 2>/dev/null | head -n1)
        _after_hash=$(sed -n 's/^HASH=//p' "$RUNTIME/config.state" 2>/dev/null | head -n1)
        case "$_after_reason" in
          profile_change|duplicate_*)
            log "[資訊] confwatch 套用結果為 $_after_reason，已略過一般 mount.conf 結果通知｜hash=$_after_hash"
            ;;
          *)
            mount_run notify_config_result "$_before_active" config_event >/dev/null 2>&1 || true
            ;;
        esac
      else
        log "[警告] mount.conf 即時套用失敗，已保留最後有效掛載｜rc=$_arc"
        if [ "$_arc" -eq 3 ]; then
          mount_run notify_config_failed "$_arc" >/dev/null 2>&1 || true
        else
          mount_run notify_config_failed "$_arc" >/dev/null 2>&1 || true
          mount_run notify_incomplete config_event >/dev/null 2>&1 || true
        fi
      fi
      rm -f "$_before_active" 2>/dev/null || true
      control_run refresh_card >/dev/null 2>&1 || true
}


user_storage_ready(){
  _usr=$1
  if [ "$_usr" = 0 ]; then
    user_is_unlocked 0 && return 0
    return 1
  fi
  [ -d "/data/media/$_usr" ] || [ -d "/storage/emulated/$_usr" ]
}
user_active_count(){
  _usr=$1
  awk -F'|' -v u="$_usr" '$2==u{c++} END{print c+0}' "$RUNTIME/active_mounts.tsv" 2>/dev/null
}
notify_unlock_start_once_service(){
  _usr=$1
  _mk="/dev/.yawasau_service_unlock_start_${_usr}_v170"
  mkdir "$_mk" 2>/dev/null || return 0
  mount_run notify_unlock_start "$_usr" >/dev/null 2>&1 || true
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
    [ ! -e "$WATCH_STOP" ] || return 0
    [ "$_delay" = 0 ] || sleep "$_delay"
    [ ! -e "$WATCH_STOP" ] || return 0
    if user_storage_ready "$_usr"; then
      log "[資訊] User $_usr 儲存根目錄已就緒，重試掛載｜來源=$_why｜retry=$_idx"
      notify_unlock_start_once_service "$_usr"
      control_run reload "user_${_usr}_storage_ready_retry${_idx}" >/dev/null 2>&1
      _rrc=$?
      if [ "$_rrc" -ne 0 ]; then
        mount_run notify_config_failed "$_rrc" >/dev/null 2>&1 || true
      fi
      control_run refresh_card >/dev/null 2>&1 || true
      _want=$(user_desired_count "$_usr"); [ -n "$_want" ] || _want=0
      _have=$(user_active_count "$_usr"); [ -n "$_have" ] || _have=0
      log "[資訊] User $_usr 儲存路徑重試完成｜rc=$_rrc｜active=$_have/$_want｜retry=$_idx"
      if [ "$_want" -eq 0 ] || { [ "$_rrc" -eq 0 ] && [ "$_have" -ge "$_want" ]; }; then
        mount_run notify_ready "user_${_usr}_ready" >/dev/null 2>&1 || true
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
  mount_run notify_incomplete "user_${_usr}_timeout" >/dev/null 2>&1 || true
  return 1
}

user_reload_retry_once() (
  # Keep a mount retry alive if its event reader is restarted or stopped.
  watch_detach "$MODDIR/service.sh" --reload-user "$1" "${2:-lifecycle}" 7>&- 8>&- 9>&-
)
user_reload_retry_guarded() (
  _usr=$1; _why=${2:-lifecycle}
  case "$_usr" in ''|*[!0-9]*) return 0;; esac
  # flock is released on exit or SIGKILL, unlike the old mkdir-only lock.
  exec 8>"/dev/.yawasau_user_reload_${_usr}_v1490.lock" || return 1
  if ! watch_lock_wait 8 30; then
    log "[資訊] User $_usr 解鎖掛載仍由其他事件處理，稍後重試｜來源=$_why"
    return 75
  fi
  [ ! -e "$WATCH_STOP" ] || return 0
  _want=$(user_desired_count "$_usr"); _have=$(user_active_count "$_usr")
  [ "${_want:-0}" -gt "${_have:-0}" ] 2>/dev/null || return 0
  user_reload_retry "$_usr" "$_why"
)

recover_unlocked_users(){
  local _ru_reason _ru_user _ru_want _ru_have _ru_failed
  _ru_reason=${1:-watcher_start}; _ru_failed=0
  [ -f "$RUNTIME/parsed/mounts.desired" ] || return 0
  for _ru_user in $(awk -F'|' '!seen[$2]++ {print $2}' "$RUNTIME/parsed/mounts.desired"); do
    case "$_ru_user" in ''|*[!0-9]*) continue ;; esac
    user_storage_ready "$_ru_user" || continue
    _ru_want=$(user_desired_count "$_ru_user")
    _ru_have=$(user_active_count "$_ru_user")
    [ "${_ru_want:-0}" -gt "${_ru_have:-0}" ] 2>/dev/null || continue
    log "[資訊] 補接已解鎖但未完成的掛載｜User=$_ru_user｜來源=$_ru_reason｜active=$_ru_have/$_ru_want"
    user_reload_retry_once "$_ru_user" "$_ru_reason" || _ru_failed=1
  done
  return "$_ru_failed"
}

run_boot_service(){
  local _bs_reason _bs_boot
  _bs_reason=$1
  [ "$_bs_reason" != boot_completed ] || [ ! -e "$WATCH_STOP" ] || return 0
  [ -x /system/bin/flock ] && [ -x /system/bin/setsid ] || {
    log '[錯誤] 缺少 flock/setsid，無法啟動服務'
    return 1
  }
  # service.sh and KernelSU boot-completed.sh can arrive together. Only one
  # performs initial state reset/config apply; the other then checks workers.
  exec 7>"$RUNTIME/boot.initial.lock" || return 1
  if ! watch_lock_wait 7 30; then
    log '[警告] 初始掛載仍在執行，本次補查未取得啟動鎖'
    exec 7>&-
    return 4
  fi
  _bs_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$_bs_boot" ] || { exec 7>&-; return 1; }
  if [ "$(cat "$RUNTIME/boot.initial.done" 2>/dev/null)" != "$_bs_boot" ]; then
    run_boot_initial
    printf '%s\n' "$_bs_boot" > "$RUNTIME/boot.initial.done"
  fi
  exec 7>&-
  if sh "$MODDIR/watchers.sh" start "$_bs_reason"; then
    log '[資訊] 背景事件監聽器啟動確認完成｜mount.conf=event-driven｜user=lifecycle-driven'
  else
    log '[錯誤] 部分事件監聽器未就緒，請查看 watchers.stderr.log'
    return 1
  fi
  recover_unlocked_users "$_bs_reason"
}

case "${1:-boot}" in
  --event)
    case "$2" in
      config) config_event ;;
      source) control_run reload source_event ;;
      recover) recover_unlocked_users rust_start ;;
      unlock:*) user_reload_retry_guarded "${2#unlock:}" rust_event ;;
      stop:*) control_run unmount_user "${2#stop:}"; control_run refresh_card ;;
      *) exit 2 ;;
    esac
    exit $? ;;
  --recover-unlocked) recover_unlocked_users "${2:-manual_recovery}"; exit $? ;;
  --reload-user) user_reload_retry_guarded "$2" "$3"; exit $? ;;
  boot) run_boot_service boot; exit $? ;;
  --boot-reconcile) run_boot_service boot_completed; exit $? ;;
  *) echo 'usage: service.sh [--event EVENT|--recover-unlocked REASON|--reload-user USER REASON|--boot-reconcile]' >&2; exit 2 ;;
esac
