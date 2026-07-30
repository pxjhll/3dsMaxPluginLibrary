[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CommitMessage,

    [string]$SourceRepository = 'D:\Tes\MBB\bundle-repository',
    [string]$GitRepository = (Split-Path $PSScriptRoot -Parent),
    [string[]]$PluginIds = @(),
    [string[]]$RemovePluginIds = @(),
    [switch]$PublishManager,
    [switch]$PublishFullCatalog,
    [string]$Remote = 'origin',
    [string]$Branch = 'main',
    [string]$BackupRoot = 'D:\Tes\MBB\publication-backups'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RepositoryPublishing.psm1') -Force
$policy = Get-CpmRepositoryPolicy

Assert-CpmSelection `
    -PluginIds $PluginIds `
    -RemovePluginIds $RemovePluginIds `
    -PublishManager:$PublishManager `
    -PublishFullCatalog:$PublishFullCatalog

$sourceRoot = [IO.Path]::GetFullPath($SourceRepository).TrimEnd('\')
$repo = [IO.Path]::GetFullPath($GitRepository).TrimEnd('\')
foreach ($localPath in @($sourceRoot, $repo, [IO.Path]::GetFullPath($BackupRoot))) {
    if ($localPath.StartsWith('\\')) {
        throw "GitHub publishing accepts local paths only: $localPath"
    }
}
if ((Split-Path $sourceRoot -Leaf) -ne $policy.SourceRepositoryDirectoryName -or
    -not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Unsafe or missing source repository: $sourceRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    throw "Not a git repository: $repo"
}
if ($sourceRoot -eq $repo) {
    throw 'SourceRepository and GitRepository must be different directories.'
}

$validator = Join-Path $PSScriptRoot 'Test-PluginRepository.ps1'
& $validator -RepositoryPath $sourceRoot

$porcelain = @(& git -C $repo status --porcelain)
if ($LASTEXITCODE -ne 0 -or $porcelain.Count -ne 0) {
    throw "Git worktree and index must be clean before publishing:`n$($porcelain -join "`n")"
}
$currentBranch = (& git -C $repo branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $Branch) {
    throw "Publishing must run from local branch '$Branch'; current branch is '$currentBranch'"
}
& git -C $repo fetch $Remote $Branch
if ($LASTEXITCODE -ne 0) {
    throw "git fetch failed: $Remote/$Branch"
}
$localHead = (& git -C $repo rev-parse HEAD).Trim()
$remoteHead = (& git -C $repo rev-parse "$Remote/$Branch").Trim()
if ($localHead -ne $remoteHead) {
    throw "Local $Branch must exactly match $Remote/$Branch before publishing."
}

$sourceCatalog = Read-CpmIniFile (Join-Path $sourceRoot 'catalog.ini')
$targetCatalog = Read-CpmIniFile (Join-Path $repo 'catalog.ini')
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
        -not $managerEntries.Contains($policy.ManagerPluginId)) {
        throw "Source manager.ini must contain only $($policy.ManagerPluginId)."
    }
    $managerRecords = @($managerEntries[$policy.ManagerPluginId].Record)
}

$backupDirectory = New-CpmBackupDirectory -BackupRoot $BackupRoot -Channel github
$catalogPath = Join-Path $repo 'catalog.ini'
$managerPath = Join-Path $repo 'manager.ini'
$catalogBackup = Join-Path $backupDirectory 'catalog.ini'
$managerBackup = Join-Path $backupDirectory 'manager.ini'
Copy-Item -LiteralPath $catalogPath -Destination $catalogBackup
Copy-Item -LiteralPath $managerPath -Destination $managerBackup

$copiedPackages = [Collections.Generic.List[object]]::new()
$allowedPaths = [Collections.Generic.List[string]]::new()
$commitCreated = $false
$commit = ''
try {
    foreach ($record in $pluginRecords) {
        $result = Copy-CpmImmutablePackage `
            -SourceRoot $sourceRoot `
            -TargetRoot $repo `
            -Record $record `
            -RequiredFolder $policy.ChildPackageDirectory
        $copiedPackages.Add($result)
        $allowedPaths.Add($result.RelativePath)
    }
    foreach ($record in $managerRecords) {
        $result = Copy-CpmImmutablePackage `
            -SourceRoot $sourceRoot `
            -TargetRoot $repo `
            -Record $record `
            -RequiredFolder $policy.ManagerPackageDirectory
        $copiedPackages.Add($result)
        $allowedPaths.Add($result.RelativePath)
    }
    if ($PublishFullCatalog -or @($PluginIds).Count -gt 0 -or @($RemovePluginIds).Count -gt 0) {
        Set-CpmIniFileAtomic -Path $catalogPath -Data $candidateCatalog
        $allowedPaths.Add('catalog.ini')
    }
    if ($PublishManager) {
        Set-CpmIniFileAtomic -Path $managerPath -Data $sourceManager
        $allowedPaths.Add('manager.ini')
    }

    & $validator -RepositoryPath $repo

    $normalizedAllowed = @($allowedPaths | Sort-Object -Unique)
    & git -C $repo add -- $normalizedAllowed
    if ($LASTEXITCODE -ne 0) {
        throw 'git add failed.'
    }
    $stagedPaths = @(& git -C $repo diff --cached --name-only)
    if ($stagedPaths.Count -eq 0) {
        throw 'Selected publication produces no Git changes.'
    }
    $unexpected = @($stagedPaths | Where-Object { $_ -notin $normalizedAllowed })
    if ($unexpected.Count -ne 0) {
        throw "Unexpected staged files were blocked:`n$($unexpected -join "`n")"
    }

    & git -C $repo commit -m $CommitMessage
    if ($LASTEXITCODE -ne 0) {
        throw 'git commit failed.'
    }
    $commitCreated = $true
    $commit = (& git -C $repo rev-parse HEAD).Trim()

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $tempRoot = Join-Path $tempBase ('cpm-github-validate-' + [guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $tempRoot 'repository.zip'
    $snapshotRoot = Join-Path $tempRoot 'snapshot'
    New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
    try {
        & git -C $repo archive --format=zip --output=$archivePath $commit
        if ($LASTEXITCODE -ne 0) {
            throw "Could not export commit for validation: $commit"
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $snapshotRoot
        & $validator -RepositoryPath $snapshotRoot
    }
    finally {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\')
        if ($resolvedTemp.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path $resolvedTemp -Leaf) -like 'cpm-github-validate-*' -and
            (Test-Path -LiteralPath $resolvedTemp)) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }

    & git -C $repo push $Remote "HEAD:$Branch"
    if ($LASTEXITCODE -ne 0) {
        throw "git push failed: $Remote/$Branch"
    }
}
catch {
    if (-not $commitCreated) {
        $rollbackPaths = @($allowedPaths | Sort-Object -Unique)
        if ($rollbackPaths.Count -gt 0) {
            & git -C $repo reset --quiet -- $rollbackPaths
        }
        Copy-Item -LiteralPath $catalogBackup -Destination $catalogPath -Force
        Copy-Item -LiteralPath $managerBackup -Destination $managerPath -Force
        foreach ($package in @($copiedPackages | Where-Object { $_.Created })) {
            if (Test-Path -LiteralPath $package.Path -PathType Leaf) {
                Remove-Item -LiteralPath $package.Path -Force
            }
        }
    }
    else {
        Write-Error (
            "Commit $commit exists locally and the worktree is clean, but validation or push failed. " +
            "Resolve the remote problem and push this exact commit; do not rebuild the same version."
        )
    }
    throw
}

$recordPath = Write-CpmPublicationRecord -BackupDirectory $backupDirectory -Record @{
    Target = 'GitHub'
    SourceRepository = $sourceRoot
    GitRepository = $repo
    Remote = $Remote
    Branch = $Branch
    Commit = $commit
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

Write-Output "GitHub publication completed: $commit"
Write-Output "Release record: $recordPath"
