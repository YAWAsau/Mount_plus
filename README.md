# YAWAsau Mount

YAWAsau Mount 是一个面向 Android root / KernelSU / Magisk 环境的储存挂载模组，用来把外部或自定义分区映射到 `/storage/emulated/<UserID>/...`，并支援多使用者、Profile 切换与跨 User 权限映射。

目前主线用途是 DCIM / 相簿 / 备份资料夹分离，例如日常相机资料夹与工作相机资料夹切换：

```text
/mnt/YAWAsau/DCIM   -> /storage/emulated/0/DCIM
/mnt/YAWAsau/DCIM2  -> /storage/emulated/0/DCIM
```

## 主要功能

- 挂载自定义分区到 Android 内置储存路径。
- 支援 User 0、User 10 等多 Android User。
- 支援 `preserve`、`media_rw`、`bindfs_shared` 三种 mount policy。
- 支援 Profile 切换，不需要重刷模组即可切换不同来源目录。
- 支援 live `mount.conf` 修改后重新套用。
- 支援 Dex-only 系统通知，开机、解锁、挂载完成、设定错误、reload 成功/失败会提示。
- 挂载设定档不会在模组更新时被覆盖。
- 设定档错误时保留最后有效 parsed snapshot，避免 WebUI / active 状态被坏设定误导。

## 挂载策略

### `preserve`

保留来源目录原始 owner / group / mode，适合不需要强制改权限的资料夹。

```ini
mount=QQ|0|QQ|Android/data/com.tencent.mobileqq/Tencent/QQfile_recv|1|||preserve|1|none
```

### `media_rw`

使用 Android 媒体储存常见权限模型，适合一般相簿、DCIM、Pictures 等场景。

```ini
mount=DCIM|0|DCIM|DCIM|1|camera|daily|media_rw|1|none
```

### `bindfs_shared`

用于跨 User 或普通 App 读取会 EACCES 的场景。它使用 `bindfs` 权限映射，挂入 MediaProvider mount namespace，不直接改来源档案权限。

```ini
mount=虚拟分区1|10|备份|虚拟分区|1|||bindfs_shared|1|none
```

注意：`bindfs_shared` 只支援 `mount=` 列，不支援 `dir=` 列。

## 设定档

live 设定档固定在：

```text
/data/adb/dcimswitch/mount.conf
```

基本格式：

```ini
version=1
partition=YAWAsau
mount_point=/mnt/YAWAsau
fs=auto

mount=名称|UserID|source|target|enabled|profile_group|profile_value|policy|create|migrate
```

栏位说明：

| 栏位 | 说明 |
| --- | --- |
| 名称 | 显示名称，也用于通知与 WebUI |
| UserID | Android User ID，例如 `0`、`10` |
| source | 来源路径；非 `/` 开头时相对于 `mount_point` |
| target | 目标路径；非 `/` 开头时相对于 `/storage/emulated/<UserID>/` |
| enabled | `1` 启用，`0` 停用 |
| profile_group | Profile 群组，可空白 |
| profile_value | Profile 值，可空白 |
| policy | `preserve`、`media_rw`、`bindfs_shared` |
| create | `1` 时自动建立目录 |
| migrate | 目前建议使用 `none` |

相对路径规则：

- `source` 不以 `/` 开头：相对于 `mount_point`。
- `target` 不以 `/` 开头：相对于 `/storage/emulated/<UserID>/`。
- 绝对 `target` 只允许 `/storage/emulated/<UserID>/...` 或 `/data/media/<UserID>/...`。
- `UserID` 必须存在；不存在会直接通知 `无此 User`。

## 通知行为

YAWAsau Mount 使用 Dex one-shot 通知，不使用 `cmd notification` fallback，也不常驻 Dex daemon。

通知场景：

- 开机后尚未解锁：提示等待使用者解锁后开始解密内置储存。
- 侦测到解锁：提示开始挂载。
- 挂载完成：例如 `挂载完成：6/6`。
- 挂载不完整：例如 `挂载不完全：3/6`，并列出异常挂载点。
- `mount.conf` 修改成功：提示新增 / 移除 / 套用结果。
- `mount.conf` 有错：提示行号与原因，不需要翻 log 才知道问题。

## 建置需求

Windows 建置环境建议：

- Android SDK
- Android NDK r28c
- API 28
- MSYS2
- PowerShell 5.1 或更新版本
- JDK / Android Gradle 环境，用于编译 Dex 通知程式

预设建置会重新编译：

- static `bindfs`
- native `mount.fuse3` / `mount_fusefs`
- `classes.dex`

`magiskpolicy` 预设沿用包内 known-good binary。需要完整重编官方 Magisk source 时才使用 `-RebuildMagiskPolicy`。

## 建置方式

```powershell
cd .\source\build
.\build_yawasau_full_module_windows.ps1
```

输出可刷模组 ZIP，例如：

```text
YAWAsau_Mount_v1.4.69_notify_result_preserve_parsed_module_20260825.zip
```

如需强制重编官方 Magisk source 的 `magiskpolicy`：

```powershell
.\build_yawasau_full_module_windows.ps1 -RebuildMagiskPolicy
```

## 常用命令

```sh
# 查看通知后端
su -c 'sh /data/adb/modules/dcimswitch/control.sh notify_backend'

# 发送通知测试
su -c 'sh /data/adb/modules/dcimswitch/control.sh notify_test'

# 查看目前状态
su -c 'sh /data/adb/modules/dcimswitch/control.sh status'

# 手动重新套用设定
su -c 'sh /data/adb/modules/dcimswitch/control.sh reload'
```

## Debug 资料

主要 log / runtime 位于：

```text
/data/adb/dcimswitch/
/data/adb/dcimswitch/runtime/
/data/adb/dcimswitch/logs/
```

若回报问题，建议附上模组产生的 `dcimswitch.zip` debug 包。


## 安全说明

本模组会执行 root 挂载操作，错误设定可能导致目录不可见、App 扫描异常或挂载点残留。模组预设不覆盖既有 `mount.conf`，设定错误时会保留最后有效设定，降低资料可见性被破坏的风险。

建议先用少量挂载点测试，确认 WebUI、通知与 App 可见性正常后再扩展设定。
