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
