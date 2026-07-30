[CmdletBinding()]
param(
    [string]$SourceRepository = 'D:\Tes\MBB\bundle-repository'
)

$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($SourceRepository).TrimEnd('\')
$toolsRoot = Split-Path $PSScriptRoot -Parent
$companyPublisher = Join-Path $toolsRoot 'Publish-CompanyDirect.ps1'
$githubPublisher = Join-Path $toolsRoot 'Publish-GitHub.ps1'
$validator = Join-Path $toolsRoot 'Test-PluginRepository.ps1'
Import-Module (Join-Path $toolsRoot 'RepositoryPublishing.psm1') -Force

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempRoot = Join-Path $tempBase ('cpm-publishing-test-' + [guid]::NewGuid().ToString('N'))
$testSource = Join-Path $tempRoot 'bundle-repository'
$companyRepo = Join-Path $tempRoot 'company\3dsMaxPluginLibrary'
$gitRepo = Join-Path $tempRoot 'github\3dsMaxPluginLibrary'
$bareRemote = Join-Path $tempRoot 'remote.git'
$backupRoot = Join-Path $tempRoot 'publication-backups'

function Copy-RepositoryContent {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

try {
    Copy-RepositoryContent -Source $sourceRoot -Destination $testSource
    Copy-RepositoryContent -Source $sourceRoot -Destination $companyRepo
    $sourceCatalog = Read-CpmIniFile -Path (Join-Path $testSource 'catalog.ini')
    $sourceEntries = Get-CpmPluginEntries -Catalog $sourceCatalog
    $testPluginIds = @($sourceEntries.Keys)
    if ($testPluginIds.Count -lt 2) {
        throw 'Publishing workflow tests require at least two child plug-ins.'
    }
    $primaryPluginId = $testPluginIds[0]
    $secondaryPluginId = $testPluginIds[1]
    $primaryRecord = $sourceEntries[$primaryPluginId].Record
    $secondaryRecord = $sourceEntries[$secondaryPluginId].Record

    New-Item -ItemType Directory -Path $gitRepo -Force | Out-Null
    & git -C $gitRepo init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize test Git repository.' }
    & git -C $gitRepo config user.name 'Publishing Workflow Test'
    & git -C $gitRepo config user.email 'publishing-test@example.invalid'
    Copy-RepositoryContent -Source $sourceRoot -Destination $gitRepo
    & git -C $gitRepo add -- catalog.ini manager.ini packages manager
    & git -C $gitRepo commit -m 'Initial repository' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create initial test commit.' }

    & git init --bare --initial-branch=main $bareRemote | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize test bare remote.' }
    & git -C $gitRepo remote add origin $bareRemote
    & git -C $gitRepo push -u origin main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not push initial test repository.' }
    $remoteBeforeCompany = (& git -C $bareRemote rev-parse main).Trim()

    & $companyPublisher `
        -SourceRepository $testSource `
        -CompanyRepository $companyRepo `
        -RemovePluginIds $primaryPluginId `
        -BackupRoot $backupRoot
    & $validator -RepositoryPath $companyRepo

    $remoteAfterCompany = (& git -C $bareRemote rev-parse main).Trim()
    Assert-Equal $remoteBeforeCompany $remoteAfterCompany (
        'Internal publication unexpectedly changed the Git remote'
    )
    if (Select-String `
        -LiteralPath (Join-Path $companyRepo 'catalog.ini') `
        -SimpleMatch "Id=$primaryPluginId") {
        throw "Internal downlisting did not remove $primaryPluginId."
    }

    $primaryRelativePath = $primaryRecord.Package -replace '/', '\'
    $primaryCompanyPackage = Join-Path $companyRepo $primaryRelativePath
    Copy-Item `
        -LiteralPath (Join-Path $testSource ($secondaryRecord.Package -replace '/', '\')) `
        -Destination $primaryCompanyPackage `
        -Force
    $catalogBeforeRejectedPublish = (
        Get-FileHash -LiteralPath (Join-Path $companyRepo 'catalog.ini') -Algorithm SHA256
    ).Hash
    $immutableRejected = $false
    try {
        & $companyPublisher `
            -SourceRepository $testSource `
            -CompanyRepository $companyRepo `
            -PluginIds $primaryPluginId `
            -BackupRoot $backupRoot
    }
    catch {
        $immutableRejected = $_.Exception.Message -like '*same-name package*'
    }
    if (-not $immutableRejected) {
        throw 'Internal publisher did not reject a different same-name package.'
    }
    $catalogAfterRejectedPublish = (
        Get-FileHash -LiteralPath (Join-Path $companyRepo 'catalog.ini') -Algorithm SHA256
    ).Hash
    Assert-Equal $catalogBeforeRejectedPublish $catalogAfterRejectedPublish (
        'Rejected internal publication changed catalog.ini'
    )

    Remove-Item -LiteralPath $primaryCompanyPackage -Force
    & $companyPublisher `
        -SourceRepository $testSource `
        -CompanyRepository $companyRepo `
        -PluginIds $primaryPluginId `
        -BackupRoot $backupRoot
    & $validator -RepositoryPath $companyRepo
    if (-not (Test-Path -LiteralPath $primaryCompanyPackage -PathType Leaf)) {
        throw 'Internal publisher did not copy a missing selected package.'
    }
    $sourcePrimaryHash = (
        Get-FileHash `
            -LiteralPath (Join-Path $testSource $primaryRelativePath) `
            -Algorithm SHA256
    ).Hash
    $companyPrimaryHash = (
        Get-FileHash -LiteralPath $primaryCompanyPackage -Algorithm SHA256
    ).Hash
    Assert-Equal $sourcePrimaryHash $companyPrimaryHash (
        'Internal copied package hash differs from source'
    )

    $companyCatalogHash = (
        Get-FileHash -LiteralPath (Join-Path $companyRepo 'catalog.ini') -Algorithm SHA256
    ).Hash

    & $githubPublisher `
        -CommitMessage 'Test external downlisting' `
        -SourceRepository $testSource `
        -GitRepository $gitRepo `
        -RemovePluginIds $secondaryPluginId `
        -Remote origin `
        -Branch main `
        -BackupRoot $backupRoot

    if (Select-String `
        -LiteralPath (Join-Path $gitRepo 'catalog.ini') `
        -SimpleMatch "Id=$secondaryPluginId") {
        throw "GitHub downlisting did not remove $secondaryPluginId."
    }
    $companyCatalogHashAfterGitHub = (
        Get-FileHash -LiteralPath (Join-Path $companyRepo 'catalog.ini') -Algorithm SHA256
    ).Hash
    Assert-Equal $companyCatalogHash $companyCatalogHashAfterGitHub (
        'GitHub publication unexpectedly changed the company repository'
    )

    $remoteAfterGitHub = (& git -C $bareRemote rev-parse main).Trim()
    if ($remoteAfterGitHub -eq $remoteAfterCompany) {
        throw 'GitHub publication did not advance the test remote.'
    }

    $secondaryRelativePath = $secondaryRecord.Package -replace '\\','/'
    & git -C $gitRepo rm -- $secondaryRelativePath | Out-Null
    & git -C $gitRepo commit -m 'Test setup: remove unreferenced historical package' | Out-Null
    & git -C $gitRepo push origin main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare missing-package GitHub test.' }

    & $githubPublisher `
        -CommitMessage 'Test external selected publication' `
        -SourceRepository $testSource `
        -GitRepository $gitRepo `
        -PluginIds $secondaryPluginId `
        -Remote origin `
        -Branch main `
        -BackupRoot $backupRoot
    & $validator -RepositoryPath $gitRepo
    $sourceSecondaryHash = (
        Get-FileHash `
            -LiteralPath (Join-Path $testSource ($secondaryRelativePath -replace '/','\')) `
            -Algorithm SHA256
    ).Hash
    $gitSecondaryHash = (
        Get-FileHash `
            -LiteralPath (Join-Path $gitRepo ($secondaryRelativePath -replace '/','\')) `
            -Algorithm SHA256
    ).Hash
    Assert-Equal $sourceSecondaryHash $gitSecondaryHash (
        'GitHub copied package hash differs from source'
    )
    $companyCatalogHashAfterGitHubRepublish = (
        Get-FileHash -LiteralPath (Join-Path $companyRepo 'catalog.ini') -Algorithm SHA256
    ).Hash
    Assert-Equal $companyCatalogHash $companyCatalogHashAfterGitHubRepublish (
        'Second GitHub publication unexpectedly changed the company repository'
    )

    $gitStatus = @(& git -C $gitRepo status --porcelain)
    Assert-Equal 0 $gitStatus.Count 'GitHub publisher left a dirty worktree'

    $companyRecords = @(Get-ChildItem -LiteralPath (Join-Path $backupRoot 'company') -Filter release.json -Recurse)
    $githubRecords = @(Get-ChildItem -LiteralPath (Join-Path $backupRoot 'github') -Filter release.json -Recurse)
    Assert-Equal 2 $companyRecords.Count 'Expected two successful company release records'
    Assert-Equal 2 $githubRecords.Count 'Expected two GitHub release records'

    Write-Output 'Publishing workflow tests passed: channels are independent and Git stays clean.'
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\')
    if ($resolvedTemp.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedTemp -Leaf) -like 'cpm-publishing-test-*' -and
        (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
