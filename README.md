# DSWorldRadar 1.1

《龙之剑：觉醒》1.1.1的探索雷达，适用于Steam／Windows x64。

收录1503个宝箱、147个区域任务、78个谜题和84个小游戏，并提供资源与动物标记。支持存档完成度同步、分类筛选和11种语言自动识别。谜题和小游戏的奖励宝箱已包含在宝箱总数中。

完整安装包：[GitHub Releases](https://github.com/Justin9609/DSWorldRadar/releases/tag/v1.1)。包含UE4SS和不包含UE4SS两个版本，安装其中一个即可。

## 仓库内容

这里保存了DSWorldRadar 1.1现有的源码、构建脚本和二进制审核资料，供维护和审核使用。**目前还缺少部分原生源码，无法从本仓库重建全部DLL。**

| 路径 | 内容 |
| --- | --- |
| [review/source](review/source/) | 现行PowerShell、C#、Lua源码，以及可取得的WCX C/H源码 |
| [review/reference_mod](review/reference_mod/) | 从不含UE4SS安装包中提取的完整MOD文件，供逐文件对照 |
| [review/build](review/build/) | 仅编译的构建脚本，不启动游戏或同步器 |
| [review/tests](review/tests/) | 留存的离线测试脚本和依赖说明 |
| [review/SOURCE_BINARY_MAP.json](review/SOURCE_BINARY_MAP.json) | 源码对应关系、5个DLL的哈希，以及缺失源码的组件说明 |
| [review/docs](review/docs/) | 构建依赖、实际运行行为和授权情况 |
| [docs/NEXUS_DESCRIPTION_ZH_EN.md](docs/NEXUS_DESCRIPTION_ZH_EN.md) | 中英文玩家说明，含安装方法和1.1更新内容 |

发布包中的8个脚本与源码文件均已收录，内容逐字节一致。`main.dll`、`main_original.dll`、`wcbridge.dll`、`dqbridge.dll`的完整源码或工程目前不可得。其中，`main_original.dll`是MnM Radar派生核心，原作者的C++源码已索取，尚未收到。

## 校验与构建

在干净的仓库目录中，使用Python 3运行以下命令，核对文件及源码对应关系：

```sh
python tools/verify_repository.py
python review/tools/verify_review_bundle.py
```

构建方法见[构建与依赖](review/docs/BUILD_AND_DEPENDENCIES_ZH_EN.md)。目前只能构建已有源码的组件。配套UE4SS为v3.0.1 Beta #0，提交`1c1a1497f942c707f47ba668db75b25e86f6c08a`；仓库中未附UE4SS本体。

本次整理核对了文件和源码对应关系，没有重新进行Windows构建或游戏内测试。仓库中的测试脚本和历史审核记录，仍按原有执行情况保留。

## 运行行为与已知限制

MOD会启动PowerShell/C#辅助程序，在本机编译同步器、读取本地加密存档，并访问游戏进程中的雷达状态。当前仍使用固定偏移访问和界面补丁，源码级替代尚未完成，详见[行为与授权说明](review/docs/BEHAVIOR_AND_PERMISSION_ZH_EN.md)。

无法识别当前存档时，可能会暂时读取最近写入的存档进度。11种语言的游戏内字体显示和长文本排版尚未逐一验证。公开反馈时，请勿附上存档数据库、解密缓存或私人邮件。

## 鸣谢与许可状态

DSWorldRadar基于**paroxis / MnM Radar**，经原作者授权独立发布，并继续使用点位和ID数据。后续维护与打包：**zouzx1996**。无需另行安装原版MnM Radar。

原作者建议重新实现所需功能，避免通过固定RVA修补其DLL，目前这部分替代尚未完成。邮件授权未被表述为通用开源许可，仓库也未统一采用MIT、GPL等许可证。具体说明见[许可状态](LICENSE_STATUS.md)和[第三方声明](review/release_metadata/THIRD_PARTY_NOTICES.txt)。私人邮件全文未公开。

---

# English

An exploration radar for **DragonSword: Awakening 1.1.1**, Steam / Windows x64.

Installation packages: [GitHub Releases](https://github.com/Justin9609/DSWorldRadar/releases/tag/v1.1).

Includes 1,503 chests, 147 local quests, 78 puzzles and 84 minigames, plus resource and wildlife markers. Features save-aware completion tracking, category filters and automatic selection across 11 languages. Puzzle and minigame reward chests are already included in the chest total.

## Repository contents

This repository preserves available sources and provides source/binary review materials for DSWorldRadar 1.1. **It is not a player installer or a complete C++ project capable of rebuilding every native DLL.**

- [review/source](review/source/): current PowerShell, C# and Lua sources, plus available WCX native C/H source.
- [review/reference_mod](review/reference_mod/): the complete mod payload from the current Without UE4SS installer for comparison.
- [review/build](review/build/): compile-only scripts.
- [review/tests](review/tests/): retained offline harnesses and dependency notes.
- [SOURCE_BINARY_MAP.json](review/SOURCE_BINARY_MAP.json): source correspondence, five DLL hashes and source gaps.
- [review/docs](review/docs/): build dependencies, actual runtime behavior and permission notes.
- [Player description](docs/NEXUS_DESCRIPTION_ZH_EN.md): bilingual installation instructions and integrated 1.1 changes.

All eight runtime source files are byte-identical to release 1.1. Full source/projects remain unavailable for `main.dll`, `main_original.dll`, `wcbridge.dll` and `dqbridge.dll`. The original author's C++ source has been requested but not received. The current native core retains MnM Radar-derived code.

## Verification and building

Run the two Python commands above in a clean checkout. See [Build and dependencies](review/docs/BUILD_AND_DEPENDENCIES_ZH_EN.md) for the available components. Not every native DLL can be rebuilt. The recorded UE4SS baseline is v3.0.1 Beta #0, commit `1c1a1497f942c707f47ba668db75b25e86f6c08a`; its runtime is not included here.

This preparation checked file integrity and source correspondence. It did not rerun Windows builds or in-game tests; retained tests are not represented as fresh executions.

## Runtime behavior and limitations

The mod launches PowerShell/C# helpers, compiles the save-sync helper locally, reads local encrypted saves and accesses radar state in the game process. Fixed-offset access and UI patches remain; source-level replacement is incomplete. See [Behavior and permission](review/docs/BEHAVIOR_AND_PERMISSION_ZH_EN.md).

When current-save identification is unavailable, progress may temporarily follow the most recently written save. Font coverage and long-text layout have not been individually verified in game for all 11 languages. Do not post save databases, decrypted caches or private correspondence in public reports.

## Credits and permission status

Based on **MnM Radar by paroxis**, continued as a standalone **DSWorldRadar** release with permission to reuse the node/ID data. Continued maintenance and packaging: **zouzx1996**. The original MnM Radar is not a separate installation requirement.

The original author advised reimplementation instead of fixed-RVA patching; that replacement remains incomplete. Private permission is not represented as a blanket open-source license. No repository-wide MIT/GPL license is asserted. See [License status](LICENSE_STATUS.md) and [Third-party notices](review/release_metadata/THIRD_PARTY_NOTICES.txt). Complete private emails are not published.
