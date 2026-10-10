#!/system/bin/sh
set -eu
BASE=$1
case "$BASE" in /data/local/tmp/yaw1493-test-*) ;; *) exit 2;; esac
cd "$BASE"
mkdir -p tree/parent/source runtime/parsed
printf 'test|0|%s/tree/parent/source|target|lower|visible|1|||preserve|0|none\n' "$BASE" > runtime/parsed/mounts.desired
./sourcewatch "$BASE/runtime/parsed/mounts.desired" > events &
worker=$!
trap 'kill "$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true' EXIT
wait_count() {
  n=0
  while [ "$(wc -l < events)" -lt "$1" ]; do
    n=$((n+1)); [ "$n" -lt 60 ] || { echo "FAIL timeout $1";exit 1; }
    sleep 0.05
  done
}
wait_count 1
rmdir tree/parent/source
sleep 0.2
[ ! -d tree/parent/source ]
[ "$(wc -l < events)" -eq 1 ]
mkdir tree/parent/source
wait_count 2
printf content > tree/parent/source/file
sleep 0.2
[ "$(wc -l < events)" -eq 2 ]
mv tree/parent tree/old-parent
sleep 0.2
mkdir -p tree/parent/source
wait_count 3
mv runtime/parsed runtime/old-parsed
mkdir -p runtime/parsed tree/second
printf 'test|0|%s/tree/second|target|lower|visible|1|||preserve|0|none\n' "$BASE" > runtime/parsed/mounts.desired
wait_count 4
rmdir tree/second
sleep 0.2
mkdir tree/second
wait_count 5
echo 'PASS: initial reconcile, deletion stays absent, recreation, no content wakeup, ancestor replacement, parsed replacement'
