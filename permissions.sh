#!/system/bin/sh
# One-shot media_rw metadata repair. No watcher, timer, or background scan.
# Invoked with an explicit BusyBox ash by core.sh; find batches its operations.
set -u

if [ "${1:-}" = --batch ]; then
  kind=$2; job=$3; shift 3
  # find never follows symlinks. Refuse a batch if a selected path changed type.
  for path do
    if [ -L "$path" ]; then echo "type changed: $path" >> "$job/errors"; exit 1; fi
    case "$kind" in
      dirs) [ -d "$path" ] || { echo "directory disappeared: $path" >> "$job/errors"; exit 1; } ;;
      files) [ -f "$path" ] || { echo "file disappeared: $path" >> "$job/errors"; exit 1; } ;;
      *) exit 2 ;;
    esac
  done
  mode=2770
  [ "$kind" != files ] || mode='u+rwX,g+rwX,o-rwx,a-st'
  if ! /system/bin/chown -h 1023:1023 "$@" ||
     ! /system/bin/chmod "$mode" "$@" ||
     ! /system/bin/chcon -h u:object_r:media_rw_data_file:s0 "$@"; then
    printf 'metadata batch failed: %s count=%s\n' "$kind" "$#" >> "$job/errors"
    exit 1
  fi
  printf '%s %s\n' "$kind" "$#" >> "$job/counts"
  exit 0
fi

[ $# -eq 3 ] || { echo 'usage: permissions.sh SOURCE STATE_DIR EXCLUSIONS'; exit 2; }
bb=${YAW_PERMISSION_BUSYBOX:-}
[ -x "$bb" ] || exit 3
self=$(readlink -f "$0") || exit 3
root=$(readlink -f "$1") || exit 3
state=$2; exclusions=$3
[ -d "$root" ] || exit 3
# media_rw is a shared-storage policy, never a whole-system permission reset.
case "$root" in
  /|/data|/data/adb|/data/adb/*|/data/system|/data/system/*|/data/user|/data/user/*|/data/user_de|/data/user_de/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/system|/system/*|/vendor|/vendor/*|/mnt|/storage)
    echo "MEDIA_REPAIR_REFUSED root=$root"; exit 4 ;;
esac
mkdir -p "$state" || exit 5
chmod 700 "$state" || exit 5
id=$(printf '%s' "$root" | cksum | awk '{print $1}')
case "$id" in ''|*[!0-9]*) exit 5 ;; esac
exec 9>"$state/$id.lock" || exit 5
/system/bin/flock -n 9 9>&9 || { echo "MEDIA_REPAIR_BUSY root=$root"; exit 75; }
job="$state/job.$id.$$"
mkdir "$job" || exit 5
trap 'rm -f "$job/prunes" "$job/key" "$job/errors" "$job/counts"; rmdir "$job" 2>/dev/null' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
: > "$job/prunes"; : > "$job/counts"

# NUL-separated mount paths preserve spaces, tabs and newlines. Same-filesystem
# bind mounts need explicit pruning as find -xdev alone cannot exclude them.
YAW_MEDIA_ROOT="$root/" awk '
  BEGIN { r=ENVIRON["YAW_MEDIA_ROOT"] }
  function decode(s, i,o,c) {
    o=""
    for(i=1;i<=length(s);i++) {
      c=substr(s,i,1)
      if(c=="\\" && substr(s,i+1,3) ~ /^[0-7][0-7][0-7]$/) {
        c=sprintf("%c",substr(s,i+1,1)*64+substr(s,i+2,1)*8+substr(s,i+3,1)); i+=3
      }
      o=o c
    }
    return o
  }
  { p=decode($5); if(index(p,r)==1) printf "%s%c",p,0 }
' /proc/self/mountinfo > "$job/prunes" || exit 6
if [ -f "$exclusions" ]; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path=$(readlink -f "$path" 2>/dev/null) || continue
    case "$path" in "$root"/*) printf '%s\0' "$path" >> "$job/prunes" ;; esac
  done < "$exclusions"
fi
# Sorting makes mount ordering and duplicate exclusions irrelevant to the cache.
"$bb" sort -zu "$job/prunes" -o "$job/prunes" || exit 6
media_uid=unknown
for pkg in com.android.providers.media.module com.google.android.providers.media.module com.android.providers.media; do
  if [ -d "/data/user_de/0/$pkg" ]; then
    media_uid=$(stat -c %u "/data/user_de/0/$pkg") || exit 6
    break
  fi
done
identity=$(stat -c '%d:%i' "$root") || exit 6
printf 'media-tree-v1\n%s\n%s\n%s\n' "$root" "$identity" "$media_uid" > "$job/key"
cksum < "$job/prunes" >> "$job/key" || exit 6
root_meta=$(stat -c '%u:%g:%a' "$root") || exit 6
root_context=$(ls -Zd "$root" | awk '{print $1}')
if [ "${YAW_MEDIA_REPAIR_FORCE:-0}" != 1 ] &&
   [ "$root_meta" = 1023:1023:2770 ] &&
   [ "$root_context" = u:object_r:media_rw_data_file:s0 ] &&
   cmp -s "$job/key" "$state/$id.done"; then
  echo "MEDIA_REPAIR_CACHED root=$root"
  exit 0
fi
# Invalidate first: a partial scan must never retain an old success marker.
rm -f "$state/$id.done" || exit 6
echo "MEDIA_REPAIR_BEGIN root=$root"
set -- "$root" -xdev '(' -path ''
while IFS= read -r -d '' path; do
  # find -path is a glob; escape literal metacharacters in exclusion names.
  pattern=$(printf '%s' "$path" | sed 's/\\/\\\\/g;s/\[/\\[/g;s/\]/\\]/g;s/\*/\\*/g;s/?/\\?/g')
  set -- "$@" -o -path "$pattern"
done < "$job/prunes"
# Keep batched -exec actions outside parentheses: the device's BusyBox find
# does not flush pending + batches nested in an action group.
set -- "$@" ')' -prune -o \
  -type d -exec "$bb" sh "$self" --batch dirs "$job" '{}' '+' \
  -o -type f -exec "$bb" sh "$self" --batch files "$job" '{}' '+'
if ! "$bb" find "$@" || [ -s "$job/errors" ]; then
  cat "$job/errors" 2>/dev/null
  echo "MEDIA_REPAIR_FAILED root=$root"
  exit 7
fi
counts=$(awk '{a[$1]+=$2} END {printf "dirs=%d files=%d",a["dirs"],a["files"]}' "$job/counts")
# An empty successful traversal is not a successful repair.
[ -s "$job/counts" ] || exit 8
[ "$(stat -c '%u:%g:%a' "$root")" = 1023:1023:2770 ] || exit 8
[ "$(ls -Zd "$root" | awk '{print $1}')" = u:object_r:media_rw_data_file:s0 ] || exit 8
# Source replacement during the scan invalidates the result.
[ "$(stat -c '%d:%i' "$root")" = "$identity" ] || exit 8
mv -f "$job/key" "$state/$id.done" || exit 8
echo "MEDIA_REPAIR_DONE root=$root $counts"
