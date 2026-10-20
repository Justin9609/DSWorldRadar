# 上传 GitHub

1. 在自己的 GitHub 账号中新建空仓库，建议名称 `DSWorldRadar`。如果要直接向版主提供无需登录的访问链接，选择 Public；Private 仓库则需要另行邀请审核人。
2. 不初始化 README、.gitignore 或许可证，本包已经包含 README 和文件规则，许可状态单独说明。
3. 解压上传包，上传内层 `DSWorldRadar` 目录中的全部内容；README.md 应位于仓库根目录，不要再嵌套一层 DSWorldRadar。
4. 建议首次提交说明：`Add DSWorldRadar 1.1 sources and binary review materials`。
5. 上传后运行 `python tools/verify_repository.py` 和 `python review/tools/verify_review_bundle.py` 核对。校验基于原始字节，勿让编辑器批量修改源码换行符。

此包不包含游戏文件、玩家存档或私人邮件，也不是玩家安装包。不要为上传而把本仓库所有内容统一标为 MIT/GPL。

---

# Upload to GitHub

1. Create an empty repository in your own account, suggested name `DSWorldRadar`. Choose Public for a reviewer link accessible without sign-in; a Private repository requires reviewer access to be granted separately.
2. Do not initialize a README, .gitignore or license. These files and the permission-status notes are already prepared.
3. Extract the archive and upload the contents of its `DSWorldRadar` directory. README.md belongs at the repository root, without an extra nested DSWorldRadar folder.
4. Suggested initial commit: `Add DSWorldRadar 1.1 sources and binary review materials`.
5. Run both Python verification commands above after upload. Preserve original source bytes and line endings.

This is not a player installer and contains no game executable, player saves or private emails. Do not apply a blanket MIT/GPL license to all contents during upload.
