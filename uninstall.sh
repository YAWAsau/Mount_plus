#!/system/bin/sh
MODDIR=${0%/*}
CONTROL="$MODDIR/control.sh"
DATA_DIR=/data/adb/dcimswitch
RUNTIME="$DATA_DIR/runtime"
CONF="$DATA_DIR/mount.conf"

for _pf in "$RUNTIME"/*.pid; do
  [ -f "$_pf" ] || continue
  _p=$(cat "$_pf" 2>/dev/null)
  case "$_p" in ''|*[!0-9]*) ;; *) kill "$_p" 2>/dev/null || true;; esac
done

sh "$CONTROL" unmount_all >/dev/null 2>&1 || true

resolve_partition() {
  _part=$1
  _first=''; _real_first=''
  for _cand in \
    "/dev/block/by-name/$_part" \
    "/dev/block/bootdevice/by-name/$_part" \
    /dev/block/platform/*/by-name/"$_part" \
    /dev/block/platform/*/*/by-name/"$_part" \
    /dev/block/platform/*/*/*/by-name/"$_part"
  do
    [ -e "$_cand" ] || continue
    _r=$(readlink -f "$_cand" 2>/dev/null || printf '%s\n' "$_cand")
    [ -z "$_first" ] && { _first="$_cand"; _real_first="$_r"; continue; }
    [ "$_r" = "$_real_first" ] || return 1
  done
  [ -n "$_first" ] && printf '%s\n' "$_first"
}

if [ -f "$CONF" ]; then
  _mp=$(grep -m1 '^mount_point=' "$CONF" 2>/dev/null | cut -d= -f2-)
  _part=$(grep -m1 '^partition=' "$CONF" 2>/dev/null | cut -d= -f2-)
  _device=$(resolve_partition "$_part" 2>/dev/null || true)
  case "$_mp" in /*)
    if command -v nsenter >/dev/null 2>&1; then
      _cur=$(nsenter -t 1 -m -- awk -v p="$_mp" '$2==p{print $1;exit}' /proc/mounts 2>/dev/null)
    else
      _cur=$(awk -v p="$_mp" '$2==p{print $1;exit}' /proc/mounts 2>/dev/null)
    fi
    if [ -n "$_cur" ] && [ -n "$_device" ]; then
      _cr=$(readlink -f "$_cur" 2>/dev/null || printf '%s\n' "$_cur")
      _dr=$(readlink -f "$_device" 2>/dev/null || printf '%s\n' "$_device")
      if [ "$_cr" = "$_dr" ]; then
        if command -v nsenter >/dev/null 2>&1; then
          nsenter -t 1 -m -- umount "$_mp" 2>/dev/null || nsenter -t 1 -m -- umount -l "$_mp" 2>/dev/null || true
        else
          umount "$_mp" 2>/dev/null || umount -l "$_mp" 2>/dev/null || true
        fi
      fi
    fi
    ;;
  esac
fi
rm -rf "$DATA_DIR" 2>/dev/null
