base=$1
MOUNTTX="$base/mounttx"
RUNTIME="$base"
cd "$base"
for f in core service watchers customize control; do sh -n "$f.sh"; /data/adb/ksu/bin/busybox ash -n "$f.sh"; done
logw(){ :; }; logi(){ :; }; valid_safe_abs(){ return 0; }
media_scan_mapping_ready(){ return 1; }
am(){ echo unexpected >> "$base/broadcasts"; }
mkdir -p "$base/existing-target"
if visible_probe 0 /proc/yaw-unwritable "$base/existing-target"; then echo FAIL-probe;exit 1; fi
: > "$base/broadcasts"
media_scan_broadcast 0 "$base/existing-target" boot_initial && exit 1
[ ! -s "$base/broadcasts" ]
media_scan_broadcast 0 "$base/existing-target" unmount_restore_source_refresh
[ ! -s "$base/broadcasts" ]
media_scan_mapping_ready(){ return 0; }
media_scan_broadcast 0 "$base/existing-target" boot_initial
[ "$(wc -l < "$base/broadcasts")" -eq 1 ]
ACTIVE="$base/active"
printf 'music|0|src|target|lower|/storage/emulated/0/Music|1|||preserve|0|none\n' > "$ACTIVE"
media_scan_schedule_visible(){ printf '%s\n' "$2" >> "$base/scheduled"; }
: > "$base/scheduled"
media_scan_schedule_user_root_if_media_active 0 boot_initial
[ "$(cat "$base/scheduled")" = /storage/emulated/0/Music ]
echo 'PASS: mksh/ash syntax, failed probe stays unhealthy, no unverified/transient scan, verified mapping scan, target-only boot scan'
