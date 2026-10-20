# 构建与依赖

## C#存档同步器

source/dlls/sync/bootstrap.ps1会调用Windows自带的.NET Framework csc.exe，编译MnMChestSaveSync.cs。

审核时可通过build/Build_SaveSync.ps1单独编译。该脚本只生成EXE，不执行同步器或启动游戏，编译参数与现行bootstrap.ps1一致：

```text
/nologo /optimize+ /target:exe /platform:x64 /reference:System.Core.dll /reference:System.Xml.dll
```

运行时通过Windows的winsqlite3.dll读取本地存档进度，无额外NuGet依赖。

## WCX 2802辅助桥

现有源码为source/native/wcxbridge.c和wcx_resolver.h，resolver_test_api.c用于主机侧定位器测试。

历史构建记录使用Python的ziglang包提供的Zig 0.17.0，目标为x86_64-windows-gnu。build/Build_WCX.ps1保留了对应命令：

```sh
python -m ziglang cc -target x86_64-windows-gnu -O2 -shared -Wall -Wextra -Werror -Wl,--strip-all wcxbridge.c -o wcxbridge.dll
```

本次确认了留存构建产物与发布DLL完全一致，没有重新执行Windows构建。编译器或SDK不同，生成文件的字节也可能不同，因此不保证重新构建后得到相同哈希。

其余4个DLL缺少完整源码，暂时无法从本仓库重建。

## 脚本与UE4SS

运行环境为Windows PowerShell 5.1；原离线测试环境使用PowerShell 7.4.6。Lua文件由配套UE4SS直接加载。PS文件内的Add-Type C#代码仍保留在原脚本中。

配套加载器为UE4SS v3.0.1 Beta #0，提交1c1a1497f942c707f47ba668db75b25e86f6c08a。

上游项目：[RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)。本仓库未收录UE4SS源码，也不提供其源码重建工程。

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
