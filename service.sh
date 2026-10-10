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
printf '========== YAWAsau Mount v1.4.92｜本次开机日志 ==========\n' >> "$LOG" 2>/dev/null
log '[资讯] 挂载服务启动'
log "[资讯] 目前生效设定｜$CONF"
log "[资讯] 模组内建模板不会被监听｜$MODDIR/mount.conf / mount.conf.default / mount.conf.example"

# v1.4.56: runtime mount state is not persistent across reboot.
# Bind mounts/FUSE mounts disappear at boot, so stale active_mounts.tsv must not
# make lifecycle retries report active=1/1 without performing a fresh mount.
if [ ! -e /dev/.yawasau_active_reset_v170 ]; then
  rm -f "$RUNTIME/active_mounts.tsv" "$RUNTIME"/active_mounts.tsv.next.* "$RUNTIME/config.state" "$RUNTIME/bindfs_policy.applied" "$RUNTIME"/media_provider_ns.*.cache 2>/dev/null || true
  rm -f "$RUNTIME"/notify.all_ready.* "$RUNTIME"/notify.incomplete.* "$RUNTIME"/notify.mount_summary.* 2>/dev/null || true
  : > /dev/.yawasau_active_reset_v170 2>/dev/null || true
  log '[资讯] 本次开机已清除非持久化 active_mounts / namespace cache，避免沿用上次开机挂载状态'
fi

# Seed config and mount physical partition before user unlock.
mount_run pre_unlock >/dev/null 2>&1
_rc=$?
if [ "$_rc" -ne 0 ]; then
  log "[错误] 主分区初始化失败｜rc=$_rc"
else
  log '[资讯] 主分区初始化完成'
fi
control_run refresh_card >/dev/null 2>&1 || true

# Wait boot_completed event-first; polling only if propwait unavailable/fails.
if [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ]; then
  if [ -x "$PROPWAIT" ]; then
    log '[资讯] propwait 等待 sys.boot_completed=1'
    "$PROPWAIT" equals sys.boot_completed 1 >/dev/null 2>&1 || true
  fi
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ]; do sleep 2; done
fi
log '[资讯] 系统开机完成'
if [ "$(user_desired_count 0)" -gt 0 ] 2>/dev/null && ! user_is_unlocked 0; then
  log '[资讯] User 0 尚未解锁，等待 CE 储存解密后再套用完整挂载'
  mount_run notify_boot_wait_unlock >/dev/null 2>&1 || true
fi

# Initial config apply mounts all currently unlocked users; locked users are deferred.
if user_is_unlocked 0; then
  mount_run notify 'YAWAsau Mount' '检测到储存已解锁，开始挂载' boot_unlocked_start >/dev/null 2>&1 || true
fi
control_run reload boot_initial >/dev/null 2>&1
_birc=$?
log "[资讯] 初始 mount.conf 已套用｜rc=$_birc"
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

config_watch_loop(){
  log "[资讯] mount.conf 事件监听启动｜binary=confwatch｜path=$CONF｜mode=native-stable-content"
  _cw_last_hash=$(config_content_hash)
  while true; do
    if [ -x "$CONFWATCH" ]; then
      # v1.4.78: confwatch owns directory inotify + content hash fallback +
      # stable debounce internally.  service.sh no longer polls mount.conf every
      # 0.25s with shell cksum/sleep; this keeps reliability for rename-style
      # editors without a permanent shell polling loop.
      _cw_hash=$("$CONFWATCH" --wait-stable-change "$CONF" "$_cw_last_hash")
      _wrc=$?
      if [ "$_wrc" -ne 0 ]; then
        log "[警告] confwatch 退出，交由管理程序退避重启｜rc=$_wrc"
        return "$_wrc"
      fi
      case "$_cw_hash" in *:*) ;; *) _cw_hash=$(config_content_hash);; esac
      if [ -z "$_cw_hash" ]; then
        log "[警告] confwatch 未取得内容 hash，稍后重试｜watch_rc=$_wrc"
        sleep 0.25
        continue
      fi
      if [ -n "$_cw_last_hash" ] && [ "$_cw_hash" = "$_cw_last_hash" ]; then
        log "[资讯] 侦测 mount.conf 非内容事件，已跳过｜watch_rc=$_wrc｜reason=confwatch_stable｜hash=$_cw_hash"
        continue
      fi
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
        log "[资讯] 侦测 Profile 内部 mount.conf 发布事件，已跳过重复 config 套用与通知｜watch_rc=$_wrc｜reason=profile_internal｜hash=$_cw_hash"
        control_run refresh_card >/dev/null 2>&1 || true
        continue
      fi
      log "[资讯] 侦测 mount.conf 内容变更｜watch_rc=$_wrc｜reason=confwatch_stable｜hash=$_cw_hash"
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
        log '[资讯] mount.conf 已即时套用'
        _after_reason=$(sed -n 's/^REASON=//p' "$RUNTIME/config.state" 2>/dev/null | head -n1)
        _after_hash=$(sed -n 's/^HASH=//p' "$RUNTIME/config.state" 2>/dev/null | head -n1)
        case "$_after_reason" in
          profile_change|duplicate_*)
            log "[资讯] confwatch 套用结果为 $_after_reason，已略过一般 mount.conf 结果通知｜hash=$_after_hash"
            ;;
          *)
            mount_run notify_config_result "$_before_active" config_event >/dev/null 2>&1 || true
            ;;
        esac
      else
        log "[警告] mount.conf 即时套用失败，已保留最后有效挂载｜rc=$_arc"
        if [ "$_arc" -eq 3 ]; then
          mount_run notify_config_failed "$_arc" >/dev/null 2>&1 || true
        else
          mount_run notify_config_failed "$_arc" >/dev/null 2>&1 || true
          mount_run notify_incomplete config_event >/dev/null 2>&1 || true
        fi
      fi
      rm -f "$_before_active" 2>/dev/null || true
      control_run refresh_card >/dev/null 2>&1 || true
    else
      # Safety fallback only; packaged arm64 module should never use this branch.
      log '[警告] confwatch 遗失，退回每 2 秒检查设定档时间戳'
      _last=''
      while [ ! -x "$CONFWATCH" ]; do
        _now=$(stat -c '%Y:%s' "$CONF" 2>/dev/null)
        if [ -n "$_last" ] && [ "$_now" != "$_last" ]; then control_run reload config_poll_fallback >/dev/null 2>&1; fi
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
      log "[资讯] User $_usr 储存根目录已就绪，重试挂载｜来源=$_why｜retry=$_idx"
      notify_unlock_start_once_service "$_usr"
      control_run reload "user_${_usr}_storage_ready_retry${_idx}" >/dev/null 2>&1
      _rrc=$?
      if [ "$_rrc" -ne 0 ]; then
        mount_run notify_config_failed "$_rrc" >/dev/null 2>&1 || true
      fi
      control_run refresh_card >/dev/null 2>&1 || true
      _want=$(user_desired_count "$_usr"); [ -n "$_want" ] || _want=0
      _have=$(user_active_count "$_usr"); [ -n "$_have" ] || _have=0
      log "[资讯] User $_usr 储存路径重试完成｜rc=$_rrc｜active=$_have/$_want｜retry=$_idx"
      if [ "$_want" -eq 0 ] || { [ "$_rrc" -eq 0 ] && [ "$_have" -ge "$_want" ]; }; then
        mount_run notify_ready "user_${_usr}_ready" >/dev/null 2>&1 || true
        return 0
      fi
    else
      log "[资讯] User $_usr 储存根目录尚未就绪，等待后重试｜来源=$_why｜retry=$_idx"
    fi
    _idx=$((_idx+1))
  done
  _want=$(user_desired_count "$_usr"); [ -n "$_want" ] || _want=0
  _have=$(user_active_count "$_usr"); [ -n "$_have" ] || _have=0
  log "[警告] User $_usr 储存路径等待逾时，已保留延后挂载｜来源=$_why｜active=$_have/$_want"
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
    log "[资讯] User $_usr 解锁挂载仍由其他事件处理，稍后重试｜来源=$_why"
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
    log "[资讯] 补接已解锁但未完成的挂载｜User=$_ru_user｜来源=$_ru_reason｜active=$_ru_have/$_ru_want"
    user_reload_retry_once "$_ru_user" "$_ru_reason" || _ru_failed=1
  done
  return "$_ru_failed"
}

userstate_watch_loop(){
  command -v logcat >/dev/null 2>&1 || return 1
  recover_unlocked_users watcher_start >/dev/null 2>&1 &
  log '[资讯] 多使用者 lifecycle 事件监听启动｜RUNNING_UNLOCKED/STOPPING/SHUTDOWN'
  while true; do
    logcat -v tag -T 1 UserController.UserState:I '*:S' | while IFS= read -r _line; do
      case "$_line" in
        *'User '*' to RUNNING_UNLOCKED'*|*'User '*'state changed from '*'to RUNNING_UNLOCKED'*)
          _u=$(printf '%s\n' "$_line" | sed -n 's/.*User \([0-9][0-9]*\) .*/\1/p' | head -n1)
          case "$_u" in ''|*[!0-9]*) continue;; esac
          log "[资讯] User 解锁事件｜User=$_u｜准备套用对应挂载"
          user_reload_retry_once "$_u" lifecycle >/dev/null 2>&1 &
          ;;
        *'User '*' to STOPPING'*|*'User '*' to SHUTDOWN'*)
          _u=$(printf '%s\n' "$_line" | sed -n 's/.*User \([0-9][0-9]*\) .*/\1/p' | head -n1)
          case "$_u" in ''|*[!0-9]*) continue;; esac
          log "[资讯] User 停止事件｜User=$_u｜卸载该 User 映射"
          control_run unmount_user "$_u" >/dev/null 2>&1
          control_run refresh_card >/dev/null 2>&1 || true
          ;;
      esac
    done
    log '[警告] User lifecycle logcat 监听意外结束，交由管理程序退避重启'
    return 1
  done
}

# User 0 event fallbacks: they race with the lifecycle watcher and are one-shot.
user0_prop_once(){
  [ -x "$PROPWAIT" ] || return 1
  if [ "$(user_desired_count 0)" -gt 0 ] 2>/dev/null; then
    _ce=$(getprop sys.user.0.ce_available 2>/dev/null)
    case "$_ce" in
      true|1) ;;
      *) "$PROPWAIT" equals sys.user.0.ce_available true >/dev/null 2>&1 || return 1; _ce=$(getprop sys.user.0.ce_available 2>/dev/null) ;;
    esac
    log "[资讯] User 0 CE 解锁事件命中｜来源=propwait｜value=${_ce:-event}"
    user_reload_retry_once 0 propwait >/dev/null 2>&1
  fi
}
user0_file_once(){
  [ -x "$FILEWATCH" ] || return 1
  [ "$(user_desired_count 0)" -gt 0 ] 2>/dev/null || return 0
  "$FILEWATCH" --wait-exists /data/media/0/Download >/dev/null 2>&1 || return 1
  log '[资讯] User 0 储存路径事件命中｜来源=filewatch'
  if ! user_is_unlocked 0; then
    # Some ROMs create Download before CE is unlocked. Continue blocking on
    # the property event instead of repeatedly waking a retry timer.
    [ -x "$PROPWAIT" ] || return 1
    "$PROPWAIT" equals sys.user.0.ce_available true >/dev/null 2>&1 || return 1
  fi
  user_reload_retry_once 0 filewatch >/dev/null 2>&1
}

run_boot_service(){
  local _bs_reason _bs_boot
  _bs_reason=$1
  [ "$_bs_reason" != boot_completed ] || [ ! -e "$WATCH_STOP" ] || return 0
  [ -x /system/bin/flock ] && [ -x /system/bin/setsid ] || {
    log '[错误] 缺少 flock/setsid，无法启动服务'
    return 1
  }
  # service.sh and KernelSU boot-completed.sh can arrive together. Only one
  # performs initial state reset/config apply; the other then checks workers.
  exec 7>"$RUNTIME/boot.initial.lock" || return 1
  if ! watch_lock_wait 7 30; then
    log '[警告] 初始挂载仍在执行，本次补查未取得启动锁'
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
    log '[资讯] 背景事件监听器启动确认完成｜mount.conf=event-driven｜user=lifecycle-driven'
  else
    log '[错误] 部分事件监听器未就绪，请查看 watchers.stderr.log'
    return 1
  fi
  recover_unlocked_users "$_bs_reason"
}

case "${1:-boot}" in
  --watcher)
    watch_name_valid "$2" || exit 2
    case "$2" in
      confwatch) [ -x "$CONFWATCH" ] || exit 127 ;;
      userstate) command -v logcat >/dev/null 2>&1 || exit 127 ;;
      user0prop) [ -x "$PROPWAIT" ] || exit 127 ;;
      user0file) [ -x "$FILEWATCH" ] || exit 127 ;;
    esac
    watch_worker_ready "$2" || exit 1
    case "$2" in
      confwatch) config_watch_loop ;;
      userstate) userstate_watch_loop ;;
      user0prop) user0_prop_once ;;
      user0file) user0_file_once ;;
    esac
    exit $? ;;
  --recover-unlocked) recover_unlocked_users "${2:-manual_recovery}"; exit $? ;;
  --reload-user) user_reload_retry_guarded "$2" "$3"; exit $? ;;
  boot) run_boot_service boot; exit $? ;;
  --boot-reconcile) run_boot_service boot_completed; exit $? ;;
  *) echo 'usage: service.sh [--watcher NAME|--recover-unlocked REASON|--reload-user USER REASON|--boot-reconcile]' >&2; exit 2 ;;
esac
