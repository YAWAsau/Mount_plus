# YAWAsau Mount v1.4.92 — 恢復出廠後的 media_rw 權限修復

## 模組修正

- `media_rw` 現在處理來源樹的目錄與一般檔案，修復保留分區中的舊 App UID、私人 mode 與 SELinux 類別；不再只修根目錄。
- 統一 owner/group 為 `media_rw:media_rw`，目錄 `2770`，一般檔案 `660`；已有執行位元的檔案保留 user/group 執行權限，移除其他使用者權限與特殊權限位元。SELinux 標籤為 `u:object_r:media_rw_data_file:s0`。
- 排除子項符號連結、巢狀掛載（含同檔案系統 bind mount），以及設定中位於來源樹內的 `preserve`／`bindfs_shared` 來源。首次修復只讀寫 metadata，不改檔案內容。
- 成功紀錄存於 `/data/adb/dcimswitch/permission-state`，依來源路徑、device/inode、MediaProvider UID、排除項目與修復規則版本判斷是否可沿用。恢復出廠清除紀錄、來源重建或 MediaProvider UID 改變時會重跑。
- 正常重載只核對快取與根目錄 metadata；不新增常駐程序或待機輪詢。首次修復會遍歷來源，所需時間取決於檔案數。
- 修復失敗不保留成功標記，錯誤傳回掛載／Profile 預檢；重試不會被「設定沒變」誤報成功。`migrate=once` 搬入舊資料後也會修復該來源。
- `mount.conf` 原內容保持原樣；新範例已更新 `media_rw` 的語意。既有設定中的舊註解不會被自動改寫。

已完成快取後，若手動搬入帶私人權限的舊資料，可以在 root shell 明確重跑：

```sh
sh /data/adb/modules/dcimswitch/control.sh repair_permissions
```

日誌在 `/data/adb/dcimswitch/runtime/mount.log`，包含 `MEDIA_REPAIR_BEGIN`、`DONE`、`CACHED` 或 `FAILED`。不需為了修復設定持續掃描檔案。

## 建置與驗證

- 原生 ELF 與 Dex 沿用 v1.4.89，本版修改 Shell。完整建置仍使用 `source/build/build_yawasau_full_module_windows.ps1`。
- 新增可獨立執行的 `source/tests/permissions_smoke.sh`，在自行建立的 `/data/local/tmp/yaw-permission-test-*` 中測試；不會執行使用者的備份腳本。
- CPH2747／Android 17 隔離回歸已通過：舊 UID／mode／context、內容保持、既有執行位元、換行檔名、含 glob 字元的排除路徑、符號連結／巢狀 bind 排除、快取、明確強制修復、失敗後移除標記與重試、模擬 userdata 狀態重置、系統根目錄拒絕、preserve 與錯誤傳遞。
- 正式備份腳本目前正在執行，本版採 KernelSU 待重啟安裝。完整正式來源修復與真實重開機尚未驗證；下方 v1.4.91 的開機驗證屬於舊版。

---

# YAWAsau Mount v1.4.91 — Shell 解析修復 / 解鎖事件恢復

2026-10-06，修復 v1.4.90 在主力機 CPH2747／Android 17 實際開機時暴露的相容性回歸。

- 根因：v1.4.90 的 `setsid sh` 子程序選中了 Android mksh；既有 `${value%%|*}`／`${value#*|}` 寫法在 mksh 將 `|` 視為樣式分支，導致 `dir=` 的路徑變成空字串、`profile=` 的群組／選項分割錯誤。同一份設定在 KernelSU ash 可正常解析。
- 掛載、通知及解鎖重試子程序統一沿用明確的 KernelSU BusyBox ash，並設定 standalone 工具環境；保留 setsid 與鎖描述符隔離。
- `dir` 與 `profile` 分割中的 `|` 加上引號，Android mksh 與 ash 都能正確解析。
- `validate`／`dryrun` 不再用上一輪快取把本次解析失敗改報成功；正式掛載的最後有效設定保留機制不變。
- 此版本只修改 Shell；原生 ELF、Dex 與使用者的 live `mount.conf` 保留。

建置：`./source/build/build_yawasau_full_module_windows.ps1`。
已有原生及 Dex 建置輸出時可重新打包：`./source/build/build_yawasau_dex_notify_module_windows.ps1 -PackOnly`。
成品：`YAWAsau_Mount_v1.4.91_event_recovery_ndkr30_api28_20261006.zip`。

v1.4.90 的隔離監聽測試未涵蓋完整設定解析與實際子程序 shell，因此未攔下此次回歸。

### v1.4.91 實機驗證（CPH2747／Android 17）

- Android mksh 與 KernelSU ash 都正確解析 7 個掛載項目、3 個目錄及 `camera=work`；解析輸出逐檔相同。
- 多餘欄位與路徑穿越設定會被拒絕；有舊快取時，本次解析失敗仍回傳失敗。
- 兩種 Shell 的隔離測試通過：程序身分、鎖爭用逾時／退出釋放、監聽子程序退出後重啟與停止、一次性監聽正常完成。
- 套用後重走完整服務啟動入口，12 秒完成、回傳 0；核心掛載逐項核對 **7/7**，四項事件監聽就緒檢查通過。live `mount.conf` 的 SHA256 與修復前相同。
- **真實重開機與首次解鎖已通過（2026-10-06）。** boot ID 已更換，開機清除舊掛載快取；未解鎖時正常延後 7 項。18:45:17 收到 User 0 CE 解鎖事件，18:45:22 自動完成 7/7，失敗 0、等待 0；沒有執行手動 reload。
- 重開後逐項核對核心掛載、手機儲存可見性紀錄及本次 boot ID 的監聽程序身分；20 個已安裝腳本／執行檔 SHA256 與交付內容一致，live 設定 SHA256 未變。背景 App namespace 同步於 18:45:38 完成。
- 此實測涵蓋主力機 CPH2747／Android 17 的一次重開機與 User 0 首次解鎖；其他 ROM／使用者及長期待機仍屬不同驗證範圍。

下方內容是版本歷史。

---

# v1.4.90 歷史紀錄 — 解鎖事件恢復 / Liquid Glass / NDK r30

2026-10-06，基於 v1.4.89，修補解鎖後掛載仍停在等待狀態的監聽管理缺口。

## 本次修正

- `service.sh` 與 `core.sh` 共用 CE 解鎖判斷：先讀 `sys.user.<id>.ce_available`，缺少屬性時再讀 `am get-started-user-state`。這台 Android 17 裝置不支援的 `cmd user is-user-unlocked` 只保留為其他系統的後備。User 0 不會只因目錄存在就判定解鎖。
- 啟動確認包含本次 boot ID、PID 與程序啟動時間；成功寫 PID 檔不再等同「監聽器已就緒」。確認逾時會記錄錯誤並回傳非零狀態。
- `watchers.sh` 以阻塞 `wait` 管理 confwatch、User lifecycle、CE property 與儲存路徑監聽器。監聽程序退出時記錄結束碼並退避重啟；兩個一次性監聽正常完成後退出。
- `setsid` 隔離監聽程序與啟動它的 session；掛載交易另有 session，監聽器重啟不會中斷正在提交的掛載。
- 解鎖掛載使用 `flock` 去重，程序退出後由核心釋放鎖；不把鎖描述符留給常駐 bindfs 子程序。多個解鎖訊號同時到達時，後到者會等待前一次結果。
- 鎖等待使用 Toybox 的 `flock FD`／`flock -n FD`，爭用時以 `timeout` 限制等待時間；不使用 Android Toybox 沒有的 `flock -w`。參考：[Toybox flock 原始碼](https://github.com/landley/toybox/blob/master/toys/other/flock.c)。
- 外部鎖工具使用明確的檔案描述符重導向，適用於 Android mksh 的 close-on-exec 行為；這項相容性問題已在主力機隔離測試中重現並修正。
- KernelSU `boot-completed.sh` 增加一次補查，與正常 `service.sh` 透過啟動鎖協調。啟動或重建 lifecycle 監聽時，也補接「已解鎖、尚有未掛載項目」的狀態。
- 安裝保留 live `mount.conf` 與當下 runtime，不會刪除使用中的交易鎖或從 `modules_update` 啟動暫存路徑的服務。**刷入後須重開機。**
- `control.sh log` 包含 `watchers.stderr.log`；啟動、停止與重啟指令會回傳實際結果。

### 待機與適用範圍

新增的管理程序在健康時阻塞等待子程序退出，沒有固定健康檢查輪詢。只有啟動確認、事件處理、失敗退避及手動停止使用有限等待；原生 confwatch 原有的內容變更偵測機制保留。會多出休眠的管理程序，不能把它描述為絕對零功耗。

本次舊版日誌顯示：初始掛載正常延後 7 項、服務聲稱監聽已啟動，但未留下真正的監聽啟動紀錄；之後觀察不到相應監聽程序。重開機後同一設定恢復 7/7。**尚無證據確定第一次程序消失的原因。** 此修正針對已確認的啟動確認及退出恢復缺口。

如果管理程序和監聽器都被外部工具強制終止，這版沒有永久輪詢器替它們重啟；開機補查或手動 `control.sh restart_service` 才會重新建立。卡住而尚未退出的程序也不會單憑 PID 被判定為故障。

### 交付狀態

本包製作時已在主力機 CPH2747／Android 17 通過 mksh 與 KernelSU ash 的腳本語法檢查及隔離測試：程序身分辨識、鎖爭用逾時與程序退出釋放、監聽子程序退出重啟與停止、一次性監聽正常完成。唯讀 CE 解鎖判斷亦符合當時的已解鎖狀態。隔離測試使用暫存目錄與自行建立的 sleep 程序。

**此打包階段尚待刷入後的真實開機／解鎖掛載驗證。** 可刷包沿用 v1.4.89 的原生 ELF 與 classes.dex，沒有重新編譯原生元件。下方 v1.4.89 的編譯／驗證紀錄屬於舊版，不能當成本版實測結果。

## Windows 建置 v1.4.90

```powershell
./source/build/build_yawasau_full_module_windows.ps1
```

完整重建後產出 `YAWAsau_Mount_v1.4.90_event_recovery_ndkr30_api28_20261006.zip`。完成一次原生／Dex 建置後，若只修改 Shell，可使用既有 `native_out` 和 `bin/classes.dex` 重新打包：

```powershell
./source/build/build_yawasau_dex_notify_module_windows.ps1 -PackOnly
```

可刷包的 `NATIVE_SHA256SUMS.txt` 記錄實際 bin 內容；來源包的 `BUILD_INFO.json` 說明交付成品的元件來源及尚未完成的驗證。來源包包含既有 native／Dex 來源及建置腳本、依賴原始碼壓縮檔，以及 filewatch／propwait／magiskpolicy 等沿用元件；不含 Gradle 快取、建置輸出或裝置日誌。

---

# v1.4.89 歷史紀錄 — Liquid Glass / NDK r30

2026-10-05，基於 v1.4.88，保留 Profile marker 與通知去重流程。

- WebUI：高通透毛玻璃、28px 背景模糊、藍綠／淡紫漸層、反光邊緣；深淺色、窄螢幕、鍵盤焦點、減少動態與無模糊支援時的實色備援。
- 原生目標：NDK r30 **30.0.16248370**、`aarch64-linux-android28`、16 KiB LOAD alignment。
- 重建：bindfs + 靜態 libfuse3、mount.fuse3 / mount_fusefs、mounttx、confwatch。bindfs / mounttx / mount.fuse3 沿用 Android 動態 PIE；confwatch 為無 libc 靜態 ELF。
- confwatch 增加 `-ffreestanding -fno-builtin`，避免 r30 把字串迴圈轉成不存在的 libc strlen。
- 通知 Dex 由此包 Java/Kotlin 來源重建；Windows 建置自動使用 ASCII 暫存目錄，避免 AIDL 中文路徑問題。
- filewatch、propwait 缺少對應來源，沿用原包；magiskpolicy 沿用原包，官方重建選項仍使用上游 ONDK。這三項不是 r30 重編產物。
- 原生 C 原始碼與 WebUI 的操作 JavaScript 均未修改。Shell 功能保留，只更新版本標記。

## Windows 建置

安裝 NDK `30.0.16248370`、Android SDK（API 34 供 Dex 編譯）、JDK 17+、MSYS2 及原配方所需工具後：

```powershell
./source/build/build_yawasau_full_module_windows.ps1
# 非 SDK 預設位置可傳入：
./source/build/build_yawasau_full_module_windows.ps1 -NdkRoot 'C:/Android/android-ndk-r30'
```

API 28 是原生編譯目標；Dex compileSdk 34 保留原設定，兩者用途不同。
原生依賴壓縮檔含在來源包 third_party 中並以 SHA256 驗證；Gradle 依賴首次使用仍需下載。
產物是根目錄 `YAWAsau_Mount_v1.4.89_liquid_glass_ndkr30_api28_20261005.zip`。
可刷 ZIP 包含必要 classes.dex 與 mounttx；原始 v1.4.88 輸入則是缺少這兩個產物的建置包。
`BUILD_INFO.json` 記錄實際工具鏈；`NATIVE_SHA256SUMS.txt` 只列出實際打包的 bin 檔案。

## 驗證範圍

本機編譯、ELF 檢查與 ZIP/雜湊驗證；Chromium 模擬 KSU API 預覽深淺色、窄螢幕、Profile 與日誌操作。
未安裝到手機，未宣稱 Android 9 實機相容性或掛載／通知端到端測試通過。

---

以下是原版本歷史說明：

# YAWAsau Mount v1.4.88-profile-notify-gate

保留 v1.4.86 native source-refresh 與 v1.4.87 Profile internal marker。修復 v1.4.87 仍可能在 Profile 切換後出現 `掛載完成 ... 已移除：日常/工作` 的通知覆蓋：`confwatch` 觸發的 `reload config_event` 即使最後只得到 `duplicate_config_event`，`service.sh` 之前仍會無條件呼叫 `notify_config_result`。本版在 service 層與 core 通知層都加 gate：`profile_change` / `duplicate_*` 不再發一般 mount summary / config apply result。

保留行為：
- Profile 切換成功只發 `Profile 已切換：camera｜old → new`。
- 手動 reload、開機、一般 mount.conf 新增/修改仍保留結果通知。
- 真正停用/刪除 QQ/TG 這類掛載項時，保留獨立移除通知。
- 不改 `mounttx` / `confwatch` / Dex / bindfs。

# YAWAsau Mount v1.4.87-profile-confwatch-race-dedup

保留 v1.4.86 native source-refresh。修復 Profile 切換時 `mounttx` 已成功、但 native `confwatch` 可能先於 `APPLIED_HASH/config.state` 提交捕捉到內部 `mount.conf` rename，導致又跑一次 config apply 並顯示「掛載完成 ... 已移除：日常/工作」的競態。v1.4.87 會在 Profile 發佈 `mount.conf` 前寫入內部 marker，service 看到相同 hash 時等待 foreground profile commit，成功後只 refresh card，不再重複通知。

# YAWAsau Mount v1.4.86-native-source-refresh-reapply

保留 v1.4.85 的 fast reapply 修復，並把 source inode refresh / core reapply 熱路徑下沉到 `mounttx`。當 `/data/speed_debug` 這類 bindfs_shared source 在掛載狀態下被刪除重建時，Shell 只負責偵測 dev:ino 變化與提交狀態；實際 core namespace 卸載、bindfs/FUSE target teardown、重掛與可見性 probe 由 `mounttx source-refresh` 執行。

## 重點

- 新增 `mounttx source-refresh --rows FILE`。
- C 端處理 core namespace unmount/mount。
- C 端處理 bindfs_shared 目標相關 bindfs 進程清理。
- C 端執行 visible probe retry。
- App namespace 仍維持 generation-fenced background sync，不阻塞 KSU/WebUI 重新套用。
- `mount.conf` parser、WebUI、通知、狀態提交仍在 Shell。

## 編譯

本版改動 `source/mounttx.c`，需要使用 Android NDK r28c/API28 重新編出 `bin/mounttx`。

```powershell
cd .\source\build
.\build_yawasau_full_module_windows.ps1
```

若只驗證 mounttx：

```powershell
cd .\source\build
.\build_yawasau_mounttx_only_windows.ps1
```

## 測試

```sh
su
rm -rf /data/speed_debug
mkdir -p /data/speed_debug
echo ok > /data/speed_debug/recreated.txt
sh /data/adb/modules/dcimswitch/control.sh reload
```

預期 log 會看到 `source-refresh native transaction 開始`、`source-refresh native 重建完成`，且 `/storage/emulated/0/虛擬分區/speed_debug` 不需要重開機即可恢復。

---

# YAWAsau Mount v1.4.85-source-refresh-core-only-fast-reapply

保留 v1.4.84 的 source inode last-good refresh。修復 KSU / WebUI「重新套用掛載」在 `/data/speed_debug` 掛載中被刪除重建後耗時過久：source-inode repair 前景路徑改為 core namespace / MediaProvider-only 重掛，不再掃所有 App namespace；bindfs_shared 的 target 相關 FUSE 進程只在整個 unmount 流程最後殺一次，避免每個 namespace 重複掃 `/proc`。App namespace 仍由既有 generation-fenced background sync 補同步。

# YAWAsau Mount v1.4.84-source-inode-lastgood-refresh

保留 v1.4.83，補強 /data/speed_debug 這類 source 目錄被刪除重建後的 same-hash 修復路徑：manual/webui reload 也會檢查 source inode；若 live mount.conf hash 等於最後成功套用值但 parser 出現短暫/異常失敗，會使用 last-good parsed 快照執行來源重掛，不再污染 config.state。

# YAWAsau Mount v1.4.83

- 保留 v1.4.81 主線。
- 新增 `vendor_gallery_quiesce=auto|off|force`。預設 `auto`。
- Profile 切換 DCIM 前，若偵測到 HyperOS/MIUI 相簿相關 package，會先 force-stop 其背景分析進程，避免同一路徑切換來源後相簿瘋狂重新載入。
- 不改 mounttx/confwatch/bindfs/classes.dex native binary。

# YAWAsau Mount v1.4.73 Profile Namespace Generation Fence

本版以 v1.4.71 為基底，保留卸載後 visible target 權限恢復與 mount.conf transient parse retry，修復連續快速切換 Profile 後可能整個 target 未掛載。

## v1.4.73 修正

- Profile 前景交易仍只同步核心 namespace，維持快速切換。
- 背景 namespace 補同步改成 **App-only**：不再卸載或重掛 init、MediaProvider、system_server、zygote、externalstorage、vold、sdcard 等核心 namespace。
- 新增 namespace generation fence：每次新的 apply/Profile transaction 都會使舊背景 worker 立即過期，避免 `daily -> work` 的背景尾巴覆蓋後續 `work -> daily`。
- Profile 背景 worker 先複製 immutable old/new row snapshot，避免前景 cleanup 太早刪除 temporary row file。
- Profile 失敗 rollback 最多重試 3 次並驗證 `row_mounted` / visible target；不再無條件宣稱「已回復」。
- `bindfs_shared` 維持 v2/static 設計，只在 init + MediaProvider namespace，不注入一般 App namespace。
- Dex / native C source 均未改；full hotfix 沿用 v1.4.71 known-good binaries。

## Windows 完整重編

```powershell
cd D:\download\YAWAsau_Mount_v1.4.73_pack_profile_ns_generation_fence_20260830\source\build
.\build_yawasau_full_module_windows.ps1
```

預期輸出：

```text
YAWAsau_Mount_v1.4.73_profile_ns_generation_fence_module_20260830.zip
```


## v1.4.76 build verify fix

v1.4.76 only fixes the Windows native build verifier gate for `bin/mounttx`: Android NDK r28c links `mounttx` with `libdl.so` in addition to `libc.so`, matching the local build transcript. The verifier now allows `libc.so,libdl.so` for `mounttx` in both full native build and mounttx-only build. Runtime native profile transaction logic is unchanged from v1.4.74.

## v1.4.74 native profile transaction

v1.4.74 adds `source/mounttx.c` and makes foreground Profile switching native-only once the module is built with `bin/mounttx`.

Scope moved into C:
- kernel bind profile transaction
- bindfs_shared profile transaction
- core namespace unmount / mount
- bindfs_shared MediaProvider/init namespace orchestration
- visible probe retry
- rollback old profile mapping
- namespace generation fence check

Shell remains responsible for:
- mount.conf parse/schema migrate
- WebUI/Action
- Dex one-shot notifications
- config state / parsed / active file publishing
- media scan scheduling

Build on Windows with Android NDK r28c/API28:

```powershell
cd .\source\build
.\build_yawasau_full_module_windows.ps1 -NdkRoot "<AndroidSdk>\ndk\28.2.13676358" -Api 28 -PageSize 16384
```

The flashable package produced by the build must contain:

```text
bin/mounttx
bin/bindfs
bin/mount.fuse3
bin/mount_fusefs
bin/classes.dex
```

Fast path when bindfs / mount.fuse3 / classes.dex are unchanged and only mounttx must be built:

```powershell
cd .\source\build
.\build_yawasau_mounttx_only_windows.ps1 -NdkRoot "<AndroidSdk>\ndk\28.2.13676358" -Api 28 -PageSize 16384
```


## v1.4.76 修正

- 修正安裝腳本未將 `bin/mounttx` 設為 0755，導致 WebUI/Profile 切換報「缺少 native mounttx」。
- `service.sh` 新增開機自修：若 `bin/mounttx` 存在但不可執行，會自動 `chmod 0755`。
- Profile native transaction、`bindfs_shared` orchestration、rollback/probe 邏輯沿用 v1.4.75，不改掛載策略。


## v1.4.83

- 新增 source inode remount guard。
- 對 active 掛載記錄來源目錄 dev:inode。
- 若來源路徑在掛載中被刪除後重建，下一次 reload 會強制卸載舊 bind/bindfs、清理舊 bindfs 進程並重新掛載。
- 修復 `/data/speed_debug` 掛到 `/storage/emulated/0/虛擬分區/speed_debug` 時，刪除並重建 `/data/speed_debug` 後必須重開機才能恢復的邊界問題。
- C/native binary 未改。
