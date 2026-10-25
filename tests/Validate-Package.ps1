param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')

function Assert-Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

foreach ($required in @('Runner.ps1', 'Archive.ps1', 'Manage.ps1', 'Settings.ps1', 'config.json', 'README.md', 'LICENSE')) {
    Assert-Check (Test-Path -LiteralPath (Join-Path $rootPath $required) -PathType Leaf) ('Required package file missing: ' + $required)
}

$manifest = Get-Content -LiteralPath (Join-Path $rootPath 'plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Check ($manifest.'$schema' -eq 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json') 'Unexpected plugin schema.'
Assert-Check ($manifest.name -eq 'codex-auto-compact') 'Unexpected plugin name.'
Assert-Check ($manifest.version -match '^\d+\.\d+\.\d+$') 'Plugin version must be semver.'

$market = Get-Content -LiteralPath (Join-Path $rootPath '.agents\plugins\marketplace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Check (@($market.plugins).Count -gt 0) 'Marketplace must expose a plugin.'
foreach ($entry in $market.plugins) {
    Assert-Check ($entry.source.source -eq 'local') 'This package expects a local marketplace source.'
    Assert-Check ($entry.source.path.StartsWith('./')) 'Source must be relative to marketplace root.'
    $source = [IO.Path]::GetFullPath((Join-Path $rootPath $entry.source.path)).TrimEnd('\')
    $inside = [string]::Equals($source, $rootPath, [StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)
    Assert-Check $inside 'Marketplace source escaped package root.'
    Assert-Check (Test-Path -LiteralPath (Join-Path $source 'plugin.json') -PathType Leaf) 'Marketplace manifest missing.'
    Assert-Check (-not [string]::IsNullOrEmpty($entry.policy.installation)) 'Marketplace installation policy missing.'
    Assert-Check (-not [string]::IsNullOrEmpty($entry.policy.authentication)) 'Marketplace authentication policy missing.'
    Assert-Check (-not [string]::IsNullOrEmpty($entry.category)) 'Marketplace category missing.'
}

$skills = @(Get-ChildItem -LiteralPath (Join-Path $rootPath 'skills') -Directory)
Assert-Check ($skills.Count -gt 0) 'At least one skill is required.'
foreach ($skill in $skills) {
    $skillPath = Join-Path $skill.FullName 'SKILL.md'
    $body = [IO.File]::ReadAllText($skillPath)
    $front = [regex]::Match($body, '\A---\r?\n(?<yaml>[\s\S]+?)\r?\n---\r?\n')
    Assert-Check $front.Success 'Skill frontmatter missing.'
    $name = [regex]::Match($front.Groups['yaml'].Value, '(?m)^name: ([a-z0-9]+(?:-[a-z0-9]+)*)\r?$')
    Assert-Check ($name.Success -and $name.Groups[1].Value -eq $skill.Name) 'Skill name must match its folder.'
    $description = [regex]::Match($front.Groups['yaml'].Value, '(?m)^description: (.+)\r?$')
    Assert-Check ($description.Success -and $description.Groups[1].Value.Length -le 1024) 'Skill description missing or too long.'
    Assert-Check ($body -notmatch '\[TODO:') 'Unfinished skill scaffold.'
}

$failures = @()
Get-ChildItem -LiteralPath $rootPath -Filter '*.ps1' -Recurse | ForEach-Object {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { $failures += $parseErrors }
}
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output $_.Message }
    throw 'PowerShell parse failures.'
}

Write-Output 'Package metadata, skill frontmatter, and PowerShell syntax checks passed. This does not confirm client plugin loading.'
