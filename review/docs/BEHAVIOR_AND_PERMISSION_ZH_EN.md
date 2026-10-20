# 行为与授权说明

## 需要审核的实际行为

- Lua/启动脚本会以隐藏窗口启动 PowerShell，并为子进程使用 -ExecutionPolicy Bypass；不是修改系统全局执行策略。
- bootstrap.ps1 在本机编译 C# 同步辅助程序，并启动或管理本 MOD 的同步进程。
- C# 辅助程序包含现有存档解密参数，派生密钥后读取 SQLCipher 格式存档，在 MOD 缓存中处理临时解密副本，并通过 winsqlite3.dll 查询进度。
- live_chest_watcher.ps1 包含 Add-Type C# 代码，使用 OpenProcess、ReadProcessMemory、WriteProcessMemory 访问游戏中的雷达和完成状态。
- 语言脚本会更新雷达语言文件；现有原生整合包含固定偏移访问和界面修改。
- WCX C 源码包含运行时函数定位、VirtualAlloc/VirtualProtect 及跳转补丁，用于取得游戏原生计数通知。

以上为审核对象说明，不是安全软件豁免请求。对于没有源码的 DLL，仅提供当前二进制及哈希，不作缺乏依据的完整源码行为声明。

## MnM Radar 关系

本 MOD 实际包含 MnM Radar 派生原生核心，并非仅引用算法。
原作者 paroxis 在维护者提供的邮件中同意以 DSWorldRadar 名义独立发布，要求保留 MnM Radar 基础署名，并允许使用点位和 ID 数据。
原作者也建议不要通过固定 RVA 修补其 DLL，而应重新实现所需功能；当前源码级替代尚未完成，固定偏移/界面整合仍存在。
原作者曾提出可尝试公开源码；目前尚未收到 C++ 源码。此许可不被表述为通用开源许可证。
THIRD_PARTY_NOTICES.txt 与发布包保持原样；没有把原 MOD 页面列为依赖链接。
完整私人邮件未附入本代码包，避免夹带不必要的个人通信内容。

---

# Behavior and permission notes

## Actual behavior requiring review

- Lua/bootstrap code launches hidden PowerShell child processes with -ExecutionPolicy Bypass; this is not a global execution-policy change.
- bootstrap.ps1 compiles the C# helper locally and starts/manages this mod's synchronization processes.
- The C# helper includes existing save-decryption parameters, derives a key, reads SQLCipher-format saves, processes temporary decrypted copies in the mod cache and queries progress through winsqlite3.dll.
- live_chest_watcher.ps1 includes inline Add-Type C# using OpenProcess, ReadProcessMemory and WriteProcessMemory to access in-game radar/completion state.
- Language code updates radar language files. Existing native integration includes fixed-offset access and UI modifications.
- The WCX C source contains runtime function resolution, VirtualAlloc/VirtualProtect and jump patches for native completion notifications.

These are review disclosures, not a request for antivirus exemption. Components without source are supplied as exact current binaries with hashes; no unsupported full source-level behavior claim is made for them.

## Relationship to MnM Radar

This mod includes a MnM Radar-derived native core; it is not merely an algorithm reference.
In correspondence supplied by the maintainer, paroxis approved a separate DSWorldRadar release with credit to MnM Radar and permitted reuse of the node/ID data.
The author also advised reimplementation instead of fixed-RVA patching of his DLL. That source-level replacement is not complete, and fixed-offset/UI integration remains.
The author offered to look into making source public, but the C++ source has not been received. The private permission is not represented as a blanket open-source license.
THIRD_PARTY_NOTICES.txt is retained unchanged. The original mod page is not presented as a required dependency.
Complete private correspondence is not included to avoid attaching unnecessary personal communication.
