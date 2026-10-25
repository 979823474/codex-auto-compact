param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$WorkspaceRoot = (Join-Path ([IO.Path]::GetTempPath()) ('CodexAutoCompact.CompareTests-' + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)
if (Test-Path -LiteralPath $WorkspaceRoot) { throw 'Use a new test directory.' }
$source = Join-Path $WorkspaceRoot 'source'
$data = Join-Path $WorkspaceRoot 'data'
$null = [IO.Directory]::CreateDirectory($source)
$null = [IO.Directory]::CreateDirectory($data)
$engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$encoding = New-Object Text.UTF8Encoding $true
$assertions = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
    $script:assertions++
}
function Save-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), $encoding)
}
function Invoke-TestRunner([string]$Mode) {
    $output = & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Root 'Runner.ps1') -Mode $Mode -ConfigPath $configPath -DataDirectory $data
    if ($LASTEXITCODE -ne 0) { throw ('Runner failed: ' + ($output -join [Environment]::NewLine)) }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}
for ($i=0; $i -lt 70; $i++) {
    $path = Join-Path $source ('sample-{0:D3}.txt' -f $i)
    [IO.File]::WriteAllText($path, ('Archive comparison fixture. ' * 400), $encoding)
    [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-3))
}
$large = Join-Path $source 'larger-than-sample-limit.txt'
$largeStream = [IO.File]::Create($large)
try { $largeStream.SetLength(33MB) } finally { $largeStream.Dispose() }
[IO.File]::SetLastWriteTimeUtc($large, [DateTime]::UtcNow.AddDays(-3))
$null = & (Join-Path $env:SystemRoot 'System32\compact.exe') /U /A /I /Q ((Join-Path $source '*')) 2>&1
$config = [ordered]@{
    SchemaVersion=1; IntervalDays=30; MinimumAgeHours=24; MinimumBytes=1; MaximumBytes=0
    SessionRoots=@(); ProjectSearchRoots=@(); StaticRoots=@($source)
    ArchiveDirectory=''; ArchiveFormat='ZIP'; ArchiveCompression='Optimal'; MaxLogs=24
}
$configPath = Join-Path $WorkspaceRoot 'config.json'
Save-Json $configPath $config
$statePath = Join-Path $data 'state.json'
Save-Json $statePath ([ordered]@{ LastSuccessUtc='2020-01-01T00:00:00Z'; LastResult='Success' })
$beforeState = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
$probe = Join-Path $source 'sample-000.txt'
$beforeHash = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
$beforeTime = [IO.File]::GetLastWriteTimeUtc($probe).Ticks
$result = Invoke-TestRunner 'Compare'
Check ($result.Result -eq 'Compared') 'Comparison did not complete.'
Check ($result.SampleFiles -eq 64) 'The file-count sample limit was not applied.'
Check ($result.SampleBytes -le 32MB) 'The byte sample limit was exceeded.'
Check ($result.EligibleFiles -eq 71 -and $result.PartialSample) 'Partial sampling was not reported.'
Check (@($result.Formats).Count -eq 2) 'Both archive formats must be compared.'
foreach ($row in $result.Formats) {
    Check ($row.Result -eq 'Success') ('Comparison failed for ' + $row.Name)
    Check ($row.ArchiveBytes -gt 0 -and $row.OriginalBytes -eq $result.SampleBytes) 'Measured archive sizes are invalid.'
    Check ([Math]::Abs($row.RatioPercent - (100.0 * $row.ArchiveBytes / $row.OriginalBytes)) -lt 0.011) 'Compression ratio differs from measured sizes.'
}
Check ((Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash -eq $beforeState) 'Comparison changed the successful-run state.'
Check ((Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash -eq $beforeHash -and [IO.File]::GetLastWriteTimeUtc($probe).Ticks -eq $beforeTime) 'Comparison changed source contents or timestamps.'
Check (([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::Compressed) -eq 0) 'Comparison enabled NTFS compression on a source.'
Check (-not (Test-Path -LiteralPath (Join-Path $data 'logs'))) 'Comparison wrote regular run logs.'
Check (@(Get-ChildItem -LiteralPath $data -Directory -Filter 'compare-*').Count -eq 0) 'Temporary comparison archives were not removed.'
Check (Test-Path -LiteralPath (Join-Path $data 'formats-last.json')) 'Comparison report was not saved.'

# Exercise TAR.GZ through the real Runner integration, separately from sampling.
$config.MaximumBytes = 65536
$config.ArchiveDirectory = Join-Path $WorkspaceRoot 'copies'
$config.ArchiveFormat = 'TAR.GZ'
Save-Json $configPath $config
$run = Invoke-TestRunner 'Now'
Check ($run.Result -eq 'Success' -and $run.ArchiveFormat -eq 'TAR.GZ') 'Configured archive format was not used.'
Check ($run.ArchivePath.EndsWith('.tar.gz') -and (Test-Path -LiteralPath $run.ArchivePath)) 'TAR.GZ output is missing.'
Check ($run.ArchiveFiles -eq 70 -and $run.ArchiveBytes -gt 0) 'Actual archive metrics were not reported.'
Check ((Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash -eq $beforeHash) 'Runner changed source contents.'
$summary = [ordered]@{ PowerShellVersion=$PSVersionTable.PSVersion.ToString(); AssertionsPassed=$assertions; Result='Passed' }
Save-Json (Join-Path $WorkspaceRoot 'test-results.json') $summary
$summary | ConvertTo-Json -Compress
