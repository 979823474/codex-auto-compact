param(
    [ValidateSet('Menu','Install','Status','RunNow','Disable','Enable','UninstallTask','Settings','Scan','Compare')]
    [string]$Action = 'Menu',
    [string]$InstallDirectory = '',
    [switch]$PreferInstalled,
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
$script:SourceDirectory = $PSScriptRoot
$defaultInstallDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexAutoCompact'
$script:LocatorPath = Join-Path $defaultInstallDirectory 'installation.json'
if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    $InstallDirectory = $defaultInstallDirectory
    if (Test-Path -LiteralPath $script:LocatorPath) {
        try {
            $locator = Get-Content -LiteralPath $script:LocatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([IO.Path]::IsPathRooted([string]$locator.InstallDirectory) -and
                (Test-Path -LiteralPath (Join-Path $locator.InstallDirectory 'Manage.ps1'))) {
                $InstallDirectory = [string]$locator.InstallDirectory
            }
        } catch { }
    }
}
$script:InstallDirectory = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($InstallDirectory)).TrimEnd('\')
$script:TaskName = 'CodexAutoCompact-30Days'
$script:TaskSource = 'CodexAutoCompact'
$script:PowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-ScheduleConnection {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    return $service
}

function Find-ToolTask($Folder) {
    $tasks = $Folder.GetTasks(1)
    for ($index = 1; $index -le $tasks.Count; $index++) {
        $candidate = $tasks.Item($index)
        if ([string]::Equals($candidate.Name, $script:TaskName, [StringComparison]::OrdinalIgnoreCase)) {
            return $candidate
        }
    }
    return $null
}

function Assert-ToolTask($Task) {
    if ($null -eq $Task) { return }
    $definition = $Task.Definition
    $expectedRunner = Join-Path $script:InstallDirectory 'Runner.ps1'
    $owned = $false
    if ($definition.RegistrationInfo.Source -eq $script:TaskSource) {
        for ($index = 1; $index -le $definition.Actions.Count; $index++) {
            $taskAction = $definition.Actions.Item($index)
            if ($taskAction.Type -eq 0 -and
                [string]::Equals([string]$taskAction.Path, $script:PowerShellPath, [StringComparison]::OrdinalIgnoreCase) -and
                ([string]$taskAction.Arguments).IndexOf(('"' + $expectedRunner + '"'), [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $owned = $true
            }
        }
    }
    if (-not $owned) {
        throw ('发现同名任务 {0}，但它不是本工具创建的任务。为避免覆盖其他任务，已停止。' -f $script:TaskName)
    }
}

function Get-EffectiveDirectory {
    if ((Test-Path -LiteralPath (Join-Path $script:InstallDirectory 'Runner.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $script:InstallDirectory 'Manage.ps1'))) {
        return $script:InstallDirectory
    }
    return $script:SourceDirectory
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Format-LocalDate($Value) {
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '暂无' }
    try {
        return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
    } catch {
        return ('无法解析：{0}' -f $Value)
    }
}

function Show-ToolStatus {
    $directory = Get-EffectiveDirectory
    Write-Host ''
    Write-Host 'Codex 自动压缩工具' -ForegroundColor Cyan
    Write-Host ('工具位置：{0}' -f $directory)
    Write-Host ('计划任务：{0}' -f $script:TaskName)
    try {
        $service = Get-ScheduleConnection
        $folder = $service.GetFolder('\')
        $task = Find-ToolTask $folder
        if ($null -eq $task) {
            Write-Host '自动执行：尚未安装'
        } else {
            Assert-ToolTask $task
            $stateText = switch ([int]$task.State) {
                1 { '已停用' }
                2 { '排队中' }
                3 { '等待检查' }
                4 { '正在运行' }
                default { '未知' }
            }
            Write-Host ('自动执行：{0}' -f $stateText)
            $nextCheck = [datetime]$task.NextRunTime
            if ($task.Enabled -and $nextCheck.Year -gt 1900) {
                Write-Host ('下次计划检查：{0}（登录后也会补检查）' -f $nextCheck.ToString('yyyy-MM-dd HH:mm:ss'))
            } else {
                Write-Host '下次计划检查：暂无；启用任务后才会自动检查'
            }
            $lastCode = [long]$task.LastTaskResult -band 4294967295L
            Write-Host ('计划任务上次返回码：0x{0:X8}' -f $lastCode)
        }
    } catch {
        Write-Host ('计划任务状态读取失败：{0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }

    $intervalDays = 30
    try {
        $configuration = Read-JsonFile (Join-Path $directory 'config.json')
        if ($null -ne $configuration -and [int]$configuration.IntervalDays -ge 1) {
            $intervalDays = [int]$configuration.IntervalDays
        }
    } catch {
        Write-Host ('配置读取失败，显示默认 30 天间隔：{0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
    Write-Host ('实际压缩间隔：{0} 天；每日检查不等于每日压缩' -f $intervalDays)
    try {
        $state = Read-JsonFile (Join-Path $directory 'state.json')
        if ($null -eq $state) {
            Write-Host '上次成功压缩：暂无；下一次检查将判断是否需要首次执行'
        } else {
            Write-Host ('上次尝试执行：{0}' -f (Format-LocalDate $state.LastRunUtc))
            Write-Host ('上次执行结果：{0}' -f $state.LastResult)
            Write-Host ('上次成功压缩：{0}' -f (Format-LocalDate $state.LastSuccessUtc))
            if (-not [string]::IsNullOrWhiteSpace([string]$state.LastSuccessUtc)) {
                $dueTime = [DateTimeOffset]::Parse([string]$state.LastSuccessUtc, [Globalization.CultureInfo]::InvariantCulture).AddDays($intervalDays)
                if ($dueTime -le [DateTimeOffset]::UtcNow) {
                    Write-Host '预计压缩到期：已经到期；下次检查时尝试执行'
                } else {
                    Write-Host ('预计压缩到期：{0}；到期后的首次检查时执行' -f $dueTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))
                }
            }
            if ($null -ne $state.LastSavedBytes) {
                Write-Host ('上次目标文件占用约减少：{0:N2} MiB' -f ([double]$state.LastSavedBytes / 1MB))
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$state.LastError)) {
                Write-Host ('上次错误：{0}' -f $state.LastError) -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host ('状态文件读取失败：{0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
    Write-Host ('结果日志：{0}' -f (Join-Path $directory 'logs'))
    Write-Host ''
}

function Install-Tool {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value
    $service = Get-ScheduleConnection
    $folder = $service.GetFolder('\')
    Assert-ToolTask (Find-ToolTask $folder)

    $requiredFiles = @('Runner.ps1','Archive.ps1','Manage.ps1','Settings.ps1','config.json','打开工具.cmd','安装自动压缩.cmd','使用说明.md')
    foreach ($fileName in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:SourceDirectory $fileName) -PathType Leaf)) {
            throw ('工具包缺少文件：{0}。请保留完整工具文件夹后再安装。' -f $fileName)
        }
    }
    $sourcePath = [IO.Path]::GetFullPath($script:SourceDirectory).TrimEnd('\')
    $targetPath = [IO.Path]::GetFullPath($script:InstallDirectory).TrimEnd('\')
    if (-not [string]::Equals($sourcePath, $targetPath, [StringComparison]::OrdinalIgnoreCase)) {
        $null = New-Item -ItemType Directory -Path $script:InstallDirectory -Force
        foreach ($fileName in $requiredFiles) {
            $destination = Join-Path $script:InstallDirectory $fileName
            if ($fileName -eq 'config.json' -and (Test-Path -LiteralPath $destination)) { continue }
            Copy-Item -LiteralPath (Join-Path $script:SourceDirectory $fileName) -Destination $destination -Force
        }
        $sourceState = Join-Path $script:SourceDirectory 'state.json'
        $targetState = Join-Path $script:InstallDirectory 'state.json'
        if ((Test-Path -LiteralPath $sourceState) -and -not (Test-Path -LiteralPath $targetState)) {
            Copy-Item -LiteralPath $sourceState -Destination $targetState
        }
    }

    $definition = $service.NewTask(0)
    $definition.RegistrationInfo.Author = $identity.Name
    $definition.RegistrationInfo.Source = $script:TaskSource
    $definition.RegistrationInfo.Description = '本地 Codex 文件透明压缩。每日及登录后检查，按配置间隔到期后才实际执行；不删除、不上传文件。'
    $definition.Principal.UserId = $sid
    $definition.Principal.LogonType = 3
    $definition.Principal.RunLevel = 0
    $definition.Settings.Enabled = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.MultipleInstances = 2
    $definition.Settings.ExecutionTimeLimit = 'PT2H'
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.RunOnlyIfNetworkAvailable = $false
    $definition.Settings.RunOnlyIfIdle = $false
    $definition.Settings.WakeToRun = $false
    $definition.Settings.Priority = 7

    $firstDailyCheck = [DateTime]::Today.AddHours(20)
    if ($firstDailyCheck -le [DateTime]::Now) { $firstDailyCheck = $firstDailyCheck.AddDays(1) }
    $daily = $definition.Triggers.Create(2)
    $daily.StartBoundary = $firstDailyCheck.ToString("yyyy-MM-dd'T'HH:mm:ss")
    $daily.DaysInterval = 1
    $daily.Enabled = $true
    $logon = $definition.Triggers.Create(9)
    $logon.UserId = $sid
    $logon.Delay = 'PT1M'
    $logon.Enabled = $true

    $taskAction = $definition.Actions.Create(0)
    $taskAction.Path = $script:PowerShellPath
    $taskAction.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $script:InstallDirectory 'Runner.ps1') + '" -Mode Due -ConfigPath "' + (Join-Path $script:InstallDirectory 'config.json') + '" -DataDirectory "' + $script:InstallDirectory + '"'
    $taskAction.WorkingDirectory = $script:InstallDirectory
    $null = $folder.RegisterTaskDefinition($script:TaskName, $definition, 6, $sid, $null, 3, $null)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:LocatorPath) -Force
    $locatorText = [pscustomobject]@{ InstallDirectory = $script:InstallDirectory } | ConvertTo-Json
    [IO.File]::WriteAllText($script:LocatorPath, $locatorText, (New-Object Text.UTF8Encoding($true)))
    Write-Host '自动压缩已安装。无需管理员权限，也未保存登录密码。' -ForegroundColor Green
    Write-Host '每天 20:00 及登录后 1 分钟检查；达到设置中的天数才实际压缩。'
    Write-Host '电脑关机或退出登录期间不执行，之后登录时补检查。'
    Show-ToolStatus
}

function Set-ToolEnabled([bool]$Enabled) {
    $service = Get-ScheduleConnection
    $folder = $service.GetFolder('\')
    $task = Find-ToolTask $folder
    if ($null -eq $task) { throw '尚未安装自动任务，请先选择安装。' }
    Assert-ToolTask $task
    $task.Enabled = $Enabled
    if ($Enabled) { Write-Host '自动检查已启用。' -ForegroundColor Green }
    else { Write-Host '自动检查已停用。文件和日志保留。' -ForegroundColor Yellow }
}

function Remove-ToolTask {
    $service = Get-ScheduleConnection
    $folder = $service.GetFolder('\')
    $task = Find-ToolTask $folder
    if ($null -eq $task) { Write-Host '自动任务已经不存在。'; return }
    Assert-ToolTask $task
    $folder.DeleteTask($script:TaskName, 0)
    Write-Host '自动任务已移除。工具文件、日志和已压缩的数据均保留。' -ForegroundColor Green
}

function Run-ToolNow {
    $directory = Get-EffectiveDirectory
    $runner = Join-Path $directory 'Runner.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw '找不到 Runner.ps1，请保留完整工具包。' }
    Write-Host '开始立即压缩；会自动跳过过新、被占用或不适合处理的文件。'
    & $script:PowerShellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Mode Now -ConfigPath (Join-Path $directory 'config.json') -DataDirectory $directory
    if ($LASTEXITCODE -ne 0) { throw ('压缩运行返回 {0}；请查看状态及 logs 文件夹。' -f $LASTEXITCODE) }
    Show-ToolStatus
}

function Open-ToolSettings {
    $directory = Get-EffectiveDirectory
    $settingsPath = Join-Path $directory 'Settings.ps1'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw '找不到 Settings.ps1，请保留完整工具包或更新安装。' }
    & $script:PowerShellPath -NoProfile -STA -ExecutionPolicy Bypass -File $settingsPath -ConfigPath (Join-Path $directory 'config.json')
    if ($LASTEXITCODE -ne 0) { throw ('设置窗口返回 {0}。' -f $LASTEXITCODE) }
}

function Show-ToolPreview {
    $directory = Get-EffectiveDirectory
    $runner = Join-Path $directory 'Runner.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw '找不到 Runner.ps1，请保留完整工具包。' }
    Write-Host '开始扫描预览；此操作不压缩、不生成 ZIP 副本。'
    & $script:PowerShellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Mode Scan -ConfigPath (Join-Path $directory 'config.json') -DataDirectory $directory
    if ($LASTEXITCODE -ne 0) { throw ('扫描返回 {0}；请查看输出及日志。' -f $LASTEXITCODE) }
}

function Show-FormatComparison {
    $directory = Get-EffectiveDirectory
    $runner = Join-Path $directory 'Runner.ps1'
    $comparisonConfig = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($comparisonConfig)) { $comparisonConfig = Join-Path $directory 'config.json' }
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw '找不到 Runner.ps1，请保留完整工具包。' }
    Write-Host '正在对已保存配置中的文件进行格式实测。使用有限样本；临时压缩副本在测试后删除。' -ForegroundColor Cyan
    $output = & $script:PowerShellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Mode Compare -ConfigPath $comparisonConfig -DataDirectory $directory
    if ($LASTEXITCODE -ne 0) { throw ('格式实测失败（返回 {0}）：{1}' -f $LASTEXITCODE, ($output -join [Environment]::NewLine)) }
    $report = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    Write-Host ('样本：{0} 个文件，原大小 {1:N2} MiB；符合条件的文件共 {2} 个。' -f $report.SampleFiles, ([double]$report.SampleBytes / 1MB), $report.EligibleFiles)
    if ($report.Result -eq 'NoSample') { Write-Host '没有可用于实测的文件。单个样本不能超过 32 MiB，请调整来源或大小范围后再试。' -ForegroundColor Yellow }
    if ($report.PartialSample) { Write-Host '只测试了部分文件，不能按比例推算全部资料的压缩后空间。' -ForegroundColor Yellow }
    $rows = foreach ($format in @($report.Formats)) {
        [pscustomobject][ordered]@{
            '格式' = [string]$format.Name
            '结果' = [string]$format.Result
            '样本原大小MiB' = if ($null -ne $format.OriginalBytes) { '{0:N2}' -f ([double]$format.OriginalBytes / 1MB) } else { '-' }
            '副本大小MiB' = if ($null -ne $format.ArchiveBytes) { '{0:N2}' -f ([double]$format.ArchiveBytes / 1MB) } else { '-' }
            '副本比例%' = if ($null -ne $format.RatioPercent) { '{0:N1}' -f [double]$format.RatioPercent } else { '-' }
            '节省%' = if ($null -ne $format.SavedPercent) { '{0:N1}' -f [double]$format.SavedPercent } else { '-' }
            '耗时秒' = if ($null -ne $format.Seconds) { '{0:N2}' -f [double]$format.Seconds } else { '-' }
            '错误' = [string]$format.Error
        }
    }
    $rows | Format-Table -AutoSize -Wrap | Out-Host
    Write-Host '这是样本归档副本实测，副本大小并非原文件实际占用。原地 NTFS 压缩另算。'
    Write-Host '原文件仍保留：开启归档后，总占用 = 原文件当前占用 + 归档副本占用。'
    Write-Host ('最近报告：{0}' -f (Join-Path $directory 'formats-last.json'))
}

function Show-ToolMenu {
    while ($true) {
        Write-Host ''
        Write-Host '===== Codex 自动压缩 =====' -ForegroundColor Cyan
        Write-Host '1. 查看状态'
        Write-Host '2. 安装 / 更新自动任务'
        Write-Host '3. 立即压缩一次'
        Write-Host '4. 暂停自动检查'
        Write-Host '5. 恢复自动检查'
        Write-Host '6. 移除自动任务（保留文件）'
        Write-Host '7. 设置天数、大小范围和保存路径'
        Write-Host '8. 扫描预览（不压缩）'
        Write-Host '9. 格式实测对比（小样本）'
        Write-Host '0. 退出'
        $choice = Read-Host '输入数字后按回车'
        try {
            switch ($choice) {
                '1' { Show-ToolStatus }
                '2' { Install-Tool }
                '3' { Run-ToolNow }
                '4' { Set-ToolEnabled $false }
                '5' { Set-ToolEnabled $true }
                '6' { Remove-ToolTask }
                '7' { Open-ToolSettings }
                '8' { Show-ToolPreview }
                '9' { Show-FormatComparison }
                '0' { return }
                default { Write-Host '请输入 0 到 9。' }
            }
        } catch {
            Write-Host ('操作未完成：{0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }
}

try {
    if ($PreferInstalled) {
        $installedManager = Join-Path $script:InstallDirectory 'Manage.ps1'
        if ((Test-Path -LiteralPath $installedManager -PathType Leaf) -and
            -not [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), [IO.Path]::GetFullPath($installedManager), [StringComparison]::OrdinalIgnoreCase)) {
            $forwardArguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installedManager,'-Action',$Action,'-InstallDirectory',$script:InstallDirectory)
            if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $forwardArguments += @('-ConfigPath',$ConfigPath) }
            & $script:PowerShellPath @forwardArguments
            exit $LASTEXITCODE
        }
    }
    switch ($Action) {
        'Menu' { Show-ToolMenu }
        'Install' { Install-Tool }
        'Status' { Show-ToolStatus }
        'RunNow' { Run-ToolNow }
        'Disable' { Set-ToolEnabled $false }
        'Enable' { Set-ToolEnabled $true }
        'UninstallTask' { Remove-ToolTask }
        'Settings' { Open-ToolSettings }
        'Scan' { Show-ToolPreview }
        'Compare' { Show-FormatComparison }
    }
} catch {
    Write-Host ('操作未完成：{0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
