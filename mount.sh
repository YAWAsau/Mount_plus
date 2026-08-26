#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/core.sh" || exit 90
cmd=${1:-reload}
case "$cmd" in
  migrate_config) seed_config && migrate_config_schema ;;
  pre_unlock)
    seed_config || exit 2
    _h=$(config_hash "$CONF" 2>/dev/null || true)
    if parse_config "$CONF" "$PARSED" >/dev/null 2>&1; then
      config_state_write valid 0 pre_unlock "$_h" >/dev/null 2>&1 || true
      mount_root_ensure
    else
      parse_global_config "$CONF" "$PARSED" || exit 3
      config_state_write invalid 3 pre_unlock_root_only "$_h" >/dev/null 2>&1 || true
      mount_root_ensure
    fi
    ;;
  reload|media_apply) apply_reload "${2:-$cmd}" ;;
  notify) notify_post "${2:-YAWAsau Mount}" "${3:-事件}" "${4:-manual}" ;;
  notify_ready) notify_all_ready_once "${2:-manual}" ;;
  notify_incomplete) notify_mount_incomplete_once "${2:-manual}" ;;
  notify_summary) notify_mount_summary "${2:-manual}" ;;
  notify_boot_wait_unlock) notify_boot_wait_unlock_once ;;
  notify_unlock_start) notify_unlock_start_once "${2:-0}" ;;
  notify_config_result) notify_config_apply_result "${2:-}" "${3:-config_event}" ;;
  notify_config_failed) notify_config_failed "${2:-1}" ;;
  media_cache_refresh) media_cache_refresh "${2:-0}" >/dev/null ;;
  media_cache_pid) media_cache_pid "${2:-0}" ;;
  media_scan_now) [ $# -ge 3 ] || exit 2; media_scan_broadcast "$2" "$3" "${4:-manual}" ;;
  fs_type) _mp=$(cfg_get mount_point); mount_fs "$_mp" ;;
  status) status_json ;;
  unmount_all) lock_acquire || exit 4; trap 'lock_release' EXIT INT TERM; unmount_active_all; lock_release; trap - EXIT INT TERM ;;
  *) echo "usage: $0 {migrate_config|pre_unlock|reload|media_apply|notify TITLE TEXT [TAG]|notify_ready [REASON]|notify_incomplete [REASON]|notify_summary [REASON]|notify_boot_wait_unlock|notify_unlock_start [USER]|notify_config_result BEFORE_ACTIVE [REASON]|notify_config_failed [RC]|media_cache_refresh [user]|media_cache_pid [user]|media_scan_now USER PATH [reason]|fs_type|status|unmount_all}" >&2; exit 2 ;;
esac
