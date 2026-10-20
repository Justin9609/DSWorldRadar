# 构建与依赖

## C# 存档同步器

运行 source/dlls/sync/bootstrap.ps1 时，游戏环境会调用 Windows 自带的 .NET Framework csc.exe 编译 MnMChestSaveSync.cs。
审核时可使用 build/Build_SaveSync.ps1 单独编译；此脚本不会执行生成的 EXE，也不会启动游戏。
编译参数与现行 bootstrap.ps1 对应：/nologo /optimize+ /target:exe /platform:x64 /reference:System.Core.dll /reference:System.Xml.dll。
运行时使用 Windows winsqlite3.dll，并读取本地存档格式。没有额外 NuGet 包。

## WCX 2802 辅助桥

source/native/wcxbridge.c 与 wcx_resolver.h 为可取得的现行源码，resolver_test_api.c 为主机定位器测试入口。
历史构建记录使用 Python ziglang 提供的 Zig 0.17.0，目标 x86_64-windows-gnu。
build/Build_WCX.ps1 保留对应命令：

python -m ziglang cc -target x86_64-windows-gnu -O2 -shared -Wall -Wextra -Werror -Wl,--strip-all wcxbridge.c -o wcxbridge.dll

编译器/SDK 差异可能改变输出字节；本次仅确认留存构建产物与发布 DLL 完全相同，没有宣称本轮重新执行 Windows 构建或保证可复现完全相同的 DLL。
其余四个 DLL 缺少完整源码，不能从本包重建。

## 脚本与 UE4SS

PowerShell 目标环境为 Windows PowerShell 5.1；离线测试脚本原使用 PowerShell 7.4.6。
Lua 文件由配套 UE4SS 加载，无单独编译步骤；PS 文件内的 Add-Type C# 实现已保留在原脚本中。
配套加载器为 UE4SS v3.0.1 Beta #0，提交 1c1a1497f942c707f47ba668db75b25e86f6c08a。
上游项目：https://github.com/UE4SS-RE/RE-UE4SS 。本包不提供或声称重建 UE4SS 源码。

---

# Build and dependencies

## C# save-sync helper

The shipped bootstrap.ps1 invokes the Windows .NET Framework csc.exe to compile MnMChestSaveSync.cs locally.
For review, build/Build_SaveSync.ps1 compiles it in isolation without executing the resulting EXE or launching the game.
Compiler flags match the shipped bootstrap: /nologo /optimize+ /target:exe /platform:x64 /reference:System.Core.dll /reference:System.Xml.dll.
Runtime SQLite access uses the Windows winsqlite3.dll. There are no additional NuGet dependencies.

## WCX 2802 auxiliary bridge

The available current sources are source/native/wcxbridge.c and wcx_resolver.h; resolver_test_api.c exposes the resolver to host tests.
The retained build record used Zig 0.17.0 through the Python ziglang package, targeting x86_64-windows-gnu.
build/Build_WCX.ps1 retains the command shown above.
Different toolchains or SDKs may change output bytes. This review preparation confirms the retained build artifact matches the shipped DLL; it does not claim a fresh Windows build or guarantee bit-for-bit reproducibility.
The other four native DLLs cannot be rebuilt from this bundle because full source is unavailable.

## Scripts and UE4SS

The runtime PowerShell target is Windows PowerShell 5.1; prior offline harnesses used PowerShell 7.4.6.
Lua is loaded by the matching UE4SS runtime without a separate compile step. Inline C# Add-Type code remains inside its original PS files.
The bundled runtime baseline is UE4SS v3.0.1 Beta #0, commit 1c1a1497f942c707f47ba668db75b25e86f6c08a.
Upstream: https://github.com/UE4SS-RE/RE-UE4SS . This bundle does not include or claim to rebuild UE4SS source.
