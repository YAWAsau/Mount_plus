#!/system/bin/sh
# Run ONLY under: busybox unshare -mpf --mount-proc --propagation private sh ...
set -eu
BASE=$1
case "$BASE" in /data/local/tmp/yaw1495-test/transaction-*) ;; *) exit 2;; esac
[ "$$" = 1 ] || { echo 'Requires private PID namespace'; exit 2; }
mount --make-rprivate /
BIN=/data/local/tmp/yaw1495-test/module/bin/mounttx
MOD=/data/local/tmp/yaw1495-test/module
mkdir -p "$BASE/a" "$BASE/b" "$BASE/dst" "$BASE/foreign"
printf a > "$BASE/a/value"
printf b > "$BASE/b/value"
printf 1 > "$BASE/generation"
: > "$BASE/empty"
row() { printf 'test|0|%s|%s|%s|%s|1|||%s|0|none\n' "$1" "$BASE/dst" "$BASE/dst" "$BASE/dst" "$2"; }
row "$BASE/a" preserve > "$BASE/old"
row "$BASE/b" preserve > "$BASE/new"
row "$BASE/absent" preserve > "$BASE/bad"
tx() { "$BIN" "$@" --runtime "$BASE" --moddir "$MOD" --log "$BASE/tx.log" --generation-file "$BASE/generation" --generation 1; }
tx profile-switch --old "$BASE/empty" --new "$BASE/old"
[ "$(cat "$BASE/dst/value")" = a ]
tx profile-switch --old "$BASE/old" --new "$BASE/new"
[ "$(cat "$BASE/dst/value")" = b ]
set +e
tx profile-switch --old "$BASE/new" --new "$BASE/bad"
rc=$?
set -e
[ "$rc" = 10 ]
[ "$(cat "$BASE/dst/value")" = b ]
# Replaced inode still proves ownership through the committed source record.
sig=$("$BIN" source-sig "$BASE/b")
printf '0|%s|%s|preserve|%s\n' "$BASE/dst" "$BASE/b" "$sig" > "$BASE/active_source_state.tsv"
mv "$BASE/b" "$BASE/b.old"
mkdir "$BASE/b"
printf recreated > "$BASE/b/value"
tx source-refresh --rows "$BASE/new"
[ "$(cat "$BASE/dst/value")" = recreated ]
umount "$BASE/dst"
mount --bind "$BASE/foreign" "$BASE/dst"
set +e
tx source-refresh --rows "$BASE/new"
rc=$?
set -e
[ "$rc" != 0 ]
"$BIN" mount-query same 1 "$BASE/foreign" "$BASE/dst"
umount "$BASE/dst"
# Real bindfs + Rust mount.fuse3 in this private namespace.
row "$BASE/a" bindfs_shared > "$BASE/fuse"
tx profile-switch --old "$BASE/empty" --new "$BASE/fuse"
[ "$(cat "$BASE/dst/value")" = a ]
"$BIN" mount-query fuse 1 "$BASE/dst"
umount "$BASE/dst"
printf 2 > "$BASE/generation"
set +e
tx profile-switch --old "$BASE/empty" --new "$BASE/old"
rc=$?
set -e
[ "$rc" = 75 ]
echo 'PASS: kernel bind, profile switch, rollback, source replacement, foreign mount protection, bindfs + Rust FUSE helper, stale generation'
