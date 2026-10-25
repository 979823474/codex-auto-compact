# GitHub 项目简介

## 推荐仓库名

`codex-auto-compact`

## About 简介

以下中文简介可直接复制到 GitHub 仓库右侧的 About → Description，长度低于 350 字符：

> Windows 本地自动透明压缩工具与 Codex 技能插件。自定义间隔天数、文件大小范围和处理目录，保留原路径供程序与本地 GPT/Codex 读取；可选 ZIP/TAR.GZ 副本、保存路径与压缩档位，并提供样本比较。离线运行，无需 API 密钥或定时模型调用。

英文一句话版本：

> A local Windows NTFS compression tool and Codex skill plugin with configurable scheduling, file sizes, folders, ZIP/TAR.GZ copies, and sample comparisons while preserving source paths.

## 推荐 Topics

GitHub 的 Topics 逐个添加以下标签即可：

`windows` · `powershell` · `ntfs` · `compression` · `codex` · `codex-plugin` · `automation` · `offline`

## 给第一次使用的人

这个工具帮你定期压缩电脑上的本地资料，文件仍在原来的位置，平时直接打开即可。先选择要处理的文件夹、间隔天数和文件大小，再扫描预览、立即执行或安装自动任务。默认每 30 天处理一次，可以修改。

原地透明压缩用于节省磁盘空间；另存 ZIP 或 TAR.GZ 副本用于备份，可选择保存路径和压缩档位，原件保留，副本额外占用空间。这两种格式无需额外安装软件。样本比较最多处理 64 个文件、合计最多 32 MiB，显示实际体积和耗时，结果不代表整个资料库。它处理电脑上的文件，不处理 ChatGPT 网页资料库。Codex 插件需要支持本地执行的客户端。

## 首发 Release 文案

推荐标签：`v0.1.0`

推荐标题：`v0.1.0 — Windows 本地自动透明压缩`

可复制的发布说明：

```markdown
首个版本：为 Windows 本地文件提供可配置的定期透明压缩。

- 自定义间隔天数、文件大小范围和源文件夹。
- 使用 NTFS 透明压缩，保留原文件路径和日常读取方式。
- 支持扫描预览、立即执行和独立 Windows 计划任务。
- 可选副本保存目录、ZIP/TAR.GZ 格式与 Fastest/Optimal 压缩档位，原件继续保留。
- 对有限样本实际打包比较体积、比例和耗时，完成后清理临时文件。
- 提供 Codex 技能插件、中文说明和 Windows 集成测试。

要求：Windows 10/11、NTFS、Windows PowerShell 5.1。

完整解压项目后，双击“打开工具.cmd”开始使用。
本地工具不压缩 ChatGPT 云端资料库；插件加载情况需在兼容客户端的新聊天中验证。
压缩副本另占空间，当前版本不自动清理旧副本。样本比较不能预测全库结果，也不保证固定压缩率。
```

GitHub 发布与公共插件目录上架是不同步骤。上传本项目不会自动将插件发布到 OpenAI 公共目录。
