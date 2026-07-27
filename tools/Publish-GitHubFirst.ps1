[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CommitMessage,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$PublishPaths,

    [string]$RepositoryPath = (Split-Path $PSScriptRoot -Parent),
    [string]$CompanyRepository = '\\10.15.128.222\角色模型\Tool\3dsMaxPluginLibrary',
    [string]$Remote = 'origin',
    [string]$Branch = 'main',
    [switch]$SkipCompanySync
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\')
$validator = Join-Path $PSScriptRoot 'Test-PluginRepository.ps1'
$syncScript = Join-Path $PSScriptRoot 'Sync-CompanyMirror.ps1'

if (-not (Test-Path -LiteralPath (Join-Path $repo '.git') -PathType Container)) {
    throw "Not a git repository: $repo"
}
$currentBranch = (& git -C $repo branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $Branch) {
    throw "Publishing must run from local branch '$Branch'; current branch is '$currentBranch'"
}

$alreadyStaged = @(& git -C $repo diff --cached --name-only)
if ($alreadyStaged.Count -ne 0) {
    throw "The git index already contains staged files. Commit or unstage them first:`n$($alreadyStaged -join "`n")"
}

& git -C $repo fetch $Remote $Branch
if ($LASTEXITCODE -ne 0) {
    throw "git fetch failed: $Remote/$Branch"
}
$localHead = (& git -C $repo rev-parse HEAD).Trim()
$remoteHead = (& git -C $repo rev-parse "$Remote/$Branch").Trim()
if ($localHead -ne $remoteHead) {
    throw "Local $Branch must exactly match $Remote/$Branch before publishing"
}

$normalizedPaths = [Collections.Generic.List[string]]::new()
$publishTargets = [Collections.Generic.List[object]]::new()
foreach ($publishPath in $PublishPaths) {
    if ([IO.Path]::IsPathRooted($publishPath) -or $publishPath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "PublishPaths must contain repository-relative paths: $publishPath"
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $repo $publishPath))
    if (-not $fullPath.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Publish path escapes the repository: $publishPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "Publish path does not exist: $publishPath"
    }
    $normalizedPath = ($publishPath -replace '\\','/').TrimEnd('/')
    $normalizedPaths.Add($normalizedPath)
    $publishTargets.Add([pscustomobject]@{
        Path = $normalizedPath
        IsDirectory = (Test-Path -LiteralPath $fullPath -PathType Container)
    })
}

& $validator -RepositoryPath $repo

$gitAddArguments = @('-C', $repo, 'add', '--') + $normalizedPaths.ToArray()
& git @gitAddArguments
if ($LASTEXITCODE -ne 0) {
    throw 'git add failed'
}
$stagedPaths = @(& git -C $repo diff --cached --name-only)
if ($stagedPaths.Count -eq 0) {
    throw 'No changes were staged for publishing'
}
$unexpectedStaged = @($stagedPaths | Where-Object {
    $stagedPath = $_
    -not @($publishTargets | Where-Object {
        if ($_.IsDirectory) {
            $stagedPath.StartsWith($_.Path + '/', [StringComparison]::Ordinal)
        }
        else {
            $stagedPath -eq $_.Path
        }
    }).Count
})
if ($unexpectedStaged.Count -ne 0) {
    & git -C $repo reset
    throw "Unexpected staged files were blocked:`n$($unexpectedStaged -join "`n")"
}

& git -C $repo commit -m $CommitMessage
if ($LASTEXITCODE -ne 0) {
    throw 'git commit failed'
}
$commit = (& git -C $repo rev-parse HEAD).Trim()

try {
    & $syncScript `
        -RepositoryPath $repo `
        -Remote $Remote `
        -Branch $Branch `
        -Ref $commit `
        -SkipFetch `
        -ValidateOnly

    & git -C $repo push $Remote "HEAD:$Branch"
    if ($LASTEXITCODE -ne 0) {
        throw "git push failed: $Remote/$Branch"
    }

    if (-not $SkipCompanySync) {
        & $syncScript `
            -RepositoryPath $repo `
            -CompanyRepository $CompanyRepository `
            -Remote $Remote `
            -Branch $Branch
    }
}
catch {
    Write-Error (
        "Commit $commit was created locally. GitHub or company synchronization did not finish. " +
        "Fix the reported issue and resume without creating another version.`n$_"
    )
    throw
}

Write-Output "Published GitHub-first release commit $commit"
