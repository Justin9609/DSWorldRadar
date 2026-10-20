# DSWorldRadar 1.1

《龙之剑：觉醒》1.1.1 的探索雷达，适用于 Steam / Windows x64。

收录 1,503 个宝箱、147 个区域任务、78 个谜题和 84 个小游戏，并提供资源与动物标记；支持存档完成度同步、分类筛选及 11 种语言自动识别。谜题和小游戏的奖励宝箱已包含在宝箱总数中。

## 仓库内容

本仓库用于维护现有源码，并为 DSWorldRadar 1.1 提供源码与二进制审核材料。**仓库不是玩家安装包，也不是可重建全部 DLL 的完整 C++ 工程。**

| 路径 | 内容 |
| --- | --- |
| [review/source](review/source/) | 现行 PowerShell、C#、Lua 源码及可取得的 WCX C/H 源码 |
| [review/reference_mod](review/reference_mod/) | 当前不含 UE4SS 安装包中的完整 MOD 文件，供逐文件对照 |
| [review/build](review/build/) | 只编译、不启动游戏或同步器的构建脚本 |
| [review/tests](review/tests/) | 留存的离线测试脚本与依赖说明 |
| [review/SOURCE_BINARY_MAP.json](review/SOURCE_BINARY_MAP.json) | 源码对应关系、五个 DLL 的哈希及源码缺口 |
| [review/docs](review/docs/) | 构建依赖、实际运行行为与授权情况 |
| [docs/NEXUS_DESCRIPTION_ZH_EN.md](docs/NEXUS_DESCRIPTION_ZH_EN.md) | 中英文玩家说明与合并的 1.1 更新内容 |

8 个运行源码文件与发布的 1.1 安装包逐字节一致。`main.dll`、`main_original.dll`、`wcbridge.dll`、`dqbridge.dll` 的完整源码/工程目前不可得。原作者的 C++ 源码已索取，尚未收到；现行原生核心仍包含 MnM Radar 派生代码。

## 审核与构建

使用 Python 3 在干净的仓库中核对文件与对应关系：

```sh
python tools/verify_repository.py
python review/tools/verify_review_bundle.py
```

构建方法见 [构建与依赖](review/docs/BUILD_AND_DEPENDENCIES_ZH_EN.md)。本仓库仅能构建已有源码对应的组件，不能从源码重建全部原生 DLL。配套 UE4SS 为 v3.0.1 Beta #0，提交 `1c1a1497f942c707f47ba668db75b25e86f6c08a`；UE4SS 本体未放入仓库。

本次整理完成了文件校验与源码对应检查，未重新执行 Windows 构建或游戏内测试。已有测试材料不代表本次重新运行。

## 运行行为与已知限制

MOD 会启动 PowerShell/C# 辅助程序，在本机编译同步器、读取本地加密存档，并访问游戏进程中的雷达状态。现行整合仍有固定偏移访问与界面补丁；源码级替代尚未完成。详情见 [行为与授权说明](review/docs/BEHAVIOR_AND_PERMISSION_ZH_EN.md)。

缺少当前存档识别信息时，进度可能暂按最近写入的存档刷新。全部 11 种语言的游戏内字体与长文本排版尚未逐一验证。请勿在公开反馈中附上存档数据库、解密缓存或私人邮件。

## 鸣谢与许可状态

基于 **paroxis / MnM Radar**，经原作者授权以 **DSWorldRadar** 名义独立发布，并继续使用点位与 ID 数据；后续维护与打包：**zouzx1996**。无需另行安装原版 MnM Radar。

原作者建议以重新实现代替固定 RVA 修补；当前版本尚未完成这项替代。私人邮件许可不被表述为通用开源许可证，本仓库没有为所有内容统一授予 MIT/GPL 等许可。见 [许可状态](LICENSE_STATUS.md) 与 [第三方声明](review/release_metadata/THIRD_PARTY_NOTICES.txt)。私人邮件全文未公开。

---

# English

An exploration radar for **DragonSword: Awakening 1.1.1**, Steam / Windows x64.

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
