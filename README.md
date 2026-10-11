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

## v1.4.93 修正與驗證範圍

- 引用 [ghjjvbjj 的 PR #3](https://github.com/YAWAsau/Mount_plus/pull/3) 的 WebUI 繁簡切換與 GitHub Actions 建置流程，保留繁體文件與 Shell；未加入自動改寫 main 的繁轉簡工作流。補上操作進行中切換語言與 localStorage 不可用的回歸測試。
- sourcewatch 以 inotify 監聽來源與父路徑的身分變更。來源刪除後不由監聽器立即重建；同一路徑恢復時要求重掛，父路徑替換與設定清單替換也會重新建立監聽。沒有固定間隔健康輪詢。
- 手動重掛不再因設定 hash 相同提早成功。核心 bind 舊 inode 以已保存的來源身分確認後卸載，避免移除不屬於模組的掛載。
- WebUI 狀態會核對來源身分與檔案可見性；來源不可寫而無法驗證時保守回報未通過，不再以目標目錄存在冒充正常。
- 媒體索引：來源重掛的空窗期不掃描底層空目錄；開機只針對掛載的媒體目錄排程，不再安排整個使用者儲存根目錄。發送前驗證 MediaProvider namespace 的映射。廣播送出不代表索引完成。
- 已通過 Android 17 隔離測試：來源／父目錄刪除重建、設定清單替換、內容寫入不觸發重掛、核心 bind 舊 inode 卸載與新來源映射、未知掛載保留、探測失敗、掃描條件及 mksh/ash 語法；WebUI Node 回歸測試通過。
- 尚未完成新版整機重開機與 Salt Player／相簿索引持久性實測。系統自行發起的掃描以及 App 私有音樂庫不受模組完全控制，不能保證既有 MediaStore ID、收藏或播放清單不變。
- 新增 sourcewatch、重建 mounttx，使用 NDK r30 30.0.16248370 / API 28 / ARM64 / 16 KiB。其餘 bin 沿用已發布 v1.4.92 成品，未重編 SMB。

安裝新版後請重開機，讓 sourcewatch 加入既有事件監聽管理程序。BUILD_KIT 含自有 C/Dex 源碼與建置配方，不是刷入包；filewatch、propwait 仍為預編譯檔，magiskpolicy 源碼需另行取得。


## v1.4.94 native core

掛載健康檢查、程序與 namespace 掃描、WebUI 狀態 JSON、設定解析及監聽器 supervisor 收斂到 `bin/mounttx`。Shell 保留安裝、通知、ROM 相容與交易流程。健康檢查和交易共用可見性探針，探針透過目錄 FD 清理，來源重命名也不遺留檔案。

配置最多 96 筆 mount/profile/dir，超長欄位與錯誤輸入會明確拒絕，不截斷後套用。監聽器健康時阻塞等待；只有異常退出才使用有上限的退避。程式仍以 NDK r30 / API 28 / ARM64 / 16 KiB 對齊建置。

`module.prop` 的 updateJson 指向最新正式 Release 的 `update.json`。版本與下載網址由實際 ZIP 的 module.prop 產生，預發布版不推送到穩定更新通道。GitHub Actions 在正式版發布後產生 update.json 與 changelog.md。
