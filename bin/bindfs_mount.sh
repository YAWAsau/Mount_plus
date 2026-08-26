#!/system/bin/sh
# v1.4.53 helper: static-fuse bindfs runner executed inside target mount namespace.
# Strategy stays v1.4.52/v2-compatible: lower path + MediaProvider namespace.
_SELF=${0%/*}
MODDIR=${MODDIR:-${_SELF%/bin}}
DATA_DIR=${DATA_DIR:-/data/adb/dcimswitch}
if [ -n "${BINDFS_PATH:-}" ]; then
  BINDFS="$BINDFS_PATH"
elif [ -x "$MODDIR/bin/bindfs" ]; then
  BINDFS="$MODDIR/bin/bindfs"
else
  BINDFS="$DATA_DIR/native/bin/bindfs"
fi
UID_MAP=$1
GID_MAP=$2
SRC=$3
DST=$4
[ -x "$BINDFS" ] || { echo "bindfs missing: $BINDFS" >&2; exit 70; }
case "$UID_MAP" in ''|*[!0-9]*) echo "bad uid: $UID_MAP" >&2; exit 72;; esac
case "$GID_MAP" in ''|*[!0-9]*) echo "bad gid: $GID_MAP" >&2; exit 72;; esac
[ -d "$SRC" ] || { echo "source missing/not dir: $SRC" >&2; exit 73; }
mkdir -p "$DST" 2>/dev/null || { echo "mkdir target failed: $DST" >&2; exit 74; }
# Static bindfs no longer needs libfuse3.so / LD_LIBRARY_PATH.  It still needs
# a mount.fuse3-compatible helper because Android toybox mount cannot reliably
# consume libfuse's fd= helper call.  Put module bin first so libfuse resolves
# our native mount.fuse3 / mount_fusefs before any system fallback.
export PATH="$MODDIR/bin:$DATA_DIR/native/bin:/system/bin:/system/xbin:$PATH"
export FUSE_MOUNT_HELPER="$MODDIR/bin/mount.fuse3"
# Keep v2 working permissions: MediaProvider UID + media_rw GID, 770 view, 660
# create perms, ignore chmod/chown writes back to the original source tree.
# Do not pass context= here; sepolicy.rule + magiskpolicy --live handles SELinux.
"$BINDFS" \
  -o fsname=bindfs_shared,allow_other \
  -u "$UID_MAP" -g "$GID_MAP" -p 770 \
  --create-for-user=0 --create-for-group=1023 --create-with-perms=660 \
  --chown-ignore --chgrp-ignore --chmod-ignore \
  "$SRC" "$DST"
_rc=$?
[ "$_rc" = 0 ] && exit 0
echo "bindfs static/native-helper attempt failed rc=$_rc; PATH=$PATH helper=$FUSE_MOUNT_HELPER" >&2
exit "$_rc"
