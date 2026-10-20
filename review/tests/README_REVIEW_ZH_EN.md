# 离线测试资料

这里保留了既有离线测试脚本，不含个人存档或运行日志。准备审核资料时，没有重新执行这些游戏行为测试。

原测试环境使用PowerShell 7.4.6，Python依赖见requirements_tests.txt。在仓库的review目录下运行以下命令，输出会写入该目录下的audit/：

```sh
pwsh -NoProfile -File tests/dispatch_lifecycle.ps1 -WatcherPath source/dlls/sync/live_chest_watcher.ps1 -OutputPath audit/dispatch_lifecycle.json
pwsh -NoProfile -File tests/common_io.ps1 -CommonPath source/dlls/sync/radar_common.ps1 -OutputPath audit/common_io.json
pwsh -NoProfile -File tests/watcher_execution.ps1 -WatcherPath source/dlls/sync/live_chest_watcher.ps1 -NodesPath reference_mod/dlls/mnm_nodes.csv -OutputPath audit/watcher_execution.json
pwsh -NoProfile -File tests/area_matching.ps1 -WatcherPath source/dlls/sync/live_chest_watcher.ps1 -IdsPath reference_mod/dlls/mnm_ids.csv -OutputPath audit/area_matching.json
```

其他脚本的参数见各文件开头。部分检查需要先生成合成存档夹具，或指定对应文件路径，运行前请按脚本说明准备依赖。

---

# Offline harnesses

These are retained test harnesses, with no personal save or runtime trace. They were not re-executed as new game-behavior tests while preparing this review bundle.
The prior environment used PowerShell 7.4.6; Python dependencies are in requirements_tests.txt.
Run the commands above from the review directory of this repository (or the extracted review-bundle root). Outputs go to audit/.
Other harness parameters are documented at the start of each file. Some need synthetic save fixtures or explicit paths and are not dependency-free game tests.
