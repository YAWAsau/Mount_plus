#!/system/bin/sh
# YAWAsau Mount generic config-driven kernel-bind/bindfs core, v1.4.81-remove-notify-real-id-profile-dedup
# Internal library only. mount.conf is parsed as data; it is never sourced.

MODDIR=${MODDIR:-${0%/*}}
case "$MODDIR" in */lib|*/bin) MODDIR=${MODDIR%/*} ;; esac
DATA_DIR=/data/adb/dcimswitch
RUNTIME="$DATA_DIR/runtime"
CONF="$DATA_DIR/mount.conf"
DEFAULT_CONF="$MODDIR/mount.conf.default"
[ -f "$DEFAULT_CONF" ] || DEFAULT_CONF="$MODDIR/mount.conf"
EXAMPLE_CONF="$MODDIR/mount.conf.example"
[ -f "$EXAMPLE_CONF" ] || EXAMPLE_CONF="$MODDIR/mount.conf"
LOG="$RUNTIME/mount.log"
ACTIVE="$RUNTIME/active_mounts.tsv"
GLOBAL_ACTIVE="$RUNTIME/global.active"
PARSED_REAL="$RUNTIME/parsed"
PARSED="$PARSED_REAL"
PARSED_HASH="$RUNTIME/parsed.applied.cksum"
LOCKDIR="$RUNTIME/reload.lock"
NATIVE_DIR="$DATA_DIR/native"
BINDFS_HELPER="$MODDIR/bin/bindfs_mount.sh"
MOUNTTX="${YAW_MOUNTTX:-$MODDIR/bin/mounttx}"
# v1.4.46: official module layout uses bin only; install/boot hard-preserves existing live/legacy mount.conf.
# Keep /data/adb/dcimswitch/native as a legacy/manual fallback only; module lib/ is no longer used.
if [ -n "${YAW_BINDFS:-}" ]; then
  BINDFS="$YAW_BINDFS"
elif [ -x "$MODDIR/bin/bindfs" ]; then
  BINDFS="$MODDIR/bin/bindfs"
else
  BINDFS="$NATIVE_DIR/bin/bindfs"
fi
if [ -n "${YAW_LIBFUSE_DIR:-}" ]; then
  BIND_LIB_DIR="$YAW_LIBFUSE_DIR"
elif [ -f "$MODDIR/libs/libfuse3.so" ]; then
  # v1.4.53: static bindfs does not need runtime libfuse3.so.
  BIND_LIB_DIR=""
elif [ -f "$MODDIR/lib/libfuse3.so" ]; then
  BIND_LIB_DIR="$MODDIR/lib"
else
  BIND_LIB_DIR="$NATIVE_DIR/lib"
fi
POLICY_TOOL="${YAW_MAGISKPOLICY:-}"
POLICY_FILE="$MODDIR/sepolicy.rule"
BIND_POLICY_MARK="$RUNTIME/bindfs_policy.applied"
CONFIG_STATE="$RUNTIME/config.state"
APPLIED_HASH="$RUNTIME/config.applied.cksum"
NS_BG_GEN="$RUNTIME/ns_background.generation"
MODULE_VERSION=v1.4.81-remove-notify-real-id-profile-dedup-20260830
mkdir -p "$RUNTIME" "$PARSED" 2>/dev/null
DELIM='|'

now() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date; }
logi() { printf '%s [資訊] %s\n' "$(now)" "$*" >> "$LOG" 2>/dev/null; }
logw() { printf '%s [警告] %s\n' "$(now)" "$*" >> "$LOG" 2>/dev/null; }
loge() { printf '%s [錯誤] %s\n' "$(now)" "$*" >> "$LOG" 2>/dev/null; }

DEX_CLASSES="$MODDIR/bin/classes.dex"
DEX_NOTIFY_CLASS="${YAWASAU_NOTIFY_CLASS:-com.xayah.dex.NotificationUtil}"
DEX_NOTIFY_LOG="$RUNTIME/notify_dex.log"
DEX_NOTIFY_STATE="$RUNTIME/notify_state"

notify_tag_safe() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9_.-' | head -c 40
}

notify_post_dex() {
  _nt_title=$1; _nt_text=$2; _nt_tag=${3:-event}
  if [ ! -f "$DEX_CLASSES" ]; then
    printf '%s missing classes.dex: %s\n' "$(now)" "$DEX_CLASSES" >> "$DEX_NOTIFY_LOG" 2>/dev/null || true
    return 11
  fi
  if ! command -v app_process >/dev/null 2>&1; then
    printf '%s app_process missing\n' "$(now)" >> "$DEX_NOTIFY_LOG" 2>/dev/null || true
    return 12
  fi
  mkdir -p "$DEX_NOTIFY_STATE" 2>/dev/null || true
  _nt_safe=$(notify_tag_safe "$_nt_tag"); [ -n "$_nt_safe" ] || _nt_safe=event
  _nt_event=INFO; _nt_channel=result; _nt_id=2400; _nt_once=1
  case "$_nt_safe" in
    *fail*|*failed*|*error*|*warn*|*timeout*) _nt_event=ERROR; _nt_channel=error; _nt_id=2401; _nt_once=0 ;;
    *debug*) _nt_event=DEBUG; _nt_channel=debug; _nt_id=2402; _nt_once=1 ;;
    *config_removed*) _nt_event=RESULT; _nt_channel=result; _nt_id=2410; _nt_once=0 ;;
    *all_ready*|*profile*|*config_reload*) _nt_event=RESULT; _nt_channel=result; _nt_id=2400; _nt_once=1 ;;
  esac
  _nt_batch="$RUNTIME/notify_dex.$$.batch"
  {
    printf 'EVENT|YAWASAU_%s\n' "$_nt_event"
    printf 'TAG|yawasau_mount_%s\n' "$_nt_safe"
    printf 'ID|%s\n' "$_nt_id"
    printf 'CHANNEL|%s\n' "$_nt_channel"
    printf 'TITLE|%s\n' "$_nt_title"
    printf 'TEXT|%s\n' "$_nt_text"
    printf 'BIGTEXT|%s\n' "$_nt_text"
    printf 'SUBTEXT|%s\n' "$MODULE_VERSION"
    printf 'GROUP|yawasau_mount\n'
    printf 'AUTO_CANCEL|1\n'
    printf 'ONLY_ALERT_ONCE|%s\n' "$_nt_once"
    printf 'SHOW_WHEN|1\n'
    printf 'END\n'
  } > "$_nt_batch" 2>/dev/null || return 1
  CLASSPATH="$DEX_CLASSES" SPEEDBACKUP_NOTIFY_STATE_DIR="$DEX_NOTIFY_STATE" DEX_HUMAN_LOG=0 \
    app_process /system/bin "$DEX_NOTIFY_CLASS" notifyBatch --stdin < "$_nt_batch" >> "$DEX_NOTIFY_LOG" 2>&1
  _nt_rc=$?
  if [ "$_nt_rc" -ne 0 ]; then
    printf '%s notify dex retry after rc=%s tag=%s\n' "$(now)" "$_nt_rc" "$_nt_tag" >> "$DEX_NOTIFY_LOG" 2>/dev/null || true
    sleep 0.25
    CLASSPATH="$DEX_CLASSES" SPEEDBACKUP_NOTIFY_STATE_DIR="$DEX_NOTIFY_STATE" DEX_HUMAN_LOG=0 \
      app_process /system/bin "$DEX_NOTIFY_CLASS" notifyBatch --stdin < "$_nt_batch" >> "$DEX_NOTIFY_LOG" 2>&1
    _nt_rc=$?
  fi
  rm -f "$_nt_batch" 2>/dev/null || true
  [ "$_nt_rc" -eq 0 ]
}

notify_post() {
  _nt_title=$1; _nt_text=$2; _nt_tag=${3:-event}
  [ -n "$_nt_title" ] || return 0
  [ -n "$_nt_text" ] || _nt_text="YAWAsau Mount"
  # Optional runtime kill switch for noisy environments.
  [ "$(getprop yawasau.mount.notify 2>/dev/null)" = 0 ] && return 0
  notify_post_dex "$_nt_title" "$_nt_text" "$_nt_tag"
  _nt_rc=$?
  [ "$_nt_rc" -eq 0 ] && return 0
  case "$_nt_rc" in
    11) logw "Dex 通知未送出｜原因=classes.dex 缺失｜tag=$_nt_tag｜classes=$DEX_CLASSES" ;;
    12) logw "Dex 通知未送出｜原因=app_process 缺失｜tag=$_nt_tag｜classes=$DEX_CLASSES" ;;
    *) logw "Dex 通知未送出｜原因=send_failed rc=$_nt_rc｜tag=$_nt_tag｜classes=$DEX_CLASSES｜log=$DEX_NOTIFY_LOG" ;;
  esac
  return "$_nt_rc"
}

notify_backend_status() {
  if [ ! -f "$DEX_CLASSES" ]; then
    printf 'dex-missing:%s\n' "$DEX_CLASSES"
  elif ! command -v app_process >/dev/null 2>&1; then
    printf 'dex-app-process-missing:%s\n' "$DEX_CLASSES"
  else
    printf 'dex:%s\n' "$DEX_CLASSES"
  fi
}
mount_desired_count() {
  [ -f "$PARSED/mounts.desired" ] || { echo 0; return 0; }
  awk -F'|' 'NF{c++} END{print c+0}' "$PARSED/mounts.desired" 2>/dev/null
}

mount_active_matching_count() {
  [ -f "$PARSED/mounts.desired" ] || { echo 0; return 0; }
  [ -f "$ACTIVE" ] || { echo 0; return 0; }
  awk -F'|' '
    NR==FNR { d[$2 "|" $3 "|" $5 "|" $10]=1; next }
    NF { k=$2 "|" $3 "|" $5 "|" $10; if ((k in d) && !(k in seen)) { c++; seen[k]=1 } }
    END{print c+0}
  ' "$PARSED/mounts.desired" "$ACTIVE" 2>/dev/null
}

mount_active_names_compact() {
  [ -f "$PARSED/mounts.desired" ] || return 0
  [ -f "$ACTIVE" ] || return 0
  awk -F'|' '
    NR==FNR { d[$2 "|" $3 "|" $5 "|" $10]=1; next }
    NF {
      k=$2 "|" $3 "|" $5 "|" $10
      if ((k in d) && !(k in seen)) {
        if (c<8) { if (out!="") out=out "、"; out=out $1 }
        c++; seen[k]=1
      }
    }
    END{ if (c>8) out=out "…"; print out }
  ' "$PARSED/mounts.desired" "$ACTIVE" 2>/dev/null
}

mount_missing_names_compact() {
  [ -f "$PARSED/mounts.desired" ] || return 0
  if [ ! -f "$ACTIVE" ]; then
    awk -F'|' 'NF{ if (c<8) { if (out!="") out=out "、"; out=out $1 "(U" $2 ")" } c++ } END{ if (c>8) out=out "…"; print out }' "$PARSED/mounts.desired" 2>/dev/null
    return 0
  fi
  awk -F'|' '
    NR==FNR { a[$2 "|" $3 "|" $5 "|" $10]=1; next }
    NF { k=$2 "|" $3 "|" $5 "|" $10; if (!(k in a)) { if (c<8) { if (out!="") out=out "、"; out=out $1 "(U" $2 ")" } c++ } }
    END { if (c>8) out=out "…"; print out }
  ' "$ACTIVE" "$PARSED/mounts.desired" 2>/dev/null
}

mount_added_names_compact() {
  _before=$1
  [ -f "$_before" ] || { mount_active_names_compact; return 0; }
  [ -f "$ACTIVE" ] || return 0
  awk -F'|' '
    NR==FNR { b[$2 "|" $3 "|" $5 "|" $10]=1; next }
    NF { k=$2 "|" $3 "|" $5 "|" $10; if (!(k in b)) { if (c<6) { if (out!="") out=out "、"; out=out $1 } c++ } }
    END{ if (c>6) out=out "…"; print out }
  ' "$_before" "$ACTIVE" 2>/dev/null
}

mount_removed_names_compact() {
  _before=$1
  [ -f "$_before" ] || return 0
  [ -f "$ACTIVE" ] || { awk -F'|' 'NF{ if (c<6) { if (out!="") out=out "、"; out=out $1 } c++ } END{ if (c>6) out=out "…"; print out }' "$_before" 2>/dev/null; return 0; }
  awk -F'|' '
    NR==FNR { a[$2 "|" $3 "|" $5 "|" $10]=1; next }
    NF { k=$2 "|" $3 "|" $5 "|" $10; if (!(k in a)) { if (c<6) { if (out!="") out=out "、"; out=out $1 } c++ } }
    END{ if (c>6) out=out "…"; print out }
  ' "$ACTIVE" "$_before" 2>/dev/null
}

notify_boot_wait_unlock_once() {
  _nbwu_marker=/dev/.yawasau_notify_boot_wait_unlock_v170
  [ -e "$_nbwu_marker" ] && return 0
  if notify_post "等待解鎖後開始掛載" "Android 開機後需要使用者解鎖，內置儲存解密完成後才會開始掛載" "boot_wait_unlock"; then
    : > "$_nbwu_marker" 2>/dev/null || true
  fi
}

notify_unlock_start_once() {
  _nus_user=${1:-0}
  _nus_marker="/dev/.yawasau_notify_unlock_start_${_nus_user}_v170"
  [ -e "$_nus_marker" ] && return 0
  if notify_post "檢測到 User $_nus_user 解鎖" "開始掛載 User $_nus_user 的儲存映射" "unlock_start_user_${_nus_user}"; then
    : > "$_nus_marker" 2>/dev/null || true
  fi
}

notify_mount_summary() {
  _nms_reason=${1:-mount}
  [ -f "$PARSED/mounts.desired" ] || return 0
  _nms_want=$(mount_desired_count); [ -n "$_nms_want" ] || _nms_want=0
  _nms_have=$(mount_active_matching_count); [ -n "$_nms_have" ] || _nms_have=0
  case "$_nms_want" in ''|*[!0-9]*) return 0;; esac
  case "$_nms_have" in ''|*[!0-9]*) _nms_have=0;; esac
  [ "$_nms_want" -gt 0 ] || return 0
  _nms_defer=$(config_state_value DEFER 2>/dev/null); [ -n "$_nms_defer" ] || _nms_defer=0
  case "$_nms_defer" in ''|*[!0-9]*) _nms_defer=0;; esac
  # Waiting-for-unlock/storage is not a failure. Do not show misleading 0/N.
  [ "$_nms_defer" -gt 0 ] && return 0
  _nms_hash=$(cat "$APPLIED_HASH" 2>/dev/null); [ -n "$_nms_hash" ] || _nms_hash=$(config_hash "$CONF" 2>/dev/null || true); [ -n "$_nms_hash" ] || _nms_hash=unknown
  _nms_tag="mount_summary_$(notify_tag_safe "$_nms_reason")"
  if [ "$_nms_have" -ge "$_nms_want" ]; then
    _nms_names=$(mount_active_names_compact)
    _nms_title="掛載完成：$_nms_have/$_nms_want"
    _nms_text="全部掛載點已完成"
    [ -n "$_nms_names" ] && _nms_text="$_nms_names"
    notify_post "$_nms_title" "$_nms_text" "$_nms_tag"
  else
    _nms_missing=$(mount_missing_names_compact)
    _nms_title="掛載不完全：$_nms_have/$_nms_want"
    _nms_text="有掛載點未完成"
    [ -n "$_nms_missing" ] && _nms_text="異常：$_nms_missing 掛載異常"
    notify_post "$_nms_title" "$_nms_text" "${_nms_tag}_incomplete"
  fi
}

notify_all_ready_once() {
  _nar_reason=${1:-mount}
  [ -f "$PARSED/mounts.desired" ] || return 0
  _nar_want=$(mount_desired_count); _nar_have=$(mount_active_matching_count)
  case "$_nar_want" in ''|*[!0-9]*) return 0;; esac
  case "$_nar_have" in ''|*[!0-9]*) return 0;; esac
  [ "$_nar_want" -gt 0 ] || return 0
  [ "$_nar_have" -ge "$_nar_want" ] || return 0
  _nar_hash=$(cat "$APPLIED_HASH" 2>/dev/null); [ -n "$_nar_hash" ] || _nar_hash=unknown
  _nar_marker="/dev/.yawasau_notify.all_ready.$_nar_hash.$(notify_tag_safe "$_nar_reason")"
  [ -f "$_nar_marker" ] && return 0
  if notify_mount_summary "$_nar_reason"; then
    : > "$_nar_marker" 2>/dev/null || true
  fi
}

notify_mount_incomplete_once() {
  _nmi_reason=${1:-mount}
  [ -f "$PARSED/mounts.desired" ] || return 0
  _nmi_want=$(mount_desired_count); _nmi_have=$(mount_active_matching_count)
  case "$_nmi_want" in ''|*[!0-9]*) return 0;; esac
  case "$_nmi_have" in ''|*[!0-9]*) _nmi_have=0;; esac
  [ "$_nmi_want" -gt 0 ] || return 0
  [ "$_nmi_have" -lt "$_nmi_want" ] || return 0
  _nmi_hash=$(cat "$APPLIED_HASH" 2>/dev/null); [ -n "$_nmi_hash" ] || _nmi_hash=$(config_hash "$CONF" 2>/dev/null || true); [ -n "$_nmi_hash" ] || _nmi_hash=unknown
  _nmi_marker="/dev/.yawasau_notify.incomplete.$_nmi_hash.$(notify_tag_safe "$_nmi_reason")"
  [ -f "$_nmi_marker" ] && return 0
  if notify_mount_summary "$_nmi_reason"; then
    : > "$_nmi_marker" 2>/dev/null || true
  fi
}

config_error_oneline() {
  _ce_saved_parsed=$PARSED; _ce_saved_log=$LOG
  _ce_log="$RUNTIME/config_error_notify.$$.log"; _ce_parsed="$RUNTIME/config_error_notify.$$.parsed"; _ce_snap="$RUNTIME/config_error_notify.$$.conf"
  rm -rf "$_ce_parsed" 2>/dev/null; rm -f "$_ce_log" "$_ce_snap" 2>/dev/null
  cp -f "$CONF" "$_ce_snap" 2>/dev/null || { echo "無法讀取 mount.conf"; return 0; }
  : > "$_ce_log" 2>/dev/null || true
  LOG=$_ce_log
  parse_config "$_ce_snap" "$_ce_parsed" >/dev/null 2>&1
  _ce_msg=$(grep -m1 '\[錯誤\]' "$_ce_log" 2>/dev/null | sed 's/^.*\[錯誤\] //' | head -n1)
  LOG=$_ce_saved_log; PARSED=$_ce_saved_parsed
  rm -rf "$_ce_parsed" 2>/dev/null; rm -f "$_ce_log" "$_ce_snap" 2>/dev/null
  [ -n "$_ce_msg" ] && echo "$_ce_msg" || echo "語法/欄位驗證未通過"
}

notify_config_failed() {
  _ncf_rc=${1:-1}
  _ncf_msg=$(config_error_oneline)
  _ncf_line=$(printf '%s
' "$_ncf_msg" | sed -n 's/.*第 \([0-9][0-9]*\) 行.*/第\1行/p' | head -n1)
  _ncf_title='mount.conf 有問題'
  [ -n "$_ncf_line" ] && _ncf_title="mount.conf 有問題：$_ncf_line"
  notify_post "$_ncf_title" "$_ncf_msg｜rc=$_ncf_rc" "config_failed"
}

notify_config_apply_result() {
  _ncar_before=$1
  _ncar_reason=${2:-config_event}
  [ -f "$PARSED/mounts.desired" ] || return 0
  _ncar_want=$(mount_desired_count); _ncar_have=$(mount_active_matching_count)
  case "$_ncar_want" in ''|*[!0-9]*) _ncar_want=0;; esac
  case "$_ncar_have" in ''|*[!0-9]*) _ncar_have=0;; esac
  _ncar_added=$(mount_added_names_compact "$_ncar_before")
  _ncar_removed=$(mount_removed_names_compact "$_ncar_before")
  _ncar_names=$(mount_active_names_compact)
  if [ "$_ncar_want" -gt 0 ] && [ "$_ncar_have" -lt "$_ncar_want" ]; then
    _ncar_missing=$(mount_missing_names_compact)
    _ncar_title="mount.conf 掛載不完全：$_ncar_have/$_ncar_want"
    _ncar_text="有掛載點未完成"
    [ -n "$_ncar_missing" ] && _ncar_text="異常：$_ncar_missing 掛載異常"
    notify_post "$_ncar_title" "$_ncar_text" "config_reload_incomplete"
    return $?
  fi

  if [ -n "$_ncar_added" ]; then
    _ncar_title="新增掛載成功：$_ncar_added"
  elif [ -n "$_ncar_removed" ]; then
    _ncar_title="移除掛載成功：$_ncar_removed"
  elif [ "$_ncar_want" -gt 0 ]; then
    _ncar_title="mount.conf 更改成功：$_ncar_have/$_ncar_want"
  else
    _ncar_title='mount.conf 更改成功'
  fi

  _ncar_text='設定已重新套用'
  [ "$_ncar_want" -gt 0 ] && _ncar_text="掛載完成：$_ncar_have/$_ncar_want"
  [ -n "$_ncar_names" ] && _ncar_text="$_ncar_text｜$_ncar_names"
  [ -n "$_ncar_removed" ] && _ncar_text="$_ncar_text｜已移除：$_ncar_removed"

  # v1.4.81: removal-only changes must be visible even if a later config/profile
  # result updates the normal main notification.  Use a dedicated result id
  # (handled by notify_post_dex for config_removed*) and put the success wording
  # in the text too, because the Dex recent/history file records text only.
  if [ -n "$_ncar_removed" ] && [ -z "$_ncar_added" ]; then
    _ncar_stamp=$(date +%s 2>/dev/null || echo $$)
    _ncar_text="移除掛載成功：$_ncar_removed｜$_ncar_text"
    notify_post "$_ncar_title" "$_ncar_text" "config_removed_${_ncar_stamp}_$$"
    return $?
  fi
  notify_post "$_ncar_title" "$_ncar_text" "config_reload"
}

ns_available() { command -v nsenter >/dev/null 2>&1 && [ -r /proc/1/ns/mnt ]; }
ns1() { if ns_available; then nsenter -t 1 -m -- "$@"; else "$@"; fi; }
mount_table() { ns1 cat /proc/mounts 2>/dev/null; }
mount_src() { mount_table | awk -v p="$1" '$2==p{print $1;exit}'; }
mount_fs() { mount_table | awk -v p="$1" '$2==p{print $3;exit}'; }
is_mounted() { mount_table | awk -v p="$1" '$2==p{f=1} END{exit f?0:1}'; }
realp() { readlink -f "$1" 2>/dev/null || printf '%s\n' "$1"; }
stat_sig_ns1() { ns1 stat -c '%d:%i' "$1" 2>/dev/null; }
same_ns1() { _a=$(stat_sig_ns1 "$1"); _b=$(stat_sig_ns1 "$2"); [ -n "$_a" ] && [ "$_a" = "$_b" ]; }

config_semantic_normalize() {
  # Used only to recognize the untouched v1.2.0 stock config during upgrade.
  # Comments/blank lines and removed legacy keys do not affect the comparison.
  _csn_file=$1
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    /^version=/ || /^device=/ || /^fallback=/ {next}
    /^profile=camera\|work$/ {print "profile=camera|daily"; next}
    {print}
  ' "$_csn_file" 2>/dev/null
}

migrate_config_schema() {
  [ -f "$CONF" ] || return 0
  _need=0
  grep -q '^device=' "$CONF" 2>/dev/null && _need=1
  grep -q '^fallback=' "$CONF" 2>/dev/null && _need=1
  grep -q '^# YAWAsau Mount v1\.2\.0 default configuration' "$CONF" 2>/dev/null && _need=1
  [ "$_need" -eq 1 ] || return 0

  _bak="$CONF.pre_v122"
  [ -f "$_bak" ] || cp -f "$CONF" "$_bak" 2>/dev/null || true
  _tmp="$CONF.migrate.$$"
  _profile=$(grep -m1 '^profile=camera|' "$CONF" 2>/dev/null | cut -d'|' -f2)
  case "$_profile" in daily|work) ;; *) _profile=daily;; esac

  _stock=0
  if [ -f "$DEFAULT_CONF" ]; then
    _a="$RUNTIME/.cfg_old_norm.$$"; _b="$RUNTIME/.cfg_new_norm.$$"
    config_semantic_normalize "$CONF" > "$_a"
    config_semantic_normalize "$DEFAULT_CONF" > "$_b"
    cmp -s "$_a" "$_b" 2>/dev/null && _stock=1
    rm -f "$_a" "$_b" 2>/dev/null
  fi

  if [ "$_stock" -eq 1 ] && [ -f "$DEFAULT_CONF" ]; then
    cp -f "$DEFAULT_CONF" "$_tmp" 2>/dev/null || return 1
    [ "$_profile" = work ] && sed -i 's/^profile=camera|daily$/profile=camera|work/' "$_tmp" 2>/dev/null || true
    logi "偵測到未自訂的 v1.2.0 預設設定，已升級為 v1.2.2 中文設定｜備份=$_bak"
  else
    # Customized configs are never replaced. Remove only keys that v1.2.1+ no longer accepts.
    awk '
      /^# YAWAsau Mount v1\.2\.0 default configuration$/ {
        print "# YAWAsau Mount v1.2.2 已遷移設定（保留自訂項目）"
        next
      }
      !/^device=/ && !/^fallback=/ {print}
    ' "$CONF" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    logi "已遷移既有自訂 mount.conf：移除 device=/fallback=，其餘設定保留｜備份=$_bak"
  fi

  chmod 0600 "$_tmp" 2>/dev/null || true
  mv -f "$_tmp" "$CONF" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  return 0
}

seed_config() {
  mkdir -p "$DATA_DIR" "$RUNTIME" 2>/dev/null || return 1
  # Preserve existing live mount.conf, but repair obsolete schema keys before
  # any parse_config call.  v1.2.0 device=/fallback= are no longer valid
  # parser keys; leaving them in place makes the whole live config invalid.
  if [ -f "$CONF" ]; then
    migrate_config_schema || return 1
  fi
  if [ ! -f "$CONF" ]; then
    if [ -f "$DEFAULT_CONF" ]; then cp -f "$DEFAULT_CONF" "$CONF" 2>/dev/null || return 1; else return 1; fi
    # Migrate old DAILY/WORK preference only when creating a brand-new live config.
    if [ -f "$DATA_DIR/config.conf" ]; then
      _old=$(grep -m1 '^PROFILE=' "$DATA_DIR/config.conf" 2>/dev/null | cut -d= -f2)
      [ "$_old" = WORK ] && sed -i 's/^profile=camera|daily$/profile=camera|work/' "$CONF" 2>/dev/null || true
    fi
    chmod 0600 "$CONF" 2>/dev/null || true
    logi "已建立預設 mount.conf｜live=$CONF｜template=$DEFAULT_CONF"
  else
    # v1.4.44: hard preserve. Flashing/upgrading must never replace or auto-upgrade
    # the user's persistent live config. Defaults/templates live only in the module.
    # Manual reset remains available through control.sh import_default.
    logi "使用既有 live mount.conf，刷入/啟動不覆蓋、不自動升級｜live=$CONF｜template=$DEFAULT_CONF"
  fi
  chmod 0600 "$CONF" 2>/dev/null || true
  return 0
}

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }
valid_abs() { case "$1" in /*) return 0;; *) return 1;; esac; }
valid_safe_abs() {
  valid_abs "$1" || return 1
  # Config is root-controlled, but reject traversal, field delimiters and controls.
  case "$1" in *'|'*|*'/../'*|*/..) return 1;; esac
  printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]' && return 1
  return 0
}
valid_safe_rel() {
  # Relative config paths are intentionally supported for mount rows:
  # source is relative to mount_point; target is relative to /storage/emulated/<user>.
  case "$1" in ''|/*|'.'|'..'|*'|'*|*'/../'*|../*|*/..|*'/.'|./*) return 1;; esac
  printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]' && return 1
  return 0
}
path_join() { _pj_a=${1%/}; _pj_b=${2#/}; printf '%s/%s
' "$_pj_a" "$_pj_b"; }
normalize_source() {
  _ns_mp=$1; _ns_src=$2
  case "$_ns_src" in
    /*) valid_safe_abs "$_ns_src" || return 1; printf '%s
' "$_ns_src" ;;
    *) valid_safe_rel "$_ns_src" || return 1; valid_safe_abs "$_ns_mp" || return 1; path_join "$_ns_mp" "$_ns_src" ;;
  esac
}
valid_user() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
user_exists() {
  # Android User existence must be validated separately from storage readiness.
  # A non-existent User should be a config error, not an infinite wait-for-unlock.
  _ue_u=$1
  valid_user "$_ue_u" || return 1
  [ "$_ue_u" = 0 ] && return 0
  _ue_list=$(cmd user list 2>/dev/null; pm list users 2>/dev/null; dumpsys user 2>/dev/null)
  # If framework commands are unavailable very early during boot, avoid a false
  # negative; later apply/reload will validate again once cmd is available.
  [ -n "$_ue_list" ] || return 0
  printf '%s
' "$_ue_list" | grep -Fq "UserInfo{$_ue_u:" && return 0
  return 1
}

config_hash() {
  [ -f "$1" ] || return 1
  cksum "$1" 2>/dev/null | awk '{print $1":"$2}' | head -n1
}

config_state_write() {
  _csw_state=$1; _csw_rc=${2:-0}; _csw_reason=${3:-unknown}; _csw_hash=${4:-}; _csw_defer=${5:-0}
  _csw_tmp="$CONFIG_STATE.tmp.$$"
  {
    printf 'STATE=%s\n' "$_csw_state"
    printf 'RC=%s\n' "$_csw_rc"
    printf 'REASON=%s\n' "$_csw_reason"
    printf 'HASH=%s\n' "$_csw_hash"
    printf 'DEFER=%s\n' "$_csw_defer"
  } > "$_csw_tmp" 2>/dev/null || return 1
  chmod 0600 "$_csw_tmp" 2>/dev/null || true
  mv -f "$_csw_tmp" "$CONFIG_STATE" 2>/dev/null
}

config_state_valid() {
  [ -f "$CONFIG_STATE" ] || return 1
  grep -q '^STATE=valid$' "$CONFIG_STATE" 2>/dev/null
}

normalize_target() {
  # prints: lower|visible ; validates embedded user id for emulated/data-media paths.
  # Relative target paths are relative to /storage/emulated/<user>.
  _u=$1; _t=$2
  case "$_t" in
    /storage/emulated/*)
      valid_safe_abs "$_t" || return 1
      _rest=${_t#/storage/emulated/}; _tu=${_rest%%/*}
      [ "$_tu" = "$_u" ] || return 1
      case "$_rest" in */*) _sub=${_rest#*/};; *) _sub='';; esac
      _lower="/data/media/$_u${_sub:+/$_sub}"
      printf '%s|%s
' "$_lower" "$_t"
      ;;
    /data/media/*)
      valid_safe_abs "$_t" || return 1
      _rest=${_t#/data/media/}; _tu=${_rest%%/*}
      [ "$_tu" = "$_u" ] || return 1
      case "$_rest" in */*) _sub=${_rest#*/};; *) _sub='';; esac
      _vis="/storage/emulated/$_u${_sub:+/$_sub}"
      printf '%s|%s
' "$_t" "$_vis"
      ;;
    /*)
      # Absolute targets must be Android emulated-storage paths for the declared User.
      # Reject typos such as /sstorage/... during parse/dryrun, before any old
      # working bind is torn down. Use relative target syntax for normal cases.
      return 1
      ;;
    *)
      valid_safe_rel "$_t" || return 1
      printf '/data/media/%s/%s|/storage/emulated/%s/%s
' "$_u" "$_t" "$_u" "$_t"
      ;;
  esac
}
parse_config() {
  _cfg=${1:-$CONF}; _out=${2:-$PARSED}
  [ -f "$_cfg" ] || { loge "設定檔不存在｜$_cfg"; return 2; }
  _tmp="$_out.tmp.$$"; rm -rf "$_tmp" 2>/dev/null; mkdir -p "$_tmp" || return 2
  _partition=''; _mp=''; _fs=auto
  # First pass: collect global keys before parsing mount rows. This lets source
  # paths use relative syntax even if a user puts mount rows after comments or dirs.
  while IFS= read -r _gline || [ -n "$_gline" ]; do
    _gline=$(trim "$_gline")
    case "$_gline" in
      partition=*) _partition=${_gline#partition=} ;;
      mount_point=*) _mp=${_gline#mount_point=} ;;
      fs=*) _fs=${_gline#fs=} ;;
    esac
  done < "$_cfg"
  : > "$_tmp/profiles"; : > "$_tmp/dirs"; : > "$_tmp/mounts.all"
  _lineno=0; _err=0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _lineno=$((_lineno+1)); _line=$(trim "$_line")
    case "$_line" in ''|'#'*) continue;; esac
    case "$_line" in
      version=*) ;;
      partition=*|mount_point=*|fs=*) ;;
      dir=*)
        _dv=${_line#dir=}; _dp=${_dv%%|*}; [ "$_dp" != "$_dv" ] || { loge "mount.conf 第 $_lineno 行 dir 格式錯誤"; _err=1; continue; }
        _dpol=${_dv#*|}; _dp_norm=$(normalize_source "$_mp" "$_dp") || { loge "mount.conf 第 $_lineno 行 dir 路徑無效/含 traversal"; _err=1; continue; }
        case "$_dpol" in preserve|media_rw) ;; *) loge "mount.conf 第 $_lineno 行 dir policy 無效"; _err=1; continue;; esac
        printf '%s|%s
' "$_dp_norm" "$_dpol" >> "$_tmp/dirs"
        ;;
      profile=*)
        _v=${_line#profile=}; _g=${_v%%|*}; [ "$_g" != "$_v" ] || { loge "mount.conf 第 $_lineno 行 profile 格式錯誤"; _err=1; continue; }
        _sel=${_v#*|}; valid_id "$_g" && valid_id "$_sel" || { loge "mount.conf 第 $_lineno 行 profile 名稱無效"; _err=1; continue; }
        printf '%s|%s\n' "$_g" "$_sel" >> "$_tmp/profiles"
        ;;
      mount=*)
        _v=${_line#mount=}
        _nf=$(printf '%s\n' "$_v" | awk -F'|' '{print NF}')
        case "$_nf" in 8|9|10) ;; *) loge "mount.conf 第 $_lineno 行 mount 必須有 8~10 個欄位"; _err=1; continue;; esac
        _name=$(printf '%s' "$_v" | cut -d'|' -f1)
        _user=$(printf '%s' "$_v" | cut -d'|' -f2)
        _src=$(printf '%s' "$_v" | cut -d'|' -f3)
        _target=$(printf '%s' "$_v" | cut -d'|' -f4)
        _enabled=$(printf '%s' "$_v" | cut -d'|' -f5)
        _group=$(printf '%s' "$_v" | cut -d'|' -f6)
        _pval=$(printf '%s' "$_v" | cut -d'|' -f7)
        _policy=$(printf '%s' "$_v" | cut -d'|' -f8)
        _create=$(printf '%s' "$_v" | cut -d'|' -f9)
        _migrate=$(printf '%s' "$_v" | cut -d'|' -f10)
        [ -n "$_policy" ] || _policy=preserve
        [ -n "$_create" ] || _create=0
        [ -n "$_migrate" ] || _migrate=none
        valid_user "$_user" || { loge "mount.conf 第 $_lineno 行 user 無效"; _err=1; continue; }
        user_exists "$_user" || { loge "mount.conf 第 $_lineno 行 user=$_user 不存在，請先建立/啟用此 Android User 或改成正確 User ID"; _err=1; continue; }
        _src_in=$_src; _target_in=$_target
        _src=$(normalize_source "$_mp" "$_src_in") || { loge "mount.conf 第 $_lineno 行來源路徑無效/含 traversal"; _err=1; continue; }
        case "$_src_in" in /*) ;; *) logi "mount.conf 第 $_lineno 行 source 相對路徑已展開｜$_src_in → $_src" ;; esac
        case "$_enabled" in 0|1) ;; *) loge "mount.conf 第 $_lineno 行 enabled 只能是 0/1"; _err=1; continue;; esac
        case "$_policy" in preserve|media_rw|bindfs_shared) ;; *) loge "mount.conf 第 $_lineno 行 policy 只接受 preserve/media_rw/bindfs_shared"; _err=1; continue;; esac
        case "$_create" in 0|1) ;; *) loge "mount.conf 第 $_lineno 行 create 只接受 0/1"; _err=1; continue;; esac
        case "$_migrate" in none|once) ;; *) loge "mount.conf 第 $_lineno 行 migrate 只接受 none/once"; _err=1; continue;; esac
        if [ -n "$_group" ] || [ -n "$_pval" ]; then valid_id "$_group" && valid_id "$_pval" || { loge "mount.conf 第 $_lineno 行 profile group/value 無效"; _err=1; continue; }; fi
        _norm=$(normalize_target "$_user" "$_target_in") || { loge "mount.conf 第 $_lineno 行 target 路徑無效，或 target 的 User ID 與 user=$_user 不一致"; _err=1; continue; }
        _lower=$(printf '%s
' "$_norm" | awk -F'|' '{print $1}'); _visible=$(printf '%s
' "$_norm" | awk -F'|' '{print $2}')
        case "$_target_in" in /*) ;; *) logi "mount.conf 第 $_lineno 行 target 相對路徑已展開｜$_target_in → $_visible"; _target=$_visible ;; esac
        [ "$(realp "$_src")" != "$(realp "$_lower")" ] || { loge "mount.conf 第 $_lineno 行來源與目標實體路徑不可相同"; _err=1; continue; }
        if [ -z "$_name" ]; then _name=${_target%/}; _name=${_name##*/}; [ -n "$_name" ] || _name="$_target"; fi
        case "$_name$_src$_target" in *'|'*) loge "mount.conf 第 $_lineno 行欄位不可包含 |"; _err=1; continue;; esac
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_name" "$_user" "$_src" "$_target" "$_lower" "$_visible" "$_enabled" "$_group" "$_pval" "$_policy" "$_create" "$_migrate" >> "$_tmp/mounts.all"
        ;;
      *) loge "mount.conf 第 $_lineno 行不支援：$_line"; _err=1 ;;
    esac
  done < "$_cfg"
  [ -n "$_partition" ] || { loge "partition 必填：請填分區名稱，例如 partition=YAWAsau"; _err=1; }
  [ -z "$_partition" ] || valid_id "$_partition" || { loge "partition 名稱無效：只接受英數字、點、底線與連字號"; _err=1; }
  [ -n "$_mp" ] || { loge "mount_point 必填：請填主分區掛載位置，例如 mount_point=/mnt/YAWAsau"; _err=1; }
  [ -z "$_mp" ] || valid_safe_abs "$_mp" || { loge "mount_point 路徑無效/含 traversal"; _err=1; }
  case "$_fs" in auto|f2fs|ext4) ;; *) loge "fs 只接受 auto/f2fs/ext4"; _err=1;; esac
  # profile lines must be unique
  if [ "$(cut -d'|' -f1 "$_tmp/profiles" 2>/dev/null | sort | uniq -d | head -n1)" ]; then loge "mount.conf 有重複 profile group"; _err=1; fi
  # Every enabled profile entry must have a selected group.
  while IFS='|' read -r _n _u _s _t _l _v _e _g _pv _pol _create _migrate; do
    [ "$_e" = 1 ] || continue
    if [ -n "$_g" ]; then grep -Fq "$_g|" "$_tmp/profiles" || { loge "profile group=$_g 沒有 profile=... 選擇值"; _err=1; }; fi
  done < "$_tmp/mounts.all"
  [ "$_err" = 0 ] || { rm -rf "$_tmp"; return 3; }
  printf 'partition=%s\nmount_point=%s\nfs=%s\n' "$_partition" "$_mp" "$_fs" > "$_tmp/global"
  # Build selected desired list and reject duplicate targets.
  : > "$_tmp/mounts.desired"
  while IFS='|' read -r _n _u _s _t _l _v _e _g _pv _pol _create _migrate; do
    [ "$_e" = 1 ] || continue
    if [ -n "$_g" ]; then _sel=$(awk -F'|' -v g="$_g" '$1==g{print $2;exit}' "$_tmp/profiles"); [ "$_sel" = "$_pv" ] || continue; fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_n" "$_u" "$_s" "$_t" "$_l" "$_v" "$_e" "$_g" "$_pv" "$_pol" "$_create" "$_migrate" >> "$_tmp/mounts.desired"
  done < "$_tmp/mounts.all"
  if [ "$(cut -d'|' -f2,5 "$_tmp/mounts.desired" | sort | uniq -d | head -n1)" ]; then loge "目前 profile 選擇造成重複 target，拒絕套用"; rm -rf "$_tmp"; return 4; fi
  # Publish the parsed snapshot file-by-file with atomic rename. Never move the
  # whole shared directory away: WebUI/status readers must not observe a brief
  # missing parsed/ directory while a profile transaction is committing.
  mkdir -p "$_out" 2>/dev/null || { rm -rf "$_tmp"; return 5; }
  for _pc_f in global profiles dirs mounts.all mounts.desired; do
    [ -f "$_tmp/$_pc_f" ] || { rm -rf "$_tmp"; return 5; }
    mv -f "$_tmp/$_pc_f" "$_out/$_pc_f" 2>/dev/null || { rm -rf "$_tmp"; return 5; }
  done
  rm -rf "$_tmp" 2>/dev/null
  return 0
}

parse_global_config() {
  # Parse only partition/mount_point/fs so the block device can be mounted even
  # when later bind rows contain mistakes. This function deliberately ignores
  # mount/dir/profile rows and never treats their errors as root-mount blockers.
  _cfg=${1:-$CONF}; _out=${2:-$PARSED}
  [ -f "$_cfg" ] || { loge "設定檔不存在｜$_cfg"; return 2; }
  _tmp="$_out.global.tmp.$$"; rm -rf "$_tmp" 2>/dev/null; mkdir -p "$_tmp" || return 2
  _partition=''; _mp=''; _fs=auto
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line=$(trim "$_line")
    case "$_line" in
      ''|'#'*) continue ;;
      partition=*) _partition=${_line#partition=} ;;
      mount_point=*) _mp=${_line#mount_point=} ;;
      fs=*) _fs=${_line#fs=} ;;
    esac
  done < "$_cfg"
  _err=0
  [ -n "$_partition" ] || { loge "partition 必填：請填分區名稱，例如 partition=YAWAsau"; _err=1; }
  [ -z "$_partition" ] || valid_id "$_partition" || { loge "partition 名稱無效：只接受英數字、點、底線與連字號"; _err=1; }
  [ -n "$_mp" ] || { loge "mount_point 必填：請填主分區掛載位置，例如 mount_point=/mnt/YAWAsau"; _err=1; }
  [ -z "$_mp" ] || valid_safe_abs "$_mp" || { loge "mount_point 路徑無效/含 traversal"; _err=1; }
  case "$_fs" in auto|f2fs|ext4) ;; *) loge "fs 只接受 auto/f2fs/ext4"; _err=1;; esac
  [ "$_err" = 0 ] || { rm -rf "$_tmp"; return 3; }
  printf 'partition=%s
mount_point=%s
fs=%s
' "$_partition" "$_mp" "$_fs" > "$_tmp/global" || { rm -rf "$_tmp"; return 2; }
  : > "$_tmp/profiles"; : > "$_tmp/dirs"; : > "$_tmp/mounts.all"; : > "$_tmp/mounts.desired"
  mkdir -p "$_out" 2>/dev/null || { rm -rf "$_tmp"; return 2; }
  for _pg_f in global profiles dirs mounts.all mounts.desired; do
    mv -f "$_tmp/$_pg_f" "$_out/$_pg_f" 2>/dev/null || { rm -rf "$_tmp"; return 2; }
  done
  rm -rf "$_tmp" 2>/dev/null
  return 0
}

validate_snapshot_make() {
  # Copy an arbitrary config to a stable private snapshot for validate/dryrun.
  # This is read-only and must never publish parsed/cache/state.
  _vsm_src=$1
  _vsm_dst=$2
  _vsm_i=0
  [ -f "$_vsm_src" ] || return 1
  while [ "$_vsm_i" -lt 8 ]; do
    _vsm_before=$(config_hash "$_vsm_src" 2>/dev/null || true)
    [ -n "$_vsm_before" ] || { sleep 0.03; _vsm_i=$((_vsm_i+1)); continue; }
    cp -f "$_vsm_src" "$_vsm_dst" 2>/dev/null || { sleep 0.03; _vsm_i=$((_vsm_i+1)); continue; }
    _vsm_copy=$(config_hash "$_vsm_dst" 2>/dev/null || true)
    _vsm_after=$(config_hash "$_vsm_src" 2>/dev/null || true)
    if [ -n "$_vsm_copy" ] && [ "$_vsm_before" = "$_vsm_after" ] && [ "$_vsm_before" = "$_vsm_copy" ]; then
      printf '%s\n' "$_vsm_copy"
      return 0
    fi
    sleep 0.03
    _vsm_i=$((_vsm_i+1))
  done
  rm -f "$_vsm_dst" 2>/dev/null
  return 1
}

validate_line_hint() {
  _vlh_msg=$1
  case "$_vlh_msg" in
    *'dir 格式錯誤'*)
      echo '    建議：dir 格式必須是 dir=路徑|preserve 或 dir=路徑|media_rw。'
      ;;
    *'dir 路徑無效'*|*'來源路徑無效'*)
      echo '    建議：路徑不可包含 ..、| 或控制字元；source/dir 可用相對路徑，相對於 mount_point。'
      echo '    例：dir=DCIM/Camera|media_rw 或 mount=日常|0|DCIM|DCIM|1|camera|daily|media_rw|1|once'
      ;;
    *'dir policy 無效'*)
      echo '    建議：dir 權限策略只接受 preserve 或 media_rw。'
      ;;
    *'profile 格式錯誤'*)
      echo '    建議：profile 格式必須是 profile=群組|目前選項，例如 profile=camera|daily。'
      ;;
    *'profile 名稱無效'*)
      echo '    建議：profile 群組與選項只接受英數字、點、底線、連字號；例如 camera、daily、work。'
      ;;
    *'mount 必須有'*'欄位'*)
      echo '    建議：mount 格式為 名稱|User|來源|目標|啟用|Profile群組|Profile選項|權限策略|自動建立|首次搬移。'
      echo '    不使用 Profile 時中間兩欄要留空：mount=名稱|0|來源|目標|1|||media_rw|1|none'
      ;;
    *'user 無效'*)
      echo '    建議：第 2 欄必須是數字 User ID，主使用者通常是 0。常見錯誤是少寫 |0|。'
      echo '    例：mount=DCIM0|0|DCIM|DCIM|1|||media_rw|1|once'
      ;;
    *'user='*'不存在'*)
      echo '    建議：這個 Android User 不存在。請先建立/啟用該使用者，或把第 2 欄改成 cmd user list 裡存在的 User ID。'
      echo '    例：主使用者填 0；隱私空間/第二使用者請先確認實際 ID。'
      ;;
    *'enabled 只能是 0/1'*)
      echo '    建議：第 5 欄 enabled 只能填 1 或 0。'
      ;;
    *'policy 只接受'*)
      echo '    建議：第 8 欄 policy 只接受 preserve、media_rw 或 bindfs_shared。bindfs_shared 適合跨 User 共享資料夾，不會遞迴改來源檔案權限。'
      ;;
    *'create 只接受 0/1'*)
      echo '    建議：第 9 欄 create 只能填 1 或 0；1=來源不存在時建立，0=不建立。'
      ;;
    *'migrate 只接受'*)
      echo '    建議：第 10 欄 migrate 只接受 none 或 once。'
      ;;
    *'profile group/value 無效'*)
      echo '    建議：第 6/7 欄 Profile 群組與選項只接受英數字、點、底線、連字號；不切換就兩欄都留空。'
      ;;
    *'target 路徑無效'*)
      echo '    建議：target 建議用相對路徑，例如 虛擬分區 或 DCIM。'
      echo '    若寫絕對路徑，只接受 /storage/emulated/<User>/... 或 /data/media/<User>/...，且 User 必須和第 2 欄一致。'
      ;;
    *'來源與目標實體路徑不可相同'*)
      echo '    建議：source 不能指向 target 對應的 /data/media 實體目錄，避免自我 bind。'
      ;;
    *'partition 必填'*)
      echo '    建議：加入 partition=分區名稱，例如 partition=YAWAsau。'
      ;;
    *'partition 名稱無效'*)
      echo '    建議：partition 只填 by-name 名稱，不要填 /dev/block/...；只接受英數字、點、底線、連字號。'
      ;;
    *'mount_point 必填'*)
      echo '    建議：加入 mount_point=/mnt/名稱，例如 mount_point=/mnt/YAWAsau。'
      ;;
    *'mount_point 路徑無效'*)
      echo '    建議：mount_point 必須是絕對路徑，且不可包含 .. 或 |。'
      ;;
    *'fs 只接受'*)
      echo '    建議：fs 只能填 auto、f2fs 或 ext4。'
      ;;
    *'重複 profile group'*)
      echo '    建議：同一個 profile group 只能有一行 profile=。'
      ;;
    *'沒有 profile='*)
      echo '    建議：有 mount row 使用這個 profile group，就必須有對應 profile=群組|選項。'
      echo '    例：profile=camera|daily'
      ;;
    *'重複 target'*)
      echo '    建議：目前選中的掛載項不能有相同 User + 相同 target；Profile daily/work 只能同時選中一個。'
      ;;
    *)
      echo '    建議：依照上方原始行檢查欄位數、分隔符 |、User ID、路徑與 Profile。'
      ;;
  esac
}

validate_error_report() {
  _ver_log=$1
  _ver_cfg=$2
  _ver_count=0
  while IFS= read -r _ver_line || [ -n "$_ver_line" ]; do
    case "$_ver_line" in *'[錯誤]'*) ;; *) continue;; esac
    _ver_count=$((_ver_count+1))
    _ver_msg=$(printf '%s\n' "$_ver_line" | sed 's/^.*\[錯誤\] //')
    _ver_no=$(printf '%s\n' "$_ver_msg" | sed -n 's/.*第 \([0-9][0-9]*\) 行.*/\1/p' | head -n1)
    echo "  錯誤 $_ver_count：$_ver_msg"
    if [ -n "$_ver_no" ]; then
      _ver_src=$(awk -v n="$_ver_no" 'NR==n{print;exit}' "$_ver_cfg" 2>/dev/null)
      [ -n "$_ver_src" ] && echo "    原始第 $_ver_no 行：$_ver_src"
    fi
    validate_line_hint "$_ver_msg"
    echo
  done < "$_ver_log"
  [ "$_ver_count" -gt 0 ] || echo '  沒有取得具體錯誤行，請查看完整日誌。'
}

validate_warning_report() {
  _vwr_parsed=$1
  _vwr_count=0
  [ -f "$_vwr_parsed/mounts.all" ] || return 0
  _vwr_tmp="$RUNTIME/validate.warn.$$"
  : > "$_vwr_tmp" 2>/dev/null || return 0
  awk -F'|' '
    { n[NR]=$1; u[NR]=$2; s[NR]=$3; t[NR]=$4; pol[NR]=$10; c=NR }
    END {
      for (i=1;i<=c;i++) {
        if (s[i] == "/data/local/tmp" && pol[i] == "media_rw") {
          print "警告：" n[i] " 的 source=/data/local/tmp 但 policy=media_rw。建議改成 policy=preserve，避免改動 shell/root 暫存區權限。"
        }
        if (pol[i] == "bindfs_shared") {
          print "提示：" n[i] " 使用 bindfs_shared。這會用 bindfs 靜態 FUSE 權限映射，不遞迴修改來源檔案；適合跨 User 共享資料夾。"
        }
      }
      for (i=1;i<=c;i++) {
        for (j=1;j<=c;j++) {
          if (i==j) continue
          if (u[i] != u[j]) continue
          prefix=t[i] "/"
          if (length(t[i]) > 1 && index(t[j], prefix) == 1) {
            print "警告：" n[j] " 的 target 位於另一個掛載項「" n[i] "」裡面：" t[j] "。這是嵌套掛載，Android App/FUSE namespace 可見性不保證；建議改成頂層 target。"
          }
        }
      }
    }
  ' "$_vwr_parsed/mounts.all" 2>/dev/null > "$_vwr_tmp"
  if [ -s "$_vwr_tmp" ]; then
    echo
    echo '提醒 / 警告：'
    while IFS= read -r _vwr_line || [ -n "$_vwr_line" ]; do
      _vwr_count=$((_vwr_count+1))
      echo "  - $_vwr_line"
    done < "$_vwr_tmp"
  fi
  rm -f "$_vwr_tmp" 2>/dev/null
  return 0
}

validate_config_report() {
  _vcr_mode=${1:-validate}; _vcr_cfg=${2:-$CONF}
  _vcr_saved_parsed=$PARSED; _vcr_saved_log=$LOG
  _vcr_global="$RUNTIME/validate.global.$$"; _vcr_parsed="$RUNTIME/validate.parsed.$$"; _vcr_log="$RUNTIME/validate.log.$$"; _vcr_snap="$RUNTIME/validate.conf.$$"
  rm -rf "$_vcr_global" "$_vcr_parsed" 2>/dev/null; rm -f "$_vcr_snap" 2>/dev/null; : > "$_vcr_log" 2>/dev/null
  LOG=$_vcr_log
  echo "設定檢查：$_vcr_cfg"
  echo "目前生效設定：$CONF"
  echo "模組內建範例：$EXAMPLE_CONF"
  echo "提示：confwatch 只監聽目前生效設定；修改模組目錄內的 mount.conf / mount.conf.example 不會即時生效。"
  echo "提示：刷入新版時既有 live mount.conf 會保留；只有 live 檔不存在時才建立預設設定。"
  echo

  _vcr_hash=$(validate_snapshot_make "$_vcr_cfg" "$_vcr_snap" 2>/dev/null || true)
  if [ -z "$_vcr_hash" ]; then
    echo "設定檔：錯誤"
    echo "  無法建立穩定快照，可能正在被編輯器寫入。請儲存完成後再檢查。"
    LOG=$_vcr_saved_log; PARSED=$_vcr_saved_parsed
    rm -rf "$_vcr_global" "$_vcr_parsed" 2>/dev/null; rm -f "$_vcr_log" "$_vcr_snap" 2>/dev/null
    return 3
  fi
  echo "設定檔快照：OK"
  echo "  hash=$_vcr_hash"
  echo

  parse_global_config "$_vcr_snap" "$_vcr_global" >/dev/null 2>&1
  _vcr_grc=$?
  if [ "$_vcr_grc" -eq 0 ]; then
    PARSED=$_vcr_global
    _vcr_part=$(cfg_get partition); _vcr_mp=$(cfg_get mount_point); _vcr_fs=$(cfg_get fs)
    _vcr_dev=$(resolve_device 2>/dev/null || true)
    _vcr_real=''; [ -n "$_vcr_dev" ] && _vcr_real=$(realp "$_vcr_dev")
    echo "主分區：OK"
    echo "  partition=$_vcr_part"
    echo "  block=${_vcr_dev:-找不到}"
    [ -n "$_vcr_real" ] && echo "  block_real=$_vcr_real"
    echo "  mount_point=$_vcr_mp"
    echo "  fs=$_vcr_fs"
    if [ "$_vcr_mode" = dryrun ]; then
      if [ -n "$_vcr_dev" ]; then
        _vcr_dfs=$(detect_fs "$_vcr_dev" 2>/dev/null || true)
        echo "  detect_fs=${_vcr_dfs:-無法辨識}"
      fi
    fi
  else
    echo "主分區：錯誤（global rc=$_vcr_grc）"
  fi
  echo

  rm -rf "$_vcr_parsed" 2>/dev/null
  : > "$_vcr_log" 2>/dev/null
  parse_config "$_vcr_snap" "$_vcr_parsed" >/dev/null 2>&1
  _vcr_rc=$?
  _vcr_used_cache=0
  if [ "$_vcr_rc" -ne 0 ] && [ "$_vcr_cfg" = "$CONF" ]; then
    _vcr_applied=$(cat "$APPLIED_HASH" 2>/dev/null)
    if [ -n "$_vcr_hash" ] && [ "$_vcr_hash" = "$_vcr_applied" ] && parsed_cache_matches_hash "$_vcr_hash" && [ -f "$PARSED_REAL/mounts.all" ]; then
      rm -rf "$_vcr_parsed" 2>/dev/null; mkdir -p "$_vcr_parsed" 2>/dev/null
      for _vcr_f in global profiles dirs mounts.all mounts.desired; do cp -f "$PARSED_REAL/$_vcr_f" "$_vcr_parsed/$_vcr_f" 2>/dev/null || true; done
      _vcr_rc=0
      _vcr_used_cache=1
    fi
  fi

  if [ "$_vcr_rc" -eq 0 ]; then
    PARSED=$_vcr_parsed
    _vcr_total=$(wc -l < "$_vcr_parsed/mounts.all" 2>/dev/null | tr -d ' '); [ -n "$_vcr_total" ] || _vcr_total=0
    _vcr_desired=$(wc -l < "$_vcr_parsed/mounts.desired" 2>/dev/null | tr -d ' '); [ -n "$_vcr_desired" ] || _vcr_desired=0
    if [ "$_vcr_used_cache" -eq 1 ]; then
      echo "mount rows：OK（使用最後成功套用快取）"
      echo "  說明：live mount.conf 的 hash 已是最後成功套用版本；本次 dryrun parser 回報與快取不一致，未污染正式狀態。"
    else
      echo "mount rows：OK（total=$_vcr_total desired=$_vcr_desired）"
    fi
    if [ -s "$_vcr_parsed/profiles" ]; then
      echo "Profiles："
      while IFS='|' read -r _vcr_g _vcr_s; do [ -n "$_vcr_g" ] && echo "  $_vcr_g=$_vcr_s"; done < "$_vcr_parsed/profiles"
    else
      echo "Profiles：未設定"
    fi
    echo "掛載項目："
    if [ -s "$_vcr_parsed/mounts.all" ]; then
      while IFS='|' read -r _vcr_n _vcr_u _vcr_s _vcr_t _vcr_l _vcr_v _vcr_e _vcr_g _vcr_pv _vcr_pol _vcr_create _vcr_migrate; do
        [ -n "$_vcr_n$_vcr_s$_vcr_t" ] || continue
        _vcr_sel=active
        if [ -n "$_vcr_g" ]; then
          _vcr_cur=$(awk -F'|' -v g="$_vcr_g" '$1==g{print $2;exit}' "$_vcr_parsed/profiles")
          [ "$_vcr_cur" = "$_vcr_pv" ] && _vcr_sel=selected || _vcr_sel=inactive
        fi
        echo "  - $_vcr_n｜User=$_vcr_u｜$_vcr_sel｜create=$_vcr_create｜policy=$_vcr_pol｜migrate=$_vcr_migrate"
        echo "    source=$_vcr_s"
        echo "    target=$_vcr_t"
        echo "    lower=$_vcr_l"
        [ -n "$_vcr_v" ] && echo "    visible=$_vcr_v"
        if [ "$_vcr_mode" = dryrun ]; then
          if [ -d "$_vcr_s" ]; then echo "    source_state=exists"; elif [ "$_vcr_create" = 1 ]; then echo "    source_state=will_create"; else echo "    source_state=missing_create0"; fi
          if user_storage_available "$_vcr_u"; then echo "    user_state=storage_available"; elif user_unlocked "$_vcr_u"; then echo "    user_state=unlocked"; else echo "    user_state=locked/deferred"; fi
        fi
      done < "$_vcr_parsed/mounts.all"
    fi
    validate_warning_report "$_vcr_parsed"
  else
    echo "mount rows：錯誤（rc=$_vcr_rc）"
    echo "錯誤明細："
    validate_error_report "$_vcr_log" "$_vcr_snap"
    echo '解析資訊：'
    grep '\[資訊\]\|\[警告\]' "$_vcr_log" 2>/dev/null | sed 's/^/  /' || true
  fi
  LOG=$_vcr_saved_log; PARSED=$_vcr_saved_parsed
  rm -rf "$_vcr_global" "$_vcr_parsed" 2>/dev/null
  rm -f "$_vcr_log" "$_vcr_snap" 2>/dev/null
  return "$_vcr_rc"
}

cfg_get() { grep -m1 "^$1=" "$PARSED/global" 2>/dev/null | cut -d= -f2-; }

parsed_publish_dir() {
  _pp_src=$1; _pp_hash=${2:-}
  [ -d "$_pp_src" ] || return 1
  mkdir -p "$PARSED_REAL" 2>/dev/null || return 1
  for _pp_f in global profiles dirs mounts.all mounts.desired; do
    [ -f "$_pp_src/$_pp_f" ] || return 1
    cp -f "$_pp_src/$_pp_f" "$PARSED_REAL/$_pp_f.tmp.$$" 2>/dev/null || return 1
    mv -f "$PARSED_REAL/$_pp_f.tmp.$$" "$PARSED_REAL/$_pp_f" 2>/dev/null || return 1
  done
  if [ -n "$_pp_hash" ]; then
    printf '%s\n' "$_pp_hash" > "$PARSED_HASH.tmp.$$" 2>/dev/null && mv -f "$PARSED_HASH.tmp.$$" "$PARSED_HASH" 2>/dev/null || true
  fi
  return 0
}

parsed_cache_matches_hash() {
  _pch=$1
  [ -n "$_pch" ] && [ -f "$PARSED_HASH" ] && [ "$(cat "$PARSED_HASH" 2>/dev/null)" = "$_pch" ]
}

config_state_value() {
  grep -m1 "^$1=" "$CONFIG_STATE" 2>/dev/null | cut -d= -f2-
}

resolve_partition_name() {
  _rpn_part=$1
  valid_id "$_rpn_part" || return 1
  _rpn_first=''; _rpn_first_real=''
  for _rpn_cand in \
    "/dev/block/by-name/$_rpn_part" \
    "/dev/block/bootdevice/by-name/$_rpn_part" \
    /dev/block/platform/*/by-name/"$_rpn_part" \
    /dev/block/platform/*/*/by-name/"$_rpn_part" \
    /dev/block/platform/*/*/*/by-name/"$_rpn_part"
  do
    [ -e "$_rpn_cand" ] || continue
    _rpn_real=$(realp "$_rpn_cand")
    case "$_rpn_real" in /dev/block/*) ;; *) continue;; esac
    if [ -z "$_rpn_first" ]; then
      _rpn_first="$_rpn_cand"; _rpn_first_real="$_rpn_real"
    elif [ "$_rpn_real" != "$_rpn_first_real" ]; then
      loge "找到多個同名分區但指向不同裝置，拒絕猜測｜partition=$_rpn_part｜第一個=$_rpn_first_real｜另一個=$_rpn_real"
      return 2
    fi
  done
  [ -n "$_rpn_first" ] || return 1
  printf '%s\n' "$_rpn_first"
}

resolve_device() {
  _rd_part=$(cfg_get partition)
  [ -n "$_rd_part" ] || return 1
  resolve_partition_name "$_rd_part"
}
blkid_line() {
  _bfd_dev=$1
  if command -v blkid >/dev/null 2>&1; then
    _bfd_line=$(blkid "$_bfd_dev" 2>/dev/null | head -n1)
    [ -n "$_bfd_line" ] && { printf '%s\n' "$_bfd_line"; return 0; }
  fi
  if command -v toybox >/dev/null 2>&1; then
    _bfd_line=$(toybox blkid "$_bfd_dev" 2>/dev/null | head -n1)
    [ -n "$_bfd_line" ] && { printf '%s\n' "$_bfd_line"; return 0; }
  fi
  if command -v busybox >/dev/null 2>&1; then
    _bfd_line=$(busybox blkid "$_bfd_dev" 2>/dev/null | head -n1)
    [ -n "$_bfd_line" ] && { printf '%s\n' "$_bfd_line"; return 0; }
  fi
  return 1
}

detect_fs() {
  _dfs_dev=$1; _dfs_want=$(cfg_get fs)
  [ "$_dfs_want" = auto ] || { printf '%s\n' "$_dfs_want"; return 0; }

  # Keep the known-good Android detector chain used before v1.2.x.
  # Some ROMs expose blkid only through toybox/busybox, and some blkid builds
  # do not support util-linux style `-s TYPE -o value` arguments.
  _dfs_line=$(blkid_line "$_dfs_dev" | head -n1)
  _dfs_type=$(printf '%s\n' "$_dfs_line" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' | head -n1)
  if [ -z "$_dfs_type" ]; then
    _dfs_type=$(printf '%s\n' "$_dfs_line" | sed -n 's/.*TYPE=\([^[:space:]]*\).*/\1/p' | head -n1)
  fi
  if [ -z "$_dfs_type" ] && command -v lsblk >/dev/null 2>&1; then
    _dfs_type=$(lsblk -no FSTYPE "$_dfs_dev" 2>/dev/null | head -n1 | tr -d '[:space:]')
  fi
  _dfs_type=$(printf '%s' "$_dfs_type" | tr 'A-Z' 'a-z')
  case "$_dfs_type" in
    f2fs|ext4) printf '%s\n' "$_dfs_type"; return 0 ;;
    *) return 1 ;;
  esac
}


global_preflight() {
  # Validate new global settings before tearing down the last known-good root.
  _newdev=$(resolve_device) || { loge "新設定預檢失敗：找不到分區裝置"; return 20; }
  _newmp=$(cfg_get mount_point)
  if [ -n "$_newdev" ]; then
    _newfs=$(detect_fs "$_newdev") || { loge "新設定預檢失敗：只支援/可辨識 f2fs/ext4｜裝置=$_newdev"; return 21; }
    if is_mounted "$_newmp"; then
      _cur=$(realp "$(mount_src "$_newmp")"); _want=$(realp "$_newdev"); _cfs=$(mount_fs "$_newmp")
      # Occupied by the desired root is fine. Occupied by the old configured root is
      # also fine during a hot swap and will be removed after this preflight.
      if [ "$_cur" = "$_want" ] && [ "$_cfs" = "$_newfs" ]; then return 0; fi
      if [ -f "$GLOBAL_ACTIVE" ]; then
        _og=$(cat "$GLOBAL_ACTIVE" 2>/dev/null)
        _omp=$(printf '%s\n' "$_og" | sed -n 's/^mount_point=//p')
        _opart=$(printf '%s\n' "$_og" | sed -n 's/^partition=//p')
        _odev=$(resolve_partition_name "$_opart" 2>/dev/null || true)
        _od1=''; [ -n "$_odev" ] && _od1=$(realp "$_odev")
        if [ "$_newmp" = "$_omp" ] && [ -n "$_od1" ] && [ "$_cur" = "$_od1" ]; then return 0; fi
      fi
      loge "新設定預檢失敗：mount_point 已被未知來源占用｜$_newmp｜來源=$_cur｜fs=$_cfs"
      return 23
    fi
  fi
  return 0
}
mount_root_ensure() {
  _dev=$(resolve_device) || { loge "找不到設定的分區裝置"; return 20; }
  _mp=$(cfg_get mount_point)
  _fs=$(detect_fs "$_dev") || { loge "只支援 f2fs/ext4，無法辨識 $_dev"; return 21; }
  mkdir -p "$_mp" 2>/dev/null || return 22
  if is_mounted "$_mp"; then
    _cur=$(realp "$(mount_src "$_mp")"); _want=$(realp "$_dev"); _cfs=$(mount_fs "$_mp")
    [ "$_cur" = "$_want" ] && [ "$_cfs" = "$_fs" ] && { logi "主分區已掛載｜裝置=$_dev｜fs=$_fs｜掛載點=$_mp"; return 0; }
    loge "mount_point 已被其他來源占用｜$_mp｜來源=$_cur｜fs=$_cfs"; return 23
  fi
  ns1 mount -t "$_fs" -o rw,noatime "$_dev" "$_mp" 2>/dev/null || {
    # concurrent mount is okay only if revalidation matches
    _cur=$(realp "$(mount_src "$_mp")"); _want=$(realp "$_dev"); _cfs=$(mount_fs "$_mp")
    [ "$_cur" = "$_want" ] && [ "$_cfs" = "$_fs" ] && { logi "偵測到併發掛載，驗證後正常｜$_mp"; return 0; }
    loge "主分區掛載失敗｜裝置=$_dev｜fs=$_fs｜掛載點=$_mp"; return 24
  }
  logi "主分區掛載成功｜裝置=$_dev｜fs=$_fs｜掛載點=$_mp"
  return 0
}

package_media() {
  _pkg=$(dumpsys package providers 2>/dev/null | awk '/\[media\]:/{w=1;next} w&&/Provider\{/{x=$0;sub(/^.*Provider\{[0-9A-Fa-f]+[[:space:]]+/,"",x);sub(/\/.*/,"",x);gsub(/[[:space:]]/,"",x);print x;exit}')
  case "$_pkg" in ''|*[!A-Za-z0-9._]*) _pkg='';; esac
  [ -n "$_pkg" ] && { printf '%s\n' "$_pkg"; return; }
  for _pkg in com.android.providers.media.module com.google.android.providers.media.module com.android.providers.media; do pidof "$_pkg" >/dev/null 2>&1 && { printf '%s\n' "$_pkg"; return; }; done
  return 1
}

pkg_uid_user() {
  _u=$1; _pkg=$2
  _out=$(cmd package list packages -U --user "$_u" "$_pkg" 2>/dev/null | head -n1)
  _uid=$(printf '%s\n' "$_out" | sed -n 's/.* uid:\([0-9][0-9]*\).*/\1/p')
  case "$_uid" in ''|*[!0-9]*) ;; *) printf '%s\n' "$_uid"; return 0;; esac
  _app=$(dumpsys package "$_pkg" 2>/dev/null | sed -n 's/^[[:space:]]*userId=\([0-9][0-9]*\).*/\1/p' | head -n1)
  case "$_app" in ''|*[!0-9]*) return 1;; esac
  printf '%s\n' $((_u*100000+_app))
}

media_cache_file() { printf '%s/media_provider_ns.%s.cache\n' "$RUNTIME" "$1"; }
media_cache_pid() {
  _u=$1; _cf=$(media_cache_file "$_u"); [ -f "$_cf" ] || return 1
  _pid=$(grep -m1 '^PID=' "$_cf" | cut -d= -f2); _ns=$(grep -m1 '^NS=' "$_cf" | cut -d= -f2); _pkg=$(grep -m1 '^PACKAGE=' "$_cf" | cut -d= -f2); _cached_uid=$(grep -m1 '^UID=' "$_cf" | cut -d= -f2)
  case "$_pid" in ''|*[!0-9]*) return 1;; esac; [ -e "/proc/$_pid/ns/mnt" ] || return 1
  _now=$(readlink "/proc/$_pid/ns/mnt" 2>/dev/null); [ -n "$_now" ] && [ "$_now" = "$_ns" ] || return 1
  _cmd=$(tr '\0' '\n' < "/proc/$_pid/cmdline" 2>/dev/null | head -n1)
  case "$_cmd" in "$_pkg"|"$_pkg":*) ;; *) return 1;; esac
  # v1.2.6 fast cache validation: do not call PackageManager on every bind/probe.
  # The UID was resolved when the cache was created; validate it directly from /proc.
  case "$_cached_uid" in
    ''|*[!0-9]*) return 1 ;;
    *) _actual_uid=$(awk '/^Uid:/{print $2;exit}' "/proc/$_pid/status" 2>/dev/null); [ "$_actual_uid" = "$_cached_uid" ] || return 1 ;;
  esac
  printf '%s\n' "$_pid"
}

media_cache_refresh() {
  _u=$1; _pkg=$(package_media) || return 1; _uid=$(pkg_uid_user "$_u" "$_pkg" 2>/dev/null || true)
  _pid=''
  if [ -n "$_uid" ]; then
    _pid=$(ps -A -o PID,UID,NAME 2>/dev/null | awk -v u="$_uid" -v p="$_pkg" '$2==u && index($3,p)==1{print $1;exit}')
  fi
  if [ -z "$_pid" ]; then
    for _p in $(pidof "$_pkg" 2>/dev/null); do
      _pu=$(awk '/^Uid:/{print $2;exit}' "/proc/$_p/status" 2>/dev/null)
      [ -n "$_uid" ] && [ "$_pu" != "$_uid" ] && continue
      if ns_available && nsenter -t "$_p" -m -- test -d "/storage/emulated/$_u" >/dev/null 2>&1; then _pid=$_p; break; fi
    done
  fi
  case "$_pid" in ''|*[!0-9]*) return 1;; esac
  _ns=$(readlink "/proc/$_pid/ns/mnt" 2>/dev/null); [ -n "$_ns" ] || return 1
  if [ -z "$_uid" ]; then _uid=$(awk '/^Uid:/{print $2;exit}' "/proc/$_pid/status" 2>/dev/null); fi
  case "$_uid" in ''|*[!0-9]*) return 1;; esac
  _cf=$(media_cache_file "$_u"); _tmp="$_cf.tmp.$$"
  { printf 'USER=%s\nPACKAGE=%s\nUID=%s\nPID=%s\nNS=%s\n' "$_u" "$_pkg" "$_uid" "$_pid" "$_ns"; } > "$_tmp" || return 1
  chmod 0600 "$_tmp" 2>/dev/null; mv -f "$_tmp" "$_cf" || return 1
  logi "已鎖定 MediaProvider namespace｜User=$_u｜package=$_pkg｜pid=$_pid｜ns=$_ns"
  printf '%s\n' "$_pid"
}

ensure_media_pid() { _p=$(media_cache_pid "$1" 2>/dev/null || true); [ -n "$_p" ] || _p=$(media_cache_refresh "$1" 2>/dev/null || true); [ -n "$_p" ] && printf '%s\n' "$_p"; }

user_unlocked() {
  _u=$1
  _x=$(cmd user is-user-unlocked "$_u" 2>/dev/null | tr 'A-Z' 'a-z' | head -n1)
  case "$_x" in true|1|*' true'*) return 0;; false|0|*' false'*) return 1;; esac
  [ "$(getprop "sys.user.$_u.ce_available" 2>/dev/null)" = true ] && return 0
  [ "$(getprop "sys.user.$_u.ce_available" 2>/dev/null)" = 1 ] && return 0
  dumpsys user 2>/dev/null | grep -A8 -F "UserInfo{$_u:" | grep -q 'state=RUNNING_UNLOCKED'
}

user_storage_available() {
  # User 0 must wait for CE unlock. /data/media/0 may exist before decrypt, but
  # binding DCIM/media targets before unlock causes misleading early success.
  # Secondary / Private Space users keep the older root-directory fallback because
  # some builds report is-user-unlocked late while their media root is already usable.
  _usa_u=$1
  if [ "$_usa_u" = 0 ]; then
    user_unlocked 0 && return 0
    return 1
  fi
  user_unlocked "$_usa_u" && return 0
  [ -d "/data/media/$_usa_u" ] && return 0
  [ -d "/storage/emulated/$_usa_u" ] && return 0
  ns1 test -d "/data/media/$_usa_u" >/dev/null 2>&1 && return 0
  ns1 test -d "/storage/emulated/$_usa_u" >/dev/null 2>&1 && return 0
  return 1
}

target_mkdir_or_defer() {
  # rc 0=created/exists, 75=deferred user-storage target, 1=fatal.
  _tmod_u=$1; _tmod_l=$2; _tmod_v=$3; _tmod_n=$4; _tmod_phase=$5
  ns1 mkdir -p "$_tmod_l" 2>/dev/null && return 0
  mkdir -p "$_tmod_l" 2>/dev/null && return 0
  if [ -n "$_tmod_v" ]; then
    logi "User 儲存目標尚未可建立，延後掛載｜階段=$_tmod_phase｜名稱=$_tmod_n｜User=$_tmod_u｜目標=$_tmod_l"
    return 75
  fi
  return 1
}

visible_target_lower_path() {
  _vtlp_u=$1; _vtlp_l=$2; _vtlp_v=$3
  case "$_vtlp_l" in
    /data/media/$_vtlp_u/*|/data/media/$_vtlp_u) printf '%s\n' "$_vtlp_l"; return 0 ;;
  esac
  case "$_vtlp_v" in
    /storage/emulated/$_vtlp_u/*|/storage/emulated/$_vtlp_u)
      _vtlp_rel=${_vtlp_v#/storage/emulated/$_vtlp_u}
      printf '/data/media/%s%s\n' "$_vtlp_u" "$_vtlp_rel"
      return 0
      ;;
  esac
  return 1
}

restore_visible_target_after_unmount() {
  # When a row is disabled/removed, the bind mount is gone and the exposed
  # /storage/emulated/<user>/... path becomes a plain lower directory again.
  # Normalize that lower directory as an Android media directory so file managers
  # do not inherit root/app-private ownership from the old mount target.
  _rvtu_u=$1; _rvtu_l=$2; _rvtu_v=$3; _rvtu_n=$4; _rvtu_reason=${5:-config_event}
  case "$_rvtu_u" in ''|*[!0-9]*) return 0;; esac
  [ -n "$_rvtu_v" ] || return 0
  user_storage_available "$_rvtu_u" || { logi "卸載後目標整理延後：User 尚未解鎖｜名稱=$_rvtu_n｜User=$_rvtu_u"; return 0; }
  _rvtu_lower=$(visible_target_lower_path "$_rvtu_u" "$_rvtu_l" "$_rvtu_v" 2>/dev/null || true)
  [ -n "$_rvtu_lower" ] || return 0
  ns1 mkdir -p "$_rvtu_lower" 2>/dev/null || mkdir -p "$_rvtu_lower" 2>/dev/null || { logw "卸載後目標整理失敗：無法建立普通目錄｜名稱=$_rvtu_n｜目標=$_rvtu_lower"; return 0; }
  chown media_rw:media_rw "$_rvtu_lower" 2>/dev/null || ns1 chown media_rw:media_rw "$_rvtu_lower" 2>/dev/null || logw "卸載後目標 chown media_rw 失敗｜名稱=$_rvtu_n｜目標=$_rvtu_lower"
  chmod 2770 "$_rvtu_lower" 2>/dev/null || ns1 chmod 2770 "$_rvtu_lower" 2>/dev/null || logw "卸載後目標 chmod 2770 失敗｜名稱=$_rvtu_n｜目標=$_rvtu_lower"
  if command -v chcon >/dev/null 2>&1; then
    chcon u:object_r:media_rw_data_file:s0 "$_rvtu_lower" 2>/dev/null || ns1 chcon u:object_r:media_rw_data_file:s0 "$_rvtu_lower" 2>/dev/null || true
  fi
  logi "已恢復卸載後目標為普通媒體目錄｜名稱=$_rvtu_n｜User=$_rvtu_u｜目標=$_rvtu_lower"
  media_scan_schedule_visible "$_rvtu_u" "$_rvtu_v" "unmount_restore_$_rvtu_reason" >/dev/null 2>&1 || true
  return 0
}

restore_disabled_mount_targets_from_config() {
  _rdmt_cfg=${1:-$CONF}; _rdmt_reason=${2:-config_event}
  [ -f "$_rdmt_cfg" ] || return 0
  while IFS= read -r _rdmt_line || [ -n "$_rdmt_line" ]; do
    _rdmt_line=${_rdmt_line%%$'\r'}
    case "$_rdmt_line" in ''|'#'*) continue;; esac
    case "$_rdmt_line" in mount=*) ;; *) continue;; esac
    _rdmt_body=${_rdmt_line#mount=}
    OLDIFS=$IFS; IFS='|'; set -- $_rdmt_body; IFS=$OLDIFS
    _rdmt_n=$1; _rdmt_u=$2; _rdmt_src=$3; _rdmt_t=$4; _rdmt_e=$5
    [ "$_rdmt_e" = 0 ] || continue
    case "$_rdmt_u" in ''|*[!0-9]*) continue;; esac
    [ -n "$_rdmt_t" ] || continue
    case "$_rdmt_t" in
      /storage/emulated/$_rdmt_u|/storage/emulated/$_rdmt_u/*)
        _rdmt_v=$_rdmt_t; _rdmt_l="/data/media/$_rdmt_u${_rdmt_t#/storage/emulated/$_rdmt_u}" ;;
      /data/media/$_rdmt_u|/data/media/$_rdmt_u/*)
        _rdmt_l=$_rdmt_t; _rdmt_v="/storage/emulated/$_rdmt_u${_rdmt_t#/data/media/$_rdmt_u}" ;;
      /*)
        continue ;;
      *)
        _rdmt_l="/data/media/$_rdmt_u/$_rdmt_t"; _rdmt_v="/storage/emulated/$_rdmt_u/$_rdmt_t" ;;
    esac
    # Do not normalize a disabled duplicate if the same target is currently
    # desired by another active row. This keeps profile pairs such as daily/work
    # from fighting each other if users keep disabled helper rows around.
    if [ -f "$PARSED/mounts.desired" ] && awk -F'|' -v u="$_rdmt_u" -v l="$_rdmt_l" '$2==u&&$5==l{found=1} END{exit found?0:1}' "$PARSED/mounts.desired" 2>/dev/null; then
      continue
    fi
    restore_visible_target_after_unmount "$_rdmt_u" "$_rdmt_l" "$_rdmt_v" "${_rdmt_n:-$_rdmt_t}" "disabled_$_rdmt_reason" >/dev/null 2>&1 || true
  done < "$_rdmt_cfg"
  return 0
}
user_proc_pids() {
  # Include already-running apps of the target Android user.  Some ROMs give
  # MT/MediaProvider/ExternalStorage separate mount namespaces; binding only
  # init/zygote/media can leave an already-open file manager seeing the old
  # lower directory and still hitting EACCES.
  _upp_u=$1
  case "$_upp_u" in ''|*[!0-9]*) return 0;; esac
  _upp_lo=$((_upp_u*100000))
  _upp_hi=$((_upp_lo+99999))
  for _upp_d in /proc/[0-9]*; do
    _upp_p=${_upp_d##*/}
    _upp_uid=$(awk '/^Uid:/{print $2; exit}' "$_upp_d/status" 2>/dev/null)
    case "$_upp_uid" in ''|*[!0-9]*) continue;; esac
    [ "$_upp_uid" -ge "$_upp_lo" ] && [ "$_upp_uid" -le "$_upp_hi" ] && printf '%s\n' "$_upp_p"
  done
}

core_ns_pids_base() {
  _u=$1
  printf '%s\n' 1
  ensure_media_pid "$_u" 2>/dev/null || true
  pidof system_server 2>/dev/null | tr ' ' '\n'
  pidof zygote64 2>/dev/null | tr ' ' '\n'
  pidof zygote 2>/dev/null | tr ' ' '\n'
  pidof android.process.media 2>/dev/null | tr ' ' '\n'
  pidof com.android.externalstorage 2>/dev/null | tr ' ' '\n'
  pidof sdcard 2>/dev/null | tr ' ' '\n'
  pidof vold 2>/dev/null | tr ' ' '\n'
}

core_ns_pids() {
  _u=$1
  core_ns_pids_base "$_u"
  user_proc_pids "$_u"
}

fast_foreground_reason() {
  case "$1" in
    boot_initial|user*_unlocked|user0_propwait|user0_filewatch|user_*_storage_ready_retry*) return 0 ;;
    # v1.4.78: live mount.conf reloads should not foreground-scan every App
    # namespace.  Mount changed rows into core namespaces first, then let the
    # generation-fenced background worker refresh already-running apps.
    config_event|config_event_retry|config_poll_fallback|manual|webui|profile_prerepair) return 0 ;;
  esac
  return 1
}

mount_row_ns_foreground() {
  _mrf_u=$1; _mrf_src=$2; _mrf_dst=$3; _mrf_pol=$4
  if [ "$_mrf_pol" = bindfs_shared ]; then
    mount_row_ns "$_mrf_u" "$_mrf_src" "$_mrf_dst" "$_mrf_pol"
  else
    bind_all_ns_base "$_mrf_u" "$_mrf_src" "$_mrf_dst"
  fi
}

ns_background_generation_set() {
  _nbgs_v=$1
  [ -n "$_nbgs_v" ] || return 1
  _nbgs_tmp="$NS_BG_GEN.tmp.$$"
  printf '%s\n' "$_nbgs_v" > "$_nbgs_tmp" 2>/dev/null || return 1
  mv -f "$_nbgs_tmp" "$NS_BG_GEN" 2>/dev/null
}

ns_background_generation_current() {
  _nbgc_v=$1
  [ -n "$_nbgc_v" ] || return 1
  [ "$(cat "$NS_BG_GEN" 2>/dev/null)" = "$_nbgc_v" ]
}

app_ns_pids_only() {
  _anpo_u=$1
  _anpo_base=''
  _anpo_seen=''
  # Build an exclusion set for init / MediaProvider / system_server / zygote /
  # externalstorage / vold / sdcard namespaces. Background work must never
  # mutate these core namespaces after the foreground transaction commits.
  for _anpo_p in $(core_ns_pids_base "$_anpo_u"); do
    case "$_anpo_p" in ''|*[!0-9]*) continue;; esac
    _anpo_ns=$(pid_ns_id "$_anpo_p"); [ -n "$_anpo_ns" ] || continue
    case " $_anpo_base " in *" $_anpo_ns "*) ;; *) _anpo_base="$_anpo_base $_anpo_ns";; esac
  done
  _anpo_lo=$((_anpo_u*100000+10000))
  _anpo_hi=$((_anpo_u*100000+99999))
  for _anpo_p in $(user_proc_pids "$_anpo_u"); do
    case "$_anpo_p" in ''|*[!0-9]*) continue;; esac
    _anpo_uid=$(awk '/^Uid:/{print $2;exit}' "/proc/$_anpo_p/status" 2>/dev/null)
    case "$_anpo_uid" in ''|*[!0-9]*) continue;; esac
    [ "$_anpo_uid" -ge "$_anpo_lo" ] && [ "$_anpo_uid" -le "$_anpo_hi" ] || continue
    _anpo_ns=$(pid_ns_id "$_anpo_p"); [ -n "$_anpo_ns" ] || continue
    case " $_anpo_base " in *" $_anpo_ns "*) continue;; esac
    case " $_anpo_seen " in *" $_anpo_ns "*) continue;; esac
    _anpo_seen="$_anpo_seen $_anpo_ns"
    printf '%s\n' "$_anpo_p"
  done
}

mount_app_ns_only() {
  _mano_gen=$1; _mano_u=$2; _mano_src=$3; _mano_dst=$4; _mano_pol=${5:-preserve}
  # bindfs_shared deliberately exists only in init + MediaProvider namespaces.
  [ "$_mano_pol" = bindfs_shared ] && return 0
  for _mano_pid in $(app_ns_pids_only "$_mano_u"); do
    ns_background_generation_current "$_mano_gen" || return 75
    ns_bind_pid "$_mano_pid" "$_mano_src" "$_mano_dst" >/dev/null 2>&1 || true
  done
  return 0
}

unmount_app_ns_only() {
  _uano_gen=$1; _uano_u=$2; _uano_src=$3; _uano_dst=$4; _uano_pol=${5:-preserve}
  [ "$_uano_pol" = bindfs_shared ] && return 0
  for _uano_pid in $(app_ns_pids_only "$_uano_u"); do
    ns_background_generation_current "$_uano_gen" || return 75
    unmount_pid_if_ours "$_uano_pid" "$_uano_src" "$_uano_dst" "$_uano_pol" >/dev/null 2>&1 || true
  done
  return 0
}

mount_active_background_sync() {
  _mabs_file=$1; _mabs_reason=${2:-background}
  [ -f "$_mabs_file" ] || return 0
  _mabs_tag="$$.$(date +%s 2>/dev/null)"
  _mabs_gen="active.$_mabs_tag.$(cat "$APPLIED_HASH" 2>/dev/null)"
  _mabs_tmp="$RUNTIME/ns_background_sync.$_mabs_tag.rows"
  cp -f "$_mabs_file" "$_mabs_tmp" 2>/dev/null || return 0
  ns_background_generation_set "$_mabs_gen" || { rm -f "$_mabs_tmp" 2>/dev/null; return 0; }
  (
    trap 'rm -f "$_mabs_tmp" 2>/dev/null || true' EXIT INT TERM
    sleep 0.2
    ns_background_generation_current "$_mabs_gen" || exit 0
    _mabs_scope=$(reason_user_scope "$_mabs_reason" 2>/dev/null || true)
    logi "背景同步 App namespace 啟動｜原因=$_mabs_reason｜scope=${_mabs_scope:-all}｜generation=$_mabs_gen"
    while IFS='|' read -r _mabs_n _mabs_u _mabs_s _mabs_t _mabs_l _mabs_v _mabs_e _mabs_g _mabs_pv _mabs_pol _mabs_create _mabs_migrate; do
      [ -n "$_mabs_l" ] || continue
      row_scope_match "$_mabs_scope" "$_mabs_u" || continue
      ns_background_generation_current "$_mabs_gen" || { logi "背景同步 App namespace 已取消：generation 過期｜原因=$_mabs_reason"; exit 0; }
      mount_app_ns_only "$_mabs_gen" "$_mabs_u" "$_mabs_s" "$_mabs_l" "$_mabs_pol" >/dev/null 2>&1 || true
    done < "$_mabs_tmp"
    ns_background_generation_current "$_mabs_gen" && logi "背景同步 App namespace 完成｜原因=$_mabs_reason｜scope=${_mabs_scope:-all}｜generation=$_mabs_gen"
  ) >/dev/null 2>&1 &
  return 0
}

policy_apply() {
  _src=$1; _pol=$2
  _uid=$(stat -c '%u' "$_src" 2>/dev/null); _gid=$(stat -c '%g' "$_src" 2>/dev/null); _mode=$(stat -c '%a' "$_src" 2>/dev/null); _ctx=$(ls -Zd "$_src" 2>/dev/null | awk '{print $1}')
  logi "來源權限稽核｜$_src｜uid=$_uid gid=$_gid mode=$_mode context=${_ctx:-unknown}｜policy=$_pol"
  [ "$_pol" = media_rw ] || return 0
  [ "$_uid" = 1023 ] && [ "$_gid" = 1023 ] || chown media_rw:media_rw "$_src" 2>/dev/null || logw "來源 chown media_rw 失敗｜$_src"
  [ "$_mode" = 2770 ] || chmod 2770 "$_src" 2>/dev/null || logw "來源 chmod 2770 失敗｜$_src"
  if command -v chcon >/dev/null 2>&1 && [ "$_ctx" != u:object_r:media_rw_data_file:s0 ]; then chcon u:object_r:media_rw_data_file:s0 "$_src" 2>/dev/null || logw "來源 chcon 失敗｜$_src"; fi
}


bindfs_ready() {
  [ -x "$BINDFS" ] || { loge "bindfs_shared 不可用：缺少 $BINDFS"; return 1; }
  [ -x "$BINDFS_HELPER" ] || { loge "bindfs_shared 不可用：缺少 $BINDFS_HELPER"; return 1; }
  _mf3="$MODDIR/bin/mount.fuse3"
  _mffs="$MODDIR/bin/mount_fusefs"
  [ -x "$_mf3" ] || _mf3="$NATIVE_DIR/bin/mount.fuse3"
  [ -x "$_mffs" ] || _mffs="$NATIVE_DIR/bin/mount_fusefs"
  [ -x "$_mf3" ] || [ -x "$_mffs" ] || { loge "bindfs_shared 不可用：缺少 native mount helper：$MODDIR/bin/mount.fuse3 或 mount_fusefs"; return 1; }
  return 0
}

apply_bindfs_policy() {
  bindfs_ready || return 1
  _pt="$POLICY_TOOL"
  if [ -z "$_pt" ]; then
    for _cand in "$MODDIR/bin/magiskpolicy" "$NATIVE_DIR/bin/magiskpolicy" /data/adb/magisk/magiskpolicy /data/adb/ksu/bin/magiskpolicy /data/adb/ap/bin/magiskpolicy /sbin/magiskpolicy /debug_ramdisk/magiskpolicy; do
      [ -x "$_cand" ] && { _pt="$_cand"; break; }
    done
  fi
  _bpm_key="version=$MODULE_VERSION tool=${_pt:-none} policy=$(ls -l "$POLICY_FILE" 2>/dev/null | awk '{print $5":"$6":"$7":"$8}')"
  if [ -f "$BIND_POLICY_MARK" ] && grep -Fqx "$_bpm_key" "$BIND_POLICY_MARK" 2>/dev/null; then
    return 0
  fi
  if [ -x "$_pt" ] && [ -f "$POLICY_FILE" ]; then
    if getenforce 2>/dev/null | grep -q '^Enforcing'; then
      _bpm_fail=0
      while IFS= read -r _bpr || [ -n "$_bpr" ]; do
        case "$_bpr" in ''|'#'*) continue;; esac
        "$_pt" --live "$_bpr" >/dev/null 2>&1 || { logw "bindfs_shared live sepolicy 套用失敗｜$_bpr"; _bpm_fail=$((_bpm_fail+1)); }
      done < "$POLICY_FILE"
      [ "$_bpm_fail" -eq 0 ] && logi "bindfs_shared live sepolicy 已套用｜tool=$_pt｜policy=$POLICY_FILE" || logw "bindfs_shared live sepolicy 部分套用失敗｜fail=$_bpm_fail"
    fi
    printf '%s\n' "$_bpm_key" > "$BIND_POLICY_MARK.tmp.$$" 2>/dev/null && mv -f "$BIND_POLICY_MARK.tmp.$$" "$BIND_POLICY_MARK" 2>/dev/null || true
  else
    rm -f "$BIND_POLICY_MARK" 2>/dev/null || true
    logw "bindfs_shared 找不到可用官方 magiskpolicy 或主動啟用的 sepolicy.rule；將直接嘗試 bindfs 並輸出 stderr。若 mount /dev/fuse 被 SELinux 擋下，請打包官方 magiskpolicy 與審核後的 sepolicy.rule"
  fi
  return 0
}

media_uid_for_bindfs() {
  _bf_u=$1
  _bf_pkg=$(package_media 2>/dev/null || true)
  _bf_uid=''
  [ -n "$_bf_pkg" ] && _bf_uid=$(pkg_uid_user "$_bf_u" "$_bf_pkg" 2>/dev/null || true)
  case "$_bf_uid" in ''|*[!0-9]*) _bf_uid=$((_bf_u*100000+10513));; esac
  printf '%s\n' "$_bf_uid"
}

bindfs_mounted_pid() {
  _bf_pid=$1; _bf_dst=$2
  [ -e "/proc/$_bf_pid/ns/mnt" ] || return 1
  nsenter -t "$_bf_pid" -m -- awk -v p="$_bf_dst" '$2==p && ($3 ~ /^fuse/ || $1 ~ /bindfs/ || $1=="bindfs_shared"){f=1} END{exit f?0:1}' /proc/mounts 2>/dev/null
}

bindfs_mounted_ns1() {
  awk -v p="$1" '$2==p && ($3 ~ /^fuse/ || $1 ~ /bindfs/ || $1=="bindfs_shared"){f=1} END{exit f?0:1}' /proc/mounts 2>/dev/null || \
  ns1 awk -v p="$1" '$2==p && ($3 ~ /^fuse/ || $1 ~ /bindfs/ || $1=="bindfs_shared"){f=1} END{exit f?0:1}' /proc/mounts 2>/dev/null
}

bindfs_mounted_for_user() {
  _bmfu_u=$1; _bmfu_dst=$2
  # v1.4.55: bindfs_shared is only useful when the current MediaProvider
  # namespace for that user also has the bindfs view.  A stale init-namespace
  # bindfs mount from a previous module/session must not make user-scoped
  # retries skip remounting, otherwise User 10 file managers can see an empty
  # lower path even while active_mounts says success.
  _bmfu_mp=$(ensure_media_pid "$_bmfu_u" 2>/dev/null || true)
  if [ -n "$_bmfu_mp" ] && bindfs_mounted_pid "$_bmfu_mp" "$_bmfu_dst"; then
    return 0
  fi
  return 1
}

row_mounted() {
  _rm_u=$1; _rm_s=$2; _rm_l=$3; _rm_pol=$4
  if [ "$_rm_pol" = bindfs_shared ]; then bindfs_mounted_for_user "$_rm_u" "$_rm_l"; else same_ns1 "$_rm_s" "$_rm_l"; fi
}

target_occupied_unknown() {
  _tou_s=$1; _tou_l=$2; _tou_pol=$3
  is_mounted "$_tou_l" || return 1
  if [ "$_tou_pol" = bindfs_shared ]; then bindfs_mounted_ns1 "$_tou_l" && return 1; else same_ns1 "$_tou_s" "$_tou_l" && return 1; fi
  return 0
}

bindfs_mount_pid() {
  _bf_pid=$1; _bf_u=$2; _bf_src=$3; _bf_dst=$4
  [ -e "/proc/$_bf_pid/ns/mnt" ] || return 1
  apply_bindfs_policy || return 1
  _bf_uid=$(media_uid_for_bindfs "$_bf_u")
  nsenter -t "$_bf_pid" -m -- mkdir -p "$_bf_dst" 2>/dev/null || true
  bindfs_mounted_pid "$_bf_pid" "$_bf_dst" && return 0
  if nsenter -t "$_bf_pid" -m -- awk -v p="$_bf_dst" '$2==p{f=1} END{exit f?0:1}' /proc/mounts 2>/dev/null; then
    logw "bindfs_shared 目標已有非 bindfs 掛載，先卸載重掛｜pid=$_bf_pid｜目標=$_bf_dst｜來源=$(nsenter -t "$_bf_pid" -m -- awk -v p="$_bf_dst" '$2==p{print $1;exit}' /proc/mounts 2>/dev/null)"
    nsenter -t "$_bf_pid" -m -- umount "$_bf_dst" 2>/dev/null || nsenter -t "$_bf_pid" -m -- umount -l "$_bf_dst" 2>/dev/null || true
  fi
  _bf_err="$RUNTIME/bindfs.$_bf_pid.$$.err"
  _bf_out="$RUNTIME/bindfs.$_bf_pid.$$.out"
  BINDFS_PATH="$BINDFS" BIND_LIB_DIR="$BIND_LIB_DIR" MODDIR="$MODDIR" DATA_DIR="$DATA_DIR" nsenter -t "$_bf_pid" -m -- /system/bin/sh "$BINDFS_HELPER" "$_bf_uid" 1023 "$_bf_src" "$_bf_dst" >"$_bf_out" 2>"$_bf_err"
  _bf_rc=$?
  if [ "$_bf_rc" != 0 ]; then
    _bf_msg=$(cat "$_bf_err" "$_bf_out" 2>/dev/null | tail -n 8 | tr '\n' ' ' | cut -c1-600)
    loge "bindfs_shared 執行失敗｜pid=$_bf_pid｜uid=$_bf_uid｜rc=$_bf_rc｜dst=$_bf_dst｜stderr=${_bf_msg:-empty}"
    rm -f "$_bf_err" "$_bf_out" 2>/dev/null || true
    return 1
  fi
  if bindfs_mounted_pid "$_bf_pid" "$_bf_dst"; then
    rm -f "$_bf_err" "$_bf_out" 2>/dev/null || true
    return 0
  fi
  _bf_mt=$(nsenter -t "$_bf_pid" -m -- awk -v p="$_bf_dst" '$2==p{print;exit}' /proc/mounts 2>/dev/null)
  _bf_msg=$(cat "$_bf_err" "$_bf_out" 2>/dev/null | tail -n 8 | tr '\n' ' ' | cut -c1-600)
  loge "bindfs_shared 執行後驗證失敗｜pid=$_bf_pid｜uid=$_bf_uid｜dst=$_bf_dst｜mount=${_bf_mt:-none}｜stderr=${_bf_msg:-empty}"
  rm -f "$_bf_err" "$_bf_out" 2>/dev/null || true
  return 1
}

bindfs_all_ns() {
  _bf_u=$1; _bf_src=$2; _bf_dst=$3
  apply_bindfs_policy || return 1
  mkdir -p "$_bf_dst" 2>/dev/null || true
  _bf_uid=$(media_uid_for_bindfs "$_bf_u")
  _bf_gid=1023
  _seen=''; _ok=0
  _mp_pid=$(ensure_media_pid "$_bf_u" 2>/dev/null || true)
  if [ -z "$_mp_pid" ] && [ "$_bf_u" != 0 ]; then
    _mp_pid=$(ensure_media_pid 0 2>/dev/null || true)
  fi
  # v1.4.53 keeps the v1.4.52/custom_mount_partition_v2 strategy: mount only lower path
  # (/data/media/<user>/...) in init + MediaProvider namespaces. Do not inject
  # directly into app namespaces or /storage/emulated, because that broke User 0
  # media_rw/preserve mounts in v1.4.50/51.
  for _pid in 1 $_mp_pid; do
    case "$_pid" in ''|*[!0-9]*) continue;; esac
    [ -e "/proc/$_pid/ns/mnt" ] || continue
    _ns=$(pid_ns_id "$_pid"); [ -n "$_ns" ] || continue
    case " $_seen " in *" $_ns "*) continue;; esac; _seen="$_seen $_ns"
    if bindfs_mount_pid "$_pid" "$_bf_u" "$_bf_src" "$_bf_dst"; then
      _ok=$((_ok+1))
    fi
  done
  [ "$_ok" -gt 0 ] || return 1
  if [ -n "$_mp_pid" ] && bindfs_mounted_pid "$_mp_pid" "$_bf_dst"; then
    logi "bindfs_shared 已掛入 MediaProvider namespace｜User=$_bf_u｜pid=$_mp_pid｜目標=$_bf_dst｜uid=$_bf_uid gid=$_bf_gid｜mode=v2-static-native-helper-mediaprovider-remount"
  fi
  bindfs_mounted_ns1 "$_bf_dst" || logw "bindfs_shared 未出現在 init namespace；已按 v2 路線至少掛入 $_ok 個 namespace｜目標=$_bf_dst"
  return 0
}

mount_row_ns() {
  _mr_u=$1; _mr_src=$2; _mr_dst=$3; _mr_pol=$4
  if [ "$_mr_pol" = bindfs_shared ]; then
    logi "使用 bindfs_shared 權限映射掛載｜User=$_mr_u｜$_mr_src → $_mr_dst｜mode=v2-static-native-helper-mediaprovider-remount-lower-mediaprovider"
    bindfs_all_ns "$_mr_u" "$_mr_src" "$_mr_dst"
  else
    bind_all_ns "$_mr_u" "$_mr_src" "$_mr_dst"
  fi
}

mount_row_ns_base() {
  _mrb_u=$1; _mrb_src=$2; _mrb_dst=$3; _mrb_pol=$4
  if [ "$_mrb_pol" = bindfs_shared ]; then
    logi "使用 bindfs_shared 權限映射掛載｜User=$_mrb_u｜$_mrb_src → $_mrb_dst｜mode=v2-static-native-helper-mediaprovider-remount-lower-mediaprovider"
    bindfs_all_ns "$_mrb_u" "$_mrb_src" "$_mrb_dst"
  else
    bind_all_ns_base "$_mrb_u" "$_mrb_src" "$_mrb_dst"
  fi
}

pid_ns_id() { readlink "/proc/$1/ns/mnt" 2>/dev/null; }
ns_bind_pid() {
  _pid=$1; _src=$2; _dst=$3
  [ -e "/proc/$_pid/ns/mnt" ] || return 1
  nsenter -t "$_pid" -m -- mkdir -p "$_dst" 2>/dev/null || true
  _ss=$(nsenter -t "$_pid" -m -- stat -c '%d:%i' "$_src" 2>/dev/null); _ds=$(nsenter -t "$_pid" -m -- stat -c '%d:%i' "$_dst" 2>/dev/null)
  [ -n "$_ss" ] && [ "$_ss" = "$_ds" ] && return 0
  nsenter -t "$_pid" -m -- mount --bind "$_src" "$_dst" 2>/dev/null || return 1
  _ds=$(nsenter -t "$_pid" -m -- stat -c '%d:%i' "$_dst" 2>/dev/null)
  [ -n "$_ss" ] && [ "$_ss" = "$_ds" ]
}

bind_all_ns() {
  _u=$1; _src=$2; _dst=$3
  mkdir -p "$_dst" 2>/dev/null || true
  _seen=''; _ok=0
  for _pid in $(core_ns_pids "$_u"); do
    case "$_pid" in ''|*[!0-9]*) continue;; esac
    _ns=$(pid_ns_id "$_pid"); [ -n "$_ns" ] || continue
    case " $_seen " in *" $_ns "*) continue;; esac; _seen="$_seen $_ns"
    if ns_available; then ns_bind_pid "$_pid" "$_src" "$_dst" && _ok=$((_ok+1)); else [ "$_pid" = 1 ] && { mount --bind "$_src" "$_dst" 2>/dev/null && _ok=$((_ok+1)); }; fi
  done
  [ "$_ok" -gt 0 ] || return 1
  same_ns1 "$_src" "$_dst"
}

bind_all_ns_base() {
  _u=$1; _src=$2; _dst=$3
  mkdir -p "$_dst" 2>/dev/null || true
  _seen=''; _ok=0
  for _pid in $(core_ns_pids_base "$_u"); do
    case "$_pid" in ''|*[!0-9]*) continue;; esac
    _ns=$(pid_ns_id "$_pid"); [ -n "$_ns" ] || continue
    case " $_seen " in *" $_ns "*) continue;; esac; _seen="$_seen $_ns"
    if ns_available; then ns_bind_pid "$_pid" "$_src" "$_dst" && _ok=$((_ok+1)); else [ "$_pid" = 1 ] && { mount --bind "$_src" "$_dst" 2>/dev/null && _ok=$((_ok+1)); }; fi
  done
  [ "$_ok" -gt 0 ] || return 1
  same_ns1 "$_src" "$_dst"
}

profile_ns_background_sync() {
  _pbs_old=$1; _pbs_new=$2; _pbs_gen=$3
  [ -n "$_pbs_gen" ] || return 0
  _pbs_tag="$$.$(date +%s 2>/dev/null)"
  _pbs_old_copy="$RUNTIME/profile.ns.old.$_pbs_tag.rows"
  _pbs_new_copy="$RUNTIME/profile.ns.new.$_pbs_tag.rows"
  : > "$_pbs_old_copy" 2>/dev/null || return 0
  : > "$_pbs_new_copy" 2>/dev/null || { rm -f "$_pbs_old_copy" 2>/dev/null; return 0; }
  [ -f "$_pbs_old" ] && cp -f "$_pbs_old" "$_pbs_old_copy" 2>/dev/null || true
  [ -f "$_pbs_new" ] && cp -f "$_pbs_new" "$_pbs_new_copy" 2>/dev/null || true
  (
    trap 'rm -f "$_pbs_old_copy" "$_pbs_new_copy" 2>/dev/null || true' EXIT INT TERM
    ns_background_generation_current "$_pbs_gen" || exit 0
    logi "Profile App namespace 背景同步啟動｜generation=$_pbs_gen"
    while IFS='|' read -r _bn _bu _bs _bt _bl _bv _be _bg _bpv _bpol _bc _bm; do
      [ -n "$_bl" ] || continue
      ns_background_generation_current "$_pbs_gen" || { logi "Profile App namespace 背景同步取消：generation 過期｜generation=$_pbs_gen"; exit 0; }
      unmount_app_ns_only "$_pbs_gen" "$_bu" "$_bs" "$_bl" "$_bpol" >/dev/null 2>&1 || true
    done < "$_pbs_old_copy"
    while IFS='|' read -r _bn _bu _bs _bt _bl _bv _be _bg _bpv _bpol _bc _bm; do
      [ -n "$_bl" ] || continue
      ns_background_generation_current "$_pbs_gen" || { logi "Profile App namespace 背景同步取消：generation 過期｜generation=$_pbs_gen"; exit 0; }
      mount_app_ns_only "$_pbs_gen" "$_bu" "$_bs" "$_bl" "$_bpol" >/dev/null 2>&1 || true
    done < "$_pbs_new_copy"
    ns_background_generation_current "$_pbs_gen" && logi "Profile App namespace 背景同步完成｜generation=$_pbs_gen"
  ) >/dev/null 2>&1 &
  return 0
}


mounttx_profile_switch() {
  _mtx_old=$1; _mtx_new=$2; _mtx_gen=$3; _mtx_tag=$4
  [ -x "$MOUNTTX" ] || return 127
  "$MOUNTTX" profile-switch \
    --old "$_mtx_old" \
    --new "$_mtx_new" \
    --runtime "$RUNTIME" \
    --moddir "$MODDIR" \
    --data-dir "$DATA_DIR" \
    --log "$LOG" \
    --generation-file "$NS_BG_GEN" \
    --generation "$_mtx_gen" \
    --tag "$_mtx_tag" \
    --timeout-ms 9000
}

profile_rows_has_bindfs() {
  _prhb_file=$1
  [ -f "$_prhb_file" ] || return 1
  awk -F'|' '$10=="bindfs_shared"{found=1} END{exit found?0:1}' "$_prhb_file" 2>/dev/null
}

profile_native_preflight_rows() {
  _pnpr_file=$1
  [ -f "$_pnpr_file" ] || return 0
  while IFS='|' read -r _pnpr_n _pnpr_u _pnpr_s _pnpr_t _pnpr_l _pnpr_v _pnpr_e _pnpr_g _pnpr_pv _pnpr_pol _pnpr_create _pnpr_migrate; do
    [ -n "$_pnpr_l" ] || continue
    if [ "$_pnpr_pol" = bindfs_shared ]; then
      bindfs_ready || return 1
      apply_bindfs_policy || return 1
      ensure_media_pid "$_pnpr_u" >/dev/null 2>&1 || logw "Profile native bindfs_shared 尚未鎖定 MediaProvider，mounttx 將自行搜尋｜User=$_pnpr_u｜名稱=$_pnpr_n"
    fi
  done < "$_pnpr_file"
  return 0
}

profile_rollback_rows() {
  _prr_new=$1; _prr_old=$2; _prr_tag=$3; _prr_reason=${4:-switch_failed}
  # Invalidate every older namespace worker before rollback touches mounts.
  ns_background_generation_set "rollback.$_prr_tag" >/dev/null 2>&1 || true
  logw "Profile rollback 開始｜原因=$_prr_reason｜tag=$_prr_tag"
  if [ -f "$_prr_new" ]; then
    while IFS='|' read -r _prr_n _prr_u _prr_s _prr_t _prr_l _prr_v _prr_e _prr_g _prr_pv _prr_pol _prr_c _prr_m; do
      [ -n "$_prr_l" ] || continue
      # Bounded foreground rollback: only core namespaces.  Never scan every app
      # namespace here, because v1.4.71 repro shows that full namespace rollback
      # can hang and leave the visible target unmounted.
      unmount_all_ns_base "$_prr_u" "$_prr_s" "$_prr_l" "$_prr_pol" >/dev/null 2>&1 || true
    done < "$_prr_new"
  fi
  _prr_fail=0
  if [ -f "$_prr_old" ]; then
    while IFS='|' read -r _prr_n _prr_u _prr_s _prr_t _prr_l _prr_v _prr_e _prr_g _prr_pv _prr_pol _prr_c _prr_m; do
      [ -n "$_prr_l" ] || continue
      _prr_try=0; _prr_ok=0
      while [ "$_prr_try" -lt 4 ]; do
        mount_row_ns_base "$_prr_u" "$_prr_s" "$_prr_l" "$_prr_pol" >/dev/null 2>&1 || true
        if row_mounted "$_prr_u" "$_prr_s" "$_prr_l" "$_prr_pol"; then
          if [ -z "$_prr_v" ] || visible_probe_retry "$_prr_u" "$_prr_s" "$_prr_v" "rollback:$_prr_n"; then _prr_ok=1; break; fi
        fi
        _prr_try=$((_prr_try+1))
        sleep 0.18
      done
      if [ "$_prr_ok" -ne 1 ]; then
        loge "Profile rollback 無法恢復舊掛載｜原因=$_prr_reason｜名稱=$_prr_n｜$_prr_s → $_prr_t"
        _prr_fail=$((_prr_fail+1))
      else
        logi "Profile rollback 已驗證舊掛載｜原因=$_prr_reason｜名稱=$_prr_n｜$_prr_s → $_prr_t"
      fi
    done < "$_prr_old"
  fi
  [ "$_prr_fail" -eq 0 ] && logi "Profile rollback 完成｜原因=$_prr_reason｜tag=$_prr_tag" || loge "Profile rollback 完成但仍有失敗｜原因=$_prr_reason｜fail=$_prr_fail｜tag=$_prr_tag"
  [ "$_prr_fail" -eq 0 ]
}


media_scan_visible_path() {
  # Print a canonical /storage/emulated/<user>/... path if this mount target is
  # worth notifying MediaStore about. Keep it conservative: media/share-facing
  # public directories only, so large backup roots are not scanned on every apply.
  _msv_u=$1; _msv_p=$2
  case "$_msv_p" in
    /storage/emulated/$_msv_u/*)
      _msv_rel=${_msv_p#/storage/emulated/$_msv_u/}
      _msv_out=$_msv_p
      ;;
    /data/media/$_msv_u/*)
      _msv_rel=${_msv_p#/data/media/$_msv_u/}
      _msv_out="/storage/emulated/$_msv_u/$_msv_rel"
      ;;
    *) return 1 ;;
  esac
  case "$_msv_rel" in
    DCIM|DCIM/*|Pictures|Pictures/*|Movies|Movies/*|Music|Music/*|Download|Download/*)
      printf '%s\n' "$_msv_out"; return 0 ;;
  esac
  return 1
}

media_scan_broadcast() {
  _msb_u=$1; _msb_path=$2; _msb_reason=${3:-mount}
  case "$_msb_u" in ''|*[!0-9]*) return 2;; esac
  valid_safe_abs "$_msb_path" || return 2
  [ -e "$_msb_path" ] || { logw "媒體掃描廣播略過：路徑不存在｜User=$_msb_u｜路徑=$_msb_path｜原因=$_msb_reason"; return 1; }
  if command -v am >/dev/null 2>&1; then
    am broadcast --user "$_msb_u" -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$_msb_path" >/dev/null 2>&1 \
      || am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$_msb_path" >/dev/null 2>&1
    _msb_rc=$?
    if [ "$_msb_rc" -eq 0 ]; then
      logi "已通知媒體掃描｜User=$_msb_u｜路徑=$_msb_path｜原因=$_msb_reason"
      return 0
    fi
    logw "媒體掃描廣播失敗｜User=$_msb_u｜路徑=$_msb_path｜原因=$_msb_reason｜rc=$_msb_rc"
    return "$_msb_rc"
  fi
  logw "媒體掃描廣播失敗：am 指令不存在｜User=$_msb_u｜路徑=$_msb_path｜原因=$_msb_reason"
  return 127
}

media_scan_schedule_path() {
  _mss_u=$1; _mss_path=$2; _mss_reason=${3:-mount}; _mss_delay=${4:-1}
  case "$_mss_u" in ''|*[!0-9]*) return 0;; esac
  valid_safe_abs "$_mss_path" || return 0
  logi "媒體掃描廣播已排程｜User=$_mss_u｜路徑=$_mss_path｜原因=$_mss_reason｜delay=${_mss_delay}s"
  (
    sleep "$_mss_delay"
    MODDIR="$MODDIR" sh "$MODDIR/mount.sh" media_scan_now "$_mss_u" "$_mss_path" "$_mss_reason"
  ) >/dev/null 2>&1 &
  return 0
}

media_scan_schedule_visible() {
  _mssv_u=$1; _mssv_visible=$2; _mssv_reason=${3:-mount}
  _mssv_path=$(media_scan_visible_path "$_mssv_u" "$_mssv_visible" 2>/dev/null || true)
  [ -n "$_mssv_path" ] || return 0
  media_scan_schedule_path "$_mssv_u" "$_mssv_path" "$_mssv_reason" 1
}

media_scan_schedule_user_root_if_media_active() {
  _msr_u=$1; _msr_reason=${2:-initial}
  case "$_msr_u" in ''|*[!0-9]*) return 0;; esac
  [ -f "$ACTIVE" ] || return 0
  _msr_has=0
  while IFS='|' read -r _msr_n _msr_ru _msr_s _msr_t _msr_l _msr_v _msr_e _msr_g _msr_pv _msr_pol _msr_create _msr_migrate; do
    [ "$_msr_ru" = "$_msr_u" ] || continue
    media_scan_visible_path "$_msr_u" "$_msr_v" >/dev/null 2>&1 && { _msr_has=1; break; }
  done < "$ACTIVE"
  [ "$_msr_has" -eq 1 ] || return 0
  media_scan_schedule_path "$_msr_u" "/storage/emulated/$_msr_u" "$_msr_reason" 1
}

media_scan_schedule_initial_roots() {
  _msir_reason=${1:-initial}
  [ -f "$ACTIVE" ] || return 0
  cut -d'|' -f2 "$ACTIVE" 2>/dev/null | awk 'NF&&!seen[$0]++{print}' | while IFS= read -r _msir_u; do
    media_scan_schedule_user_root_if_media_active "$_msir_u" "$_msir_reason"
  done
}

visible_probe() {
  _u=$1; _src=$2; _vis=$3; [ -n "$_vis" ] || return 0
  _seq=".$$.$(date +%s 2>/dev/null).$RANDOM"; _probe="$_src/.yawasau_probe$_seq"
  : > "$_probe" 2>/dev/null || { [ -d "$_vis" ] && return 0; return 1; }
  _base=${_probe##*/}; _rel=${_vis%/}/$_base
  if [ -e "$_rel" ]; then rm -f "$_probe"; return 0; fi
  _pid=$(ensure_media_pid "$_u" 2>/dev/null || true)
  if [ -n "$_pid" ] && nsenter -t "$_pid" -m -- test -e "$_rel" >/dev/null 2>&1; then rm -f "$_probe"; return 0; fi
  sleep 0.12
  if [ -e "$_rel" ] || { [ -n "$_pid" ] && nsenter -t "$_pid" -m -- test -e "$_rel" >/dev/null 2>&1; }; then rm -f "$_probe"; return 0; fi
  rm -f "$_probe"; return 1
}

visible_probe_retry() {
  _vpr_u=$1; _vpr_src=$2; _vpr_vis=$3; _vpr_label=${4:-mount}
  _vpr_try=0
  for _vpr_delay in 0 0.12 0.25 0.45; do
    [ "$_vpr_delay" = 0 ] || sleep "$_vpr_delay"
    if visible_probe "$_vpr_u" "$_vpr_src" "$_vpr_vis"; then
      [ "$_vpr_try" -gt 0 ] && logi "可見性驗證重試成功｜名稱=$_vpr_label｜路徑=$_vpr_vis｜try=$_vpr_try"
      return 0
    fi
    _vpr_try=$((_vpr_try+1))
  done
  return 1
}

unmount_pid_if_ours() {
  _pid=$1; _src=$2; _dst=$3; _pol=${4:-preserve}; [ -e "/proc/$_pid/ns/mnt" ] || return 0
  if [ "$_pol" = bindfs_shared ]; then
    bindfs_mounted_pid "$_pid" "$_dst" || return 0
    nsenter -t "$_pid" -m -- umount "$_dst" 2>/dev/null || nsenter -t "$_pid" -m -- umount -l "$_dst" 2>/dev/null || true
    return 0
  fi
  _ss=$(nsenter -t "$_pid" -m -- stat -c '%d:%i' "$_src" 2>/dev/null); _ds=$(nsenter -t "$_pid" -m -- stat -c '%d:%i' "$_dst" 2>/dev/null)
  [ -n "$_ss" ] && [ "$_ss" = "$_ds" ] || return 0
  nsenter -t "$_pid" -m -- umount "$_dst" 2>/dev/null || nsenter -t "$_pid" -m -- umount -l "$_dst" 2>/dev/null || true
}
unmount_all_ns() {
  _u=$1; _src=$2; _dst=$3; _pol=${4:-preserve}; _seen=''
  for _pid in $(core_ns_pids "$_u"); do
    case "$_pid" in ''|*[!0-9]*) continue;; esac; _ns=$(pid_ns_id "$_pid"); [ -n "$_ns" ] || continue
    case " $_seen " in *" $_ns "*) continue;; esac; _seen="$_seen $_ns"
    ns_available && unmount_pid_if_ours "$_pid" "$_src" "$_dst" "$_pol"
  done
  if [ "$_pol" = bindfs_shared ]; then
    bindfs_mounted_ns1 "$_dst" && ns1 umount "$_dst" 2>/dev/null || ns1 umount -l "$_dst" 2>/dev/null || true
  else
    if same_ns1 "$_src" "$_dst"; then ns1 umount "$_dst" 2>/dev/null || ns1 umount -l "$_dst" 2>/dev/null || true; fi
  fi
}

unmount_all_ns_base() {
  _u=$1; _src=$2; _dst=$3; _pol=${4:-preserve}; _seen=''
  for _pid in $(core_ns_pids_base "$_u"); do
    case "$_pid" in ''|*[!0-9]*) continue;; esac; _ns=$(pid_ns_id "$_pid"); [ -n "$_ns" ] || continue
    case " $_seen " in *" $_ns "*) continue;; esac; _seen="$_seen $_ns"
    ns_available && unmount_pid_if_ours "$_pid" "$_src" "$_dst" "$_pol"
  done
  if [ "$_pol" = bindfs_shared ]; then
    bindfs_mounted_ns1 "$_dst" && ns1 umount "$_dst" 2>/dev/null || ns1 umount -l "$_dst" 2>/dev/null || true
  else
    if same_ns1 "$_src" "$_dst"; then ns1 umount "$_dst" 2>/dev/null || ns1 umount -l "$_dst" 2>/dev/null || true; fi
  fi
}


ensure_dir_policy() {
  _p=$1; _pol=$2
  mkdir -p "$_p" 2>/dev/null || { loge "建立準備目錄失敗｜$_p"; return 1; }
  policy_apply "$_p" "$_pol"
}

ensure_source_dir() {
  _src=$1; _create=$2; _pol=$3
  if [ ! -d "$_src" ]; then
    [ "$_create" = 1 ] || return 1
    mkdir -p "$_src" 2>/dev/null || return 1
    logi "已依 mount.conf 建立來源目錄｜$_src"
  fi
  policy_apply "$_src" "$_pol"
  return 0
}

migrate_once() {
  _u=$1; _src=$2; _lower=$3; _mode=$4
  [ "$_mode" = once ] || return 0
  [ "$_src" != "$_lower" ] || return 0
  _id=$(printf '%s' "$_u|$_lower" | cksum 2>/dev/null | awk '{print $1}')
  [ -n "$_id" ] || _id=$(printf '%s' "$_u$_lower" | wc -c | tr -d ' ')
  _marker="$RUNTIME/migrated.$_id"
  [ -f "$_marker" ] && return 0
  mkdir -p "$_src" "$_lower" 2>/dev/null || return 1
  # Never migrate from a path that is already a mountpoint; that could copy another mounted source.
  if is_mounted "$_lower"; then
    logw "首次搬移略過：目標已是掛載點｜$_lower"
    : > "$_marker" 2>/dev/null || true
    return 0
  fi
  _has=$(find "$_lower" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)
  if [ -z "$_has" ]; then : > "$_marker" 2>/dev/null || true; return 0; fi
  logi "開始一次性搬移既有內容｜$_lower → $_src"
  _list="$RUNTIME/migrate.$$.list"; _mfail=0
  find "$_lower" -mindepth 1 -maxdepth 1 2>/dev/null > "$_list"
  while IFS= read -r _item; do
    [ -n "$_item" ] || continue
    _bn=${_item##*/}
    if [ -e "$_src/$_bn" ]; then
      logw "搬移同名衝突，保留來源目標兩邊既有項目｜$_bn"
      continue
    fi
    mv "$_item" "$_src/" 2>/dev/null || { logw "搬移失敗，保留待下次重試｜$_item"; _mfail=1; }
  done < "$_list"
  rm -f "$_list" 2>/dev/null
  if [ "$_mfail" -ne 0 ]; then return 1; fi
  : > "$_marker" 2>/dev/null || true
  logi "一次性搬移完成｜$_lower → $_src"
  return 0
}

lock_owner_pid() { cat "$LOCKDIR/pid" 2>/dev/null; }
lock_acquire() {
  _la_i=0
  _la_missing=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    _la_pid=$(lock_owner_pid)
    case "$_la_pid" in
      ''|*[!0-9]*)
        # mkdir -> pid write has a real (small) window. Never treat a fresh
        # owner-less directory as stale immediately; that was the v1.2.6 race.
        _la_missing=$((_la_missing+1))
        if [ "$_la_missing" -lt 10 ]; then
          sleep 0.05
          _la_i=$((_la_i+1)); [ "$_la_i" -lt 120 ] && continue
          return 1
        fi
        # Missing owner for >= ~0.5 s: only now consider it stale. Re-check
        # immediately before removal so a late owner publication wins.
        _la_pid=$(lock_owner_pid)
        case "$_la_pid" in
          ''|*[!0-9]*) rm -rf "$LOCKDIR" 2>/dev/null ;;
          *) _la_missing=0; continue ;;
        esac
        ;;
      *)
        _la_missing=0
        if [ -d "/proc/$_la_pid" ]; then
          sleep 0.05
          _la_i=$((_la_i+1)); [ "$_la_i" -lt 120 ] && continue
          return 1
        fi
        # Dead owner: stale lock.
        rm -rf "$LOCKDIR" 2>/dev/null
        ;;
    esac
    _la_i=$((_la_i+1)); [ "$_la_i" -lt 120 ] || return 1
  done

  # Publish ownership. If the write fails, never leave an owner-less lock.
  _la_tmp="$LOCKDIR/pid.tmp.$$"
  if ! printf '%s\n' $$ > "$_la_tmp" 2>/dev/null || ! mv -f "$_la_tmp" "$LOCKDIR/pid" 2>/dev/null; then
    rm -f "$_la_tmp" 2>/dev/null
    rm -rf "$LOCKDIR" 2>/dev/null
    return 1
  fi
  return 0
}

lock_release() {
  _lr_pid=$(lock_owner_pid)
  [ "$_lr_pid" = "$$" ] && rm -rf "$LOCKDIR" 2>/dev/null || true
}

config_snapshot_make() {
  # Copy mount.conf to a private immutable transaction snapshot. Validate that
  # the source did not change while it was copied. This protects parsing from
  # atomic editor saves and from any writer that does not participate in our lock.
  _csm_dst=$1
  _csm_i=0
  while [ "$_csm_i" -lt 8 ]; do
    _csm_before=$(config_hash "$CONF" 2>/dev/null || true)
    [ -n "$_csm_before" ] || { sleep 0.03; _csm_i=$((_csm_i+1)); continue; }
    cp -f "$CONF" "$_csm_dst" 2>/dev/null || { sleep 0.03; _csm_i=$((_csm_i+1)); continue; }
    _csm_copy=$(config_hash "$_csm_dst" 2>/dev/null || true)
    _csm_after=$(config_hash "$CONF" 2>/dev/null || true)
    if [ -n "$_csm_copy" ] && [ "$_csm_before" = "$_csm_after" ] && [ "$_csm_before" = "$_csm_copy" ]; then
      printf '%s\n' "$_csm_copy"
      return 0
    fi
    sleep 0.03
    _csm_i=$((_csm_i+1))
  done
  rm -f "$_csm_dst" 2>/dev/null
  return 1
}

reason_user_scope() {
  # User-specific lifecycle/probe reasons must not be blocked by other users'
  # locked/closed storage rows. Empty output means a full/unscoped apply.
  case "$1" in
    user0_propwait|user0_filewatch) printf '0
' ;;
    user_[0-9]*_*) _rus=${1#user_}; _rus=${_rus%%_*}; case "$_rus" in ''|*[!0-9]*) ;; *) printf '%s
' "$_rus";; esac ;;
  esac
}

row_scope_match() {
  _rsm_scope=$1; _rsm_user=$2
  [ -z "$_rsm_scope" ] && return 0
  [ "$_rsm_scope" = "$_rsm_user" ]
}

apply_reload() {
  _reason=${1:-manual}
  if [ "${YAWASAU_RELOAD_LOCK_PREHELD:-0}" = 1 ]; then
    [ -f "$CONF" ] || return 2
    migrate_config_schema || return 2
  else
    seed_config || return 2
  fi

  case "$_reason" in
    config_event|config_event_retry)
      _pre_hash=$(config_hash "$CONF" 2>/dev/null || true)
      _pre_applied=$(cat "$APPLIED_HASH" 2>/dev/null)
      if [ -n "$_pre_hash" ] && [ "$_pre_hash" = "$_pre_applied" ] && parsed_cache_matches_hash "$_pre_hash"; then
        config_state_write valid 0 "duplicate_$_reason" "$_pre_hash" >/dev/null 2>&1 || true
        return 0
      fi
      ;;
  esac

  if [ "${YAWASAU_RELOAD_LOCK_PREHELD:-0}" = 1 ]; then
    _owner=$(cat "$LOCKDIR/pid" 2>/dev/null)
    [ "$_owner" = "$$" ] || { loge "Profile 交易鎖擁有者不一致"; return 4; }
  else
    lock_acquire || { loge "取得重新套用鎖超時"; return 4; }
  fi

  _parsed_saved=$PARSED
  _txn_cfg="$RUNTIME/config.txn.$$"
  _txn_parsed="$RUNTIME/parsed.txn.$$"
  trap 'rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null; PARSED="$_parsed_saved"; lock_release' EXIT INT TERM

  _cfg_hash=$(config_snapshot_make "$_txn_cfg") || {
    loge "建立 mount.conf 穩定快照失敗，保留目前掛載｜原因=$_reason"
    rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
    PARSED="$_parsed_saved"; lock_release; trap - EXIT INT TERM
    return 3
  }

  case "$_reason" in
    config_event|config_event_retry)
      _applied_after_lock=$(cat "$APPLIED_HASH" 2>/dev/null)
      if [ -n "$_cfg_hash" ] && [ "$_cfg_hash" = "$_applied_after_lock" ]; then
        # The live config is already the last applied config. However an earlier
        # failed preflight from v1.3.0 could have polluted runtime/parsed with an
        # invalid candidate. Repair the parsed cache from this stable snapshot
        # before declaring the event duplicate, so WebUI and module.prop return
        # to the real last-good state immediately.
        if ! parsed_cache_matches_hash "$_cfg_hash"; then
          rm -rf "$_txn_parsed" 2>/dev/null
          if parse_config "$_txn_cfg" "$_txn_parsed" >/dev/null 2>&1; then
            parsed_publish_dir "$_txn_parsed" "$_cfg_hash" >/dev/null 2>&1 || true
          fi
        fi
        config_state_write valid 0 "duplicate_$_reason" "$_cfg_hash" >/dev/null 2>&1 || true
        rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
        PARSED="$_parsed_saved"; lock_release; trap - EXIT INT TERM
        return 0
      fi
      ;;
  esac

  rm -rf "$_txn_parsed" 2>/dev/null
  _parse_ok=0
  if parse_config "$_txn_cfg" "$_txn_parsed"; then
    _parse_ok=1
  else
    # v1.4.77: retry every reload reason, not only confwatch/profile.
    # Manual/WebUI apply can hit the same editor partial-write window, and a
    # single invalid manual snapshot should not poison config.state until the
    # live file has been re-sampled after a short settle.
    _pri=1
    for _psleep in 0.20 0.45 0.80; do
      logw "mount.conf 解析失敗，可能仍在寫入中，稍後重試｜原因=$_reason｜retry=$_pri"
      sleep "$_psleep"
      rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
      _cfg_hash=$(config_snapshot_make "$_txn_cfg" 2>/dev/null || true)
      if [ -n "$_cfg_hash" ] && parse_config "$_txn_cfg" "$_txn_parsed"; then
        _parse_ok=1
        logi "mount.conf 重試解析成功｜原因=$_reason｜retry=$_pri"
        break
      fi
      _pri=$((_pri+1))
    done
  fi
  if [ "$_parse_ok" -ne 1 ]; then
    # Full bind-row validation failed. Still try the root-only parser so a valid
    # block device/mount_point is mounted at boot and remains usable for debugging.
    _root_only="$RUNTIME/parsed.rootonly.$$"
    rm -rf "$_root_only" 2>/dev/null
    if parse_global_config "$_txn_cfg" "$_root_only" >/dev/null 2>&1; then
      _po_saved=$PARSED; PARSED="$_root_only"
      if mount_root_ensure >/dev/null 2>&1; then
        # Keep the last-good full parsed cache when a new mount.conf is invalid.
        # Publishing root-only parsed here makes WebUI/notifications lose the old
        # 6/6 mount rows even though active_mounts is intentionally preserved.
        logw "mount.conf 掛載項驗證失敗，但主分區 global 設定有效，已先掛載主分區｜原因=$_reason"
      else
        _porc=$?
        logw "mount.conf 掛載項驗證失敗；global 有效但主分區掛載也失敗｜原因=$_reason｜rc=$_porc"
      fi
      PARSED="$_po_saved"
    fi
    rm -rf "$_root_only" 2>/dev/null
    config_state_write invalid 3 "$_reason" "$_cfg_hash" >/dev/null 2>&1 || true
    loge "設定熱更新失敗：穩定快照語法/驗證未通過，保留目前掛載｜原因=$_reason"
    rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
    PARSED="$_parsed_saved"; lock_release; trap - EXIT INT TERM
    return 3
  fi

  PARSED="$_txn_parsed"

  _applied_hash=$(cat "$APPLIED_HASH" 2>/dev/null)
  case "$_reason" in
    config_event|config_event_retry|profile_change)
      if [ -n "$_cfg_hash" ] && [ "$_cfg_hash" = "$_applied_hash" ]; then
        parsed_publish_dir "$_txn_parsed" "$_cfg_hash" >/dev/null 2>&1 || true
        config_state_write valid 0 "duplicate_$_reason" "$_cfg_hash" >/dev/null 2>&1 || true
        rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
        PARSED="$_parsed_saved"; lock_release; trap - EXIT INT TERM
        return 0
      fi
      ;;
  esac

  _newglobal=$(cat "$PARSED/global" 2>/dev/null); _oldglobal=$(cat "$GLOBAL_ACTIVE" 2>/dev/null)

  _root_ok=0
  if [ -n "$_oldglobal" ] && [ "$_oldglobal" = "$_newglobal" ]; then
    _same_mp=$(cfg_get mount_point); _same_dev=$(resolve_device 2>/dev/null || true)
    if [ -n "$_same_dev" ] && is_mounted "$_same_mp"; then
      _same_cur=$(realp "$(mount_src "$_same_mp")"); _same_want=$(realp "$_same_dev"); _same_fs=$(mount_fs "$_same_mp")
      case "$_same_fs" in f2fs|ext4) [ "$_same_cur" = "$_same_want" ] && _root_ok=1;; esac
    fi
  fi

  if [ "$_root_ok" -ne 1 ]; then
    global_preflight || {
      _rc=$?
      config_state_write invalid "$_rc" "$_reason" "$_cfg_hash" >/dev/null 2>&1 || true
      loge "設定熱更新預檢失敗，保留目前掛載｜原因=$_reason｜rc=$_rc"
      rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
      PARSED="$_parsed_saved"; lock_release; trap - EXIT INT TERM
      return "$_rc"
    }
    if [ -n "$_oldglobal" ] && [ "$_oldglobal" != "$_newglobal" ]; then
      logw "主分區設定已變更，先卸載既有映射再切換裝置/掛載點"
      unmount_active_all
      _oldmp=$(printf '%s\n' "$_oldglobal" | sed -n 's/^mount_point=//p')
      _oldpart=$(printf '%s\n' "$_oldglobal" | sed -n 's/^partition=//p')
      _olddev=$(resolve_partition_name "$_oldpart" 2>/dev/null || true)
      if [ -n "$_oldmp" ] && is_mounted "$_oldmp"; then
        _curdev=$(realp "$(mount_src "$_oldmp")")
        _expect=''; [ -n "$_olddev" ] && _expect=$(realp "$_olddev")
        if [ -n "$_expect" ] && [ "$_curdev" = "$_expect" ]; then
          ns1 umount "$_oldmp" 2>/dev/null || ns1 umount -l "$_oldmp" 2>/dev/null || true
        else
          loge "拒絕卸載已被其他來源取代或已無法確認來源的舊主掛載點｜$_oldmp｜目前來源=$_curdev｜舊分區=$_oldpart"
          config_state_write invalid 25 "$_reason" "$_cfg_hash" >/dev/null 2>&1 || true
          rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
          PARSED="$_parsed_saved"; lock_release; trap - EXIT INT TERM
          return 25
        fi
      fi
    fi
    mount_root_ensure || {
      _rc=$?
      config_state_write invalid "$_rc" "$_reason" "$_cfg_hash" >/dev/null 2>&1 || true
      rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
      PARSED="$_parsed_saved"; lock_release; trap - EXIT INT TERM
      return "$_rc"
    }
  fi

  case "$_reason" in
    profile_change) ;;
    *)
      if [ -f "$PARSED/dirs" ]; then
        while IFS='|' read -r _dp _dpol; do
          [ -n "$_dp" ] || continue
          ensure_dir_policy "$_dp" "$_dpol" || {
            config_state_write invalid 26 "$_reason" "$_cfg_hash" >/dev/null 2>&1 || true
            rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
            PARSED="$_parsed_saved"; lock_release; trap - EXIT INT TERM
            return 26
          }
        done < "$PARSED/dirs"
      fi
      ;;
  esac

  _apply_scope=$(reason_user_scope "$_reason")
  if ! preflight_desired_mounts "$PARSED/mounts.desired" "$_apply_scope"; then
    _rc=27
    config_state_write invalid "$_rc" "$_reason" "$_cfg_hash" >/dev/null 2>&1 || true
    loge "設定熱更新預檢失敗，未卸載既有掛載｜原因=$_reason｜rc=$_rc"
    rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
    PARSED="$_parsed_saved"; lock_release; trap - EXIT INT TERM
    return "$_rc"
  fi

  # Fence any older background namespace worker before this transaction can
  # unmount or replace a target.  Older workers are best-effort only and must
  # never outlive a newer foreground mount decision.
  ns_background_generation_set "applytxn.$$.$_cfg_hash" >/dev/null 2>&1 || true

  printf '%s
' "$_newglobal" > "$GLOBAL_ACTIVE.tmp.$$"; mv -f "$GLOBAL_ACTIVE.tmp.$$" "$GLOBAL_ACTIVE"
  _next="$ACTIVE.next.$$"; : > "$_next"; _fail=0; _defer=0

  # For a user-scoped event, keep other users' last-good active mappings as-is.
  # A User 0 unlock retry must never be blocked by User 10 / Private Space rows,
  # and vice versa.
  if [ -n "$_apply_scope" ] && [ -f "$ACTIVE" ]; then
    while IFS='|' read -r _an _au _as _at _al _av _ae _ag _apv _apol _acreate _amigrate; do
      [ -n "$_al" ] || continue
      if [ "$_au" != "$_apply_scope" ]; then
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s
' "$_an" "$_au" "$_as" "$_at" "$_al" "$_av" "$_ae" "$_ag" "$_apv" "$_apol" "$_acreate" "$_amigrate" >> "$_next"
      fi
    done < "$ACTIVE"
  fi

  if [ -f "$ACTIVE" ]; then
    while IFS='|' read -r _n _u _s _t _l _v _e _g _pv _pol _create _migrate; do
      [ -n "$_l" ] || continue
      row_scope_match "$_apply_scope" "$_u" || continue
      _match=$(awk -F'|' -v u="$_u" -v l="$_l" '$2==u&&$5==l{print;exit}' "$PARSED/mounts.desired")
      _ms=$(printf '%s
' "$_match" | awk -F'|' '{print $3}')
      _mpol=$(printf '%s
' "$_match" | awk -F'|' '{print $10}')
      if [ -z "$_match" ] || [ "$_ms" != "$_s" ] || [ "$_mpol" != "$_pol" ]; then
        logi "卸載已刪除/變更項目｜名稱=$_n｜User=$_u｜目標=$_t｜舊策略=$_pol｜新策略=${_mpol:-none}"
        unmount_all_ns "$_u" "$_s" "$_l" "$_pol"
        restore_visible_target_after_unmount "$_u" "$_l" "$_v" "$_n" "$_reason" >/dev/null 2>&1 || true
      fi
    done < "$ACTIVE"
  fi

  restore_disabled_mount_targets_from_config "$_txn_cfg" "$_reason" >/dev/null 2>&1 || true

  while IFS='|' read -r _n _u _s _t _l _v _e _g _pv _pol _create _migrate; do
    [ -n "$_l" ] || continue
    row_scope_match "$_apply_scope" "$_u" || continue
    _row=$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$_n" "$_u" "$_s" "$_t" "$_l" "$_v" "$_e" "$_g" "$_pv" "$_pol" "$_create" "$_migrate")
    if [ -f "$ACTIVE" ] && grep -Fqx "$_row" "$ACTIVE" 2>/dev/null && row_mounted "$_u" "$_s" "$_l" "$_pol"; then
      printf '%s
' "$_row" >> "$_next"
      continue
    fi

    if [ -n "$_v" ] && ! user_storage_available "$_u"; then logi "User 儲存根目錄尚未就緒，延後掛載｜名稱=$_n｜User=$_u"; _defer=$((_defer+1)); continue; fi
    if [ "$_pol" = bindfs_shared ] && ! bindfs_ready; then loge "bindfs_shared 依賴缺失，暫不掛載｜名稱=$_n"; _fail=$((_fail+1)); continue; fi
    if ! ensure_source_dir "$_s" "$_create" "$_pol"; then logw "來源不存在且 create=0，暫不掛載｜名稱=$_n｜來源=$_s"; _fail=$((_fail+1)); continue; fi
    target_mkdir_or_defer "$_u" "$_l" "$_v" "$_n" apply
    _tm_rc=$?
    case "$_tm_rc" in
      0) ;;
      75) _defer=$((_defer+1)); continue ;;
      *) loge "建立目標失敗｜名稱=$_n｜$_l"; _fail=$((_fail+1)); continue ;;
    esac
    if target_occupied_unknown "$_s" "$_l" "$_pol"; then
      _occupied=$(mount_src "$_l")
      loge "目標已被未知來源占用，拒絕堆疊掛載｜名稱=$_n｜目標=$_l｜目前來源=${_occupied:-unknown}"
      _fail=$((_fail+1)); continue
    fi
    migrate_once "$_u" "$_s" "$_l" "$_migrate" || { logw "一次性搬移未完整成功｜名稱=$_n"; _fail=$((_fail+1)); }
    if row_mounted "$_u" "$_s" "$_l" "$_pol"; then
      _bok=1
    else
      if fast_foreground_reason "$_reason"; then
        mount_row_ns_foreground "$_u" "$_s" "$_l" "$_pol" && _bok=1 || _bok=0
      else
        mount_row_ns "$_u" "$_s" "$_l" "$_pol" && _bok=1 || _bok=0
      fi
    fi
    if [ "$_bok" = 1 ]; then
      if [ -n "$_v" ]; then
        if visible_probe "$_u" "$_s" "$_v"; then
          logi "手機儲存已可看到掛載｜名稱=$_n｜User=$_u｜路徑=$_v"
          media_scan_schedule_visible "$_u" "$_v" "$_reason" >/dev/null 2>&1 || true
          logi "掛載正常｜名稱=$_n｜User=$_u｜$_s → $_t"
        else
          logw "掛載已完成但手機儲存可見性驗證失敗｜名稱=$_n｜User=$_u｜目標=$_v"; _fail=$((_fail+1))
        fi
      else
        logi "掛載正常｜名稱=$_n｜User=$_u｜$_s → $_t"
      fi
      printf '%s
' "$_row" >> "$_next"
    else
      loge "掛載失敗｜名稱=$_n｜User=$_u｜$_s → $_t"; _fail=$((_fail+1))
    fi
  done < "$PARSED/mounts.desired"

  if [ "$_fail" -eq 0 ]; then
    mv -f "$_next" "$ACTIVE"
    parsed_publish_dir "$_txn_parsed" "$_cfg_hash" >/dev/null 2>&1 || true
    [ -n "$_cfg_hash" ] && printf '%s\n' "$_cfg_hash" > "$APPLIED_HASH.tmp.$$" 2>/dev/null && mv -f "$APPLIED_HASH.tmp.$$" "$APPLIED_HASH" 2>/dev/null
    config_state_write valid 0 "$_reason" "$_cfg_hash" "$_defer" >/dev/null 2>&1 || true
    case "$_reason" in
      boot_initial|media_apply|user*_unlocked|user0_propwait|user0_filewatch|user_*_storage_ready_retry*)
        media_scan_schedule_initial_roots "$_reason" >/dev/null 2>&1 || true
        ;;
    esac
    if fast_foreground_reason "$_reason"; then
      mount_active_background_sync "$ACTIVE" "$_reason" >/dev/null 2>&1 || true
    fi
  else
    rm -f "$_next" 2>/dev/null
    config_state_write invalid 1 "$_reason" "$_cfg_hash" "$_defer" >/dev/null 2>&1 || true
    logw "設定套用未完整成功，active_mounts 保留上一個成功狀態｜原因=$_reason｜失敗=$_fail"
  fi
  logi "設定已套用｜原因=$_reason｜失敗=$_fail｜等待解鎖=$_defer"
  rm -f "$_txn_cfg" 2>/dev/null; rm -rf "$_txn_parsed" 2>/dev/null
  PARSED="$_parsed_saved"
  lock_release; trap - EXIT INT TERM
  [ "$_fail" -eq 0 ]
}


preflight_desired_mounts() {
  # Validate every new or changed desired row before unmounting any old working
  # mapping. Locked/closed user storage is deferred, not fatal. Optional $2
  # scopes validation to one User for lifecycle retries.
  _pf_fail=0
  _pf_defer=0
  _pf_file=${1:-$PARSED/mounts.desired}
  _pf_scope=$2
  [ -f "$_pf_file" ] || return 0
  while IFS='|' read -r _pf_n _pf_u _pf_s _pf_t _pf_l _pf_v _pf_e _pf_g _pf_pv _pf_pol _pf_create _pf_migrate; do
    [ -n "$_pf_l" ] || continue
    row_scope_match "$_pf_scope" "$_pf_u" || continue
    _pf_row=$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$_pf_n" "$_pf_u" "$_pf_s" "$_pf_t" "$_pf_l" "$_pf_v" "$_pf_e" "$_pf_g" "$_pf_pv" "$_pf_pol" "$_pf_create" "$_pf_migrate")
    if [ -f "$ACTIVE" ] && grep -Fqx "$_pf_row" "$ACTIVE" 2>/dev/null && row_mounted "$_pf_u" "$_pf_s" "$_pf_l" "$_pf_pol"; then
      continue
    fi
    if [ -n "$_pf_v" ] && ! user_storage_available "$_pf_u"; then
      logi "User 儲存根目錄尚未就緒，預檢延後掛載｜名稱=$_pf_n｜User=$_pf_u"
      _pf_defer=$((_pf_defer+1))
      continue
    fi
    if [ "$_pf_pol" = bindfs_shared ] && ! bindfs_ready; then
      loge "預檢失敗：bindfs_shared 依賴缺失，保留既有掛載｜名稱=$_pf_n"
      _pf_fail=$((_pf_fail+1))
      continue
    fi
    if ! ensure_source_dir "$_pf_s" "$_pf_create" "$_pf_pol"; then
      logw "預檢失敗：來源不存在或無法建立，保留既有掛載｜名稱=$_pf_n｜來源=$_pf_s"
      _pf_fail=$((_pf_fail+1))
      continue
    fi
    target_mkdir_or_defer "$_pf_u" "$_pf_l" "$_pf_v" "$_pf_n" preflight
    _pf_mrc=$?
    case "$_pf_mrc" in
      0) ;;
      75) _pf_defer=$((_pf_defer+1)); continue ;;
      *)
        loge "預檢失敗：目標無法建立，保留既有掛載｜名稱=$_pf_n｜目標=$_pf_l"
        _pf_fail=$((_pf_fail+1))
        continue
        ;;
    esac
    if target_occupied_unknown "$_pf_s" "$_pf_l" "$_pf_pol"; then
      _pf_old=''
      _pf_old_s=''
      _pf_old_pol=''
      if [ -f "$ACTIVE" ]; then
        _pf_old=$(awk -F'|' -v u="$_pf_u" -v l="$_pf_l" '$2==u&&$5==l{print;exit}' "$ACTIVE")
        _pf_old_s=$(printf '%s
' "$_pf_old" | awk -F'|' '{print $3}')
        _pf_old_pol=$(printf '%s
' "$_pf_old" | awk -F'|' '{print $10}')
      fi
      if [ -n "$_pf_old" ] && [ "$_pf_old_s" = "$_pf_s" ] && [ "$_pf_old_pol" != "$_pf_pol" ]; then
        logi "預檢允許替換既有掛載策略｜名稱=$_pf_n｜User=$_pf_u｜目標=$_pf_l｜舊策略=$_pf_old_pol｜新策略=$_pf_pol"
      else
        _pf_occ=$(mount_src "$_pf_l")
        loge "預檢失敗：目標已被未知來源占用，保留既有掛載｜名稱=$_pf_n｜目標=$_pf_l｜目前來源=${_pf_occ:-unknown}"
        _pf_fail=$((_pf_fail+1))
        continue
      fi
    fi
  done < "$_pf_file"
  [ "$_pf_fail" -eq 0 ]
}

unmount_active_all() {
  [ -f "$ACTIVE" ] || return 0
  while IFS='|' read -r _n _u _s _t _l _v _e _g _pv _pol _create _migrate; do [ -n "$_l" ] || continue; unmount_all_ns "$_u" "$_s" "$_l" "$_pol"; done < "$ACTIVE"
  : > "$ACTIVE"
}


unmount_user_active() {
  _target_user=$1; valid_user "$_target_user" || return 2
  lock_acquire || return 4; trap 'lock_release' EXIT INT TERM
  _next="$ACTIVE.usernext.$$"; : > "$_next"
  if [ -f "$ACTIVE" ]; then
    while IFS='|' read -r _n _u _s _t _l _v _e _g _pv _pol _create _migrate; do
      [ -n "$_l" ] || continue
      if [ "$_u" = "$_target_user" ]; then
        logi "User 停止，卸載項目｜User=$_u｜名稱=$_n｜目標=$_t"
        unmount_all_ns "$_u" "$_s" "$_l" "$_pol"
      else
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_n" "$_u" "$_s" "$_t" "$_l" "$_v" "$_e" "$_g" "$_pv" "$_pol" "$_create" "$_migrate" >> "$_next"
      fi
    done < "$ACTIVE"
  fi
  mv -f "$_next" "$ACTIVE"
  rm -f "$(media_cache_file "$_target_user")" 2>/dev/null
  lock_release; trap - EXIT INT TERM
  return 0
}

set_profile() {
  _sp_group=$1; _sp_value=$2
  valid_id "$_sp_group" && valid_id "$_sp_value" || return 2
  [ -f "$CONF" ] || seed_config || return 2

  # v1.4.77: if a previous manual/config reload failed during a partial
  # editor write, try to repair the last-good parsed snapshot from the now
  # stable live mount.conf before rejecting profile switches.
  if ! config_state_valid || [ ! -f "$PARSED/profiles" ] || [ ! -f "$PARSED/mounts.all" ] || [ ! -f "$PARSED/mounts.desired" ]; then
    logw "Profile 切換前檢測最後有效設定快照無效，先嘗試重新套用目前 mount.conf"
    apply_reload profile_prerepair >/dev/null 2>&1 || true
  fi

  # Fast profile transaction:
  # - never reparses live mount.conf on the normal profile path;
  # - uses the last-good parsed snapshot + applied hash as the authority;
  # - does not publish mount.conf until the new bind is already verified;
  # - confwatch therefore sees only the final committed config and hash-skips it.
  lock_acquire || { loge "Profile 切換取得交易鎖超時"; return 4; }
  trap 'lock_release' EXIT INT TERM

  if ! config_state_valid || [ ! -f "$PARSED/profiles" ] || [ ! -f "$PARSED/mounts.all" ] || [ ! -f "$PARSED/mounts.desired" ]; then
    loge "Profile 切換拒絕：最後有效設定快照不存在或無效"
    lock_release; trap - EXIT INT TERM
    return 3
  fi

  _sp_live_hash=$(config_hash "$CONF" 2>/dev/null || true)
  _sp_applied_hash=$(cat "$APPLIED_HASH" 2>/dev/null)
  if [ -z "$_sp_live_hash" ] || [ -z "$_sp_applied_hash" ] || [ "$_sp_live_hash" != "$_sp_applied_hash" ]; then
    logw "Profile 切換暫停：mount.conf 有尚未套用的外部變更，等待 confwatch 先完成"
    lock_release; trap - EXIT INT TERM
    return 8
  fi
  if ! parsed_cache_matches_hash "$_sp_live_hash"; then
    _sp_repair="$RUNTIME/profile.parsed.repair.$$"
    rm -rf "$_sp_repair" 2>/dev/null
    if parse_config "$CONF" "$_sp_repair" >/dev/null 2>&1; then
      parsed_publish_dir "$_sp_repair" "$_sp_live_hash" >/dev/null 2>&1 || true
    fi
    rm -rf "$_sp_repair" 2>/dev/null
  fi

  _sp_current=$(awk -F'|' -v g="$_sp_group" '$1==g{print $2;exit}' "$PARSED/profiles")
  [ -n "$_sp_current" ] || {
    loge "Profile 切換失敗：找不到群組｜group=$_sp_group"
    lock_release; trap - EXIT INT TERM
    return 4
  }
  if [ "$_sp_current" = "$_sp_value" ]; then
    lock_release; trap - EXIT INT TERM
    return 0
  fi

  # The requested option must already exist in the last-good parsed config.
  awk -F'|' -v g="$_sp_group" -v v="$_sp_value" '$7=="1"&&$8==g&&$9==v{f=1} END{exit f?0:1}' "$PARSED/mounts.all" || {
    loge "Profile 切換失敗：群組沒有此選項｜group=$_sp_group｜value=$_sp_value"
    lock_release; trap - EXIT INT TERM
    return 4
  }

  _sp_tag="$$.$(date +%s 2>/dev/null)"
  _sp_conf_new="$RUNTIME/profile.conf.new.$_sp_tag"
  _sp_profiles_new="$RUNTIME/profile.profiles.new.$_sp_tag"
  _sp_desired_new="$RUNTIME/profile.desired.new.$_sp_tag"
  _sp_active_new="$RUNTIME/profile.active.new.$_sp_tag"
  _sp_changed_old="$RUNTIME/profile.changed.old.$_sp_tag"
  _sp_changed_new="$RUNTIME/profile.changed.new.$_sp_tag"
  _sp_cleanup="$_sp_conf_new $_sp_profiles_new $_sp_desired_new $_sp_active_new $_sp_changed_old $_sp_changed_new"

  # Build the new config without touching the live file.
  awk -F'|' -v g="$_sp_group" -v v="$_sp_value" '
    BEGIN{done=0}
    $1=="profile="g {print "profile="g"|"v;done=1;next}
    {print}
    END{if(!done) exit 7}
  ' "$CONF" > "$_sp_conf_new" || {
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 5
  }
  chmod 0600 "$_sp_conf_new" 2>/dev/null

  # Rebuild only the two derived profile files from the already validated
  # mounts.all snapshot. This avoids the intermittent v1.2.3-v1.2.7 full-parser
  # failure entirely on WebUI/Action profile switches.
  awk -F'|' -v g="$_sp_group" -v v="$_sp_value" '
    $1==g {$2=v}
    {print $1"|"$2}
  ' "$PARSED/profiles" > "$_sp_profiles_new" || {
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 5
  }
  awk -F'|' '
    NR==FNR {sel[$1]=$2; next}
    $7!="1" {next}
    $8=="" || sel[$8]==$9 {print}
  ' "$_sp_profiles_new" "$PARSED/mounts.all" > "$_sp_desired_new" || {
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 5
  }

  # A profile option is allowed only if the resulting active view still has
  # unique User+lower targets. This is the same safety contract as parse_config.
  if [ "$(cut -d'|' -f2,5 "$_sp_desired_new" 2>/dev/null | sort | uniq -d | head -n1)" ]; then
    loge "Profile 切換拒絕：選擇後會造成重複 target"
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 4
  fi

  # Refuse to race an editor that does not participate in our lock.
  _sp_now_hash=$(config_hash "$CONF" 2>/dev/null || true)
  if [ "$_sp_now_hash" != "$_sp_live_hash" ]; then
    logw "Profile 切換取消：mount.conf 同時被其他程序修改"
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 7
  fi

  : > "$_sp_changed_old"; : > "$_sp_changed_new"

  # Find only targets whose selected source actually changes.
  if [ -f "$ACTIVE" ]; then
    while IFS='|' read -r _sp_n _sp_u _sp_s _sp_t _sp_l _sp_v _sp_e _sp_g _sp_pv _sp_pol _sp_create _sp_migrate; do
      [ -n "$_sp_l" ] || continue
      _sp_match=$(awk -F'|' -v u="$_sp_u" -v l="$_sp_l" '$2==u&&$5==l{print;exit}' "$_sp_desired_new")
      _sp_match_src=$(printf '%s\n' "$_sp_match" | awk -F'|' '{print $3}')
      if [ -z "$_sp_match" ] || [ "$_sp_match_src" != "$_sp_s" ]; then
        printf '%s\n' "$_sp_n|$_sp_u|$_sp_s|$_sp_t|$_sp_l|$_sp_v|$_sp_e|$_sp_g|$_sp_pv|$_sp_pol|$_sp_create|$_sp_migrate" >> "$_sp_changed_old"
      fi
    done < "$ACTIVE"
  fi

  while IFS='|' read -r _sp_n _sp_u _sp_s _sp_t _sp_l _sp_v _sp_e _sp_g _sp_pv _sp_pol _sp_create _sp_migrate; do
    [ -n "$_sp_l" ] || continue
    _sp_old=$(awk -F'|' -v u="$_sp_u" -v l="$_sp_l" '$2==u&&$5==l{print;exit}' "$ACTIVE" 2>/dev/null)
    _sp_old_src=$(printf '%s\n' "$_sp_old" | awk -F'|' '{print $3}')
    if [ -z "$_sp_old" ] || [ "$_sp_old_src" != "$_sp_s" ] || ! row_mounted "$_sp_u" "$_sp_s" "$_sp_l" "$_sp_pol"; then
      printf '%s\n' "$_sp_n|$_sp_u|$_sp_s|$_sp_t|$_sp_l|$_sp_v|$_sp_e|$_sp_g|$_sp_pv|$_sp_pol|$_sp_create|$_sp_migrate" >> "$_sp_changed_new"
    fi
  done < "$_sp_desired_new"

  # Preflight every new/changed source BEFORE tearing down the old profile.
  _sp_pre_fail=0
  while IFS='|' read -r _sp_n _sp_u _sp_s _sp_t _sp_l _sp_v _sp_e _sp_g _sp_pv _sp_pol _sp_create _sp_migrate; do
    [ -n "$_sp_l" ] || continue
    if [ -n "$_sp_v" ] && ! user_storage_available "$_sp_u"; then
      logw "Profile 切換暫停：User 儲存根目錄尚未就緒｜User=$_sp_u｜名稱=$_sp_n"
      _sp_pre_fail=1; break
    fi
    ensure_source_dir "$_sp_s" "$_sp_create" "$_sp_pol" || {
      loge "Profile 切換失敗：來源不存在或無法準備｜名稱=$_sp_n｜來源=$_sp_s"
      _sp_pre_fail=1; break
    }
    mkdir -p "$_sp_l" 2>/dev/null || { _sp_pre_fail=1; break; }
  done < "$_sp_changed_new"
  if [ "$_sp_pre_fail" -ne 0 ]; then
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 9
  fi

  # One final external-editor check immediately before changing mounts.
  _sp_now_hash=$(config_hash "$CONF" 2>/dev/null || true)
  if [ "$_sp_now_hash" != "$_sp_live_hash" ]; then
    logw "Profile 切換取消：掛載前 mount.conf 已被其他程序修改"
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 7
  fi

  # Invalidate every older App-namespace worker before changing the core
  # namespaces. This closes the v1.4.70/v1.4.71 rapid-profile race where a
  # previous background tail could unmount or remount the target after a newer
  # profile had already committed.
  _sp_fence_gen="profiletxn.$_sp_tag"
  if ! ns_background_generation_set "$_sp_fence_gen"; then
    loge "Profile 切換失敗：無法建立 namespace generation fence"
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 5
  fi

  # v1.4.74: foreground Profile mount transaction is native-only.
  # mounttx owns: core namespace unmount/mount, bindfs_shared orchestration,
  # visible probe retry, and rollback.  Shell only prepares source dirs and
  # commits config/parsed/active state after native success.
  if [ ! -x "$MOUNTTX" ]; then
    loge "Profile 切換失敗：缺少 native mounttx，v1.4.74 不再用 shell 執行前景掛載交易｜path=$MOUNTTX"
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 127
  fi
  profile_native_preflight_rows "$_sp_changed_new" || {
    loge "Profile native 預檢失敗：bindfs_shared 依賴或 policy 未就緒"
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 9
  }
  profile_native_preflight_rows "$_sp_changed_old" >/dev/null 2>&1 || true
  while IFS='|' read -r _sp_n _sp_u _sp_s _sp_t _sp_l _sp_v _sp_e _sp_g _sp_pv _sp_pol _sp_create _sp_migrate; do
    [ -n "$_sp_l" ] || continue
    migrate_once "$_sp_u" "$_sp_s" "$_sp_l" "$_sp_migrate" || true
  done < "$_sp_changed_new"

  logi "Profile native transaction 呼叫 mounttx｜group=$_sp_group｜$_sp_current → $_sp_value｜old=$(wc -l < "$_sp_changed_old" 2>/dev/null)｜new=$(wc -l < "$_sp_changed_new" 2>/dev/null)"
  mounttx_profile_switch "$_sp_changed_old" "$_sp_changed_new" "$_sp_fence_gen" "$_sp_tag"
  _sp_mtx_rc=$?
  _sp_switch_fail=0
  case "$_sp_mtx_rc" in
    0)
      while IFS='|' read -r _sp_n _sp_u _sp_s _sp_t _sp_l _sp_v _sp_e _sp_g _sp_pv _sp_pol _sp_create _sp_migrate; do
        [ -n "$_sp_l" ] || continue
        [ -n "$_sp_v" ] && media_scan_schedule_visible "$_sp_u" "$_sp_v" "profile_change" >/dev/null 2>&1 || true
        logi "Profile native 切換成功｜名稱=$_sp_n｜$_sp_s → $_sp_t"
      done < "$_sp_changed_new"
      ;;
    10)
      loge "Profile native 切換失敗，mounttx 已驗證 rollback 回上一個掛載狀態｜group=$_sp_group｜value=$_sp_value"
      _sp_switch_fail=1; _sp_fail_rc=10
      ;;
    11)
      loge "Profile native 切換失敗且 mounttx rollback 驗證失敗｜group=$_sp_group｜value=$_sp_value"
      _sp_switch_fail=1; _sp_fail_rc=11
      ;;
    *)
      loge "Profile native transaction 異常返回｜rc=$_sp_mtx_rc｜嘗試 shell recovery rollback"
      if profile_rollback_rows "$_sp_changed_new" "$_sp_changed_old" "$_sp_tag" "mounttx_rc_$_sp_mtx_rc"; then
        _sp_switch_fail=1; _sp_fail_rc=10
      else
        _sp_switch_fail=1; _sp_fail_rc=11
      fi
      ;;
  esac

  if [ "$_sp_switch_fail" -ne 0 ]; then
    notify_post "YAWAsau Mount" "Profile 切換失敗：$_sp_group → $_sp_value" "profile_failed"
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return "$_sp_fail_rc"
  fi

  # Mounts are verified first; only now publish the new config and last-good
  # parsed selection. This means a failed switch never leaves mount.conf claiming
  # a profile that was not actually mounted.
  _sp_new_hash=$(config_hash "$_sp_conf_new" 2>/dev/null || true)
  [ -n "$_sp_new_hash" ] || {
    profile_rollback_rows "$_sp_changed_new" "$_sp_changed_old" "$_sp_tag" new_hash_failed >/dev/null 2>&1 || true
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 6
  }

  mv -f "$_sp_conf_new" "$CONF" || {
    profile_rollback_rows "$_sp_changed_new" "$_sp_changed_old" "$_sp_tag" config_publish_failed >/dev/null 2>&1 || true
    rm -f $_sp_cleanup 2>/dev/null
    lock_release; trap - EXIT INT TERM
    return 6
  }
  chmod 0600 "$CONF" 2>/dev/null

  mv -f "$_sp_profiles_new" "$PARSED/profiles" || true
  mv -f "$_sp_desired_new" "$PARSED/mounts.desired" || true

  # Rebuild ACTIVE from what is actually mounted; unrelated rows are preserved
  # without any bind/probe work.
  : > "$_sp_active_new"
  while IFS='|' read -r _sp_n _sp_u _sp_s _sp_t _sp_l _sp_v _sp_e _sp_g _sp_pv _sp_pol _sp_create _sp_migrate; do
    [ -n "$_sp_l" ] || continue
    row_mounted "$_sp_u" "$_sp_s" "$_sp_l" "$_sp_pol" && printf '%s\n' "$_sp_n|$_sp_u|$_sp_s|$_sp_t|$_sp_l|$_sp_v|$_sp_e|$_sp_g|$_sp_pv|$_sp_pol|$_sp_create|$_sp_migrate" >> "$_sp_active_new"
  done < "$PARSED/mounts.desired"
  mv -f "$_sp_active_new" "$ACTIVE"

  printf '%s\n' "$_sp_new_hash" > "$APPLIED_HASH.tmp.$$" 2>/dev/null && mv -f "$APPLIED_HASH.tmp.$$" "$APPLIED_HASH" 2>/dev/null
  printf '%s\n' "$_sp_new_hash" > "$PARSED_HASH.tmp.$$" 2>/dev/null && mv -f "$PARSED_HASH.tmp.$$" "$PARSED_HASH" 2>/dev/null || true
  config_state_write valid 0 profile_change "$_sp_new_hash" >/dev/null 2>&1 || true
  logi "Profile 已快速切換｜group=$_sp_group｜$_sp_current → $_sp_value"
  notify_post "YAWAsau Mount" "Profile 已切換：$_sp_group｜$_sp_current → $_sp_value" "profile_$_sp_group"
  _sp_commit_gen="profile.$_sp_tag.$_sp_new_hash"
  if ns_background_generation_set "$_sp_commit_gen"; then
    profile_ns_background_sync "$_sp_changed_old" "$_sp_changed_new" "$_sp_commit_gen"
  else
    logw "Profile 已提交，但 App namespace 背景同步 generation 建立失敗；核心 namespace 掛載保持有效"
  fi

  rm -f $_sp_cleanup 2>/dev/null
  lock_release; trap - EXIT INT TERM
  return 0
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g'; }
status_json() {
  if [ -f "$CONF" ]; then migrate_config_schema >/dev/null 2>&1 || true; else seed_config >/dev/null 2>&1; fi
  if [ ! -f "$PARSED/global" ] || [ ! -f "$PARSED/mounts.all" ]; then
    if parse_config "$CONF" "$PARSED" >/dev/null 2>&1; then _sjh=$(config_hash "$CONF" 2>/dev/null || true); [ -n "$_sjh" ] && printf '%s\n' "$_sjh" > "$PARSED_HASH.tmp.$$" 2>/dev/null && mv -f "$PARSED_HASH.tmp.$$" "$PARSED_HASH" 2>/dev/null || true; config_state_write valid 0 status_init "$_sjh" >/dev/null 2>&1 || true; fi
  fi
  if config_state_valid; then _cfgok=true; else _cfgok=false; fi
  _mp=$(cfg_get mount_point); _part=$(cfg_get partition); _dev=$(resolve_device 2>/dev/null || true); _fs=$(mount_fs "$_mp"); [ -n "$_fs" ] || _fs='-'
  is_mounted "$_mp" && _pm=true || _pm=false
  printf '{"version":"%s","config":"%s","configValid":%s,"partition":"%s","device":"%s","mountPoint":"%s","fsType":"%s","partitionMounted":%s,' "$(json_escape "$MODULE_VERSION")" "$(json_escape "$CONF")" "$_cfgok" "$(json_escape "$_part")" "$(json_escape "$_dev")" "$(json_escape "$_mp")" "$(json_escape "$_fs")" "$_pm"
  printf '"profiles":['; _first=1
  if [ -f "$PARSED/profiles" ]; then while IFS='|' read -r _g _sel; do [ -n "$_g" ] || continue; [ "$_first" = 1 ] || printf ','; _first=0; printf '{"group":"%s","selected":"%s","options":[' "$(json_escape "$_g")" "$(json_escape "$_sel")"; _of=1; awk -F'|' -v g="$_g" '$8==g{print $9"|"$1"|"$3"|"$4}' "$PARSED/mounts.all" | awk -F'|' '!seen[$1]++' | while IFS='|' read -r _ov _on _os _ot; do [ "$_of" = 1 ] || printf ','; _of=0; printf '{"value":"%s","name":"%s","source":"%s","target":"%s"}' "$(json_escape "$_ov")" "$(json_escape "$_on")" "$(json_escape "$_os")" "$(json_escape "$_ot")"; done; printf ']}'; done < "$PARSED/profiles"; fi
  printf '],"mounts":['; _first=1
  if [ -f "$PARSED/mounts.all" ]; then while IFS='|' read -r _n _u _s _t _l _v _e _g _pv _pol _create _migrate; do
    [ "$_first" = 1 ] || printf ','; _first=0
    _active=false; _mounted=false; _visible=false; _selected=true
    if [ -n "$_g" ]; then _sel=$(awk -F'|' -v g="$_g" '$1==g{print $2;exit}' "$PARSED/profiles"); [ "$_sel" = "$_pv" ] || _selected=false; fi
    [ "$_e" = 1 ] && [ "$_selected" = true ] && _active=true
    if [ -d "$_s" ] && row_mounted "$_u" "$_s" "$_l" "$_pol"; then _mounted=true; fi
    if [ -z "$_v" ]; then _visible=$_mounted; elif [ "$_mounted" = true ] && [ -d "$_v" ]; then _visible=true; else _pid=$(media_cache_pid "$_u" 2>/dev/null || true); [ -n "$_pid" ] && nsenter -t "$_pid" -m -- test -d "$_v" >/dev/null 2>&1 && _visible=true; fi
    printf '{"name":"%s","user":%s,"source":"%s","target":"%s","enabled":%s,"active":%s,"mounted":%s,"visible":%s,"group":"%s","profile":"%s","policy":"%s","create":%s,"migrate":"%s"}' "$(json_escape "$_n")" "$_u" "$(json_escape "$_s")" "$(json_escape "$_t")" "$([ "$_e" = 1 ] && echo true || echo false)" "$_active" "$_mounted" "$_visible" "$(json_escape "$_g")" "$(json_escape "$_pv")" "$(json_escape "$_pol")" "$([ "$_create" = 1 ] && echo true || echo false)" "$(json_escape "$_migrate")"
  done < "$PARSED/mounts.all"; fi
  printf ']}'
}

refresh_card() {
  _prop="$MODDIR/module.prop"; [ -f "$_prop" ] || return 0
  _state=$(config_state_value STATE)
  _rc=$(config_state_value RC)
  if [ "$_state" = invalid ]; then
    _live_part=$(grep -m1 '^partition=' "$CONF" 2>/dev/null | cut -d= -f2-)
    case "$_rc" in
      20) _desc="錯誤｜找不到分區：${_live_part:-未設定}" ;;
      3) _desc="錯誤｜mount.conf 語法/欄位無效（目前掛載保留最後有效設定）" ;;
      *) _desc="錯誤｜mount.conf 套用失敗 rc=$_rc（目前掛載保留最後有效設定）" ;;
    esac
  else
    _live_hash=$(config_hash "$CONF" 2>/dev/null || true)
    _applied_hash=$(cat "$APPLIED_HASH" 2>/dev/null)
    if [ -n "$_live_hash" ] && [ "$_live_hash" = "$_applied_hash" ] && ! parsed_cache_matches_hash "$_live_hash"; then
      _rcp="$RUNTIME/card.parsed.repair.$$"
      rm -rf "$_rcp" 2>/dev/null
      if parse_config "$CONF" "$_rcp" >/dev/null 2>&1; then parsed_publish_dir "$_rcp" "$_live_hash" >/dev/null 2>&1 || true; fi
      rm -rf "$_rcp" 2>/dev/null
    fi
    [ -f "$PARSED/global" ] || parse_config "$CONF" "$PARSED" >/dev/null 2>&1 || true
    _mp=$(cfg_get mount_point); _part=$(cfg_get partition)
    _dev=$(resolve_device 2>/dev/null || true)
    if [ -z "$_dev" ]; then
      # If the last-good parsed cache is somehow stale, fall back to global.active
      # before showing an error on the module card.
      _ag=$(cat "$GLOBAL_ACTIVE" 2>/dev/null)
      _ap=$(printf '%s\n' "$_ag" | sed -n 's/^partition=//p')
      _amp=$(printf '%s\n' "$_ag" | sed -n 's/^mount_point=//p')
      _adev=''; [ -n "$_ap" ] && _adev=$(resolve_partition_name "$_ap" 2>/dev/null || true)
      if [ -n "$_adev" ]; then
        _part=$_ap; _mp=$_amp; _dev=$_adev
      fi
    fi
    if [ -z "$_dev" ]; then
      _desc="錯誤｜找不到分區：$_part"
    else
      _fs=$(mount_fs "$_mp"); [ -n "$_fs" ] || _fs='-'
      _total=$(wc -l < "$ACTIVE" 2>/dev/null | tr -d ' '); [ -n "$_total" ] || _total=0
      _ok=0
      if [ -f "$ACTIVE" ]; then
        while IFS='|' read -r _n _u _s _t _l _v _e _g _pv _pol _create _migrate; do
          [ -d "$_s" ] && row_mounted "$_u" "$_s" "$_l" "$_pol" && _ok=$((_ok+1))
        done < "$ACTIVE"
      fi
      _desc="$_fs｜掛載 $_ok/$_total｜分區=$_part｜事件即時更新"
    fi
  fi
  _tmp="$_prop.tmp.$$"
  awk -v d="$_desc" 'BEGIN{done=0} /^description=/{print "description="d;done=1;next}{print}END{if(!done)print "description="d}' "$_prop" > "$_tmp" && mv -f "$_tmp" "$_prop"
  touch "$_prop" 2>/dev/null || true
}
