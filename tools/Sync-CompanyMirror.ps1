[CmdletBinding()]
param(
    [string]$RepositoryPath = (Split-Path $PSScriptRoot -Parent),
    [string]$CompanyRepository = '\\10.15.128.222\角色模型\Tool\3dsMaxPluginLibrary',
    [string]$Remote = 'origin',
    [string]$Branch = 'main',
    [string]$Ref = '',
    [switch]$SkipFetch,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\')
$validator = Join-Path $PSScriptRoot 'Test-PluginRepository.ps1'
if (-not (Test-Path -LiteralPath (Join-Path $repo '.git') -PathType Container)) {
    throw "Not a git repository: $repo"
}

if (-not $SkipFetch) {
    & git -C $repo fetch $Remote $Branch
    if ($LASTEXITCODE -ne 0) {
        throw "git fetch failed: $Remote/$Branch"
    }
}

$sourceRef = if ([string]::IsNullOrWhiteSpace($Ref)) { "$Remote/$Branch" } else { $Ref }
$commit = (& git -C $repo rev-parse $sourceRef).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') {
    throw "Could not resolve git ref: $sourceRef"
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempRoot = Join-Path $tempBase ('cpm-github-snapshot-' + [guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $tempRoot 'repository.zip'
$snapshotRoot = Join-Path $tempRoot 'snapshot'
New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null

function Read-PackageReferences([string]$CatalogPath) {
    $references = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $CatalogPath) {
        if ($line.Trim() -match '^Package=(.+)$') {
            $references.Add($Matches[1].Trim())
        }
    }
    return $references
}

try {
    & git -C $repo archive --format=zip --output=$archivePath $commit
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Could not export git commit: $commit"
    }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $snapshotRoot
    & $validator -RepositoryPath $snapshotRoot

    if ($ValidateOnly) {
        Write-Output "Validated GitHub snapshot $commit; company repository was not changed."
        return
    }

    $companyRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $CompanyRepository
    ).TrimEnd('\')
    if ((Split-Path $companyRoot -Leaf) -ne '3dsMaxPluginLibrary' -or
        -not (Test-Path -LiteralPath $companyRoot -PathType Container)) {
        throw "Unsafe or missing company repository path: $companyRoot"
    }

    $backupRoot = Join-Path (Split-Path $repo -Parent) 'publication-backups'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $shortCommit = $commit.Substring(0, 12)
    $catalogBackup = Join-Path $backupRoot "catalog-$stamp-$shortCommit.ini"
    $managerBackup = Join-Path $backupRoot "manager-$stamp-$shortCommit.ini"
    $liveCatalog = Join-Path $companyRoot 'catalog.ini'
    $liveManager = Join-Path $companyRoot 'manager.ini'
    $catalogExisted = Test-Path -LiteralPath $liveCatalog -PathType Leaf
    $managerExisted = Test-Path -LiteralPath $liveManager -PathType Leaf
    if ($catalogExisted) {
        Copy-Item -LiteralPath $liveCatalog -Destination $catalogBackup
    }
    if ($managerExisted) {
        Copy-Item -LiteralPath $liveManager -Destination $managerBackup
    }

    $packageReferences = @(
        (Read-PackageReferences (Join-Path $snapshotRoot 'catalog.ini'))
        (Read-PackageReferences (Join-Path $snapshotRoot 'manager.ini'))
    ) | Sort-Object -Unique

    foreach ($relativePath in $packageReferences) {
        $sourcePackage = [IO.Path]::GetFullPath(
            (Join-Path $snapshotRoot ($relativePath -replace '/', '\'))
        )
        if (-not $sourcePackage.StartsWith(
            $snapshotRoot.TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Snapshot package path escapes the repository: $relativePath"
        }
        $targetPackage = [IO.Path]::GetFullPath(
            (Join-Path $companyRoot ($relativePath -replace '/', '\'))
        )
        if (-not $targetPackage.StartsWith(
            $companyRoot + '\',
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Company package path escapes the repository: $relativePath"
        }
        $targetDirectory = Split-Path $targetPackage -Parent
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        $sourceHash = (Get-FileHash -LiteralPath $sourcePackage -Algorithm SHA256).Hash
        if (Test-Path -LiteralPath $targetPackage -PathType Leaf) {
            $targetHash = (Get-FileHash -LiteralPath $targetPackage -Algorithm SHA256).Hash
            if ($sourceHash -ne $targetHash) {
                throw "Refusing to overwrite a different same-name package: $targetPackage"
            }
        }
        else {
            Copy-Item -LiteralPath $sourcePackage -Destination $targetPackage
            $copiedHash = (Get-FileHash -LiteralPath $targetPackage -Algorithm SHA256).Hash
            if ($sourceHash -ne $copiedHash) {
                throw "Copied package hash mismatch: $targetPackage"
            }
        }
    }

    try {
        Copy-Item -LiteralPath (Join-Path $snapshotRoot 'catalog.ini') -Destination $liveCatalog -Force
        Copy-Item -LiteralPath (Join-Path $snapshotRoot 'manager.ini') -Destination $liveManager -Force
        & $validator -RepositoryPath $companyRoot
    }
    catch {
        if ($catalogExisted) {
            Copy-Item -LiteralPath $catalogBackup -Destination $liveCatalog -Force
        }
        elseif (Test-Path -LiteralPath $liveCatalog -PathType Leaf) {
            Remove-Item -LiteralPath $liveCatalog -Force
        }
        if ($managerExisted) {
            Copy-Item -LiteralPath $managerBackup -Destination $liveManager -Force
        }
        elseif (Test-Path -LiteralPath $liveManager -PathType Leaf) {
            Remove-Item -LiteralPath $liveManager -Force
        }
        throw
    }

    Write-Output "Company repository synchronized from GitHub commit $commit"
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\')
    if ($resolvedTemp.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedTemp -Leaf) -like 'cpm-github-snapshot-*' -and
        (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
