# 上传与更新GitHub文件

## 首次上传仓库

1. 在自己的GitHub账号下新建空仓库，建议命名为`DSWorldRadar`。选Public可提供无需登录的审核链接；Private仓库需要另行邀请审核人。
2. 创建仓库时，不初始化README、.gitignore或许可证。上传包已包含README和文件规则，许可情况另有说明。
3. 解压上传包，将内层`DSWorldRadar`目录中的文件和文件夹上传到仓库根目录。README.md应直接位于根目录。
4. GitHub网页可能拦截点开头的文件。如果.gitignore或.gitattributes提示“This file is hidden”，在仓库根目录通过“Add file → Create new file”分别新建，完整复制原文件内容后提交。
5. 首次提交说明可填：`Add DSWorldRadar 1.1 sources and binary review materials`。
6. 上传后，在干净的仓库目录运行`python tools/verify_repository.py`，核对文件是否完整。该命令也会检查审核资料中的源码与二进制对应关系。

校验使用文件原始字节，请保留源码中的换行符。仓库未统一采用MIT或GPL许可，具体情况见根目录LICENSE_STATUS.md。

## 更新文档

1. 解压文档修改包，进入`upload`目录。
2. 在仓库根目录选择“Add file → Upload files”，将`upload`目录中的全部文件和文件夹拖入页面。保留包内目录结构，让同路径文件更新到原位置。
3. 提交到main分支。建议提交说明：`统一中文排版并润色说明`。
4. 修改包中的校验清单应一同上传，以便更新后继续核对文件。

## 更新Release说明

进入已有的v1.1发布页，点击编辑按钮，用修改包中的RELEASE_NOTES_ZH_EN.md替换发布说明，再点击“Update release”。版本标签沿用v1.1，两个正式安装附件继续使用原包。

---

# Upload to GitHub

1. Create an empty repository in your own account, suggested name `DSWorldRadar`. Choose Public for a reviewer link accessible without sign-in; a Private repository requires reviewer access to be granted separately.
2. Do not initialize a README, .gitignore or license. These files and the permission-status notes are already prepared.
3. Extract the archive and upload the contents of its `DSWorldRadar` directory. README.md belongs at the repository root, without an extra nested DSWorldRadar folder.
4. Suggested initial commit: `Add DSWorldRadar 1.1 sources and binary review materials`.
5. Run both Python verification commands above after upload. Preserve original source bytes and line endings.

This is not a player installer and contains no game executable, player saves or private emails. Do not apply a blanket MIT/GPL license to all contents during upload.

## Browser upload notes and later updates

The GitHub web uploader may reject dotfiles with “This file is hidden.” Create .gitignore and .gitattributes at the repository root with Add file → Create new file, copying their exact original contents.

For a documentation update bundle, open Add file → Upload files at the repository root and upload the contents of its upload directory, preserving paths and including the updated checksum manifests. Commit the changes to main.

To update the release text, edit the existing v1.1 release, replace its description with RELEASE_NOTES_ZH_EN.md and click Update release. Keep the existing v1.1 tag and installation assets.
