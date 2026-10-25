param(
    [string]$RunnerPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Runner.ps1'),
    [string]$WorkspaceRoot = (Join-Path ([IO.Path]::GetTempPath()) ('CodexAutoCompact.Tests-' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'These integration tests require Windows and NTFS.' }
$RunnerPath = [IO.Path]::GetFullPath($RunnerPath)
if (-not [IO.File]::Exists($RunnerPath)) { throw ('Runner not found: ' + $RunnerPath) }
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)
if (Test-Path -LiteralPath $WorkspaceRoot) { throw 'Use a new, empty WorkspaceRoot; tests never overwrite an existing directory.' }
$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($WorkspaceRoot))
if ($drive.DriveFormat -ne 'NTFS') { throw 'Real compression tests require an NTFS workspace.' }
$null = New-Item -ItemType Directory -Path $WorkspaceRoot
$engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8 = New-Object Text.UTF8Encoding $true
$script:Passed = 0
$script:Cases = New-Object 'Collections.Generic.List[object]'

function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10), $utf8)
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}

function Is-Compressed([string]$Path) {
    return (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::Compressed) -ne 0)
}

function New-TextFixture([string]$Path, [int]$Length = 65536, [bool]$Old = $true) {
    $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
    $content = ('Codex local compression integration fixture. ' * ([int]($Length / 40) + 2)).Substring(0, $Length)
    [IO.File]::WriteAllText($Path, $content, (New-Object Text.UTF8Encoding $false))
    if ($Old) { [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddDays(-3)) }
    # TEMP may inherit NTFS compression from its parent; each fixture starts uncompressed.
    $null = & (Join-Path $env:SystemRoot 'System32\compact.exe') /U /A /I /Q $Path 2>&1
    if (Is-Compressed $Path) { throw ('Could not prepare an uncompressed fixture: ' + $Path) }
    if ($Old) { [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddDays(-3)) }
    return $Path
}

function New-Case([string]$Name) {
    $root = Join-Path $WorkspaceRoot $Name
    $source = Join-Path $root 'source'
    $data = Join-Path $root 'data'
    $null = New-Item -ItemType Directory -Path $source -Force
    $null = New-Item -ItemType Directory -Path $data -Force
    $config = [ordered]@{
        SchemaVersion = 1
        IntervalDays = 30
        MinimumAgeHours = 24
        MinimumBytes = 8192
        MaximumBytes = 131072
        SessionRoots = @()
        ProjectSearchRoots = @()
        StaticRoots = @($source)
        ArchiveDirectory = ''
        MaxLogs = 24
    }
    $configPath = Join-Path $root 'config.json'
    Write-Json $configPath $config
    return [pscustomobject]@{ Root = $root; Source = $source; Data = $data; Config = $config; ConfigPath = $configPath }
}

function Invoke-Runner($Case, [string]$Mode, [int]$ExpectedCode = 0) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $RunnerPath -Mode $Mode -ConfigPath $Case.ConfigPath -DataDirectory $Case.Data 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $log = Join-Path $Case.Root ('invoke-' + $Mode + '-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($log, $text, $utf8)
    if ($code -ne $ExpectedCode) {
        throw ('Expected exit {0}, got {1}; output: {2}; full log: {3}' -f $ExpectedCode, $code, (($text -split '\r?\n' | Select-Object -Last 8) -join ' | '), $log)
    }
    $script:Passed++
}

function Read-State($Case) {
    $path = Join-Path $Case.Data 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Run-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Cases.Add([pscustomobject]@{ Name = $Name; Result = 'Passed' })
        Write-Host ('PASS ' + $Name) -ForegroundColor Green
    } catch {
        $script:Cases.Add([pscustomobject]@{ Name = $Name; Result = 'Failed'; Error = $_.Exception.Message })
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}

Run-Case 'Scan is read only' {
    $case = New-Case 'scan'
    $file = New-TextFixture (Join-Path $case.Source 'scan.txt')
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    Invoke-Runner $case 'Scan'
    Assert-True (-not (Is-Compressed $file)) 'Scan changed compression.'
    Assert-True ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $hash) 'Scan changed contents.'
    $state = Read-State $case
    Assert-True ($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.LastSuccessUtc)) 'Scan recorded a successful compression run.'
}

Run-Case 'Real compression preserves contents and respects exclusions' {
    $case = New-Case 'filters'
    $allowed = New-TextFixture (Join-Path $case.Source 'eligible.txt')
    $hash = (Get-FileHash -LiteralPath $allowed -Algorithm SHA256).Hash
    $mtime = [IO.File]::GetLastWriteTimeUtc($allowed)
    $skipped = @(
        (New-TextFixture (Join-Path $case.Source 'small.txt') 4096),
        (New-TextFixture (Join-Path $case.Source 'large.txt') 262144),
        (New-TextFixture (Join-Path $case.Source 'new.txt') 65536 $false),
        (New-TextFixture (Join-Path $case.Source 'state.db')),
        (New-TextFixture (Join-Path $case.Source 'state.sqlite')),
        (New-TextFixture (Join-Path $case.Source 'state.db-wal')),
        (New-TextFixture (Join-Path $case.Source 'state.db-shm')),
        (New-TextFixture (Join-Path $case.Source 'settings.lock'))
    )
    $lockedPath = New-TextFixture (Join-Path $case.Source 'active.txt')
    $handle = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Invoke-Runner $case 'Now' } finally { $handle.Dispose() }
    Assert-True (Is-Compressed $allowed) 'Eligible text was not compressed.'
    Assert-True ((Get-FileHash -LiteralPath $allowed -Algorithm SHA256).Hash -eq $hash) 'Compression changed content bytes.'
    Assert-True ([IO.File]::GetLastWriteTimeUtc($allowed) -eq $mtime) 'Compression changed modification time.'
    foreach ($path in $skipped + @($lockedPath)) {
        Assert-True (-not (Is-Compressed $path)) ('Excluded file was compressed: ' + [IO.Path]::GetFileName($path))
    }
    $state = Read-State $case
    Assert-True ($null -ne $state -and -not [string]::IsNullOrWhiteSpace([string]$state.LastSuccessUtc)) 'Successful compression was not recorded.'
    Assert-True ([long]$state.LastSavedBytes -gt 0) 'Compressible fixture should save allocated bytes.'
}

Run-Case 'Session roots accept JSONL only' {
    $case = New-Case 'sessions'
    $case.Config.StaticRoots = @()
    $case.Config.SessionRoots = @($case.Source)
    Write-Json $case.ConfigPath $case.Config
    $allowed = New-TextFixture (Join-Path $case.Source 'session.jsonl')
    $other = New-TextFixture (Join-Path $case.Source 'other.txt')
    Invoke-Runner $case 'Now'
    Assert-True (Is-Compressed $allowed) 'Old JSONL was not compressed.'
    Assert-True (-not (Is-Compressed $other)) 'Non-JSONL file in SessionRoots was compressed.'
}

Run-Case 'Browser profiles stay excluded when a parent folder is selected' {
    $case = New-Case 'browser-parent'
    $normal = New-TextFixture (Join-Path $case.Source 'normal.txt')
    $browserFiles = @(
        (New-TextFixture (Join-Path $case.Source 'Google\Chrome\User Data\Default\Cookies')),
        (New-TextFixture (Join-Path $case.Source 'Microsoft\Edge\User Data\Default\Login Data')),
        (New-TextFixture (Join-Path $case.Source 'Mozilla\Firefox\Profiles\test\logins.json'))
    )
    Invoke-Runner $case 'Now'
    Assert-True (Is-Compressed $normal) 'Ordinary file under selected parent was not processed.'
    foreach ($file in $browserFiles) {
        Assert-True (-not (Is-Compressed $file)) ('Browser data was compressed through a selected ancestor: ' + $file)
    }
}

Run-Case 'Due interval can be customized' {
    $case = New-Case 'due'
    $file = New-TextFixture (Join-Path $case.Source 'due.txt')
    $case.Config.IntervalDays = 30
    Write-Json $case.ConfigPath $case.Config
    $lastSuccess = [DateTimeOffset]::UtcNow.AddDays(-29).ToString('o')
    Write-Json (Join-Path $case.Data 'state.json') ([ordered]@{ LastSuccessUtc = $lastSuccess; LastRunUtc = $lastSuccess; LastResult = 'Success'; LastSavedBytes = 0; LastError = '' })
    Invoke-Runner $case 'Due'
    Assert-True (-not (Is-Compressed $file)) 'Due compressed before the 30-day interval.'
    Assert-True ((Read-State $case).LastSuccessUtc -eq $lastSuccess) 'A not-due check changed LastSuccessUtc.'
    $case.Config.IntervalDays = 7
    Write-Json $case.ConfigPath $case.Config
    Invoke-Runner $case 'Due'
    Assert-True (Is-Compressed $file) 'Customized 7-day interval was not applied.'
    Assert-True ((Read-State $case).LastSuccessUtc -ne $lastSuccess) 'Due run did not advance LastSuccessUtc.'
    $boundary = New-Case 'due-thirty-days'
    $boundaryFile = New-TextFixture (Join-Path $boundary.Source 'after-30-days.txt')
    $old = [DateTimeOffset]::UtcNow.AddDays(-30).AddMinutes(-1).ToString('o')
    Write-Json (Join-Path $boundary.Data 'state.json') ([ordered]@{ LastSuccessUtc = $old; LastRunUtc = $old; LastResult = 'Success'; LastSavedBytes = 0; LastError = '' })
    Invoke-Runner $boundary 'Due'
    Assert-True (Is-Compressed $boundaryFile) 'Due did not compress after 30 days.'
}

Run-Case 'Exclusive run lock prevents concurrent writes' {
    $case = New-Case 'lock'
    $file = New-TextFixture (Join-Path $case.Source 'concurrent.txt')
    $lock = [IO.File]::Open((Join-Path $case.Data 'run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Invoke-Runner $case 'Now' 2 } finally { $lock.Dispose() }
    Assert-True (-not (Is-Compressed $file)) 'Second run ignored the exclusive lock.'
    Assert-True ($null -eq (Read-State $case)) 'Blocked concurrent run wrote state.'
}

Run-Case 'Configuration errors do not erase prior success' {
    $case = New-Case 'failure'
    $lastSuccess = [DateTimeOffset]::UtcNow.AddDays(-40).ToString('o')
    Write-Json (Join-Path $case.Data 'state.json') ([ordered]@{ LastSuccessUtc = $lastSuccess; LastRunUtc = $lastSuccess; LastResult = 'Success'; LastSavedBytes = 5; LastError = '' })
    $case.Config.IntervalDays = 0
    Write-Json $case.ConfigPath $case.Config
    Invoke-Runner $case 'Now' 1
    Assert-True ((Read-State $case).LastSuccessUtc -eq $lastSuccess) 'Failed run changed prior successful timestamp.'
}

Run-Case 'Log failures do not postpone the next due run' {
    $case = New-Case 'log-failure'
    $null = New-TextFixture (Join-Path $case.Source 'pending.txt')
    $lastSuccess = [DateTimeOffset]::UtcNow.AddDays(-40).ToString('o')
    Write-Json (Join-Path $case.Data 'state.json') ([ordered]@{ LastSuccessUtc = $lastSuccess; LastRunUtc = $lastSuccess; LastResult = 'Success'; LastSavedBytes = 5; LastError = '' })
    [IO.File]::WriteAllText((Join-Path $case.Data 'logs'), 'An ordinary file blocks the log directory.')
    Invoke-Runner $case 'Due' 1
    Assert-True ((Read-State $case).LastSuccessUtc -eq $lastSuccess) 'A failed run advanced LastSuccessUtc and postponed retry.'
}

Run-Case 'Directory junctions are not traversed' {
    $case = New-Case 'junction'
    $target = Join-Path $case.Root 'outside-source'
    $secret = New-TextFixture (Join-Path $target 'must-stay-uncompressed.txt')
    $link = Join-Path $case.Source 'junction'
    $null = New-Item -ItemType Junction -Path $link -Value $target
    $normal = New-TextFixture (Join-Path $case.Source 'normal.txt')
    Invoke-Runner $case 'Now'
    Assert-True (Is-Compressed $normal) 'Regular source file was not processed.'
    Assert-True (-not (Is-Compressed $secret)) 'Runner traversed a directory junction.'
}

Run-Case 'Optional ZIP destination preserves originals and bytes' {
    $case = New-Case 'archive'
    $file = New-TextFixture (Join-Path $case.Source 'original.txt')
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    $destination = Join-Path $case.Root 'selected destination'
    $case.Config.ArchiveDirectory = $destination
    Write-Json $case.ConfigPath $case.Config
    Invoke-Runner $case 'Now'
    Assert-True ([IO.File]::Exists($file)) 'Archive mode removed the original path.'
    Assert-True ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $hash) 'Archive mode changed the original bytes.'
    $archives = @(Get-ChildItem -LiteralPath $destination -Filter '*.zip' -File -Recurse)
    Assert-True ($archives.Count -gt 0) 'No ZIP was saved to the selected destination.'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $found = $false
    foreach ($archive in $archives) {
        $zip = [IO.Compression.ZipFile]::OpenRead($archive.FullName)
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.Length -ne [IO.File]::ReadAllBytes($file).Length) { continue }
                $stream = $entry.Open()
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $entryHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
                finally { $sha.Dispose(); $stream.Dispose() }
                if ($entryHash -eq $hash) { $found = $true }
            }
        } finally { $zip.Dispose() }
    }
    Assert-True $found 'ZIP does not contain a byte-identical copy of the fixture.'
}

$failed = @($script:Cases | Where-Object { $_.Result -eq 'Failed' })
$report = [ordered]@{
    TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    WorkspaceRoot = $WorkspaceRoot
    AssertionsPassed = $script:Passed
    CasesPassed = @($script:Cases | Where-Object { $_.Result -eq 'Passed' }).Count
    CasesFailed = $failed.Count
    Cases = $script:Cases.ToArray()
}
Write-Json (Join-Path $WorkspaceRoot 'test-results.json') $report
Write-Host ('Assertions passed: {0}; cases passed: {1}; cases failed: {2}' -f $script:Passed, $report.CasesPassed, $report.CasesFailed)
Write-Host ('Evidence retained at: ' + $WorkspaceRoot)
if ($failed.Count -gt 0) { exit 1 }
exit 0
