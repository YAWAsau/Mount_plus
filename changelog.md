# v1.4.95

掛載模塊自家原生工具統一為 Rust multicall，降低常駐程序與待機喚醒，保留既有掛載設定。

- 僅保留一份 mounttx ELF；confwatch、propwait、mount.fuse3、mount_fusefs 在安裝時建立為相對符號連結。
- 設定解析、狀態 JSON、程序與掛載身分、Profile 交易、來源恢復、FUSE helper 與事件監聽統一 Rust。
- 來源刪除／重建可觸發恢复；操作結果驗證來源身分與可見性，避免僅有掛載記錄就誤報成功。
- inotify、CE 屬性與必要時的使用者生命週期事件取代常態輪詢；健康待機保留一個 Rust 監聽程序。
- 保留媒體掃描保護與繁簡 WebUI，移除被取代的自家 C 源碼及舊獨立 watcher。
- NDK r30/API 28，ARM64，Rust ELF LOAD/RELRO 16 KiB 對齊。

驗證：4 個 Android 單元／交易測試，含私有 mount namespace、Profile 回滾、來源替換、外來掛載保護及真實 bindfs/FUSE；設定去重、來源重建與單例測試通過。主力機七個有效掛載曾完成冷開機與熱更新驗證；閒置 30 秒 CPU 增量為零。新符號連結佈局已在重開機後觀察到啟動，發布時 ADB 已斷線，未重跑完整冷開機掛載審核。

限制：副使用者完整生命週期、其他 ROM/API 28 實機及相簿／播放器私人資料庫跨重啟保留仍待驗證。部分 ROM 的 live SELinux 規則有既存套用警告；目前主力機掛載可見性驗證通過，不代表所有 ROM 規則皆成功。Shell 編排、第三方 bindfs/libfuse、magiskpolicy 與 Java 通知元件仍保留。
