# YAWAsau Mount v1.4.53 native build kit

预设一条 `./build_yawasau_native_windows.ps1` 会编译：

- static-fuse `bin/bindfs`（`libfuse3.a` 静态连入，不打包 `libs/libfuse3.so`）
- native `bin/mount.fuse3` / `bin/mount_fusefs` helper（处理 libfuse numeric fd + mount(2)）
- 官方 Magisk source `bin/magiskpolicy`
- 最终 full module zip：`YAWAsau_Mount_v1.4.53_static_bindfs_native_helper_module_20260824.zip`

挂载策略保留 v1.4.52 已通过路线：`/data/media/<user>/...` lower target + MediaProvider namespace，不再做 `/storage/emulated` app namespace 直挂。

---

# Windows native build v1.4.40

预设一条指令完成全部 native build 与模组打包：

```powershell
.\build_yawasau_native_windows.ps1
```

v1.4.40 起 `bindfs` 预设静态连入 `libfuse3.a`，runtime 不再需要 `lib/libfuse3.so`。完整模组会打包 `bin/bindfs` 与官方 Magisk source 自编的 `bin/magiskpolicy`。

---

# YAWAsau native build / pack

## v1.4.26 打包完整模组

编译完成后会有：

```text
native_out/bin/bindfs
native_out/lib/libfuse3.a（build-time only；不打包）
native_out/SHA256SUMS.txt
```

直接打包完整模组：

```powershell
.\pack_yawasau_module_windows.ps1
```

或编译后立刻打包：

```powershell
.\build_yawasau_native_windows.ps1 `
  -NdkVersion 30.0.16248370 `
  -Api 28 `
  -Msys2Root C:\msys64 `
  -PackModule
```

打包脚本会把 `native_out/bin/bindfs` 与 `native_out/lib/libfuse3.a（build-time only；不打包）` 放入 zip 的 `native/`，安装时 `customize.sh` 会部署到 `/data/adb/dcimswitch/native/`。

# YAWAsau native Windows build flow

这套脚本是把 SpeedBackup 的 native 规范搬到 YAWAsau，v1.4.18 承接 Android bionic patch、Windows/MSYS2 no-chown install、libfuse headers 手动收集、bindfs src-only build、bindfs `config.cache`、fake file/PE tools，并修正 deterministic pkg-config wrapper：libfuse Meson 阶段固定走 `/usr/bin/pkg-config`，fake wrapper 只允许 FUSE package，避免 optional liburing/numa/udev 误判。缺少 libfuse / bindfs source 时，预设仍会自动下载官方 source tarball 到 root 层 `third_party/`，再用本机 NDK 编译。

目标：

- Android NDK r28c / API 28
- arm64-v8a
- dynamic PIE executable 使用 `/system/bin/linker64`
- 16K page / RELRO alignment 验证
- 产出 SHA256SUMS
- 不把来源不明第三方 prebuilt 当正式包

## 前置需求

Windows：

- Android SDK + NDK `30.0.16248370`
- PowerShell 5+
- MSYS2，并安装 `meson ninja pkgconf autoconf automake libtool make python git file`
- 官方 Magisk source 需要照 Magisk 上游文件准备 Python、JDK、Android SDK/NDK/Rust/ONDK 相关环境

MSYS2 套件可参考：

```powershell
C:\msys64\usr\bin\bash.exe -lc "pacman -S --needed --noconfirm meson ninja pkgconf autoconf automake libtool make python git file"
```

也可用内建 helper 检查并安装套件：

```powershell
powershell -ExecutionPolicy Bypass -File .\source\build\check_msys2_native_deps_windows.ps1 `
  -Msys2Root C:\msys64 `
  -InstallPackages
```


### 没装 MSYS2 时

若 `C:\msys64\usr\bin\bash.exe` 不存在，可先让 helper 尝试用 winget 安装 MSYS2，并安装 native build 套件：

```powershell
powershell -ExecutionPolicy Bypass -File .\source\build\check_msys2_native_deps_windows.ps1 `
  -Msys2Root C:\msys64 `
  -AutoInstallWinget `
  -InstallPackages
```

也可以让主 build script 直接呼叫 helper：

```powershell
powershell -ExecutionPolicy Bypass -File .\source\build\build_yawasau_native_windows.ps1 `
  -NdkVersion 30.0.16248370 `
  -Api 28 `
  -AutoInstallMsys2
```

若 winget 或安装器要求管理员权限，请手动安装 MSYS2 到 `C:\msys64` 后再跑 dependency helper。

### v1.4.18 pkg-config filter + Meson real pkg-config

若 bindfs configure 停在：

```text
checking for pkg-config... /usr/bin/pkg-config
```

v1.4.18 会在 `native_work/fakebin/` 产生 `pkg-config` / `aarch64-linux-android-pkg-config` wrapper，但 wrapper 只回应 `fuse` / `fuse3` / `libfuse` / `libfuse3`；libfuse Meson cross file 固定使用 `/usr/bin/pkg-config`，bindfs configure 才使用 fake wrapper，并直接喂入：

```text
FUSE_CFLAGS=-I$OUT/include/fuse3 -DFUSE_USE_VERSION=317
FUSE_LIBS=-L$OUT/lib -lfuse3 -ldl
```

这避免 bindfs Autotools 吃到 MSYS2 host pkg-config 或 host `.pc` 状态。

### v1.4.10 Windows/MSYS2 manual install collection

Windows/MSYS2 不支援 upstream install rule 内的 `chown root:root`。本 build kit 不需要 `fusermount3`，也不需要把 libfuse 安装到系统路径，因此 v1.4.9 改成手动收集产物：

```text
native_out/lib/libfuse3.a（build-time only；不打包）
native_out/bin/bindfs
native_out/lib/pkgconfig/fuse3.pc
native_out/lib/pkgconfig/fuse.pc
```

正式放手机时只需要：

```text
（v1.4.40 起不需要手动部署 libfuse3.so）
/data/adb/dcimswitch/native/bin/bindfs
```

## 目录范例

```text
YAWAsauBuild/
  source/build/build_yawasau_native_windows.ps1
  source/build/fetch_yawasau_native_sources_windows.ps1
  source/build/check_msys2_native_deps_windows.ps1
  source/build/verify_elf_yaw_native.ps1
  third_party/
    libfuse-fuse-3.18.2/
    bindfs-1.18.4/
    Magisk/
```

注意：`source/third_party/` 是文件区；真正下载/解压的 native source 预设放在 root 层 `third_party/`。

## 编 bindfs + libfuse3

一般情况直接执行；缺 source 时会自动下载并解压：

```powershell
powershell -ExecutionPolicy Bypass -File .\source\build\build_yawasau_native_windows.ps1 `
  -NdkVersion 30.0.16248370 `
  -Api 28 `
  -Msys2Root C:\msys64
```

若你要先单独下载 source：

```powershell
powershell -ExecutionPolicy Bypass -File .\source\build\fetch_yawasau_native_sources_windows.ps1
```

若你已手动放好 source，或要完全离线检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\source\build\build_yawasau_native_windows.ps1 `
  -NdkVersion 30.0.16248370 `
  -Api 28 `
  -Msys2Root C:\msys64 `
  -NoFetchSources `
  -LibfuseSrc .\third_party\libfuse-fuse-3.18.2 `
  -BindfsSrc .\third_party\bindfs-1.18.4
```

产物：

```text
native_out/bin/bindfs
native_out/lib/libfuse3.a（build-time only；不打包）
native_out/SHA256SUMS.txt
third_party/SHA256SUMS_DOWNLOADED_SOURCES.txt
```

## 编官方 magiskpolicy

准备官方 Magisk source：

```sh
git clone --recurse-submodules https://github.com/topjohnwu/Magisk.git third_party/Magisk
```

依 Magisk 官方文件准备 SDK/JDK/NDK/ONDK/Rust 环境后执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\source\build\build_yawasau_native_windows.ps1 `
  -BuildMagiskPolicy `
  -SkipBindfs `
  -MagiskSrc .\third_party\Magisk
```

`magiskpolicy` 必须来自官方 `topjohnwu/Magisk` source 的 `build.py native magiskpolicy`，不要用已封存的旧 `topjohnwu/magiskpolicy` repo，也不要用来源不明 prebuilt。

## 放到手机

```sh
su -c 'mkdir -p /data/adb/dcimswitch/native/bin /data/adb/dcimswitch/native/lib'
su -c 'cp /sdcard/bindfs /data/adb/dcimswitch/native/bin/bindfs'
# v1.4.40 起不需要手动部署 libfuse3.so
su -c 'cp /sdcard/magiskpolicy /data/adb/dcimswitch/native/bin/magiskpolicy' # optional
su -c 'chmod 0755 /data/adb/dcimswitch/native/bin/bindfs /data/adb/dcimswitch/native/bin/magiskpolicy 2>/dev/null || true'
# v1.4.40 起不需要 chmod libfuse3.so
```


## v1.4.5 注意

如果 v1.4.4 出现类似 `bash.exe : $x; done; if [ -n $missing ] ... syntax error near done`，请改用 v1.4.5。
本版把 MSYS2 tool check 从 inline one-liner 改成临时 `.sh` 档，并用 UTF-8 no BOM 写入 bash script / Meson cross file。


## v1.4.6 PowerShell $ORIGIN rpath 修正

修正 `build_yawasau_native_windows.ps1` 产生 bindfs `LDFLAGS` 时，PowerShell strict mode 会把 ELF rpath 的 `$ORIGIN` 当成本机变数展开而中止的问题。v1.4.6 会先把 literal `$ORIGIN` 放入安全变数，再输出成 shell 需要的 `\$ORIGIN/../lib`。


## v1.4.9 Android bionic librt 修正

若 Meson 停在：

```text
lib/meson.build:40:14: ERROR: C shared or static library 'rt' not found
```

代表进入 libfuse cross build 后，upstream Meson 脚本尝试连结独立 `librt`。Android bionic 没有独立 `librt`，所以 v1.4.9 会在 build 工作目录中 patch 解压后 source 的 `lib/meson.build`，把 `cc.find_library('rt')` 改为空 dependency。这不改 source tarball，也不把 prebuilt 放进正式包。


## v1.4.9 Android pthread / mount backend note

Android bionic 不提供 `pthread_cancel` / `pthread_setcancelstate` / `PTHREAD_CANCEL_ENABLE` / `PTHREAD_CANCEL_DISABLE`。libfuse 3.18.2 若直接用 NDK cross compile，会在 `fuse.c` 与 `fuse_loop_mt.c` 停止。build script 会在解压后的本机 build tree 注入 no-op pthread cancellation shim。

Android 是 Linux kernel 环境；若 upstream Meson 只用 `host_machine.system() == 'linux'` 选 Linux mount backend，Android 可能落到 BSD mount helper。build script 会把 Android 纳入 Linux mount backend；同时保留 `mount_bsd.c` 的 Android fallback shim。source archive hash 不变，不内建任何 prebuilt。


## v1.4.14 bindfs configure cache

若 bindfs configure 停在：

```text
checking for file... file
```

代表 libfuse 已完成，卡点在 bindfs Autotools/libtool 的 host file magic / deplibs 探测。v1.4.14 会产生 `native_work/bindfs-config.cache` 并用 `--cache-file` 喂给 configure，固定 `lt_cv_path_MAGIC_CMD`、`lt_cv_file_magic_cmd`、`lt_cv_deplibs_check_method=pass_all` 与 NDK LLVM binutils。


## v1.4.12 note

若 bindfs configure 停在 `checking for link... link -dump`，请使用 v1.4.12 或更新版。build script 会明确指定 Android NDK LLVM binutils，避免 Autotools/libtool 在 Windows/MSYS2 内误用 `link.exe` / `dumpbin`。


## v1.4.16 note

- bindfs Autotools/libtool configure 在 MSYS2/Windows 交叉编译时若探测到 `dlltool` / `windres` / `windmc`，可能停在 Windows PE/COFF tool discovery。
- v1.4.16 以 `native_work/fakebin` 的 fail-fast PE helpers 与 configure cache 强制跳过这条路径。
- Android target 仍使用 NDK LLVM `clang/ld.lld/llvm-nm/llvm-objdump/llvm-strip`。


## v1.4.15 note

bindfs Autotools configure now uses a deterministic fake `file` tool and both prefixed/unprefixed cache variables to avoid MSYS2/Windows file-magic probing hangs during Android cross build.


### v1.4.19 pkg-config fuse3 preseed

v1.4.18 在 bindfs configure 通过 libtool/xattr 探测后仍可能停在 FUSE pkg-config 探测前后。v1.4.19 将 bindfs configure 明确加上 `--with-fuse3`，补齐 `fuse3_CFLAGS` / `fuse3_LIBS` 与 `pkg_cv_fuse3_CFLAGS` / `pkg_cv_fuse3_LIBS`，并修正 fake pkg-config wrapper 以支援 Autoconf 常见的 quoted module expression，例如 `fuse3 >= 3.4.0`。


## v1.4.30 Magisk policy auto-fetch

When `-BuildMagiskPolicy` is supplied, the build script now auto-fetches the official `topjohnwu/Magisk` source into `third_party/Magisk` if `build.py` is missing. Use `-MagiskRef <tag-or-commit>` to pin a specific official ref, or `-NoFetchMagisk` to require an already-present checkout.

Example:

```powershell
.\build_yawasau_native_windows.ps1 `
  -NdkVersion 30.0.16248370 `
  -Api 28 `
  -Msys2Root C:\msys64 `
  -BuildMagiskPolicy `
  -SetupMagiskNdk `
  -PackModule `
  -IncludeMagiskPolicy
```


## v1.4.31
- BuildMagiskPolicy now derives Android SDK root from the resolved NDK path and exports ANDROID_HOME/ANDROID_SDK_ROOT before running official Magisk build.py, fixing the upstream `Please set Android SDK path to environment variable ANDROID_HOME` stop on Windows PowerShell.


### v1.4.32 note

When `-SetupMagiskNdk` is used with Python 3.13 on Windows, the wrapper patches the official Magisk `build.py` ONDK extraction step from streaming `tarfile.open(mode="r|xz")` to seekable `BytesIO` + `tarfile.open(mode="r:xz")`. This avoids `tarfile.StreamError: seeking backwards is not allowed` while still building from official `topjohnwu/Magisk` source.


## v1.4.39 one-command default

Default command now performs the full pipeline:

```powershell
.uild_yawasau_native_windows.ps1
```

This builds bindfs/libfuse3, fetches/builds official-source magiskpolicy, verifies native ELF files, and packs the flashable module. Use switches only to override/debug individual stages.


## v1.4.39 pack path separator fix

PowerShell 5.1 `GetFullPath()` relative path strings use single backslashes. `pack_yawasau_module_windows.ps1` now converts `[char]92` to `/` before creating `ZipArchive` entries, so local `bin\bindfs` is accepted and emitted as ZIP entry `bin/bindfs`.
