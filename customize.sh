SKIPUNZIP=1
MODID=dcimswitch
DATA_DIR=/data/adb/dcimswitch
CONF="$DATA_DIR/mount.conf"

ui_print '── YAWAsau Mount v1.4.72 安裝 ──'
ui_print '檢查環境：arm64 / Dex 通知 / static bindfs'
[ "$ARCH" = arm64 ] || abort '不支援的架構：本模組只支援 arm64-v8a'

ui_print '解壓模組檔案...'
unzip -oq "$ZIPFILE" 'module.prop' 'core.sh' 'service.sh' 'mount.sh' 'control.sh' 'action.sh' 'uninstall.sh' 'sepolicy.rule' 'mount.conf.default' 'mount.conf.example' -d "$MODPATH" >/dev/null 2>&1 || abort '解壓核心檔案失敗'
mkdir -p "$MODPATH/bin" "$MODPATH/webroot"
unzip -oq "$ZIPFILE" 'bin/*' 'webroot/*' -d "$MODPATH" >/dev/null 2>&1 || abort '解壓執行檔或 WebUI 失敗'
touch "$MODPATH/skip_mount"

# Dex-only notification build must not be flashed without classes.dex.
# The source/build-kit zip intentionally carries source; the flashable output must be generated
# by source/build/build_yawasau_full_module_windows.ps1 so bin/classes.dex is bundled.
if [ ! -f "$MODPATH/bin/classes.dex" ]; then
  ui_print '缺少 bin/classes.dex：這是 build-kit，不是可刷成品'
  ui_print '請刷 build 腳本輸出的 *_module_*.zip'
  abort '安裝中止：Dex 通知檔不存在'
fi

mkdir -p "$DATA_DIR/runtime" "$DATA_DIR/backups" 2>/dev/null
LIVE_EXISTED=0
LIVE_HASH_BEFORE=
LIVE_BACKUP=
LIVE_SRC=
STAMP=$(date +%Y%m%d%H%M%S 2>/dev/null || echo now)

# Hard preserve live config:
# 1) prefer the real live config under /data/adb/dcimswitch/mount.conf;
# 2) if it does not exist, rescue legacy configs that older builds kept in the module directory;
# 3) never seed bundled defaults when any user/legacy config can be found.
for _cand in \
  "$CONF" \
  "/data/adb/modules/$MODID/mount.conf" \
  "/data/adb/modules_update/$MODID/mount.conf" \
  "$MODPATH/mount.conf"; do
  if [ -f "$_cand" ]; then
    LIVE_SRC="$_cand"
    break
  fi
done

if [ -n "$LIVE_SRC" ]; then
  LIVE_EXISTED=1
  LIVE_BACKUP="$DATA_DIR/backups/mount.conf.preserve_v1468.$STAMP"
  cp -f "$LIVE_SRC" "$LIVE_BACKUP" 2>/dev/null || true
  if [ "$LIVE_SRC" != "$CONF" ]; then
    cp -f "$LIVE_SRC" "$CONF" 2>/dev/null || abort '匯入舊設定失敗'
    chmod 0600 "$CONF" 2>/dev/null || true
    ui_print '設定檔：已匯入舊版設定並保留'
  else
    ui_print '設定檔：保留現有 mount.conf'
  fi
  LIVE_HASH_BEFORE=$(cksum "$CONF" 2>/dev/null | awk '{print $1":"$2}' | head -n1)
else
  ui_print '設定檔：首次安裝，將建立預設 mount.conf'
fi

# Runtime cache may be rebuilt, but the live config above must never be deleted or replaced.
rm -rf "$DATA_DIR/runtime/parsed" "$DATA_DIR/runtime/reload.lock" 2>/dev/null
rm -f "$DATA_DIR/runtime/active_mounts.tsv" "$DATA_DIR/runtime/global.active" "$DATA_DIR/runtime/media_provider_ns.cache" 2>/dev/null

ui_print '設定權限...'
set_perm_recursive "$MODPATH" 0 0 0755 0644
for _f in service.sh mount.sh control.sh action.sh uninstall.sh bin/propwait bin/filewatch bin/confwatch bin/bindfs_mount.sh bin/bindfs bin/mount.fuse3 bin/mount_fusefs bin/magiskpolicy bin/mounttx bin/classes.dex bin/notify_client.sh; do [ -e "$MODPATH/$_f" ] && set_perm "$MODPATH/$_f" 0 0 0755; done
set_perm "$MODPATH/core.sh" 0 0 0644
[ -f "$MODPATH/sepolicy.rule" ] && set_perm "$MODPATH/sepolicy.rule" 0 0 0644

if [ -f "$MODPATH/bin/bindfs" ] && [ -x "$MODPATH/bin/mount.fuse3" ]; then
  ui_print 'Native：static bindfs + mount.fuse3 已就緒'
else
  ui_print '警告：缺少 bindfs 或 mount.fuse3，bindfs_shared 可能不可用'
fi
if [ -f "$MODPATH/bin/magiskpolicy" ]; then
  ui_print 'SELinux：內建 magiskpolicy 已就緒'
else
  ui_print '警告：缺少 magiskpolicy，bindfs_shared 可能需要系統端支援'
fi
ui_print '通知：Dex-only 已就緒'

# Hard preserve live/legacy config. If a live or legacy config was found above,
# installation must not migrate, replace, normalize, or re-seed it.
# Only create the bundled default when no config exists anywhere.
if [ "$LIVE_EXISTED" = 1 ]; then
  LIVE_HASH_AFTER=$(cksum "$CONF" 2>/dev/null | awk '{print $1":"$2}' | head -n1)
  if [ -n "$LIVE_HASH_BEFORE" ] && [ -n "$LIVE_HASH_AFTER" ] && [ "$LIVE_HASH_BEFORE" != "$LIVE_HASH_AFTER" ]; then
    cp -f "$LIVE_BACKUP" "$CONF" 2>/dev/null || abort '還原保留設定失敗'
    chmod 0600 "$CONF" 2>/dev/null || true
    ui_print '設定檔：安裝期間被改動，已還原原始內容'
  else
    ui_print '設定檔：已原樣保留，不自動覆蓋'
  fi
else
  if sh "$MODPATH/mount.sh" migrate_config >/dev/null 2>&1; then
    ui_print '設定檔：預設 mount.conf 已建立'
  else
    abort '建立預設 mount.conf 失敗'
  fi
fi

ui_print '啟動服務...'
# Stop old watcher processes from the currently active module, then start this package's service directly.
if [ -x "/data/adb/modules/$MODID/control.sh" ]; then
  sh "/data/adb/modules/$MODID/control.sh" stop_watchers >/dev/null 2>&1 || true
fi
rm -f "$DATA_DIR/runtime/"*.pid 2>/dev/null || true
(sh "$MODPATH/service.sh" >/dev/null 2>&1 &) || true

ui_print '完成：設定已保留，服務已啟動'
ui_print '提示：掛載結果會由 Dex 通知彙總顯示；也可開 WebUI 查看狀態'
