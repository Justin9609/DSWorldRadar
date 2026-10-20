# DSWorldRadar 1.1 — 版主代码审核资料

对应游戏：《龙之剑：觉醒》1.1.1，Steam / Windows x64。
本包供代码和二进制审核使用，不是玩家安装包。

## 审核入口

- source/：与当前发布包逐字节一致的 PowerShell、C#、Lua 源码，以及可取得的 WCX 2802 原生 C/H 源码。
- reference_mod/：从当前不含 UE4SS 安装包原样提取的完整 MOD 文件，含五个现行 DLL、数据和语言文件，供对照分析。
- SOURCE_BINARY_MAP.json：源码对应关系、原生组件来源说明和源码缺口。
- build/：仅编译、不启动游戏或同步器的构建脚本。
- docs/：依赖、敏感行为和授权状态说明。
- tests/：现有离线测试脚本；本次未把此前测试算作新执行。
- release_metadata/：两个正式安装包的名称、SHA-256 和包信息。
- tools/verify_review_bundle.py：用 Python 标准库核对文件校验和及源码对应关系。

## 源码完整性说明

现行的 8 个运行源码文件已包含，WCX 2802 C/H 源码也已包含。
main.dll、main_original.dll、wcbridge.dll、dqbridge.dll 的完整原生源码目前不可得。
其中 main_original.dll 是 MnM Radar 派生核心，原作者的 C++ 源码仍未收到。
其余三个组件的源码/工程在目前可取得的项目记录中未找到；不将它们冒称为有完整源码的第三方或自编译组件。

因此，本包不能宣称为全部原生 DLL 均可重建的完整 C++ 工程。
没有用推测或重写代码冒充缺失源码。对应 DLL 原文件和哈希均保留供独立分析。

未包含游戏 EXE、PAK、玩家存档、解密缓存、个人运行日志或私人邮件全文。
UE4SS 本体未重复打入此包；所用版本、提交和哈希已记录。

---

# DSWorldRadar 1.1 — Source and binary review bundle

Target game: DragonSword: Awakening 1.1.1, Steam / Windows x64.
This is material for moderator review, not an installer.

## Starting points

- source/: byte-identical shipped PowerShell, C# and Lua sources, plus available WCX 2802 native C/H source.
- reference_mod/: the complete mod directory extracted unchanged from the current Without UE4SS installer, including five shipped DLLs, data and translations.
- SOURCE_BINARY_MAP.json: source correspondence, component descriptions and source gaps.
- build/: compilation-only scripts that do not launch the game or save-sync helper.
- docs/: dependencies, sensitive behavior and permission status.
- tests/: existing offline test harnesses. Earlier test results are not represented as new executions.
- release_metadata/: filenames, SHA-256 hashes and metadata of both public installation archives.
- tools/verify_review_bundle.py: standard-library Python verification of checksums and source correspondence.

## Source coverage and limitations

All eight current runtime source files and the WCX 2802 C/H source are included.
Full native source is currently unavailable for main.dll, main_original.dll, wcbridge.dll and dqbridge.dll.
main_original.dll is the MnM Radar-derived core; the original author's C++ source has been requested but not received.
Source/projects for the other three retained native components were not located in the available project records; no unsupported authorship or source-completeness claim is made.

This is therefore not a complete C++ project capable of rebuilding every native DLL.
Missing source has not been replaced with speculative code. Exact shipped binaries and hashes are retained for independent analysis.

No game executable, PAK, player save, decrypted cache, personal runtime log or complete private email is included.
The UE4SS runtime itself is not duplicated; its recorded version, commit and hash are included.
