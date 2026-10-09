#!/system/bin/sh
# Event workers are supervised with wait(2), with no healthy-state timer.
WATCH_MODDIR=${MODDIR:-${0%/*}}
WATCH_RUNTIME=/data/adb/dcimswitch/runtime
WATCH_STOP=/dev/.yawasau_watchers_stopped_v1490

watch_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$WATCH_RUNTIME/service.log"
}
watch_name_valid() {
  case "$1" in confwatch|userstate|user0prop|user0file) return 0 ;; *) return 1 ;; esac
}
watch_with_fd() {
  # Android mksh marks exec-opened descriptors close-on-exec. Explicitly
  # re-export the requested descriptor for flock (including through timeout).
  case "$1" in
    6) shift; "$@" 6>&6 ;;
    7) shift; "$@" 7>&7 ;;
    8) shift; "$@" 8>&8 ;;
    9) shift; "$@" 9>&9 ;;
    *) return 2 ;;
  esac
}
watch_lock_wait() {
  local wl_fd wl_seconds wl_i
  wl_fd=$1; wl_seconds=$2
  watch_with_fd "$wl_fd" /system/bin/flock -n "$wl_fd" && return 0
  # Android Toybox flock supports an fd and -n, not util-linux's -w option.
  # Block in the kernel; timeout exists only for this contended acquisition.
  if [ -x /system/bin/timeout ]; then
    watch_with_fd "$wl_fd" /system/bin/timeout "$wl_seconds" /system/bin/flock "$wl_fd"
    return $?
  fi
  # Compatibility fallback is bounded and only runs during contention.
  wl_i=0
  while [ "$wl_i" -lt "$((wl_seconds*10))" ]; do
    sleep 0.1
    watch_with_fd "$wl_fd" /system/bin/flock -n "$wl_fd" && return 0
    wl_i=$((wl_i+1))
  done
  return 1
}
watch_identity() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  # Ignore the comm field, which may itself contain spaces, and reject zombies.
  awk '{sub(/^.*\) /, ""); if ($1 != "Z" && $1 != "X") print $20}' "/proc/$1/stat" 2>/dev/null
}
watch_record_live() {
  local wr_pid wr_start wr_boot wr_actual
  read -r wr_pid wr_start wr_boot 2>/dev/null < "$1" || return 1
  [ -n "$wr_start" ] || return 1
  [ -n "$wr_boot" ] && [ "$wr_boot" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ] || return 1
  wr_actual=$(watch_identity "$wr_pid")
  [ -n "$wr_actual" ] && [ "$wr_actual" = "$wr_start" ]
}
watch_write_record() {
  local ww_start ww_boot
  ww_start=$(watch_identity "$2")
  [ -n "$ww_start" ] || return 1
  ww_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$ww_boot" ] || return 1
  printf '%s %s %s\n' "$2" "$ww_start" "$ww_boot" > "$1.tmp.$2" || return 1
  mv -f "$1.tmp.$2" "$1"
}
watch_once_done() {
  local wo_boot
  case "$1" in user0prop|user0file) ;; *) return 1 ;; esac
  wo_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$wo_boot" ] && [ "$(cat "$WATCH_RUNTIME/watch.$1.done" 2>/dev/null)" = "$wo_boot" ]
}
watch_ready() {
  watch_once_done "$1" && return 0
  watch_record_live "$WATCH_RUNTIME/watch.$1.supervisor" &&
    watch_record_live "$WATCH_RUNTIME/watch.$1.worker"
}
watch_worker_ready() {
  local ww_pid ww_rest
  watch_name_valid "$1" || return 2
  # read is a shell builtin, so /proc/self refers to this worker, not a helper.
  read -r ww_pid ww_rest < /proc/self/stat || return 1
  watch_write_record "$WATCH_RUNTIME/watch.$1.worker" "$ww_pid" || return 1
  watch_log "[資訊] 事件監聽器就緒｜name=$1｜pid=$ww_pid"
}
watch_detach() {
  if [ -x /data/adb/ksu/bin/busybox ]; then
    export ASH_STANDALONE=1
    exec /system/bin/setsid /data/adb/ksu/bin/busybox sh "$@"
  else
    exec /system/bin/setsid /system/bin/sh "$@"
  fi
}
watch_signal_record() {
  local wk_pid wk_start wk_boot
  watch_record_live "$1" || return 0
  read -r wk_pid wk_start wk_boot < "$1" || return 1
  # Workers own a setsid process group. Mount transactions run in a separate
  # session, so stopping an event reader cannot interrupt a filesystem change.
  if [ "${2:-process}" = group ]; then
    kill -TERM -- "-$wk_pid" 2>/dev/null || kill -TERM "$wk_pid" 2>/dev/null || true
  else
    kill -TERM "$wk_pid" 2>/dev/null || true
  fi
}
watch_supervise() {
  local ws_name ws_pid ws_rest ws_child ws_sleep ws_stop ws_rc ws_delay ws_begin ws_end ws_saved ws_i
  ws_name=$1
  watch_name_valid "$ws_name" || return 2
  # The kernel releases flock even after SIGKILL. Never unlink this lock file:
  # doing so would allow a second supervisor to lock a different inode.
  exec 9>"$WATCH_RUNTIME/watch.$ws_name.lock" || return 1
  /system/bin/flock -n 9 9>&9 || return 0
  [ ! -e "$WATCH_STOP" ] || return 0
  watch_once_done "$ws_name" && return 0
  # A supervisor may have died while its event reader survived. Retire that
  # exact worker before publishing a replacement; never stack duplicate readers.
  watch_signal_record "$WATCH_RUNTIME/watch.$ws_name.worker" group
  ws_i=0
  while watch_record_live "$WATCH_RUNTIME/watch.$ws_name.worker"; do
    [ "$ws_i" -lt 40 ] || {
      watch_log "[錯誤] 舊監聽器尚未退出，保留紀錄並拒絕重複啟動｜name=$ws_name"
      return 1
    }
    sleep 0.05; ws_i=$((ws_i+1))
  done
  read -r ws_pid ws_rest < /proc/self/stat || return 1
  watch_write_record "$WATCH_RUNTIME/watch.$ws_name.supervisor" "$ws_pid" || return 1
  printf '%s\n' "$ws_pid" > "$WATCH_RUNTIME/$ws_name.pid"
  ws_stop=0; ws_child=; ws_sleep=; ws_delay=1
  trap '' HUP
  trap 'ws_stop=1; if [ -n "$ws_child" ]; then kill -TERM -- "-$ws_child" 2>/dev/null || kill -TERM "$ws_child" 2>/dev/null || true; fi; [ -z "$ws_sleep" ] || kill -TERM "$ws_sleep" 2>/dev/null || true' TERM INT
  watch_log "[資訊] 事件監聽管理程序啟動｜name=$ws_name｜pid=$ws_pid"
  while [ "$ws_stop" = 0 ] && [ ! -e "$WATCH_STOP" ]; do
    rm -f "$WATCH_RUNTIME/watch.$ws_name.worker"
    ws_begin=$(date +%s)
    # Close the lock fd in the worker tree. A crashed supervisor must not leave
    # its flock held by logcat/propwait or a mount subprocess.
    watch_detach "$WATCH_MODDIR/service.sh" --watcher "$ws_name" 9>&- </dev/null >> "$WATCH_RUNTIME/watchers.stderr.log" 2>&1 &
    ws_child=$!
    wait "$ws_child"; ws_rc=$?
    [ "$ws_stop" = 0 ] || { wait "$ws_child" 2>/dev/null || true; break; }
    case "$ws_name:$ws_rc" in
      user0prop:0|user0file:0)
        cat /proc/sys/kernel/random/boot_id > "$WATCH_RUNTIME/watch.$ws_name.done"
        watch_log "[資訊] 一次性監聽已完成｜name=$ws_name"
        break ;;
    esac
    # Only event readers remain in this group. Recoveries/mount transactions
    # have their own sessions and are allowed to commit or roll back normally.
    kill -TERM -- "-$ws_child" 2>/dev/null || true
    ws_child=
    rm -f "$WATCH_RUNTIME/watch.$ws_name.worker"
    [ ! -e "$WATCH_STOP" ] || break
    ws_end=$(date +%s)
    [ "$((ws_end-ws_begin))" -lt 60 ] || ws_delay=1
    watch_log "[警告] 事件監聽器退出，將重啟｜name=$ws_name｜rc=$ws_rc｜delay=${ws_delay}s"
    sleep "$ws_delay" 9>&- &
    ws_sleep=$!
    wait "$ws_sleep" 2>/dev/null || true
    ws_sleep=
    ws_delay=$((ws_delay*2)); [ "$ws_delay" -le 30 ] || ws_delay=30
  done
  rm -f "$WATCH_RUNTIME/watch.$ws_name.worker" "$WATCH_RUNTIME/watch.$ws_name.supervisor"
  ws_saved=$(cat "$WATCH_RUNTIME/$ws_name.pid" 2>/dev/null)
  [ "$ws_saved" != "$ws_pid" ] || rm -f "$WATCH_RUNTIME/$ws_name.pid"
  watch_log "[資訊] 事件監聽管理程序結束｜name=$ws_name"
}
watch_start_all() {
  local wa_name wa_i wa_failed
  if [ "$1" = boot_completed ] && [ -e "$WATCH_STOP" ]; then return 0; fi
  [ -x /system/bin/flock ] && [ -x /system/bin/setsid ] || {
    watch_log '[錯誤] 缺少 flock/setsid，無法啟動監聽管理程序'
    return 1
  }
  exec 6>"$WATCH_RUNTIME/watchers.control.lock" || return 1
  watch_lock_wait 6 10 || return 4
  if [ "$1" = boot_completed ] && [ -e "$WATCH_STOP" ]; then return 0; fi
  rm -f "$WATCH_STOP"
  wa_failed=0
  for wa_name in confwatch userstate user0prop user0file; do
    watch_ready "$wa_name" && continue
    watch_detach "$WATCH_MODDIR/watchers.sh" supervise "$wa_name" 6>&- </dev/null >> "$WATCH_RUNTIME/watchers.stderr.log" 2>&1 &
    # Bounded startup handshake only; this loop is not a resident health poll.
    wa_i=0
    while [ "$wa_i" -lt 40 ]; do
      watch_ready "$wa_name" && break
      sleep 0.05; wa_i=$((wa_i+1))
    done
    if ! watch_ready "$wa_name"; then
      watch_log "[錯誤] 事件監聽器啟動確認逾時｜name=$wa_name"
      wa_failed=1
    fi
  done
  return "$wa_failed"
}
watch_stop_all() (
  local wt_name wt_alive wt_i
  exec 6>"$WATCH_RUNTIME/watchers.control.lock" || return 1
  watch_lock_wait 6 10 || return 4
  . "$WATCH_MODDIR/core.sh" || return 90
  # Serialize with actual mount commits. A check for the directory alone has
  # a check/use race with a newly arriving unlock/config event.
  if ! lock_acquire; then
    watch_log '[警告] 掛載交易仍在進行，暫不停止事件監聽器'
    return 4
  fi
  trap 'lock_release' EXIT
  trap 'exit 1' INT TERM
  : > "$WATCH_STOP" || return 1
  for wt_name in confwatch userstate user0prop user0file; do
    watch_signal_record "$WATCH_RUNTIME/watch.$wt_name.supervisor"
    watch_signal_record "$WATCH_RUNTIME/watch.$wt_name.worker" group
  done
  wt_i=0
  while [ "$wt_i" -lt 40 ]; do
    wt_alive=
    for wt_name in confwatch userstate user0prop user0file; do
      watch_record_live "$WATCH_RUNTIME/watch.$wt_name.supervisor" && wt_alive=1
      watch_record_live "$WATCH_RUNTIME/watch.$wt_name.worker" && wt_alive=1
    done
    [ -n "$wt_alive" ] || return 0
    sleep 0.05; wt_i=$((wt_i+1))
  done
  watch_log '[警告] 監聽管理程序仍在結束中，保留 PID 紀錄供診斷'
  return 1
)

# May also be sourced by service.sh to publish the worker startup handshake.
if [ "${0##*/}" = watchers.sh ]; then
  mkdir -p "$WATCH_RUNTIME" || exit 1
  case "$1" in
    start) watch_start_all "${2:-manual}" ;;
    stop) watch_stop_all ;;
    supervise) watch_supervise "$2" ;;
    *) echo 'usage: watchers.sh {start [reason]|stop|supervise NAME}' >&2; exit 2 ;;
  esac
  exit $?
fi
