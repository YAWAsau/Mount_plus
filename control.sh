#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/core.sh" || exit 90
cmd=${1:-status}
case "$cmd" in
  status) status_json ;;
  validate) validate_config_report validate "${2:-$CONF}"; exit $? ;;
  dryrun) validate_config_report dryrun "${2:-$CONF}"; exit $? ;;
  reload|apply_all)
    _reason=${2:-manual}
    _before_active="$RUNTIME/active.before.manual.$$"
    cp -f "$ACTIVE" "$_before_active" 2>/dev/null || : > "$_before_active"
    apply_reload "$_reason"
    _rc=$?
    refresh_card >/dev/null 2>&1 || true
    case "$_reason" in
      boot_initial|config_event|config_event_retry|user_*|user0_*|media_apply|profile_change|duplicate_*) ;;
      *)
        if [ "$_rc" -eq 0 ]; then
          notify_config_apply_result "$_before_active" "$_reason" >/dev/null 2>&1 || true
        else
          notify_config_failed "$_rc" >/dev/null 2>&1 || true
        fi
        ;;
    esac
    rm -f "$_before_active" 2>/dev/null || true
    exit $_rc
    ;;
  profile) [ $# -ge 3 ] || { echo "usage: $0 profile GROUP VALUE" >&2; exit 2; }; set_profile "$2" "$3"; exit $? ;;
  profile_async)
    [ $# -ge 3 ] || { echo "usage: $0 profile_async GROUP VALUE" >&2; exit 2; }
    valid_id "$2" && valid_id "$3" || exit 2
    _tok="$$.$(date +%s 2>/dev/null)"
    _st="$RUNTIME/profile_async.state"
    _out="$RUNTIME/profile_async.out"
    printf 'RUNNING|%s|%s|%s|%s\n' "$_tok" "$2" "$3" "$$" > "$_st.tmp.$$" 2>/dev/null && mv -f "$_st.tmp.$$" "$_st" 2>/dev/null
    (
      _ao="$RUNTIME/profile_async.out.$_tok"
      sh "$0" profile "$2" "$3" > "$_ao" 2>&1
      _rc=$?
      mv -f "$_ao" "$_out" 2>/dev/null || true
      printf 'DONE|%s|%s|%s|%s\n' "$_tok" "$2" "$3" "$_rc" > "$_st.tmp.$_tok" 2>/dev/null && mv -f "$_st.tmp.$_tok" "$_st" 2>/dev/null
    ) >/dev/null 2>&1 &
    printf 'QUEUED|%s\n' "$_tok"
    exit 0
    ;;
  profile_async_state)
    cat "$RUNTIME/profile_async.state" 2>/dev/null || true
    ;;
  daily) set_profile camera daily; exit $? ;;
  work) set_profile camera work; exit $? ;;
  current)
    parse_config "$CONF" "$PARSED" >/dev/null 2>&1 || exit 1
    awk -F'|' '$1=="camera"{print toupper($2);exit}' "$PARSED/profiles"
    ;;
  primary_profile)
    if [ ! -f "$PARSED/profiles" ] || [ ! -f "$PARSED/mounts.all" ]; then parse_config "$CONF" "$PARSED" >/dev/null 2>&1 || exit 1; fi
    head -n1 "$PARSED/profiles" | awk -F'|' '{print $1"|"$2}'
    ;;
  primary_action_info)
    if [ ! -f "$PARSED/profiles" ] || [ ! -f "$PARSED/mounts.all" ]; then parse_config "$CONF" "$PARSED" >/dev/null 2>&1 || exit 1; fi
    _line=$(head -n1 "$PARSED/profiles")
    _g=$(printf '%s\n' "$_line" | cut -d'|' -f1)
    _sel=$(printf '%s\n' "$_line" | cut -d'|' -f2)
    [ -n "$_g" ] || exit 10
    _cur_name=$(awk -F'|' -v g="$_g" -v s="$_sel" '$8==g&&$9==s{print $1;exit}' "$PARSED/mounts.all")
    _next_line=$(awk -F'|' -v g="$_g" -v s="$_sel" '$8==g&&$9!=s{print $9"|"$1;exit}' "$PARSED/mounts.all")
    [ -n "$_next_line" ] || exit 10
    _next=$(printf '%s\n' "$_next_line" | cut -d'|' -f1)
    _next_name=$(printf '%s\n' "$_next_line" | cut -d'|' -f2-)
    [ -n "$_cur_name" ] || _cur_name=$_sel
    [ -n "$_next_name" ] || _next_name=$_next
    printf '%s|%s|%s|%s|%s\n' "$_g" "$_sel" "$_cur_name" "$_next" "$_next_name"
    ;;
  toggle_primary)
    _info=$(sh "$0" primary_action_info 2>/dev/null); _irc=$?
    if [ "$_irc" -eq 10 ]; then echo "未設定可切換項目"; exit 0; fi
    [ "$_irc" -eq 0 ] || exit "$_irc"
    _g=$(printf '%s\n' "$_info" | cut -d'|' -f1)
    _next=$(printf '%s\n' "$_info" | cut -d'|' -f4)
    set_profile "$_g" "$_next"; exit $?
    ;;
  refresh_card) refresh_card ;;

  notify_test)
    _nb=$(notify_backend_status 2>/dev/null)
    if notify_post "YAWAsau Mount" "Dex 通知測試｜backend=$_nb" "debug_notify_test"; then
      echo "通知測試已送出｜backend=$_nb"
    else
      echo "通知測試未送出｜backend=$_nb｜log=$DEX_NOTIFY_LOG"
    fi
    ;;
  notify_backend) notify_backend_status ;;
  log)
    echo '===== service.log｜開機 / 解鎖 / 事件監聽 ====='
    cat "$RUNTIME/service.log" 2>/dev/null || true
    echo
    echo '===== mount.log｜主分區 / 掛載 / 手機儲存可見性 ====='
    cat "$LOG" 2>/dev/null || true
    if [ -s "$RUNTIME/dcim_switch.log" ]; then
      echo
      echo '===== dcim_switch.log｜舊版相容日誌 ====='
      cat "$RUNTIME/dcim_switch.log" 2>/dev/null || true
    fi
    ;;
  config_path) printf '%s\n' "$CONF" ;;
  config_info)
    echo "目前生效設定：$CONF"
    echo "模組內建範例：$EXAMPLE_CONF"
    echo "模組預設模板：$DEFAULT_CONF"
    echo "注意：confwatch 只監聽目前生效設定；修改模組目錄內的範例不會即時生效。"
    ;;
  backup_config)
    mkdir -p "$DATA_DIR/backups" 2>/dev/null || exit 1
    _dst="$DATA_DIR/backups/mount.conf.manual.$(date +%Y%m%d%H%M%S 2>/dev/null || echo now)"
    cp -f "$CONF" "$_dst" 2>/dev/null || exit 1
    chmod 0600 "$_dst" 2>/dev/null || true
    echo "已備份目前生效設定：$_dst"
    ;;
  import_default|restore_default)
    mkdir -p "$DATA_DIR/backups" 2>/dev/null || exit 1
    if [ -f "$CONF" ]; then
      _dst="$DATA_DIR/backups/mount.conf.before_default.$(date +%Y%m%d%H%M%S 2>/dev/null || echo now)"
      cp -f "$CONF" "$_dst" 2>/dev/null || exit 1
      chmod 0600 "$_dst" 2>/dev/null || true
      echo "已備份原 live 設定：$_dst"
    fi
    cp -f "$DEFAULT_CONF" "$CONF" 2>/dev/null || exit 1
    chmod 0600 "$CONF" 2>/dev/null || true
    echo "已匯入模組預設設定到 live：$CONF"
    apply_reload import_default
    _rc=$?
    refresh_card >/dev/null 2>&1 || true
    exit $_rc
    ;;
  stop_watchers)
    for _n in confwatch userstate user0prop user0file; do
      _pf="$RUNTIME/${_n}.pid"; _p=$(cat "$_pf" 2>/dev/null)
      case "$_p" in ''|*[!0-9]*) ;; *) kill "$_p" 2>/dev/null || true ;; esac
      rm -f "$_pf" 2>/dev/null || true
    done
    echo "事件監聽器已停止"
    ;;
  start_watchers)
    sh "$MODDIR/service.sh" >/dev/null 2>&1 &
    echo "事件監聽器/掛載服務已啟動"
    ;;
  restart_watchers|restart_service)
    sh "$0" stop_watchers >/dev/null 2>&1 || true
    sh "$MODDIR/service.sh" >/dev/null 2>&1 &
    echo "事件監聽器/掛載服務已重啟"
    ;;
  unmount_user) [ $# -ge 2 ] || exit 2; unmount_user_active "$2" ;;
  unmount_all) lock_acquire || exit 4; trap 'lock_release' EXIT INT TERM; unmount_active_all; lock_release; trap - EXIT INT TERM ;;
  *) echo "usage: $0 {status|reload|apply_all|profile GROUP VALUE|profile_async GROUP VALUE|profile_async_state|primary_action_info|toggle_primary|refresh_card|notify_test|notify_backend|log|config_path|config_info|backup_config|import_default|restore_default|validate [CONF]|dryrun [CONF]|start_watchers|stop_watchers|restart_service|unmount_user USER|unmount_all}" >&2; exit 2 ;;
esac
