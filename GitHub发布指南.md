# 把它作为第一个 GitHub 项目

项目建议命名为 `codex-auto-compact`。下面的步骤发布源码和使用说明；不会把电脑里的聊天资料或压缩备份上传到 GitHub。

## 先检查项目

1. 在 Windows 上运行 `tests\Integration.ps1`，确认测试通过。
2. 确认 `config.json` 使用通用默认值，里面没有你的个人目录。
3. 确认没有 `state.json`、`logs/`、安装定位文件和压缩备份。这些文件已写入 `.gitignore`，但仍应检查待上传列表。
4. `LICENSE` 采用 MIT，允许别人使用、修改和分发这个项目。

## 第一次上传

初学者可以用 GitHub Desktop：

1. 登录 GitHub Desktop，选择 **File → Add local repository**，选择项目文件夹。
2. 如果提示不是 Git 仓库，选择 **create a repository here**，名称填 `codex-auto-compact`。确保它使用当前项目目录，没有再套一层同名文件夹。
3. 查看变更列表，确认只有工具源码、测试、文档和插件文件。
4. 提交说明写 `Initial release: local scheduled NTFS compression`，点击提交。
5. 点击 **Publish repository**，选择公开或私人后再发布。

公开仓库任何人都能看到；私人仓库适合先自行测试。插件目录和仓库公开发布是两件事：GitHub 上传成功不会自动进入 OpenAI 公共插件目录。

## 让别人安装

把仓库地址和 README 发给对方。对方可以下载 ZIP 后运行工具，也可以在兼容的 Codex 客户端添加 marketplace。发布后的命令形如：

```powershell
codex plugin marketplace add YOUR_NAME/codex-auto-compact
codex plugin add codex-auto-compact@codex-auto-compact-marketplace
```

把 `YOUR_NAME` 换成自己的 GitHub 用户名。私人仓库需要相应的 GitHub 访问权限。

建议第一次发布标记为 `v0.1.0`，在 Release 中说明系统要求、测试范围和已知限制。后续改代码先测试，再增加版本号和发布说明。
