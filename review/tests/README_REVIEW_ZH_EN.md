# 离线测试资料

此目录为既有测试脚本，不包含个人存档或个人运行日志。准备审核包时未重新执行这些游戏行为测试。
原测试环境使用 PowerShell 7.4.6；Python 依赖见 requirements_tests.txt。
以下命令在解压后根目录执行，输出只写入 audit/：

pwsh -NoProfile -File tests/dispatch_lifecycle.ps1 -WatcherPath source/dlls/sync/live_chest_watcher.ps1 -OutputPath audit/dispatch_lifecycle.json
pwsh -NoProfile -File tests/common_io.ps1 -CommonPath source/dlls/sync/radar_common.ps1 -OutputPath audit/common_io.json
pwsh -NoProfile -File tests/watcher_execution.ps1 -WatcherPath source/dlls/sync/live_chest_watcher.ps1 -NodesPath reference_mod/dlls/mnm_nodes.csv -OutputPath audit/watcher_execution.json
pwsh -NoProfile -File tests/area_matching.ps1 -WatcherPath source/dlls/sync/live_chest_watcher.ps1 -IdsPath reference_mod/dlls/mnm_ids.csv -OutputPath audit/area_matching.json

其他脚本的参数见各文件开头。部分检查需要生成合成存档夹具或指定路径，不能把它们当作无需依赖的一键游戏测试。

---

# Offline harnesses

These are retained test harnesses, with no personal save or runtime trace. They were not re-executed as new game-behavior tests while preparing this review bundle.
The prior environment used PowerShell 7.4.6; Python dependencies are in requirements_tests.txt.
Run the commands above from the extracted root. Outputs go to audit/.
Other harness parameters are documented at the start of each file. Some need synthetic save fixtures or explicit paths and are not dependency-free game tests.
