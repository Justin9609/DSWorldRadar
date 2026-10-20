# 行为与授权说明

## 实际运行行为

- Lua和启动脚本会通过隐藏窗口启动PowerShell，并为子进程使用`-ExecutionPolicy Bypass`。该参数用于子进程，不会修改系统全局执行策略。
- bootstrap.ps1会在本机编译C#同步辅助程序，并启动或管理本MOD的同步进程。
- C#辅助程序包含现有存档解密参数，派生密钥后读取SQLCipher格式存档，在MOD缓存中处理临时解密副本，再通过winsqlite3.dll查询进度。
- live_chest_watcher.ps1内含通过Add-Type编译的C#代码，使用OpenProcess、ReadProcessMemory和WriteProcessMemory访问游戏中的雷达及完成状态。
- 语言脚本会更新雷达语言文件。现有原生整合仍使用固定偏移访问和界面补丁。
- WCX C源码包含运行时函数定位、VirtualAlloc/VirtualProtect和跳转补丁，用于取得游戏原生计数通知。

以上列出实际需要审核的行为，不作为安全软件豁免的依据。没有源码的DLL仅提供现行二进制及哈希，无法据此作出完整的源码行为说明。

## 与MnM Radar的关系

本MOD实际使用了MnM Radar派生原生核心，并非只引用算法。

原作者paroxis在邮件中同意以DSWorldRadar名义独立发布，要求保留MnM Radar署名，并允许沿用点位和ID数据。他也建议重新实现所需功能，避免通过固定RVA修补其DLL。目前源码级替代尚未完成，固定偏移访问和界面整合仍在使用。

原作者曾表示可以尝试公开源码，目前尚未收到C++源码。这份邮件授权未被表述为通用开源许可。

THIRD_PARTY_NOTICES.txt保留发布包中的原文，原MOD页面未被列为安装依赖。私人邮件全文未附入代码包。

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
