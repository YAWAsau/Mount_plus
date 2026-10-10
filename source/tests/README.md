# v1.4.93 regression checks

- `node source/tests/webui_i18n.cjs`: language toggle while busy, localStorage exceptions, failed apply and incorrect visibility.
- Compile `sourcewatch.c` with NDK r30 API 28, push it and `sourcewatch_android.sh` into a **new** `/data/local/tmp/yaw1493-test-*` directory and run `sh test.sh <absolute-directory>` as root.
- Compile `mounttx_identity_android.c` with NDK r30 API 28; run it as root with a **new empty** `/data/local/tmp/yaw1493-native-*` directory argument. It first unshares a mount namespace and makes propagation private, then tests only temporary paths. It never calls the module transaction against init/MediaProvider namespaces.
- `python source/tests/shell_checks_android.py <output-directory>` extracts current functions; push generated files into a temporary directory and run `sh test.sh <directory>` on Android with KernelSU BusyBox. Installed module scripts are not sourced.

Passed on Android 17: watcher cases, private-namespace native tests, shell checks. New-version installation/reboot, full bindfs_shared namespace recovery and Salt Player/gallery index persistence have not been verified. Do not treat asynchronous scan-request acceptance as scan completion or preservation of MediaStore IDs.
