param(
    [string]$ArchiveModule = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Archive.ps1'),
    [string]$WorkspaceRoot = (Join-Path ([IO.Path]::GetTempPath()) ('CodexAutoCompact.Archives-' + [guid]::NewGuid().ToString('N'))),
    [string]$OtherRoot = ''
)

$ErrorActionPreference = 'Stop'
. $ArchiveModule
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $WorkspaceRoot) { throw 'Use a new WorkspaceRoot.' }
$null = New-Item -ItemType Directory -Path $WorkspaceRoot
if (-not $OtherRoot) { $OtherRoot = Join-Path $WorkspaceRoot 'second-root' }
if (Test-Path -LiteralPath $OtherRoot) { throw 'Use a new OtherRoot.' }
$rootA = Join-Path $WorkspaceRoot 'first root'
$rootB = $OtherRoot
$null = New-Item -ItemType Directory -Path $rootA -Force
$null = New-Item -ItemType Directory -Path $rootB -Force
$utf8 = New-Object Text.UTF8Encoding $false
$paths = @(
    (Join-Path $rootA '同名 文件.txt'),
    (Join-Path $rootB '同名 文件.txt'),
    (Join-Path $rootA (('long-path-' + ('a' * 80)) + '\Unicode 测试.dat'))
)
$records = New-Object 'Collections.Generic.List[object]'
$expected = @{}
for ($i=0; $i -lt $paths.Count; $i++) {
    $path = $paths[$i]
    $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
    [IO.File]::WriteAllText($path, (('Fixture number ' + $i + ' 中文 content. ') * 3000), $utf8)
    [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-5))
    $info = Get-Item -LiteralPath $path
    $root = if ($i -eq 1) { $rootB } else { $rootA }
    $records.Add([pscustomobject]@{Path=$path;Root=$root;Length=$info.Length;Ticks=$info.LastWriteTimeUtc.Ticks})
    $expected[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Test-Unchanged($Record) {
    if (-not [IO.File]::Exists($Record.Path)) { return $false }
    $info = Get-Item -LiteralPath $Record.Path -Force
    return ($info.Length -eq $Record.Length -and $info.LastWriteTimeUtc.Ticks -eq $Record.Ticks)
}

$script:Assertions = 0
function Assert-ArchiveTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Assertions++
}

$results = New-Object 'Collections.Generic.List[object]'
foreach ($format in @('ZIP','TAR.GZ')) {
    Assert-ArchiveTest (Get-AutoCompactFormatAvailability $format).Available ('Format unavailable: ' + $format)
    foreach ($level in @('Fastest','Optimal')) {
        $output = Join-Path $WorkspaceRoot ($format.Replace('.','-') + '-' + $level)
        $result = New-AutoCompactArchive $records $output $format $level
        Assert-ArchiveTest ([IO.File]::Exists($result.Path)) 'Archive missing.'
        Assert-ArchiveTest ($result.Files -eq $records.Count) 'Wrong archived file count.'
        $total = 0L
        foreach ($record in $records) { $total += $record.Length }
        Assert-ArchiveTest ($result.OriginalBytes -eq $total) 'Wrong uncompressed byte count.'
        Assert-ArchiveTest ($result.ArchiveBytes -gt 0 -and $result.ArchiveBytes -lt $result.OriginalBytes) 'Archive size should be positive and smaller for these compressible fixtures.'
        $extract = Join-Path $output 'extracted'
        $null = New-Item -ItemType Directory -Path $extract
        if ($format -eq 'ZIP') {
            [IO.Compression.ZipFile]::ExtractToDirectory($result.Path, $extract)
        } else {
            $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
            if (-not [IO.File]::Exists($tar)) { throw 'Native tar.exe is required to independently verify the TAR.GZ writer.' }
            $nativeOutput = @(& $tar -xzf $result.Path -C $extract 2>&1)
            if ($LASTEXITCODE -ne 0) { throw ('Native tar extraction failed: ' + ($nativeOutput -join ' ')) }
        }
        $extracted = @(Get-ChildItem -LiteralPath $extract -File -Recurse)
        Assert-ArchiveTest ($extracted.Count -eq $records.Count) 'Extraction has missing or duplicate files.'
        foreach ($record in $records) {
            $label = if ($record.Root -eq $rootA) { 'root-001' } else { 'root-002' }
            $relative = $record.Path.Substring($record.Root.Length).TrimStart('\')
            $copy = Join-Path (Join-Path $extract $label) $relative
            Assert-ArchiveTest ([IO.File]::Exists($copy)) ('Entry path was not preserved: ' + $copy)
            Assert-ArchiveTest ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -eq $expected[$record.Path]) 'Extracted content hash differs.'
            Assert-ArchiveTest ((Get-FileHash -LiteralPath $record.Path -Algorithm SHA256).Hash -eq $expected[$record.Path]) 'Original content changed.'
            Assert-ArchiveTest ([IO.File]::GetLastWriteTimeUtc($record.Path).Ticks -eq $record.Ticks) 'Original modification time changed.'
        }
        $results.Add($result)
        Write-Host ('PASS {0} {1}: {2} bytes -> {3} bytes' -f $format,$level,$result.OriginalBytes,$result.ArchiveBytes)
    }
}

foreach ($format in @('ZIP','TAR.GZ')) {
    $failedDirectory = Join-Path $WorkspaceRoot ('failed-' + $format.Replace('.','-'))
    $invalid = [pscustomobject]@{ Path=$records[0].Path; Root=$records[0].Root; Length=$records[0].Length; Ticks=($records[0].Ticks - 10000000L) }
    $threw = $false
    try { $null = New-AutoCompactArchive @($invalid) $failedDirectory $format 'Optimal' }
    catch { $threw = $true }
    Assert-ArchiveTest $threw 'Changed source did not abort the archive.'
    $leftovers = @(Get-ChildItem -LiteralPath $failedDirectory -File)
    Assert-ArchiveTest ($leftovers.Count -eq 0) 'Failed archive left a partial or final file.'
}
Assert-ArchiveTest (-not (Get-AutoCompactFormatAvailability '7Z').Available) 'Unsupported format should be explicit.'

$summary = [ordered]@{
    TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    AssertionsPassed = $script:Assertions
    WorkspaceRoot = $WorkspaceRoot
    OtherRoot = $OtherRoot
    Results = $results.ToArray()
}
[IO.File]::WriteAllText((Join-Path $WorkspaceRoot 'archive-test-results.json'), ($summary | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $true))
Write-Host ('PASS archive tests; assertions: ' + $script:Assertions)
Write-Host ('Evidence retained at: ' + $WorkspaceRoot)
