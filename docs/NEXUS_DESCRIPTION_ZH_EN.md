**DSWorldRadar 1.1｜中文说明**

DSWorldRadar 是《龙之剑：觉醒》的探索雷达 MOD，可显示宝箱、探索活动、资源和动物等目标，支持分类筛选，并结合当前存档与游戏事件同步已支持目标的完成状态。

**版本与运行要求**

- MOD 版本：**1.1**。
- 适配游戏版本：**1.1.1**，Steam / Windows x64。
- 配套 UE4SS：实验版 **v3.0.1 Beta #0**，提交 **1c1a1497**，采用嵌套目录结构。
- 需要 Windows PowerShell、.NET Framework 自带的 C# 编译器，以及 MOD 文件夹写入权限。存档同步程序会在首次启动时于本机编译，玩家无需安装 Python。

游戏版本标注依据 Steam 10 月 15 日的 1.1.1 更新公告。运行文件的完整构建指纹见包内 GAME_VERSION_ZH_EN.txt；文件资源中的 5.3.2.0 为 UE 引擎版本，与游戏版本分别记录。其他 UE4SS 构建尚未验证能否替代配套版本。

**主要功能**

- 收录 **1,503 个探索宝箱**和 **147 个区域任务**。
- 84 个小游戏：飞行 34、地鼠 40、波动 10。
- 78 个谜题：踏板 48、滑块 29、石像 1。
- 食材、矿石、结晶、动物及其他兴趣点标记。
- 宝箱及已支持活动的完成状态同步，载入、切换存档后按对应进度刷新。
- 分类筛选、雷达总开关、最大显示距离、标记大小和文字显示设置。
- 11 种文本语言及自动语言识别。

以上为收录总量，并非当前存档尚未完成的数量。谜题和小游戏的奖励宝箱已包含在 1,503 个宝箱总数中，无需重复相加。

**1.1 更新内容**

- 适配游戏 1.1.1，更新宝箱数据并校正部分点位坐标。
- 优化不同存档的完成度同步，以及载入和切换存档后的刷新。
- 改善宝箱与区域任务的完成状态识别。
- 调整自动保存、事件处理和失败重试，提高同步稳定性。
- 优化后台同步与日志管理，清理不再使用的辅助文件。
- 统一安装包命名和中英文说明，保留 11 种语言及自动语言识别。

**下载选择**

两个版本的雷达功能相同，只需安装其中一个：

- **包含 UE4SS：**DSWorldRadar_v1.1_Game_v1.1.1_With_UE4SS.zip。适合尚未安装 UE4SS 的环境，包含配套加载器及启用雷达的配置。
- **不包含 UE4SS：**DSWorldRadar_v1.1_Game_v1.1.1_Without_UE4SS.zip。适合已有兼容 UE4SS 的玩家，沿用现有加载器配置和其他 MOD。

**安装与更新**

1. 完全退出游戏，解压所选压缩包。
2. 将包内 **DS** 文件夹合并到游戏根目录中已有的 DS 文件夹。
3. 确认最终 MOD 位置为：

DS/Binaries/Win64/ue4ss/Mods/DSWorldRadar/

请勿多套一层 DS/DS 或 ue4ss/ue4ss。已有 UE4SS 的玩家更新时请选择不包含 UE4SS 版，保留现有设置和进度缓存，无需为升级清空缓存。

使用不包含 UE4SS 版时，在现有加载配置中启用 DSWorldRadar。若使用 ue4ss/Mods/mods.txt，添加或修改以下一行，并保留其他条目：

DSWorldRadar : 1

若使用 mods.json，则在原有配置中添加或启用 DSWorldRadar，并保留其他 MOD 条目。启动前请停用原版 MnMRadar 和重复安装的 DSWorldRadar。**无需另行安装原版 MnM Radar。**

**使用方法**

载入存档后，按 **ESC**，点击菜单底部的 **Radar／雷达** 入口。在面板中选择分类，调整显示距离、标记大小及文字设置。所有语言下的面板标题均为 **DSWorldRadar**。

**语言支持**

韩语、英语、日语、简体中文、繁体中文、德语、法语、西班牙语、巴西葡萄牙语、俄语和泰语。

游戏内有对应文本的名称采用相应语种的游戏原文，雷达自定义界面文本单独翻译。自动识别优先跟随游戏保存的文本语言，再检查启动参数、配置中的语言文本及 Steam 语言；没有识别到支持的语言时使用英文。

修改游戏文本语言后，请完全退出并重新启动游戏。韩、日、德、西班牙、巴西葡萄牙、俄、泰语的原生总开关目前保留 OFF / ON。全部 11 种语言的游戏内字体覆盖和长文本排版尚未逐一验证。

**同步与兼容说明**

读档、切换存档或触发自动保存后，完成度同步可能需要短暂等待。缺少当前存档识别信息时，可能暂按最近写入的存档刷新；若显示与当前进度不一致，请提供相关日志反馈。

**存档访问与技术说明**

MOD 会启动 PowerShell／C# 同步程序，读取本地加密存档，并在 MOD 自己的缓存目录中处理临时解密副本；同时会读写游戏进程中的雷达状态。进程访问、脚本执行及本机编译行为可能触发安全软件的启发式提示。

当前原生整合仍包含固定偏移访问和界面补丁，尚未完成源码级替代。1.1 的版本号不表示原生核心已经重写。

**关于 MnM Radar 与鸣谢**

DSWorldRadar 基于 **paroxis** 制作的 **MnM Radar**，已获得原作者许可继续开发，并作为独立 MOD 发布。

paroxis 在邮件中表示，他已停止游玩并不再维护 MnM Radar；他支持以新维护者名义单独发布 DSWorldRadar，保留原作者署名，并允许继续使用原雷达的点位和 ID 数据。

当前版本仍保留基于 MnM Radar 的原生核心。原作者曾表示可以尝试公开源码，目前已提出索取请求，尚未收到 C++ 源码。

- 原始雷达基础：**paroxis / MnM Radar**。
- 后续开发与打包：**zouzx1996**。
- UE4SS：**Narknon 及 RE-UE4SS 项目贡献者**，包内保留相关许可证及声明。

DSWorldRadar 的问题反馈请联系本项目维护者。

**问题反馈**

请提供 MOD 版本、游戏版本、游戏语言、问题截图，以及相关 UE4SS、live_chest_watcher 和 reload_watcher 日志。完成度问题请说明是在启动、读档、切换存档还是开箱后出现。

请勿在公开反馈中上传存档数据库或解密缓存文件。

---

**DSWorldRadar 1.1｜English Description**

DSWorldRadar is an exploration radar for DragonSword: Awakening. It displays chests, activities, resources and wildlife, with category filters and completion tracking for supported objectives using your current save and game events.

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
