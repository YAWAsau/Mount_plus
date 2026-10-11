# Native convergence validation

Device: Xiaomi 13 (fuxi), Android 17, KernelSU Next, ARM64. NDK r30 30.0.16248370, API 28, 16 KiB ELF alignment.

Baseline: v1.4.93 RC2 Shell code at c2fffa2. Each copy uses a private runtime directory. The same real configuration contains eight rows (seven selected). These figures measure control operations, not file I/O throughput. Device `/system/bin/time -p`, five runs, including the shell entry point:

| Operation | Shell median (s) | Native median (s) |
|---|---:|---:|
| parse | 12.690035 | 0.134257 |
| pids | 54.713217 | 0.157453 |
| status | 5.857930 | 0.337587 |

Tests:
- `native_android.py`: old/new parsed output comparison, malformed configuration rejection, no partial publication, Unicode/space paths, stale process records, JSON structure, timings.
- `mounttx_identity_android.c`: private mount namespace; replaced source, foreign bind protection, unwritable source, mount-table whitespace decoding.
- `live_native_android.py --serial SERIAL --live`: explicit spare-device opt-in; add test-only mounts, source deletion/recreation, MediaProvider namespace reads, profile switch, manual reload, exact configuration restore.
- Native supervisor: crash restart, duplicate suppression, idle worker identity, signal/group cleanup (isolated fake worker).
- Shell syntax in mksh and KernelSU ash; media scan guards; WebUI i18n regression.

The module still uses Shell for deployment, Android framework commands, ROM policy integration, and transaction orchestration. `filewatch` and `propwait` remain existing prebuilts; this change does not claim complete source provenance for them.

Stable update metadata is generated from the actual release ZIP by `source/build/generate_update_json.py`. The update workflow refuses prereleases and requires exactly one installable ZIP. Future stable packages must use a versionCode greater than the installed candidate to offer automatic updates.

Installed-device results: original 7 active mounts healthy after reboot. Test-only kernel-bind and bindfs_shared sources correctly became unhealthy when deleted and automatically recovered after recreation (4.09 s and 2.77 s respectively, including polling/ADB overhead). MediaProvider namespace read verified new content. Profile a/b/a and manual reload passed. Original config restored byte-for-byte.

One boot attempt did not complete: vendor fingerprint HAL repeatedly crashed, before user mounts were applied. Subsequent reboot completed. Keep this limitation in release notes; this test does not establish the cause of that ROM failure or guarantee all-device boot behavior.

The complete test exposed an old preflight inconsistency: a recreated source's old bind was classified as foreign before native refresh ran. Preflight and unmount now share the saved device/inode ownership proof. Actual foreign kernel binds remain protected. FUSE ownership requires the module's `bindfs_shared` fsname, rather than accepting every FUSE mount.

The Salt Player/gallery private-library persistence issue still needs that app's own reboot/reindex reproduction. Mount visibility and guarded MediaProvider requests do not prove app database persistence.
