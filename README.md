# YAWAsau Mount v1.4.70 Fast Unlock Mount

修正 v1.4.68 測試後發現的通知與錯誤設定狀態問題：

- 無效 mount.conf 不再把 runtime/parsed 覆蓋成 root-only 空掛載表，保留上一個有效掛載快照。
- 手動 reload / WebUI 手動套用失敗也會發 Dex 通知，不必翻 log 才知道原因。
- mount.conf 成功通知標題直接顯示「新增掛載成功 / 移除掛載成功 / 更改成功 X/Y」。
- mount.conf 失敗通知標題直接顯示錯誤行號，例如「mount.conf 有問題：第65行」。
- config 語法錯誤時不再額外刷一條容易誤解的「掛載不完全」。
- Dex 仍為 one-shot app_process，無 daemon，無 cmd notification fallback。

完整重編：

```powershell
cd D:\download\YAWAsau_Mount_v1.4.70_pack_fast_unlock_mount_20260826\source\build
.\build_yawasau_full_module_windows.ps1
```

輸出：

```text
YAWAsau_Mount_v1.4.70_fast_unlock_mount_module_20260826.zip
```
