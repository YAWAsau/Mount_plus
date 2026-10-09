#!/system/bin/sh
# Shared CE readiness check. A directory alone does not prove User 0 is unlocked.
yaw_user_unlocked() {
  local yaw_user yaw_ce yaw_state
  yaw_user=$1
  case "$yaw_user" in ''|*[!0-9]*) return 1 ;; esac
  yaw_ce=$(getprop "sys.user.$yaw_user.ce_available" 2>/dev/null)
  case "$yaw_ce" in true|1) return 0 ;; false|0) return 1 ;; esac
  yaw_state=$(am get-started-user-state "$yaw_user" 2>/dev/null)
  case "$yaw_state" in RUNNING_UNLOCKED) return 0 ;; RUNNING_*|STOPPING|SHUTDOWN) return 1 ;; esac
  # Older vendor builds may expose this command; Android 17 on the reported
  # device does not. Consult it only when the supported signals are absent.
  yaw_state=$(cmd user is-user-unlocked "$yaw_user" 2>/dev/null)
  case "$yaw_state" in true|1) return 0 ;; false|0) return 1 ;; esac
  dumpsys user 2>/dev/null | grep -A8 -F "UserInfo{$yaw_user:" | grep -q 'state=RUNNING_UNLOCKED'
}
