# Codex Auto Compact

[简体中文](README.md) | [English](README.en.md)

[![Windows checks](https://github.com/979823474/codex-auto-compact/actions/workflows/windows.yml/badge.svg)](https://github.com/979823474/codex-auto-compact/actions/workflows/windows.yml)
[![Download ZIP](https://img.shields.io/badge/Download-ZIP-brightgreen)](https://codeload.github.com/979823474/codex-auto-compact/zip/refs/heads/main)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

一个为 Windows 用户准备的本地自动压缩工具，也能作为 Codex 技能插件使用。自定义间隔、文件大小和处理目录，让本地资料与开发文件定期节省空间。文件还在原来的位置，扩展名、内容和日常打开方式保持一致；有本地文件访问权限的 GPT/Codex 可以继续读取。

这是个人开源项目，与 OpenAI 无隶属关系。项目同时提供双击启动工具和 Codex 技能插件；自动压缩由 Windows 计划任务执行，不需要模型每月运行，也不需要 API 密钥。

**[下载 Windows 工具（ZIP）](https://codeload.github.com/979823474/codex-auto-compact/zip/refs/heads/main)** · [v0.1.0 功能说明](docs/releases/v0.1.0.md) · [反馈问题](https://github.com/979823474/codex-auto-compact/issues)

当前下载为 main 分支源码 ZIP，已包含启动脚本，完整解压即可使用，无需编译。正式 Release 附件尚未发布；此下载包会随 main 分支更新。

## 界面与实测

在设置窗口中选择间隔天数、文件大小范围、来源文件夹和可选副本的保存路径：

![设置窗口：自定义压缩间隔、文件筛选、归档格式与保存路径](docs/images/settings.png)

格式比较的一次本机实测：**64 个文件，原始 15,909,531 字节（15.17 MiB），Optimal 档位**。

| 副本格式 | 压缩后大小 | 占原始大小 | 节省比例 | 单次耗时 |
| --- | --- | --- | --- | --- |
| ZIP | 3,600,105 字节（3.43 MiB） | 22.63% | 77.37% | 0.464 秒 |
| TAR.GZ | 3,575,739 字节（3.41 MiB） | 22.48% | 77.52% | 0.420 秒 |

这组数据仅代表该样本，不保证其他文件或整个资料库的压缩效果。表格记录的是**额外归档副本**，原件保留，因此目标目录会额外占用这些空间；节省源盘空间使用 NTFS 原地透明压缩。

<details>
<summary>查看格式比较窗口</summary>

![格式比较窗口示例](docs/images/formats.png)

此图使用另一个仅含 2 个小文件、约 0.09 MiB 的界面演示样本，图中的 99.3% 不是上表的实测结果，也不代表整个资料库。

</details>

## 适用环境

- Windows 10/11、NTFS 文件系统。
- 系统自带 Windows PowerShell 5.1，或兼容的 PowerShell 环境。
- 当前 Windows 用户可访问的本地文件。无须常驻后台进程。

ChatGPT 网页中的云端资料库不属于本工具的处理范围。安装这个插件也不会让纯云端聊天自动获得电脑文件访问权限。

## 开始使用

1. [下载 Windows ZIP](https://codeload.github.com/979823474/codex-auto-compact/zip/refs/heads/main)，完整解压，然后打开其中的 **codex-auto-compact-main** 文件夹。无需编译。
2. 双击 **打开工具.cmd**，进入设置，选择间隔天数、文件大小范围和要压缩的文件夹；需要额外备份时选择保存目录、格式和压缩档位。
3. 先运行扫描预览，再按需要立即压缩，或安装自动任务。

双击 **安装自动压缩.cmd** 可以安装独立的本地计划任务。默认工具目录为 `%LOCALAPPDATA%\CodexAutoCompact`；开发者可通过 `Manage.ps1 -InstallDirectory` 指定其他目录。更新安装会保留已有配置。

自动任务每天 20:00、登录后 1 分钟做一次到期检查。只有距离上次成功压缩达到配置天数时才处理文件；未到期直接退出。关机期间不会执行，之后登录时补检查。默认间隔为 30 天。

完整操作见 [使用说明](使用说明.md)。

## 能设置什么

| 设置 | 含义 | 默认值 |
| --- | --- | --- |
| 间隔天数 | 两次成功压缩之间的间隔 | 30 天，可设 1–3650 天 |
| 最小文件大小 | 小于该大小的文件不压缩 | 4 KiB |
| 最大文件大小 | 大于该大小的文件不压缩，0 表示不限 | 不限 |
| 文件年龄 | 最近修改的文件先跳过 | 24 小时 |
| 源文件夹 | 选择原地透明压缩的范围 | 已知 Codex 会话与开发缓存范围 |
| 副本保存目录 | 可选，把压缩副本存到指定目录 | 关闭 |
| 副本格式 | ZIP 或 TAR.GZ，两者均无需额外安装软件 | ZIP |
| 压缩档位 | Fastest（优先速度）或 Optimal（平衡体积与耗时） | Optimal |

“文件大小”按压缩前的逻辑长度筛选，并不是输出压缩包的目标大小，也不能保证压缩比。

**原地压缩**用于节省原文件所在磁盘的空间。**另存压缩副本**用于备份，会保留原件并额外占用目标目录空间。项目不会自动删除、移动原件，也不会用目录链接替换原路径。格式与档位只影响额外副本，原地压缩仍使用 Windows 标准 NTFS 压缩。

可以先运行格式比较：对当前筛选结果中最多 64 个文件、合计最多 32 MiB 的样本实际打包，显示 ZIP 与 TAR.GZ 的体积、占原始样本的比例和耗时。比较完成会删除临时样本，不更新上次成功压缩时间。样本结果受文件类型和大小影响，不能用来预测整个资料库，也不保证任何固定压缩率。

| 方式 | 读取与适用情况 | 空间结果 |
| --- | --- | --- |
| NTFS 透明压缩 | 保留原路径，普通程序可直接读取 | 工具报告实际磁盘占用；用于节省源盘空间 |
| ZIP 副本 | 逐文件压缩，兼容方便 | 另存副本，原件仍占空间 |
| TAR.GZ 副本 | 整包压缩，相似文本可能更小但不能保证；取单个文件需解包 | 另存副本，原件仍占空间 |

TAR.GZ 使用 UTF-8 pax 文件名。部分 Windows `tar.exe` 版本在特定系统语言环境下无法解出中文等非 ASCII 文件名，遇到这种情况可用支持 UTF-8 的解包工具，或选择 ZIP。

比较中的 `ArchiveBytes` 是压缩包文件的字节数，不含磁盘簇分配与文件系统元数据；`Seconds` 是单次打包实测耗时，会受缓存等运行条件影响。

## 工作方式

使用 Windows 标准 NTFS 透明压缩 `compact.exe /C`。它由文件系统负责解压读取，普通程序和本地文件工具仍按原路径访问。文本通常更容易节省空间；图片、视频、ZIP 等已经压缩的数据收益很小。

内置筛选跳过最近修改、占用中或不适合处理的文件，以及数据库、凭据和链接等。已经启用 NTFS 压缩的文件不重复执行原地压缩；开启副本时，符合其他筛选条件的已压缩文件仍可写入副本。工具不会自动删除旧副本，请选择空间充足的保存目录并按需要整理。

不要把整个系统盘、浏览器配置目录或整个 `.codex` 目录直接加入处理范围。运行结果和错误写在本机状态及日志中，不上传文件内容。

## 作为 Codex 插件使用

项目包含官方 Agent Plugins 格式的 `plugin.json`、`skills/`，以及仓库目录 `.agents/plugins/marketplace.json`。这是含脚本的本地技能插件，不需要 MCP 服务。

在支持本地插件的 Codex 客户端中，将本项目目录添加为 marketplace：

```powershell
codex plugin marketplace add "C:\path\to\codex-auto-compact"
```

然后在客户端插件列表中选择 **Codex Auto Compact** 并安装，开启新聊天测试。支持对应 CLI 命令的版本也可运行：

```powershell
codex plugin add codex-auto-compact@codex-auto-compact-marketplace
```

示例请求：

> 使用 codex-auto-compact，查看我的压缩设置和下次到期时间。

> 把自动压缩改为每 15 天，只处理 1 MiB 到 200 MiB 的文件。

> 用当前筛选条件比较 ZIP 和 TAR.GZ 的样本压缩效果，再帮我设置副本保存目录。

插件能力受客户端版本及本地执行权限限制。首次安装后应在新聊天中验证技能被加载；仅有 manifest 或已安装独立工具不代表插件已加载。添加 marketplace 不会自动安装 Windows 计划任务。

官方规范：[插件打包与本地分发](https://developers.openai.com/plugins/build/plugins)。

## 开发与验证

使用 Windows PowerShell 5.1 运行项目测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Integration.ps1
```

测试应使用独立临时文件夹，验证真实压缩前后的哈希、筛选、到期判断、锁处理和副本格式。`Archive.ps1` 是副本与比较功能的内置引擎，发布时须随工具一起提供。GitHub Actions 会在 Windows 上解析 PowerShell 源码并运行测试；CI 使用 Python 3.13 标准库独立解包 TAR.GZ（`ArchiveFormats.ps1 -TarExtractor Python`），本地测试默认使用 Windows `tar.exe`。Python 只用于 CI／测试，日常工具无需安装 Python。CI 成功不代表用户机器上的计划任务已经安装或执行。

公开仓库只保留通用默认配置。不要提交个人文件路径、会话内容、日志、`state.json`、安装定位文件或压缩备份。发布第一份 GitHub 项目的步骤见 [GitHub 发布指南](GitHub发布指南.md)。

仓库简介、Topics 和首发说明可直接参考 [GitHub 项目简介](GitHub项目简介.md)。

## 许可证

[MIT](LICENSE)。
