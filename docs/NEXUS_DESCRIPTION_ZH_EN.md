**DSWorldRadar 1.1｜中文说明**

DSWorldRadar是《龙之剑：觉醒》的探索雷达MOD，可显示宝箱、探索活动、资源和动物等标记，支持分类筛选，并根据存档和游戏事件同步宝箱及已支持活动的完成状态。

**GitHub下载与源码**

- 完整安装包：[DSWorldRadar 1.1下载页（适配游戏1.1.1）](https://github.com/Justin9609/DSWorldRadar/releases/tag/v1.1)。包含UE4SS和不包含UE4SS两个版本，安装其中一个即可。
- 现有源码与审核资料：[GitHub项目仓库](https://github.com/Justin9609/DSWorldRadar)。各组件的源码情况及缺失部分见仓库README。

**版本与运行要求**

- MOD版本：**1.1**。
- 适配游戏版本：**1.1.1**，Steam／Windows x64。
- 配套UE4SS：实验版**v3.0.1 Beta #0**，提交**1c1a1497**，采用嵌套目录结构。
- 运行需要Windows PowerShell、.NET Framework自带的C#编译器，以及MOD目录的写入权限。存档同步程序会在首次启动时自动编译，无需安装Python。

游戏版本按Steam10月15日发布的1.1.1更新公告标注。包内GAME_VERSION_ZH_EN.txt记录了所核对的运行文件信息；文件属性中的5.3.2.0对应UE引擎版本。其他UE4SS版本的兼容性尚未验证。

**主要功能**

- 收录**1503个探索宝箱**和**147个区域任务**。
- 84个小游戏：飞行34个、地鼠40个、波动10个。
- 78个谜题：踏板48个、滑块29个、石像1个。
- 可标记食材、矿石、结晶、动物及其他兴趣点。
- 载入或切换存档后，刷新宝箱及已支持活动的完成状态。
- 支持分类筛选、雷达总开关，以及显示距离、标记大小和文字设置。
- 支持11种文本语言，可自动识别游戏语言。

以上数字是各类内容的收录总数。谜题和小游戏的奖励宝箱已包含在1503个宝箱中。

**1.1更新内容**

- 适配游戏1.1.1，更新宝箱数据，校正部分点位坐标。
- 改进不同存档之间的完成度同步，以及读档、切换存档后的刷新。
- 改进宝箱和区域任务的完成状态识别。
- 调整自动保存、事件处理和失败重试，提高同步稳定性。
- 整理后台同步和日志管理，移除不再使用的辅助文件。
- 统一安装包命名与中英文说明，保留11种语言和自动识别。

**下载选择**

两个版本的雷达功能相同，安装其中一个即可：

- **包含UE4SS：**DSWorldRadar_v1.1_Game_v1.1.1_With_UE4SS.zip。适合尚未安装UE4SS的玩家，包含配套加载器和雷达启用配置。
- **不包含UE4SS：**DSWorldRadar_v1.1_Game_v1.1.1_Without_UE4SS.zip。适合已安装兼容UE4SS的玩家，沿用现有加载器及MOD配置。

**安装与更新**

1. 完全退出游戏，解压所选压缩包。
2. 将包内的**DS**文件夹合并到游戏根目录下已有的DS文件夹。
3. 最终安装位置应为：

DS/Binaries/Win64/ue4ss/Mods/DSWorldRadar/

合并后检查目录层级，避免出现DS/DS或ue4ss/ue4ss。已安装UE4SS的玩家更新时，请选不包含UE4SS版，并保留现有设置和进度缓存。

使用不包含UE4SS版时，需要在现有加载配置中启用DSWorldRadar。若使用ue4ss/Mods/mods.txt，添加或修改以下一行，并保留其他条目：

DSWorldRadar : 1

如果使用mods.json，在原有配置中添加或启用DSWorldRadar，并保留其他MOD条目。启动前，请停用原版MnMRadar和重复安装的DSWorldRadar。**无需另行安装原版MnM Radar。**

**使用方法**

载入存档后按**ESC**，点击菜单底部的**Radar／雷达**，即可打开面板。在面板中选择分类，并调整显示距离、标记大小和文字设置。所有语言下的面板标题均为**DSWorldRadar**。

**语言支持**

韩语、英语、日语、简体中文、繁体中文、德语、法语、西班牙语、巴西葡萄牙语、俄语和泰语。

游戏中已有对应文本的名称，沿用相应语种的游戏原文；雷达自定义界面文字单独翻译。自动识别优先读取游戏保存的文本语言，再依次检查启动参数、配置中的语言文本和Steam语言；无法识别支持的语言时使用英文。

更改游戏文本语言后，需要完全退出并重新启动游戏。韩语、日语、德语、西班牙语、巴西葡萄牙语、俄语和泰语的原生总开关目前仍显示OFF／ON。11种语言的游戏内字体显示和长文本排版尚未逐一验证。

**同步与兼容说明**

读档、切换存档或自动保存后，同步可能稍有延迟。无法识别当前存档时，可能会暂时读取最近写入的存档进度。如果显示与实际进度不符，请附上相关日志反馈。

**存档访问与技术说明**

MOD会启动PowerShell／C#同步程序，读取本地加密存档，并在MOD缓存目录内处理临时解密副本；同时读写游戏进程中的雷达状态。这些进程访问、脚本执行和本机编译操作，可能触发安全软件的启发式提示。

原生核心尚未重写，当前仍使用固定偏移访问和界面补丁。

**关于MnM Radar与鸣谢**

DSWorldRadar基于**paroxis**制作的**MnM Radar**，经原作者许可继续开发，并以独立MOD发布。

paroxis已停止游玩并不再维护MnM Radar。他在邮件中支持由新维护者独立发布DSWorldRadar，要求保留原作者署名，并允许沿用点位和ID数据。

目前仍使用MnM Radar派生的原生核心。原作者曾表示可以尝试公开源码；我们已提出索取请求，目前尚未收到C++源码。

- 原始雷达：**paroxis / MnM Radar**。
- 后续开发与打包：**zouzx1996**。
- UE4SS：**Narknon及RE-UE4SS项目贡献者**。包内保留相关许可证和声明。

DSWorldRadar的问题请向本项目维护者反馈。

**问题反馈**

请附上MOD版本、游戏版本、游戏语言、问题截图，以及相关的UE4SS、live_chest_watcher和reload_watcher日志。完成度问题请说明发生在启动、读档、切换存档还是开箱之后。

公开反馈时，请勿上传存档数据库或解密缓存文件。

---

**DSWorldRadar 1.1｜English Description**

DSWorldRadar is an exploration radar for DragonSword: Awakening. It displays chests, activities, resources and wildlife, with category filters and completion tracking for supported objectives using your current save and game events.

**GitHub downloads and source**

- Installation packages: [DSWorldRadar 1.1 downloads for game 1.1.1](https://github.com/Justin9609/DSWorldRadar/releases/tag/v1.1). With UE4SS and Without UE4SS packages are available; install one.
- Available source and review materials: [GitHub repository](https://github.com/Justin9609/DSWorldRadar). See its README for source coverage and remaining gaps.

**Versions and requirements**

- Mod version: **1.1**.
- Target game version: **1.1.1**, Steam / Windows x64.
- Bundled UE4SS: experimental **v3.0.1 Beta #0**, commit **1c1a1497**, using the nested directory layout.
- Requires Windows PowerShell, the .NET Framework C# compiler and write access to the mod folder. The save-sync helper is compiled locally on first launch; players do not need Python.

The game version label comes from the October 15 Steam update announcement for 1.1.1. See GAME_VERSION_ZH_EN.txt for the reviewed executable fingerprint. File resource version 5.3.2.0 is Unreal engine metadata, recorded separately from the game version. Other UE4SS builds have not been verified as substitutes for the bundled version.

**Main features**

- A catalog of **1,503 exploration treasure chests** and **147 local quests**.
- 84 minigames: 34 Flight, 40 Mole and 10 Wave.
- 78 puzzles: 48 platform, 29 sliding and 1 statue.
- Markers for ingredients, ores, crystals, wildlife and other points of interest.
- Completion tracking for chests and supported activities, refreshed for the corresponding progress after loading or switching saves.
- Category filters, a radar master switch, adjustable maximum distance, marker size and text settings.
- 11 text languages with automatic language selection.

These are catalog totals, not the number of unfinished objectives in your save. Puzzle and minigame reward chests are already included in the 1,503 chest total.

**What's new in 1.1**

- Targets game version 1.1.1, with updated chest data and corrected marker coordinates.
- Improves completion synchronization between saves and refreshes after loading or switching saves.
- Improves completion-state recognition for chests and local quests.
- Refines autosave handling, event processing and failure retries for more reliable synchronization.
- Improves background synchronization and log management, and removes retired helper files.
- Standardizes archive names and Chinese/English documentation while retaining all 11 languages and automatic language selection.

**Choose your download**

Both archives provide the same radar functionality. Install one:

- **With UE4SS:** DSWorldRadar_v1.1_Game_v1.1.1_With_UE4SS.zip. For a setup without an existing UE4SS installation; includes the matching loader and a configuration enabling the radar.
- **Without UE4SS:** DSWorldRadar_v1.1_Game_v1.1.1_Without_UE4SS.zip. For users with a compatible UE4SS installation; uses your existing loader configuration and other mods.

**Installation and upgrading**

1. Completely exit the game and extract your chosen archive.
2. Merge the included **DS** folder into the existing DS folder in the game root.
3. Confirm that the final mod path is:

DS/Binaries/Win64/ue4ss/Mods/DSWorldRadar/

Do not create an extra DS/DS or ue4ss/ue4ss directory. If UE4SS is already installed, use Without_UE4SS when upgrading. Preserve your existing settings and progress caches; clearing caches is not required for this upgrade.

For the Without UE4SS version, enable DSWorldRadar in your existing loader configuration. If your setup uses ue4ss/Mods/mods.txt, add or edit this line while preserving the other entries:

DSWorldRadar : 1

If your setup uses mods.json, add or enable DSWorldRadar there while preserving the other mod entries. Disable the original MnMRadar and duplicate DSWorldRadar installations before launching. **A separate installation of the original MnM Radar is not required.**

**How to use**

Load a save, press **Escape**, then click the **Radar** entry at the bottom of the menu. Select categories and adjust distance, marker size and text settings. The panel title is **DSWorldRadar** in every language.

**Languages**

Korean, English, Japanese, Simplified Chinese, Traditional Chinese, German, French, Spanish, Brazilian Portuguese, Russian and Thai.

Names with corresponding game text use the official text in that language; radar-specific labels are translated separately. Automatic selection prioritizes the game's saved text-language setting, followed by launch arguments, textual configuration and Steam language. English is used if no supported language is found.

Completely restart the game after changing its text language. Korean, Japanese, German, Spanish, Brazilian Portuguese, Russian and Thai currently retain OFF / ON for the native master switch. Font coverage and long-text layout have not been individually verified in game for all 11 languages.

**Synchronization and compatibility**

Completion synchronization may take a short time after loading, switching saves or an autosave. When current-save identification is unavailable, progress may temporarily follow the most recently written save. If the display does not match your current progress, please include the relevant logs in your report.

**Save access and technical behavior**

The mod starts PowerShell/C# helpers, reads local encrypted saves and processes temporary decrypted copies in its own cache directory. It also reads and writes radar state in the game process. Process access, script execution and local compilation can trigger antivirus heuristics.

The current native integration still includes fixed-offset access and UI patches. A source-level replacement is not complete; version 1.1 does not imply a rewritten native core.

**About MnM Radar and credits**

DSWorldRadar is based on **MnM Radar by paroxis**, used with the original author's permission and released as a separate mod.

In our correspondence, paroxis explained that he had stopped playing the game and was no longer maintaining MnM Radar. He supported a separate DSWorldRadar release under the new maintainer's name, with clear credit, and permitted reuse of the radar's node and ID data.

The current version retains the MnM Radar-derived native core. The original author offered to look into making the source public; it has been requested but has not yet been received.

- Original radar foundation: **paroxis / MnM Radar**.
- Continued development and packaging: **zouzx1996**.
- UE4SS: **Narknon and the RE-UE4SS contributors**. Bundled licenses and notices are retained.

Please direct DSWorldRadar support requests to this project's maintainer.

**Bug reports**

Please include your mod version, game version, game language, a screenshot and the relevant UE4SS, live_chest_watcher and reload_watcher logs. For completion issues, state whether the problem occurred at startup, after loading or switching saves, or after opening a chest.

Do not include save databases or decrypted cache files in public reports.
