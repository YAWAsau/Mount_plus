# YAWAsau Mount

YAWAsau Mount 是一個面向 Android root / KernelSU / Magisk 環境的儲存掛載模組，用來把外部或自定義分區映射到 `/storage/emulated/<UserID>/...`，並支援多使用者、Profile 切換與跨 User 權限映射。

目前主線用途是 DCIM / 相簿 / 備份資料夾分離，例如日常相機資料夾與工作相機資料夾切換：

```text
/mnt/YAWAsau/DCIM   -> /storage/emulated/0/DCIM
/mnt/YAWAsau/DCIM2  -> /storage/emulated/0/DCIM
```

## 主要功能

- 掛載自定義分區到 Android 內置儲存路徑。
- 支援 User 0、User 10 等多 Android User。
- 支援 `preserve`、`media_rw`、`bindfs_shared` 三種 mount policy。
- 支援 Profile 切換，不需要重刷模組即可切換不同來源目錄。
- 支援 live `mount.conf` 修改後重新套用。
- 支援 Dex-only 系統通知，開機、解鎖、掛載完成、設定錯誤、reload 成功/失敗會提示。
- 掛載設定檔不會在模組更新時被覆蓋。
- 設定檔錯誤時保留最後有效 parsed snapshot，避免 WebUI / active 狀態被壞設定誤導。

## 掛載策略

### `preserve`

保留來源目錄原始 owner / group / mode，適合不需要強制改權限的資料夾。

```ini
mount=QQ|0|QQ|Android/data/com.tencent.mobileqq/Tencent/QQfile_recv|1|||preserve|1|none
```

### `media_rw`

使用 Android 媒體儲存常見權限模型，適合一般相簿、DCIM、Pictures 等場景。

```ini
mount=DCIM|0|DCIM|DCIM|1|camera|daily|media_rw|1|none
```

### `bindfs_shared`

用於跨 User 或普通 App 讀取會 EACCES 的場景。它使用 `bindfs` 權限映射，掛入 MediaProvider mount namespace，不直接改來源檔案權限。

```ini
mount=虛擬分區1|10|備份|虛擬分區|1|||bindfs_shared|1|none
```

注意：`bindfs_shared` 只支援 `mount=` 列，不支援 `dir=` 列。

## 設定檔

live 設定檔固定在：

```text
/data/adb/dcimswitch/mount.conf
```

基本格式：

```ini
version=1
partition=YAWAsau
mount_point=/mnt/YAWAsau
fs=auto

mount=名稱|UserID|source|target|enabled|profile_group|profile_value|policy|create|migrate
```

欄位說明：

| 欄位 | 說明 |
| --- | --- |
| 名稱 | 顯示名稱，也用於通知與 WebUI |
| UserID | Android User ID，例如 `0`、`10` |
| source | 來源路徑；非 `/` 開頭時相對於 `mount_point` |
| target | 目標路徑；非 `/` 開頭時相對於 `/storage/emulated/<UserID>/` |
| enabled | `1` 啟用，`0` 停用 |
| profile_group | Profile 群組，可空白 |
| profile_value | Profile 值，可空白 |
| policy | `preserve`、`media_rw`、`bindfs_shared` |
| create | `1` 時自動建立目錄 |
| migrate | 目前建議使用 `none` |

相對路徑規則：

- `source` 不以 `/` 開頭：相對於 `mount_point`。
- `target` 不以 `/` 開頭：相對於 `/storage/emulated/<UserID>/`。
- 絕對 `target` 只允許 `/storage/emulated/<UserID>/...` 或 `/data/media/<UserID>/...`。
- `UserID` 必須存在；不存在會直接通知 `無此 User`。

## 通知行為

YAWAsau Mount 使用 Dex one-shot 通知，不使用 `cmd notification` fallback，也不常駐 Dex daemon。

通知場景：

- 開機後尚未解鎖：提示等待使用者解鎖後開始解密內置儲存。
- 偵測到解鎖：提示開始掛載。
- 掛載完成：例如 `掛載完成：6/6`。
- 掛載不完整：例如 `掛載不完全：3/6`，並列出異常掛載點。
- `mount.conf` 修改成功：提示新增 / 移除 / 套用結果。
- `mount.conf` 有錯：提示行號與原因，不需要翻 log 才知道問題。

## 建置需求

Windows 建置環境建議：

- Android SDK
- Android NDK r28c
- API 28
- MSYS2
- PowerShell 5.1 或更新版本
- JDK / Android Gradle 環境，用於編譯 Dex 通知程式

預設建置會重新編譯：

- static `bindfs`
- native `mount.fuse3` / `mount_fusefs`
- `classes.dex`

`magiskpolicy` 預設沿用包內 known-good binary。需要完整重編官方 Magisk source 時才使用 `-RebuildMagiskPolicy`。

## 建置方式

```powershell
cd .\source\build
.\build_yawasau_full_module_windows.ps1
```

輸出可刷模組 ZIP，例如：

```text
YAWAsau_Mount_v1.4.69_notify_result_preserve_parsed_module_20260825.zip
```

如需強制重編官方 Magisk source 的 `magiskpolicy`：

```powershell
.\build_yawasau_full_module_windows.ps1 -RebuildMagiskPolicy
```

## 常用命令

```sh
# 查看通知後端
su -c 'sh /data/adb/modules/dcimswitch/control.sh notify_backend'

# 發送通知測試
su -c 'sh /data/adb/modules/dcimswitch/control.sh notify_test'

# 查看目前狀態
su -c 'sh /data/adb/modules/dcimswitch/control.sh status'

# 手動重新套用設定
su -c 'sh /data/adb/modules/dcimswitch/control.sh reload'
```

## Debug 資料

主要 log / runtime 位於：

```text
/data/adb/dcimswitch/
/data/adb/dcimswitch/runtime/
/data/adb/dcimswitch/logs/
```

若回報問題，建議附上模組產生的 `dcimswitch.zip` debug 包。


## 安全說明

本模組會執行 root 掛載操作，錯誤設定可能導致目錄不可見、App 掃描異常或掛載點殘留。模組預設不覆蓋既有 `mount.conf`，設定錯誤時會保留最後有效設定，降低資料可見性被破壞的風險。

建議先用少量掛載點測試，確認 WebUI、通知與 App 可見性正常後再擴展設定。
