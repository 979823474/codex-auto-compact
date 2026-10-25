[CmdletBinding()]
param(
    [ValidateSet('Due','Now','Scan','Compare')][string]$Mode = 'Due',
    [string]$ConfigPath = '',
    [string]$DataDirectory = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
if (-not $DataDirectory) { $DataDirectory = $PSScriptRoot }
$script:Problems = New-Object 'System.Collections.Generic.List[string]'
$script:Stats = [ordered]@{ Mode=$Mode; Result='Starting'; Roots=0; Examined=0; Eligible=0; AlreadyCompressed=0; Compressed=0; Skipped=0; SavedBytes=0L; SourceLogicalBytes=0L; SourceDiskBytes=0L; ArchiveFiles=0; ArchivePath=$null; ArchiveFormat=$null; ArchiveBytes=0L; ArchiveOriginalBytes=0L; ArchiveRatioPercent=$null; ArchiveSeconds=0.0; Errors=0 }
$script:SeenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:Roots = New-Object 'System.Collections.Generic.List[object]'
$script:SeenRoots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:SkippedDirectories = @('.git','.svn','node_modules','.venv','venv','outputs','Tools','.cache','__pycache__','.codex','.ssh','.aws','.azure')
$script:ExcludedExtensions = @('.db','.sqlite','.sqlite3','.wal','.shm','.lock','.zip','.7z','.rar','.gz','.xz','.bz2','.zst','.png','.jpg','.jpeg','.webp','.gif','.mp4','.mkv','.mp3','.pdf','.iso','.vhd','.vhdx','.pfx','.pem','.key')
$script:Lock = $null
$script:State = $null
$exitCode = 0

function Read-Json([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Write-AtomicJson([string]$Path, $Value) {
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $true))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Add-Problem([string]$Text) {
    $script:Stats.Errors++
    if ($script:Problems.Count -lt 30) { $script:Problems.Add($Text) }
}

function Expand-LocalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A folder path is empty.' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -notmatch '^[A-Za-z]:[\\/]') { throw "Use an absolute local drive path: $Path" }
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
}

function Test-Within([string]$Path, [string]$Parent) {
    return ($Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Test-SafeAncestors([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $true
}

function Assert-Ntfs([string]$Path) {
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Path))
    if (-not $drive.IsReady -or $drive.DriveFormat -ne 'NTFS') { throw "NTFS is required: $Path" }
}

function Read-Configuration {
    $c = Read-Json $ConfigPath
    if ($null -eq $c) { throw "Configuration not found: $ConfigPath" }
    foreach ($property in @('SchemaVersion','IntervalDays','MinimumAgeHours','MinimumBytes','MaximumBytes','SessionRoots','ProjectSearchRoots','StaticRoots','ArchiveDirectory','MaxLogs')) {
        if ($null -eq $c.PSObject.Properties[$property]) { throw "Missing configuration field: $property" }
    }
    foreach ($pair in @(@('IntervalDays',1,3650),@('MinimumAgeHours',0,87600),@('MinimumBytes',0,[long]::MaxValue),@('MaximumBytes',0,[long]::MaxValue),@('MaxLogs',1,1000))) {
        $number = 0L
        if (-not [long]::TryParse([string]$c.($pair[0]), [ref]$number) -or $number -lt $pair[1] -or $number -gt $pair[2]) { throw "Invalid configuration field: $($pair[0])" }
    }
    if ($c.SchemaVersion -ne 1) { throw 'Unsupported SchemaVersion.' }
    if ($null -eq $c.PSObject.Properties['ArchiveFormat']) { $c | Add-Member NoteProperty ArchiveFormat 'ZIP' }
    if ($null -eq $c.PSObject.Properties['ArchiveCompression']) { $c | Add-Member NoteProperty ArchiveCompression 'Optimal' }
    if ($c.ArchiveFormat -notin @('ZIP','TAR.GZ')) { throw 'ArchiveFormat must be ZIP or TAR.GZ.' }
    if ($c.ArchiveCompression -notin @('Fastest','Optimal')) { throw 'ArchiveCompression must be Fastest or Optimal.' }
    if ([long]$c.MaximumBytes -gt 0 -and [long]$c.MaximumBytes -lt [long]$c.MinimumBytes) { throw 'MaximumBytes must be zero (unlimited) or at least MinimumBytes.' }
    foreach ($property in @('SessionRoots','ProjectSearchRoots','StaticRoots')) {
        if ($null -eq $c.$property -or $c.$property -is [string]) { throw "$property must be an array." }
        foreach ($path in $c.$property) { $null = Expand-LocalPath ([string]$path) }
    }
    return $c
}

function Add-Root([string]$Path, [bool]$Session) {
    $full = Expand-LocalPath $Path
    if (-not [IO.Directory]::Exists($full)) { return }
    if (-not (Test-SafeAncestors $full)) { $script:Stats.Skipped++; return }
    Assert-Ntfs $full
    if ($full.Length -le 3) { throw "Select a specific folder, not an entire drive: $full" }
    foreach ($protected in @($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},(Join-Path $env:USERPROFILE '.ssh'),(Join-Path $env:USERPROFILE '.aws'))) {
        if ($protected -and (Test-Within $full $protected)) { throw "Protected folder is excluded: $full" }
    }
    if ($full -match '(?i)\\(?:Google\\Chrome|Microsoft\\Edge|Mozilla\\Firefox)(?:\\|$)') { throw 'Browser profiles are excluded.' }
    $codexRoot = Join-Path $env:USERPROFILE '.codex'
    if ((Test-Within $full $codexRoot) -and -not ($Session -and ((Test-Within $full (Join-Path $codexRoot 'sessions')) -or (Test-Within $full (Join-Path $codexRoot 'archived_sessions'))))) { throw 'Only session JSONL folders may be selected inside .codex.' }
    if ($script:SeenRoots.Add($full)) { $script:Roots.Add([pscustomobject]@{Path=$full;Session=$Session}) }
}

function Find-ProjectRoots([string]$Path) {
    $full = Expand-LocalPath $Path
    if (-not [IO.Directory]::Exists($full)) { return }
    if (-not (Test-SafeAncestors $full)) { return }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($full)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        try { $children = @(Get-ChildItem -LiteralPath $current -Force -Directory -ErrorAction Stop) }
        catch { Add-Problem "Cannot discover project folders: $current"; continue }
        foreach ($child in $children) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($child.Name -in $script:SkippedDirectories) { continue }
            if ($child.Name -eq 'pio-home') {
                Add-Root (Join-Path $child.FullName 'packages') $false
            } elseif ($child.Name -in @('pio-build','pio-libdeps')) {
                Add-Root $child.FullName $false
            } else { $pending.Push($child.FullName) }
        }
    }
}

function Test-Openable([string]$Path) {
    $probe = $null
    try {
        $probe = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        return $true
    } catch [IO.IOException] { return $false }
    finally { if ($null -ne $probe) { $probe.Dispose() } }
}

function Get-Candidates($Root, $Configuration) {
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root.Path)
    $cutoff = [DateTime]::UtcNow.AddHours(-[long]$Configuration.MinimumAgeHours)
    $unsafe = [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Encrypted -bor [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Offline -bor [IO.FileAttributes]::System
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        if (-not (Test-SafeAncestors $current)) { $script:Stats.Skipped++; continue }
        try { $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop) }
        catch { Add-Problem "Cannot enumerate folder: $current"; continue }
        foreach ($child in $children) {
            if (($child.Attributes -band $unsafe) -ne 0) { $script:Stats.Skipped++; continue }
            if ($child.PSIsContainer) {
                $browser = $child.FullName -match '(?i)\\(?:Google\\Chrome|Microsoft\\Edge|Mozilla\\Firefox)(?:\\|$)'
                if (-not $browser -and $child.Name -notin $script:SkippedDirectories -and -not (Test-Within $child.FullName $script:ArchiveRoot) -and -not (Test-Within $child.FullName $DataDirectory)) { $pending.Push($child.FullName) }
                continue
            }
            if (-not $script:SeenFiles.Add($child.FullName)) { continue }
            $script:Stats.Examined++
            $excludeName = $child.Name -match '(?i)(?:\.(?:db|sqlite|sqlite3)-(?:wal|shm)$|(?:^|\.)lock$|^\.env(?:\.|$)|^auth\.json$|^credentials(?:\.|$))'
            if (($Root.Session -and $child.Extension -ne '.jsonl') -or $child.Extension -in $script:ExcludedExtensions -or $excludeName -or $child.Length -lt [long]$Configuration.MinimumBytes -or ([long]$Configuration.MaximumBytes -gt 0 -and $child.Length -gt [long]$Configuration.MaximumBytes) -or $child.LastWriteTimeUtc -gt $cutoff) { $script:Stats.Skipped++; continue }
            try {
                if (-not (Test-Openable $child.FullName)) { $script:Stats.Skipped++; continue }
                $compressed = (($child.Attributes -band [IO.FileAttributes]::Compressed) -ne 0)
                $script:Stats.Eligible++
                if ($compressed) { $script:Stats.AlreadyCompressed++ }
                [pscustomobject]@{Path=$child.FullName;Root=$Root.Path;Length=[long]$child.Length;Ticks=$child.LastWriteTimeUtc.Ticks;Compressed=$compressed;BeforeBytes=[AutoCompactNative]::DiskBytes($child.FullName)}
            } catch { Add-Problem "Cannot inspect file: $($child.FullName)" }
        }
    }
}

function Test-Unchanged($Record) {
    if (-not (Test-SafeAncestors $Record.Path)) { return $false }
    $file = Get-Item -LiteralPath $Record.Path -Force -ErrorAction Stop
    $unsafe = [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Encrypted -bor [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Offline -bor [IO.FileAttributes]::System
    return (($file.Attributes -band $unsafe) -eq 0 -and $file.Length -eq $Record.Length -and $file.LastWriteTimeUtc.Ticks -eq $Record.Ticks -and (Test-Openable $Record.Path))
}

function Compress-Candidates($Records) {
    $compact = Join-Path $env:SystemRoot 'System32\compact.exe'
    $todo = @($Records | Where-Object { -not $_.Compressed })
    for ($offset = 0; $offset -lt $todo.Count; $offset += 20) {
        $batch = New-Object 'System.Collections.Generic.List[object]'
        for ($i=$offset; $i -lt [Math]::Min($offset+20,$todo.Count); $i++) {
            try { if (Test-Unchanged $todo[$i]) { $batch.Add($todo[$i]) } else { $script:Stats.Skipped++ } }
            catch [IO.IOException] { $script:Stats.Skipped++ }
            catch { Add-Problem "Cannot recheck file: $($todo[$i].Path)" }
        }
        if ($batch.Count -eq 0) { continue }
        $paths = @($batch | ForEach-Object { $_.Path })
        # Capture compact's verbose localized output; logs contain only our bounded summary.
        $nativeOutput = & $compact /C /A /I /Q @paths 2>&1
        $nativeExit = $LASTEXITCODE
        foreach ($record in $batch) {
            try {
                $after = Get-Item -LiteralPath $record.Path -Force
                if ($after.Length -ne $record.Length -or $after.LastWriteTimeUtc.Ticks -ne $record.Ticks) { Add-Problem "File changed during compression: $($record.Path)"; continue }
                if (($after.Attributes -band [IO.FileAttributes]::Compressed) -ne 0) {
                    $script:Stats.Compressed++
                    $script:Stats.SavedBytes += ($record.BeforeBytes - [AutoCompactNative]::DiskBytes($record.Path))
                } elseif (-not (Test-Openable $record.Path)) { $script:Stats.Skipped++ }
                else { Add-Problem "Compression not confirmed (compact exit $nativeExit): $($record.Path)" }
            } catch { Add-Problem "Cannot verify compressed file: $($record.Path)" }
        }
        $nativeOutput = $null
    }
}

function Save-Archive($Records, $Configuration) {
    if (-not $script:ArchiveRoot -or $Records.Count -eq 0) { return }
    . (Join-Path $PSScriptRoot 'Archive.ps1')
    $archive = New-AutoCompactArchive $Records $script:ArchiveRoot ([string]$Configuration.ArchiveFormat) ([string]$Configuration.ArchiveCompression)
    $script:Stats.ArchiveFiles = $archive.Files
    $script:Stats.ArchivePath = $archive.Path
    $script:Stats.ArchiveFormat = $Configuration.ArchiveFormat
    $script:Stats.ArchiveBytes = $archive.ArchiveBytes
    $script:Stats.ArchiveOriginalBytes = $archive.OriginalBytes
    $script:Stats.ArchiveSeconds = $archive.Seconds
    if ($archive.OriginalBytes -gt 0) { $script:Stats.ArchiveRatioPercent = [Math]::Round(100.0 * $archive.ArchiveBytes / $archive.OriginalBytes, 2) }
}

function Compare-ArchiveFormats($Records, $Configuration) {
    . (Join-Path $PSScriptRoot 'Archive.ps1')
    $sample = New-Object 'System.Collections.Generic.List[object]'
    $sampleBytes = 0L
    foreach ($record in $Records) {
        if ($sample.Count -ge 64) { break }
        if ($sampleBytes + $record.Length -le 32MB) {
            $sample.Add($record)
            $sampleBytes += $record.Length
        }
    }
    $result = [ordered]@{
        Result = 'Compared'
        TimeUtc = [DateTime]::UtcNow.ToString('o')
        Compression = $Configuration.ArchiveCompression
        SampleFiles = $sample.Count
        SampleBytes = $sampleBytes
        EligibleFiles = $Records.Count
        PartialSample = ($sample.Count -lt $Records.Count)
        Limits = [ordered]@{ MaximumFiles=64; MaximumBytes=33554432 }
        Formats = @()
        Note = 'Actual sample archives; not a prediction for all files. Originals are retained; archive bytes are additional storage.'
    }
    if ($sample.Count -eq 0) { $result.Result='NoSample'; $result.Note='No eligible files fit the sample limits (64 files / 32 MiB). Select smaller files or adjust the filters.' }
    else {
        $benchmarkPath = Join-Path $DataDirectory ('compare-' + [Guid]::NewGuid().ToString('N'))
        if (-not (Test-SafeAncestors $benchmarkPath)) { throw 'Comparison directory has a reparse point.' }
        $null = [IO.Directory]::CreateDirectory($benchmarkPath)
        try {
            foreach ($format in @('ZIP','TAR.GZ')) {
                $row = [ordered]@{ Name=$format; Result='Failed'; OriginalBytes=$sampleBytes; ArchiveBytes=$null; RatioPercent=$null; SavedPercent=$null; Seconds=$null; Error=$null }
                try {
                    $archive = New-AutoCompactArchive $sample $benchmarkPath $format ([string]$Configuration.ArchiveCompression)
                    $row.Result='Success'
                    $row.OriginalBytes=$archive.OriginalBytes
                    $row.ArchiveBytes=$archive.ArchiveBytes
                    $row.Seconds=$archive.Seconds
                    if ($archive.OriginalBytes -gt 0) {
                        $row.RatioPercent=[Math]::Round(100.0 * $archive.ArchiveBytes / $archive.OriginalBytes,2)
                        $row.SavedPercent=[Math]::Round(100.0 - $row.RatioPercent,2)
                    }
                    [IO.File]::Delete($archive.Path)
                } catch { $row.Error=$_.Exception.Message }
                $result.Formats += [pscustomobject]$row
            }
        } finally {
            # Only remove this run's own random child directory after checking its exact parent.
            if ([IO.Path]::GetDirectoryName($benchmarkPath) -eq $DataDirectory -and (Test-SafeAncestors $benchmarkPath) -and [IO.Directory]::Exists($benchmarkPath)) { [IO.Directory]::Delete($benchmarkPath,$true) }
        }
    }
    Write-AtomicJson (Join-Path $DataDirectory 'formats-last.json') $result
    return [pscustomobject]$result
}
try {
try {
    $DataDirectory = Expand-LocalPath $DataDirectory
    if (-not (Test-SafeAncestors $DataDirectory)) { throw 'Data directory has a reparse point.' }
    $null = [IO.Directory]::CreateDirectory($DataDirectory)
    try { $script:Lock = [IO.File]::Open((Join-Path $DataDirectory 'run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { Write-Output '{"Result":"AlreadyRunning"}'; exit 2 }
    $statePath = Join-Path $DataDirectory 'state.json'
    $oldState = Read-Json $statePath
    $script:State = [ordered]@{ LastSuccessUtc=$null; LastRunUtc=[DateTime]::UtcNow.ToString('o'); LastResult='Starting'; LastSavedBytes=0L; LastError=$null }
    if ($null -ne $oldState) { $script:State.LastSuccessUtc=$oldState.LastSuccessUtc }
    $configuration = Read-Configuration
    if ($Mode -eq 'Due' -and $script:State.LastSuccessUtc) {
        $lastSuccess = [DateTimeOffset]::Parse([string]$script:State.LastSuccessUtc, [Globalization.CultureInfo]::InvariantCulture)
        if ($lastSuccess.AddDays([int]$configuration.IntervalDays) -gt [DateTimeOffset]::UtcNow) {
            Write-Output '{"Result":"NotDue"}'
            exit 0
        }
    }
    $script:ArchiveRoot = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$configuration.ArchiveDirectory)) {
        $script:ArchiveRoot = Expand-LocalPath ([string]$configuration.ArchiveDirectory)
        if (-not (Test-SafeAncestors $script:ArchiveRoot)) { throw 'Archive directory has a reparse point.' }
        if ($script:ArchiveRoot.Length -le 3) { throw 'Select an archive subfolder, not a drive root.' }
        if (Test-Within $DataDirectory $script:ArchiveRoot) { throw 'Archive directory cannot contain the tool data directory.' }
    }
    if (-not ('AutoCompactNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AutoCompactNative {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern uint GetCompressedFileSizeW(string file,out uint high);
  [DllImport("kernel32.dll")] static extern void SetLastError(uint error);
  public static long DiskBytes(string path) {
    uint high; SetLastError(0); uint low=GetCompressedFileSizeW(path,out high);
    int error=Marshal.GetLastWin32Error();
    if(low==0xffffffff && error!=0) throw new System.ComponentModel.Win32Exception(error);
    return ((long)high << 32) | low;
  }
}
'@
    }
    foreach ($root in $configuration.SessionRoots) { Add-Root ([string]$root) $true }
    foreach ($root in $configuration.StaticRoots) { Add-Root ([string]$root) $false }
    foreach ($root in $configuration.ProjectSearchRoots) { Find-ProjectRoots ([string]$root) }
    $script:Stats.Roots=$script:Roots.Count
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in $script:Roots) {
        if ($script:ArchiveRoot -and (Test-Within $root.Path $script:ArchiveRoot)) { throw 'A source folder cannot be inside the archive directory.' }
        foreach ($record in Get-Candidates $root $configuration) { $candidates.Add($record) }
    }
    if ($Mode -eq 'Compare') {
        if ($script:Stats.Errors -gt 0) { throw 'Cannot compare formats because source scanning failed.' }
        $comparison = Compare-ArchiveFormats $candidates $configuration
        $comparison | ConvertTo-Json -Depth 8 -Compress
        exit 0
    }
    if ($Mode -eq 'Scan') { $script:Stats.Result='Scanned' }
    else {
        Compress-Candidates $candidates
        foreach ($record in $candidates) {
            $script:Stats.SourceLogicalBytes += $record.Length
            try { $script:Stats.SourceDiskBytes += [AutoCompactNative]::DiskBytes($record.Path) }
            catch { Add-Problem "Cannot measure final file size: $($record.Path)" }
        }
        if ($script:Stats.Errors -eq 0) { Save-Archive $candidates $configuration }
        if ($script:Stats.Errors -gt 0) { throw 'One or more files could not be processed. See the summary log.' }
        $script:Stats.Result='Success'
        $script:State.LastSuccessUtc=[DateTime]::UtcNow.ToString('o')
        $script:State.LastResult='Success'
        $script:State.LastSavedBytes=$script:Stats.SavedBytes
    }
} catch {
    $exitCode=1
    Add-Problem $_.Exception.Message
    $script:Stats.Result='Failed'
    if ($null -ne $script:Lock -and $null -ne $script:State -and $Mode -notin @('Scan','Compare')) {
        $script:State.LastSuccessUtc = if ($null -ne $oldState) { $oldState.LastSuccessUtc } else { $null }
        $script:State.LastResult='Failed'
        $script:State.LastError=($_.Exception.Message)
        try { Write-AtomicJson $statePath $script:State } catch { }
    }
}

if ($Mode -notin @('Scan','Compare')) {
    try {
        $logs = Join-Path $DataDirectory 'logs'
        if (-not (Test-SafeAncestors $logs)) { throw 'Log directory has a reparse point.' }
        $null = [IO.Directory]::CreateDirectory($logs)
        $log = [ordered]@{ TimeUtc=[DateTime]::UtcNow.ToString('o'); Summary=$script:Stats; Problems=$script:Problems.ToArray() }
        $logName = 'run-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.json'
        Write-AtomicJson (Join-Path $logs $logName) $log
        $keep = 24
        if ($null -ne $configuration) { $keep = [Math]::Max(1,[Math]::Min(1000,[int]$configuration.MaxLogs)) }
        $expired = @(Get-ChildItem -LiteralPath $logs -File | Where-Object { $_.Name -match '^run-\d{8}-\d{6}-\d{3}-[a-f0-9]{8}\.json$' } | Sort-Object Name -Descending | Select-Object -Skip $keep)
        foreach ($item in $expired) { [IO.File]::Delete($item.FullName) }
    } catch { $exitCode=1; Add-Problem 'Cannot write or rotate summary logs.'; $script:Stats.Result='Failed' }
    if ($null -ne $script:State -and $script:State.LastResult -eq 'Success') {
        if ($exitCode -ne 0) {
            $script:State.LastSuccessUtc = if ($null -ne $oldState) { $oldState.LastSuccessUtc } else { $null }
            $script:State.LastResult='Failed'
            $script:State.LastError='Cannot write or rotate summary logs.'
        }
        try { Write-AtomicJson $statePath $script:State }
        catch { $exitCode=1; $script:Stats.Result='Failed'; Add-Problem 'Cannot commit success state.' }
    }
}
[pscustomobject]$script:Stats | ConvertTo-Json -Compress
if ($script:Problems.Count -gt 0) { Write-Warning ($script:Problems -join [Environment]::NewLine) }
exit $exitCode
} finally {
    if ($null -ne $script:Lock) { $script:Lock.Dispose() }
}
