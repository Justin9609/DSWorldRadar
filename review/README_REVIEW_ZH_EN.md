# DSWorldRadar 1.1｜版主代码审核资料

对应游戏：《龙之剑：觉醒》1.1.1，Steam／Windows x64。
此目录用于源码和二进制审核，玩家安装包请到项目Releases下载。

## 审核入口

- source/：与发布包逐字节一致的PowerShell、C#、Lua源码，以及可取得的WCX 2802原生C/H源码。
- reference_mod/：从不含UE4SS安装包中原样提取的完整MOD文件，含5个DLL、数据和语言文件，供逐文件对照。
- SOURCE_BINARY_MAP.json：源码对应关系、原生组件说明和缺失源码的情况。
- build/：仅编译的构建脚本，不启动游戏或同步器。
- docs/：依赖、实际运行行为和授权说明。
- tests/：留存的离线测试脚本，执行情况见目录内说明。
- release_metadata/：两个正式安装包的名称、SHA-256和包信息。
- tools/verify_review_bundle.py：使用Python标准库检查文件校验和及源码对应关系。

## 源码完整性

已收录现行的8个运行源码文件，以及WCX 2802的C/H源码。

`main.dll`、`main_original.dll`、`wcbridge.dll`、`dqbridge.dll`的完整原生源码目前不可得。其中，`main_original.dll`是MnM Radar派生核心，原作者的C++源码仍未收到；其余3个组件的源码或工程，尚未在可取得的项目记录中找到。

因此，目前无法从这些资料重建全部原生DLL。缺失源码的组件保留了实际发布的DLL和哈希，供独立分析，没有用推测或重写的代码代替原始源码。

此目录不含游戏EXE、PAK、玩家存档、解密缓存、个人运行日志或私人邮件全文。UE4SS本体也未重复收录，所用版本、提交和哈希均已记录。

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
