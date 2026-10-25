param([string]$ConfigPath = '', [string]$SmokeTestPath = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function Show-SettingsError([string]$Message) {
    Write-Host $Message -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($SmokeTestPath)) { return }
    $null = [Windows.Forms.MessageBox]::Show($Message, '操作未完成', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning)
}

function Get-NormalPath([string]$Path) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([string]::IsNullOrWhiteSpace($expanded) -or $expanded -notmatch '^[A-Za-z]:[\\/]') {
        throw '请选择本机的绝对目录路径，例如 D:\Codex。'
    }
    $fullPath = [IO.Path]::GetFullPath($expanded)
    if ([string]::Equals($fullPath, [IO.Path]::GetPathRoot($fullPath), [StringComparison]::OrdinalIgnoreCase)) { return $fullPath }
    return $fullPath.TrimEnd('\')
}

function Set-ConfigValue([string]$Name, $Value) {
    if ($null -eq $script:Configuration.PSObject.Properties[$Name]) {
        $script:Configuration | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    } else { $script:Configuration.$Name = $Value }
}

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $control = New-Object Windows.Forms.Label
    $control.Text = $Text
    $control.SetBounds($X, $Y, $Width, $Height)
    return $control
}

function New-Button([string]$Text, [int]$X, [int]$Y, [int]$Width) {
    $control = New-Object Windows.Forms.Button
    $control.Text = $Text
    $control.SetBounds($X, $Y, $Width, 32)
    return $control
}

function New-Number([int]$X, [int]$Y, [decimal]$Minimum, [decimal]$Maximum, [int]$Places) {
    $control = New-Object Windows.Forms.NumericUpDown
    $control.SetBounds($X, $Y, 150, 29)
    $control.Minimum = $Minimum
    $control.Maximum = $Maximum
    $control.DecimalPlaces = $Places
    $control.ThousandsSeparator = $true
    return $control
}

function Update-DriveSpace {
    $sourceDrives = @()
    foreach ($item in $script:SourceList.Items) {
        try {
            $root = [IO.Path]::GetPathRoot((Get-NormalPath $item.SubItems[1].Text))
            if ($sourceDrives -notcontains $root) { $sourceDrives += $root }
        } catch { }
    }
    $parts = @()
    foreach ($root in $sourceDrives) {
        try {
            $drive = New-Object IO.DriveInfo($root)
            if ($drive.IsReady) { $parts += ('{0} 可用 {1:N1} GB' -f $root.TrimEnd('\'), ($drive.AvailableFreeSpace / 1GB)) }
            else { $parts += ('{0} 未就绪' -f $root.TrimEnd('\')) }
        } catch { $parts += ('{0} 无法读取' -f $root.TrimEnd('\')) }
    }
    $text = '来源磁盘：' + ($parts -join '；')
    if ($archiveEnabled.Checked) {
        try {
            $root = [IO.Path]::GetPathRoot((Get-NormalPath $archivePath.Text))
            $drive = New-Object IO.DriveInfo($root)
            if ($drive.IsReady) { $text += ('  | 副本盘：{0} 可用 {1:N1} GB' -f $root.TrimEnd('\'), ($drive.AvailableFreeSpace / 1GB)) }
        } catch { $text += '  | 副本盘：请选择有效位置' }
    }
    $script:SpaceLabel.Text = $text
    $spaceTip.SetToolTip($script:SpaceLabel, $text)
}

function Show-ComparisonReport($Report, $Owner) {
    $dialog = New-Object Windows.Forms.Form
    try {
        $dialog.Text = '压缩格式实测对比'
        $dialog.StartPosition = 'CenterParent'
        $dialog.ClientSize = New-Object Drawing.Size(1020, 450)
        $dialog.MinimumSize = New-Object Drawing.Size(1036, 489)
        $dialog.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
        $summary = New-Label ('实际样本：{0} 个文件，{1:N2} MiB；符合筛选条件共 {2} 个文件。' -f $Report.SampleFiles, ([double]$Report.SampleBytes / 1MB), $Report.EligibleFiles) 18 16 980 30
        $summary.Anchor = 'Top,Left,Right'
        $scope = '有限样本实测：最多 64 个文件 / 32 MiB；此结果不能直接预测全部资料的压缩后大小。'
        if (-not $Report.PartialSample) { $scope = '本次样本已覆盖全部符合条件的文件；文件变化后，压缩效果和耗时也会变化。' }
        if ($Report.Result -eq 'NoSample') { $scope = '没有可用样本：单个文件需符合筛选且不超过 32 MiB；请调整来源或文件大小范围后再试。' }
        $scopeLabel = New-Label $scope 18 48 980 36
        $scopeLabel.Anchor = 'Top,Left,Right'
        $grid = New-Object Windows.Forms.DataGridView
        $grid.SetBounds(18, 90, 984, 226)
        $grid.Anchor = 'Top,Bottom,Left,Right'
        $grid.ReadOnly = $true
        $grid.AllowUserToAddRows = $false
        $grid.AllowUserToDeleteRows = $false
        $grid.RowHeadersVisible = $false
        $grid.AutoSizeColumnsMode = 'Fill'
        $grid.SelectionMode = 'FullRowSelect'
        foreach ($column in @(@('Format','格式'),@('Result','结果'),@('Original','原大小 MiB'),@('Archive','副本 MiB'),@('Ratio','副本比例 %'),@('Saved','节省 %'),@('Seconds','耗时秒'),@('Error','错误'))) {
            $null = $grid.Columns.Add($column[0], $column[1])
        }
        foreach ($format in @($Report.Formats)) {
            $original = if ($null -ne $format.OriginalBytes) { '{0:N3}' -f ([double]$format.OriginalBytes / 1MB) } else { '-' }
            $archive = if ($null -ne $format.ArchiveBytes) { '{0:N3}' -f ([double]$format.ArchiveBytes / 1MB) } else { '-' }
            $ratio = if ($null -ne $format.RatioPercent) { '{0:N1}' -f [double]$format.RatioPercent } else { '-' }
            $saved = if ($null -ne $format.SavedPercent) { '{0:N1}' -f [double]$format.SavedPercent } else { '-' }
            $seconds = if ($null -ne $format.Seconds) { '{0:N2}' -f [double]$format.Seconds } else { '-' }
            $null = $grid.Rows.Add([object[]]@([string]$format.Name, [string]$format.Result, $original, $archive, $ratio, $saved, $seconds, [string]$format.Error))
        }
        $note = New-Label "副本比例 = 归档大小 ÷ 样本原大小；数值越低，归档越小。耗时越短，速度越快。`r`n原地 NTFS 压缩另算。归档保留原文件，总占用 = 原文件当前占用 + 归档副本占用。" 18 328 984 64
        $note.Anchor = 'Bottom,Left,Right'
        $close = New-Button '关闭' 876 402 126
        $close.Anchor = 'Bottom,Right'
        $close.DialogResult = [Windows.Forms.DialogResult]::OK
        $dialog.AcceptButton = $close
        $dialog.CancelButton = $close
        $dialog.Controls.AddRange(@($summary, $scopeLabel, $grid, $note, $close))
        $null = $dialog.ShowDialog($Owner)
    } finally { $dialog.Dispose() }
}

function Add-SourceItem([string]$Kind, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    foreach ($existing in $script:SourceList.Items) {
        if ($existing.Tag -eq $Kind -and [string]::Equals($existing.SubItems[1].Text, $Path, [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    $item = New-Object Windows.Forms.ListViewItem($script:KindLabels[$Kind])
    $null = $item.SubItems.Add($Path)
    $item.Tag = $Kind
    $null = $script:SourceList.Items.Add($item)
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw ('找不到配置文件：{0}' -f $ConfigPath) }
    $script:Configuration = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $interval = [int]$script:Configuration.IntervalDays
    $minimumBytes = [long]$script:Configuration.MinimumBytes
    $maximumBytes = [long]$script:Configuration.MaximumBytes
    if ($interval -lt 1 -or $interval -gt 3650 -or $minimumBytes -lt 0 -or $maximumBytes -lt 0) { throw '配置中的天数或文件大小范围无效。请先修复 config.json。' }

    $script:KindLabels = @{
        SessionRoots = '旧聊天（仅 JSONL）'
        ProjectSearchRoots = '项目根目录（识别工具与构建）'
        StaticRoots = '自选目录（原地压缩）'
    }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Codex 自动压缩设置'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object Drawing.Size(940, 714)
    $form.MinimumSize = New-Object Drawing.Size(956, 753)
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $form.AutoScaleMode = 'Dpi'

    $intro = New-Label '使用 Windows NTFS 透明压缩，原文件保留原路径，可直接打开。保存设置不会立即压缩。' 20 16 900 40
    $intro.Anchor = 'Top,Left,Right'
    $form.Controls.Add($intro)
    $form.Controls.Add((New-Label '压缩间隔（天）' 20 64 180 24))
    $form.Controls.Add((New-Label '最小文件（KB）' 240 64 180 24))
    $form.Controls.Add((New-Label '最大文件（MB；0 为不限）' 470 64 280 24))
    $daysInput = New-Number 20 92 1 3650 0
    $daysInput.Value = $interval
    $minInput = New-Number 240 92 0 ([decimal]::Floor([decimal][long]::MaxValue / 1024)) 3
    $minInput.Value = [Math]::Min([decimal]$minimumBytes / 1024, $minInput.Maximum)
    $maxInput = New-Number 470 92 0 ([decimal]::Floor([decimal][long]::MaxValue / 1048576)) 6
    $maxInput.Value = [Math]::Min([decimal]$maximumBytes / 1048576, $maxInput.Maximum)
    $originalMinimumValue = $minInput.Value
    $originalMaximumValue = $maxInput.Value
    $form.Controls.AddRange(@($daysInput, $minInput, $maxInput))
    $form.Controls.Add((New-Label ('每天检查一次；达到间隔才压缩。文件须至少 {0} 小时未修改；正在使用的文件会跳过。' -f $script:Configuration.MinimumAgeHours) 20 132 900 26))
    $form.Controls.Add((New-Label '处理来源（选中后可移除；自选目录会扫描其子目录）' 20 168 900 25))

    $script:SourceList = New-Object Windows.Forms.ListView
    $script:SourceList.SetBounds(20, 198, 900, 192)
    $script:SourceList.View = 'Details'
    $script:SourceList.FullRowSelect = $true
    $script:SourceList.GridLines = $true
    $script:SourceList.HideSelection = $false
    $script:SourceList.Anchor = 'Top,Bottom,Left,Right'
    $null = $script:SourceList.Columns.Add('类型', 255)
    $null = $script:SourceList.Columns.Add('目录', 620)
    foreach ($kind in @('SessionRoots','ProjectSearchRoots','StaticRoots')) {
        foreach ($source in @($script:Configuration.$kind)) { Add-SourceItem $kind ([string]$source) }
    }
    $form.Controls.Add($script:SourceList)

    $kindPicker = New-Object Windows.Forms.ComboBox
    $kindPicker.SetBounds(20, 402, 290, 30)
    $kindPicker.DropDownStyle = 'DropDownList'
    $kindPicker.Anchor = 'Bottom,Left'
    foreach ($kind in @('StaticRoots','ProjectSearchRoots','SessionRoots')) { $null = $kindPicker.Items.Add($script:KindLabels[$kind]) }
    $kindPicker.SelectedIndex = 0
    $addButton = New-Button '添加文件夹…' 324 400 142
    $addButton.Anchor = 'Bottom,Left'
    $removeButton = New-Button '移除选中项' 480 400 142
    $removeButton.Anchor = 'Bottom,Left'
    $form.Controls.AddRange(@($kindPicker, $addButton, $removeButton))
    $addButton.Add_Click({
        $picker = New-Object Windows.Forms.FolderBrowserDialog
        try {
            $picker.Description = '选择要处理的本机目录'
            $picker.ShowNewFolderButton = $false
            if ($picker.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
                $kind = @('StaticRoots','ProjectSearchRoots','SessionRoots')[$kindPicker.SelectedIndex]
                $path = Get-NormalPath $picker.SelectedPath
                if ([IO.Path]::GetPathRoot($path).TrimEnd('\') -eq $path.TrimEnd('\')) { throw '请选择具体文件夹，不能选择整个磁盘。' }
                Add-SourceItem $kind $path
                Update-DriveSpace
            }
        } catch { Show-SettingsError $_.Exception.Message }
        finally { $picker.Dispose() }
    })
    $removeButton.Add_Click({ foreach ($item in @($script:SourceList.SelectedItems)) { $script:SourceList.Items.Remove($item) }; Update-DriveSpace })

    $archiveGroup = New-Object Windows.Forms.GroupBox
    $archiveGroup.Text = '可选：另存压缩副本'
    $archiveGroup.SetBounds(20, 448, 900, 186)
    $archiveGroup.Anchor = 'Bottom,Left,Right'
    $archiveEnabled = New-Object Windows.Forms.CheckBox
    $archiveEnabled.Text = '同时保存压缩副本（原文件不移动，会额外占用存储空间）'
    $archiveEnabled.SetBounds(15, 24, 850, 25)
    $archiveEnabled.Checked = -not [string]::IsNullOrWhiteSpace([string]$script:Configuration.ArchiveDirectory)
    $archivePath = New-Object Windows.Forms.TextBox
    $archivePath.SetBounds(15, 96, 725, 28)
    $archivePath.Anchor = 'Top,Left,Right'
    $archivePath.Text = [string]$script:Configuration.ArchiveDirectory
    $archiveBrowse = New-Button '选择位置…' 752 94 132
    $archiveBrowse.Anchor = 'Top,Right'
    $archiveFormatLabel = New-Label '副本格式' 15 57 90 24
    $archiveFormat = New-Object Windows.Forms.ComboBox
    $archiveFormat.SetBounds(110, 54, 160, 28)
    $archiveFormat.DropDownStyle = 'DropDownList'
    $archiveFormat.Items.AddRange([object[]]@('ZIP','TAR.GZ'))
    $selectedFormat = [string]$script:Configuration.ArchiveFormat
    if ([string]::IsNullOrWhiteSpace($selectedFormat)) { $selectedFormat = 'ZIP' }
    if ($selectedFormat -notin @('ZIP','TAR.GZ')) { throw ('不支持的归档格式：{0}。本版支持 ZIP、TAR.GZ。' -f $selectedFormat) }
    $archiveFormat.SelectedItem = $selectedFormat
    $archiveLevelLabel = New-Label '压缩偏好' 300 57 90 24
    $archiveLevel = New-Object Windows.Forms.ComboBox
    $archiveLevel.SetBounds(395, 54, 190, 28)
    $archiveLevel.DropDownStyle = 'DropDownList'
    $archiveLevel.Items.AddRange([object[]]@('快速（Fastest）','更小（Optimal）'))
    $selectedLevel = [string]$script:Configuration.ArchiveCompression
    if ([string]::IsNullOrWhiteSpace($selectedLevel)) { $selectedLevel = 'Optimal' }
    if ($selectedLevel -notin @('Fastest','Optimal')) { throw ('不支持的压缩偏好：{0}' -f $selectedLevel) }
    $archiveLevel.SelectedIndex = if ($selectedLevel -eq 'Fastest') { 0 } else { 1 }
    $archiveNote = New-Label '节省固态空间只需原地透明压缩；副本可保存到另一块盘。此工具不自动删除旧副本。' 15 134 860 24
    $formatNote = New-Label 'ZIP 兼容性广；TAR.GZ 合并后压缩。实际效果取决于文件内容，请用下方“格式实测对比”。' 15 158 860 23
    $archiveGroup.Controls.AddRange(@($archiveEnabled, $archiveFormatLabel, $archiveFormat, $archiveLevelLabel, $archiveLevel, $archivePath, $archiveBrowse, $archiveNote, $formatNote))
    $archivePath.Enabled = $archiveEnabled.Checked
    $archiveBrowse.Enabled = $archiveEnabled.Checked
    $archiveEnabled.Add_CheckedChanged({ $archivePath.Enabled = $archiveEnabled.Checked; $archiveBrowse.Enabled = $archiveEnabled.Checked; Update-DriveSpace })
    $archivePath.Add_TextChanged({ Update-DriveSpace })
    $archiveBrowse.Add_Click({
        $picker = New-Object Windows.Forms.FolderBrowserDialog
        try {
            $picker.Description = '选择压缩副本保存位置；不能位于处理来源内部'
            if ($picker.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $archivePath.Text = $picker.SelectedPath }
        } finally { $picker.Dispose() }
    })
    $form.Controls.Add($archiveGroup)

    $script:SpaceLabel = New-Label '' 20 638 900 20
    $script:SpaceLabel.AutoEllipsis = $true
    $script:SpaceLabel.Anchor = 'Bottom,Left,Right'
    $spaceTip = New-Object Windows.Forms.ToolTip
    $form.Controls.Add($script:SpaceLabel)
    Update-DriveSpace

    $compareButton = New-Button '格式实测对比' 20 660 156
    $compareButton.Anchor = 'Bottom,Left'
    $compareStatus = New-Label '使用已保存配置；修改后请先保存，再实测。' 188 666 452 35
    $compareStatus.Anchor = 'Bottom,Left,Right'
    $saveButton = New-Button '保存设置' 656 660 126
    $cancelButton = New-Button '取消' 794 660 126
    $saveButton.Anchor = 'Bottom,Right'
    $cancelButton.Anchor = 'Bottom,Right'
    $cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $cancelButton
    $form.Controls.AddRange(@($compareButton, $compareStatus, $saveButton, $cancelButton))
    $saveButton.Add_Click({
        try {
            if ($script:SourceList.Items.Count -eq 0) { throw '请至少保留一个处理来源。' }
            $newMinimum = $minimumBytes
            $newMaximum = $maximumBytes
            if ($minInput.Value -ne $originalMinimumValue) { $newMinimum = [long][decimal]::Round($minInput.Value * 1024, 0) }
            if ($maxInput.Value -ne $originalMaximumValue) { $newMaximum = [long][decimal]::Round($maxInput.Value * 1048576, 0) }
            if ($newMaximum -gt 0 -and $newMaximum -lt $newMinimum) { throw '最大文件大小须大于等于最小文件大小；设为 0 表示不限。' }
            $roots = @{ SessionRoots = @(); ProjectSearchRoots = @(); StaticRoots = @() }
            $normalRoots = @()
            foreach ($item in $script:SourceList.Items) {
                $path = $item.SubItems[1].Text.Trim()
                $normal = Get-NormalPath $path
                if ([IO.Path]::GetPathRoot($normal).TrimEnd('\') -eq $normal.TrimEnd('\')) { throw '处理来源不能是整个磁盘，请选择具体文件夹。' }
                $roots[[string]$item.Tag] += $path
                $normalRoots += $normal
            }
            $newArchive = ''
            if ($archiveEnabled.Checked) {
                $newArchive = Get-NormalPath $archivePath.Text
                foreach ($root in $normalRoots) {
                    if ([string]::Equals($newArchive, $root, [StringComparison]::OrdinalIgnoreCase) -or
                        $newArchive.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                        throw '压缩副本保存位置不能在处理来源内部，请选另一目录或另一块磁盘。'
                    }
                }
            }
            Set-ConfigValue 'IntervalDays' ([int]$daysInput.Value)
            Set-ConfigValue 'MinimumBytes' $newMinimum
            Set-ConfigValue 'MaximumBytes' $newMaximum
            foreach ($kind in @('SessionRoots','ProjectSearchRoots','StaticRoots')) { Set-ConfigValue $kind @($roots[$kind]) }
            Set-ConfigValue 'ArchiveDirectory' $newArchive
            Set-ConfigValue 'ArchiveFormat' ([string]$archiveFormat.SelectedItem)
            Set-ConfigValue 'ArchiveCompression' $(if ($archiveLevel.SelectedIndex -eq 0) { 'Fastest' } else { 'Optimal' })
            $temporaryPath = Join-Path ([IO.Path]::GetDirectoryName($ConfigPath)) ('.config-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [IO.File]::WriteAllText($temporaryPath, ($script:Configuration | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($true)))
                [IO.File]::Replace($temporaryPath, $ConfigPath, [NullString]::Value)
            } finally { if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force } }
            $null = [Windows.Forms.MessageBox]::Show('设置已保存。自动任务下一次检查时使用新设置；也可从菜单选择扫描预览。', '已保存', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
            $form.DialogResult = [Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch { Show-SettingsError $_.Exception.Message }
    })

    $script:ComparisonBusy = $false
    $comparisonTimer = New-Object Windows.Forms.Timer
    $comparisonTimer.Interval = 250
    $comparisonTimer.Add_Tick({
        if (-not $script:ComparisonBusy -or -not $script:ComparisonProcess.HasExited) { return }
        $comparisonTimer.Stop()
        try {
            $text = $script:ComparisonOutput.GetAwaiter().GetResult()
            $errorText = $script:ComparisonError.GetAwaiter().GetResult()
            if ($script:ComparisonProcess.ExitCode -ne 0) { throw ('格式实测失败：{0} {1}' -f $text, $errorText) }
            $report = $text | ConvertFrom-Json
            $compareStatus.Text = ('实测完成：{0} 个样本文件，{1:N2} MiB。' -f $report.SampleFiles, ([double]$report.SampleBytes / 1MB))
            $form.UseWaitCursor = $false
            Show-ComparisonReport $report $form
        } catch {
            $compareStatus.Text = '格式实测未完成，请检查提示。'
            Show-SettingsError $_.Exception.Message
        } finally {
            $script:ComparisonBusy = $false
            $script:ComparisonProcess.Dispose()
            $compareButton.Enabled = $true
            $saveButton.Enabled = $true
            $cancelButton.Enabled = $true
            $form.UseWaitCursor = $false
        }
    })
    $compareButton.Add_Click({
        try {
            $runner = Join-Path $PSScriptRoot 'Runner.ps1'
            if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw '找不到 Runner.ps1，请保留完整工具包。' }
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $runner + '" -Mode Compare -ConfigPath "' + $ConfigPath + '" -DataDirectory "' + $PSScriptRoot + '"'
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $start.StandardOutputEncoding = [Text.Encoding]::UTF8
            $start.StandardErrorEncoding = [Text.Encoding]::UTF8
            $script:ComparisonProcess = New-Object Diagnostics.Process
            $script:ComparisonProcess.StartInfo = $start
            $null = $script:ComparisonProcess.Start()
            $script:ComparisonOutput = $script:ComparisonProcess.StandardOutput.ReadToEndAsync()
            $script:ComparisonError = $script:ComparisonProcess.StandardError.ReadToEndAsync()
            $script:ComparisonBusy = $true
            $compareButton.Enabled = $false
            $saveButton.Enabled = $false
            $cancelButton.Enabled = $false
            $form.UseWaitCursor = $true
            $compareStatus.Text = '正在实测已保存配置的小样本，请稍候…'
            $comparisonTimer.Start()
        } catch {
            if ($null -ne $script:ComparisonProcess) { $script:ComparisonProcess.Dispose() }
            Show-SettingsError $_.Exception.Message
        }
    })
    $form.Add_FormClosing({
        if ($script:ComparisonBusy) {
            $_.Cancel = $true
            $compareStatus.Text = '格式实测正在进行，请完成后关闭。'
        }
    })

    if (-not [string]::IsNullOrWhiteSpace($SmokeTestPath)) {
        $script:CapturePath = [IO.Path]::GetFullPath($SmokeTestPath)
        $smokeTimer = New-Object Windows.Forms.Timer
        $smokeTimer.Interval = 500
        $smokeTimer.Add_Tick({
            $smokeTimer.Stop()
            try {
                $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
                try {
                    $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                    $bitmap.Save($script:CapturePath, [Drawing.Imaging.ImageFormat]::Png)
                } finally { $bitmap.Dispose() }
            } catch { Write-Error $_.Exception.Message }
            finally { $form.Close() }
        })
        $form.Add_Shown({ $smokeTimer.Start() })
    }
    $null = $form.ShowDialog()
    if ($null -ne $smokeTimer) { $smokeTimer.Dispose() }
    $comparisonTimer.Dispose()
    $spaceTip.Dispose()
    $form.Dispose()
} catch {
    Show-SettingsError $_.Exception.Message
    exit 1
}
