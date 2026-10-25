---
name: codex-auto-compact
description: Configure, inspect, or run the bundled Windows NTFS transparent compression utility and its local schedule. Use for this plugin's storage compression workflow; not for ChatGPT cloud Library files, context compaction, or general archive extraction.
---

Use the bundled PowerShell tool on Windows with local shell access. Its standard NTFS compression preserves each source file's path, format, and logical contents. An optional ZIP or TAR.GZ archive is an extra copy; it does not replace the source or reduce cloud Library storage. Both formats use the bundled engine without external compression software. A cloud-only ChatGPT session cannot access the user's Windows files through this skill alone.

Resolve the plugin root as two directories above this `SKILL.md` folder. The tool files are `Runner.ps1`, `Archive.ps1`, `Manage.ps1`, `Settings.ps1`, and `config.json` at that root. Read the root `使用说明.md` for current UI controls. Use Windows PowerShell 5.1 or later. Paths may contain spaces; pass them as individual quoted arguments, never interpolated shell fragments.

## Inspect and configure

Use `Manage.ps1 -Action Status` to inspect installation and timing. `Runner.ps1 -Mode Scan -ConfigPath <config> -DataDirectory <data>` previews eligible files without compressing them. The default standalone install lives at `%LOCALAPPDATA%\CodexAutoCompact`; a user-selected install directory can override it. Honor the existing installed configuration instead of overwriting it with package defaults.

Open `Manage.ps1 -Action Settings` when a user wants to choose folders or adjust the interval and size range interactively. If the user explicitly asks you to set values, update the installed `config.json` carefully, preserving unrelated properties. Validate values before saving:

- `IntervalDays`: integer 1–3650; default 30. Daily/logon task triggers only check whether this interval has elapsed since the last successful compression.
- `MinimumBytes`: minimum original file size; default 4096.
- `MaximumBytes`: maximum original file size; 0 means unlimited. A nonzero maximum must be at least the minimum.
- `MinimumAgeHours`: skip recently modified files; default 24.
- `StaticRoots`: user-selected extra source folders for in-place compression.
- `ArchiveDirectory`: optional destination for archive copies; empty disables them. Keep the original files accessible, and explain that backup copies require additional disk space.
- `ArchiveFormat`: `ZIP` (default) or `TAR.GZ`; these choose the format of the extra copy, not the in-place NTFS compression.
- `ArchiveCompression`: `Fastest` or `Optimal` (default); this selects the archive speed/size tradeoff and does not promise a fixed compression ratio.
- `SessionRoots` and `ProjectSearchRoots`: scopes used to discover supported local data; do not expand them to whole drives or unrelated application data without the user's request.

## Run and automate

For an authorized immediate compression, use `Runner.ps1 -Mode Now`; `-Mode Due` respects the interval. `-ConfigPath` and `-DataDirectory` allow explicit installed or isolated test paths. Let the runner perform selection, lock handling, state updates, and log retention; do not substitute recursive `compact /S` or archive-and-delete operations. Existing archive copies are not automatically removed.

Use `Runner.ps1 -Mode Compare` to compare ZIP and TAR.GZ using actual eligible samples, capped at 64 files and 32 MiB in total. Report archive sizes, ratios, elapsed times, and the sample scope from the actual result. The runner removes temporary samples after comparison and does not advance the successful-compression timestamp. A sample result is not a full-library prediction; do not invent fixed compression ratios or recommend a format without considering its actual result.

For an authorized schedule installation, use `Manage.ps1 -Action Install`, optionally with `-InstallDirectory <directory>`. The task runs locally using Windows Task Scheduler; it needs neither an API key nor recurring model calls. Manage actions `Disable`, `Enable`, and `UninstallTask` control only this tool's task. Uninstalling the task leaves files and existing NTFS compression in place.

The runner skips unsafe/recent/locked files and protected formats. Do not bypass those exclusions, rename active databases, delete originals, or introduce junctions to make moved files appear at old paths.

After an operation, read the actual result/state and report processed/skipped/error counts and space savings when available. Distinguish successful script execution from successful scheduled execution and from plugin loading. An installed manifest does not prove a new chat has loaded the skill. Do not describe cloud Library files as compressed by this local tool.
