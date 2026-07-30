[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SourceRepository = 'D:\Tes\MBB\bundle-repository',
    [string]$CompanyRepository = '\\10.15.128.222\角色模型\Tool\3dsMaxPluginLibrary',
    [string[]]$PluginIds = @(),
    [string[]]$RemovePluginIds = @(),
    [switch]$PublishManager,
    [switch]$PublishFullCatalog,
    [string]$BackupRoot = 'D:\Tes\MBB\publication-backups'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RepositoryPublishing.psm1') -Force

Assert-CpmSelection `
    -PluginIds $PluginIds `
    -RemovePluginIds $RemovePluginIds `
    -PublishManager:$PublishManager `
    -PublishFullCatalog:$PublishFullCatalog

$sourceRoot = [IO.Path]::GetFullPath($SourceRepository).TrimEnd('\')
$companyRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $CompanyRepository
).TrimEnd('\')
if ((Split-Path $sourceRoot -Leaf) -ne 'bundle-repository' -or
    -not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Unsafe or missing source repository: $sourceRoot"
}
if ((Split-Path $companyRoot -Leaf) -ne '3dsMaxPluginLibrary' -or
    -not (Test-Path -LiteralPath $companyRoot -PathType Container)) {
    throw "Unsafe or missing company repository: $companyRoot"
}
if ($sourceRoot -eq $companyRoot) {
    throw 'SourceRepository and CompanyRepository must be different directories.'
}

$validator = Join-Path $PSScriptRoot 'Test-PluginRepository.ps1'
& $validator -RepositoryPath $sourceRoot
& $validator -RepositoryPath $companyRoot

$sourceCatalog = Read-CpmIniFile (Join-Path $sourceRoot 'catalog.ini')
$targetCatalog = Read-CpmIniFile (Join-Path $companyRoot 'catalog.ini')
$candidateCatalog = New-CpmCatalogCandidate `
    -SourceCatalog $sourceCatalog `
    -TargetCatalog $targetCatalog `
    -PluginIds $PluginIds `
    -RemovePluginIds $RemovePluginIds `
    -PublishFullCatalog:$PublishFullCatalog
$pluginRecords = @(
    Get-CpmPublishRecords `
        -SourceCatalog $sourceCatalog `
        -PluginIds $PluginIds `
        -PublishFullCatalog:$PublishFullCatalog
)

$sourceManager = $null
$managerRecords = @()
if ($PublishManager) {
    $sourceManager = Read-CpmIniFile (Join-Path $sourceRoot 'manager.ini')
    $managerEntries = Get-CpmPluginEntries -Catalog $sourceManager
    if ($managerEntries.Count -ne 1 -or
        -not $managerEntries.Contains('companypluginmanager')) {
        throw 'Source manager.ini must contain only companypluginmanager.'
    }
    $managerRecords = @($managerEntries['companypluginmanager'].Record)
}

$summary = @(
    if ($PublishFullCatalog) { 'full child catalog' }
    if (@($PluginIds).Count -gt 0) { "publish: $($PluginIds -join ', ')" }
    if (@($RemovePluginIds).Count -gt 0) { "remove: $($RemovePluginIds -join ', ')" }
    if ($PublishManager) { 'manager update' }
) -join '; '
if (-not $PSCmdlet.ShouldProcess($companyRoot, "Publish $summary")) {
    return
}

$backupDirectory = New-CpmBackupDirectory -BackupRoot $BackupRoot -Channel company
$liveCatalogPath = Join-Path $companyRoot 'catalog.ini'
$liveManagerPath = Join-Path $companyRoot 'manager.ini'
$catalogBackup = Join-Path $backupDirectory 'catalog.ini'
$managerBackup = Join-Path $backupDirectory 'manager.ini'
Copy-Item -LiteralPath $liveCatalogPath -Destination $catalogBackup
Copy-Item -LiteralPath $liveManagerPath -Destination $managerBackup

$copiedPackages = [Collections.Generic.List[object]]::new()
foreach ($record in $pluginRecords) {
    $copiedPackages.Add((Copy-CpmImmutablePackage `
        -SourceRoot $sourceRoot `
        -TargetRoot $companyRoot `
        -Record $record `
        -RequiredFolder packages))
}
foreach ($record in $managerRecords) {
    $copiedPackages.Add((Copy-CpmImmutablePackage `
        -SourceRoot $sourceRoot `
        -TargetRoot $companyRoot `
        -Record $record `
        -RequiredFolder manager))
}

try {
    if ($PublishFullCatalog -or @($PluginIds).Count -gt 0 -or @($RemovePluginIds).Count -gt 0) {
        Set-CpmIniFileAtomic -Path $liveCatalogPath -Data $candidateCatalog
    }
    if ($PublishManager) {
        Set-CpmIniFileAtomic -Path $liveManagerPath -Data $sourceManager
    }
    & $validator -RepositoryPath $companyRoot
}
catch {
    Copy-Item -LiteralPath $catalogBackup -Destination $liveCatalogPath -Force
    Copy-Item -LiteralPath $managerBackup -Destination $liveManagerPath -Force
    throw
}

$recordPath = Write-CpmPublicationRecord -BackupDirectory $backupDirectory -Record @{
    Target = 'Company'
    SourceRepository = $sourceRoot
    TargetRepository = $companyRoot
    PluginIds = @($PluginIds)
    RemovePluginIds = @($RemovePluginIds)
    PublishManager = [bool]$PublishManager
    PublishFullCatalog = [bool]$PublishFullCatalog
    Packages = @($copiedPackages | ForEach-Object {
        [ordered]@{
            Path = $_.RelativePath
            Sha256 = $_.Hash
            Created = $_.Created
        }
    })
    Validation = 'passed'
}

Write-Output "Company publication completed: $summary"
Write-Output "Release record: $recordPath"
