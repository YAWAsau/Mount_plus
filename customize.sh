SKIPUNZIP=1
MODID=dcimswitch
DATA_DIR=/data/adb/dcimswitch
CONF="$DATA_DIR/mount.conf"

ui_print '── YAWAsau Mount v1.4.92 安装 ──'
ui_print '检查环境：arm64 / Dex 通知 / bindfs'
[ "$ARCH" = arm64 ] || abort '不支援的架构：本模组只支援 arm64-v8a'

ui_print '解压模组档案...'
unzip -oq "$ZIPFILE" 'module.prop' 'core.sh' 'permissions.sh' 'service.sh' 'watchers.sh' 'user-state.sh' 'boot-completed.sh' 'mount.sh' 'control.sh' 'action.sh' 'uninstall.sh' 'sepolicy.rule' 'mount.conf.default' 'mount.conf.example' -d "$MODPATH" >/dev/null 2>&1 || abort '解压核心档案失败'
mkdir -p "$MODPATH/bin" "$MODPATH/webroot"
unzip -oq "$ZIPFILE" 'bin/*' 'webroot/*' -d "$MODPATH" >/dev/null 2>&1 || abort '解压执行档或 WebUI 失败'
touch "$MODPATH/skip_mount"

# Dex-only notification build must not be flashed without classes.dex.
# The source/build-kit zip intentionally carries source; the flashable output must be generated
# by source/build/build_yawasau_full_module_windows.ps1 so bin/classes.dex is bundled.
if [ ! -f "$MODPATH/bin/classes.dex" ]; then
  ui_print '缺少 bin/classes.dex：这是 build-kit，不是可刷成品'
  ui_print '请刷 build 脚本输出的 *_module_*.zip'
  abort '安装中止：Dex 通知档不存在'
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
    cp -f "$LIVE_SRC" "$CONF" 2>/dev/null || abort '汇入旧设定失败'
    chmod 0600 "$CONF" 2>/dev/null || true
    ui_print '设定档：已汇入旧版设定并保留'
  else
    ui_print '设定档：保留现有 mount.conf'
  fi
  LIVE_HASH_BEFORE=$(cksum "$CONF" 2>/dev/null | awk '{print $1":"$2}' | head -n1)
else
  ui_print '设定档：首次安装，将建立预设 mount.conf'
fi

# Do not reset runtime or remove locks while the previous module is running.
# The new service performs its once-per-boot reset after the manager activates it.

ui_print '设定权限...'
set_perm_recursive "$MODPATH" 0 0 0755 0644
for _f in permissions.sh service.sh watchers.sh boot-completed.sh mount.sh control.sh action.sh uninstall.sh bin/propwait bin/filewatch bin/confwatch bin/bindfs_mount.sh bin/bindfs bin/mount.fuse3 bin/mount_fusefs bin/magiskpolicy bin/mounttx bin/classes.dex bin/notify_client.sh; do [ -e "$MODPATH/$_f" ] && set_perm "$MODPATH/$_f" 0 0 0755; done
set_perm "$MODPATH/core.sh" 0 0 0644
[ -f "$MODPATH/sepolicy.rule" ] && set_perm "$MODPATH/sepolicy.rule" 0 0 0644

if [ -f "$MODPATH/bin/bindfs" ] && [ -x "$MODPATH/bin/mount.fuse3" ]; then
  ui_print 'Native：bindfs + mount.fuse3 已就绪'
else
  ui_print '警告：缺少 bindfs 或 mount.fuse3，bindfs_shared 可能不可用'
fi
if [ -f "$MODPATH/bin/magiskpolicy" ]; then
  ui_print 'SELinux：内建 magiskpolicy 已就绪'
else
  ui_print '警告：缺少 magiskpolicy，bindfs_shared 可能需要系统端支援'
fi
ui_print '通知：Dex-only 已就绪'

# Hard preserve live/legacy config. If a live or legacy config was found above,
# installation must not migrate, replace, normalize, or re-seed it.
# Only create the bundled default when no config exists anywhere.
if [ "$LIVE_EXISTED" = 1 ]; then
  LIVE_HASH_AFTER=$(cksum "$CONF" 2>/dev/null | awk '{print $1":"$2}' | head -n1)
  if [ -n "$LIVE_HASH_BEFORE" ] && [ -n "$LIVE_HASH_AFTER" ] && [ "$LIVE_HASH_BEFORE" != "$LIVE_HASH_AFTER" ]; then
    cp -f "$LIVE_BACKUP" "$CONF" 2>/dev/null || abort '还原保留设定失败'
    chmod 0600 "$CONF" 2>/dev/null || true
    ui_print '设定档：安装期间被改动，已还原原始内容'
  else
    ui_print '设定档：已原样保留，不自动覆盖'
  fi
else
  if sh "$MODPATH/mount.sh" migrate_config >/dev/null 2>&1; then
    ui_print '设定档：预设 mount.conf 已建立'
  else
    abort '建立预设 mount.conf 失败'
  fi
fi

# Staged modules_update paths are renamed at reboot. Launching workers from
# there during installation can strand them on an obsolete script path.
ui_print '完成：设定已保留，请重开机套用新版服务'
ui_print '提示：挂载结果会由 Dex 通知汇总显示；也可开 WebUI 查看状态'
