#!/system/bin/sh
# One Rust event service; Shell is used only for start/stop and transaction locking.
WATCH_MODDIR=${MODDIR:-${0%/*}}
WATCH_RUNTIME=/data/adb/dcimswitch/runtime
WATCH_STOP=/dev/.yawasau_watchers_stopped_v1490

watch_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$WATCH_RUNTIME/service.log"
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
watch_record_live() {
  "$WATCH_MODDIR/bin/mounttx" watch-live "$1"
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
  "$WATCH_MODDIR/bin/mounttx" watch-signal "$1" "${2:-process}"
}
watch_start_all() {
  local wa_i
  if [ "$1" = boot_completed ] && [ -e "$WATCH_STOP" ]; then return 0; fi
  [ -x /system/bin/flock ] && [ -x /system/bin/setsid ] || {
    watch_log '[錯誤] 缺少 flock/setsid，無法啟動監聽管理程序'
    return 1
  }
  exec 6>"$WATCH_RUNTIME/watchers.control.lock" || return 1
  watch_lock_wait 6 10 || return 4
  if [ "$1" = boot_completed ] && [ -e "$WATCH_STOP" ]; then return 0; fi
  rm -f "$WATCH_STOP"
  watch_record_live "$WATCH_RUNTIME/watch.rust.supervisor" && return 0
  /system/bin/setsid "$WATCH_MODDIR/bin/mounttx" watch "$WATCH_MODDIR" "$WATCH_RUNTIME" "$WATCH_STOP" 6>&- </dev/null >> "$WATCH_RUNTIME/watchers.stderr.log" 2>&1 &
  wa_i=0
  while [ "$wa_i" -lt 40 ]; do
    watch_record_live "$WATCH_RUNTIME/watch.rust.supervisor" && return 0
    sleep 0.05; wa_i=$((wa_i+1))
  done
  watch_log '[錯誤] Rust 事件服務啟動確認逾時'
  return 1
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
  for wt_name in rust confwatch sourcewatch userstate user0prop user0file; do
    watch_signal_record "$WATCH_RUNTIME/watch.$wt_name.supervisor"
    watch_signal_record "$WATCH_RUNTIME/watch.$wt_name.worker" group
  done
  wt_i=0
  while [ "$wt_i" -lt 40 ]; do
    wt_alive=
    for wt_name in rust confwatch sourcewatch userstate user0prop user0file; do
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
    *) echo 'usage: watchers.sh {start [reason]|stop}' >&2; exit 2 ;;
  esac
  exit $?
fi
