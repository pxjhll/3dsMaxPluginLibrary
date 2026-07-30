Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CpmRepositoryPolicy {
    param(
        [string]$Path = (Join-Path $PSScriptRoot 'repository-policy.json')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Repository policy is missing: $Path"
    }
    $policy = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($requiredProperty in @(
        'SchemaVersion',
        'ManagerPluginId',
        'AllowedTags',
        'SourceRepositoryDirectoryName',
        'PublishedRepositoryDirectoryName',
        'ChildPackageDirectory',
        'ManagerPackageDirectory',
        'ChildRepositoryName',
        'ManagerRepositoryName'
    )) {
        if ($null -eq $policy.PSObject.Properties[$requiredProperty]) {
            throw "Repository policy is missing $requiredProperty"
        }
    }
    if ([int]$policy.SchemaVersion -ne 1) {
        throw "Unsupported repository policy schema: $($policy.SchemaVersion)"
    }
    if (@($policy.AllowedTags).Count -lt 1) {
        throw 'Repository policy must allow at least one tag.'
    }
    foreach ($directoryName in @(
        $policy.SourceRepositoryDirectoryName,
        $policy.PublishedRepositoryDirectoryName,
        $policy.ChildPackageDirectory,
        $policy.ManagerPackageDirectory
    )) {
        if ([string]::IsNullOrWhiteSpace($directoryName) -or
            $directoryName -match '[\\/]' -or
            $directoryName -in @('.', '..')) {
            throw "Repository policy contains an unsafe directory name: $directoryName"
        }
    }
    return $policy
}

function ConvertFrom-CpmIniLines {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

    $sections = [ordered]@{}
    $sectionName = ''
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $sectionName = $Matches[1].Trim()
            if ($sections.Contains($sectionName)) {
                throw "Duplicate INI section: $sectionName"
            }
            $sections[$sectionName] = [ordered]@{}
        }
        elseif ($sectionName -ne '' -and $trimmed -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            if ($sections[$sectionName].Contains($key)) {
                throw "Duplicate INI key: [$sectionName] $key"
            }
            $sections[$sectionName][$key] = $Matches[2].Trim()
        }
    }
    return $sections
}

function Read-CpmIniFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing INI file: $Path"
    }
    return ConvertFrom-CpmIniLines -Lines @(Get-Content -LiteralPath $Path)
}

function Copy-CpmIniData {
    param([Parameter(Mandatory)][Collections.IDictionary]$Data)

    $copy = [ordered]@{}
    foreach ($sectionName in $Data.Keys) {
        $copy[$sectionName] = [ordered]@{}
        foreach ($key in $Data[$sectionName].Keys) {
            $copy[$sectionName][$key] = $Data[$sectionName][$key]
        }
    }
    return $copy
}

function ConvertTo-CpmIniText {
    param([Parameter(Mandatory)][Collections.IDictionary]$Data)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($sectionName in $Data.Keys) {
        $lines.Add("[$sectionName]")
        foreach ($key in $Data[$sectionName].Keys) {
            $lines.Add("$key=$($Data[$sectionName][$key])")
        }
        $lines.Add('')
    }
    return (($lines -join "`r`n").TrimEnd() + "`r`n")
}

function Set-CpmIniFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IDictionary]$Data
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $tempPath = Join-Path $parent ('.cpm-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText(
            $tempPath,
            (ConvertTo-CpmIniText -Data $Data),
            [Text.Encoding]::Unicode
        )
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $replaceBackup = Join-Path $parent (
                '.cpm-' + [guid]::NewGuid().ToString('N') + '.bak'
            )
            try {
                [IO.File]::Replace($tempPath, $fullPath, $replaceBackup)
            }
            finally {
                if (Test-Path -LiteralPath $replaceBackup -PathType Leaf) {
                    Remove-Item -LiteralPath $replaceBackup -Force
                }
            }
        }
        else {
            [IO.File]::Move($tempPath, $fullPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Get-CpmPluginEntries {
    param([Parameter(Mandatory)][Collections.IDictionary]$Catalog)

    $entries = [ordered]@{}
    foreach ($sectionName in @($Catalog.Keys | Where-Object { $_ -like 'Plugin.*' })) {
        $record = $Catalog[$sectionName]
        if (-not $record.Contains('Id') -or [string]::IsNullOrWhiteSpace($record.Id)) {
            throw "[$sectionName] is missing Id"
        }
        $normalizedId = $record.Id.Trim().ToLowerInvariant()
        if ($entries.Contains($normalizedId)) {
            throw "Duplicate plug-in Id: $($record.Id)"
        }
        $entries[$normalizedId] = [pscustomobject]@{
            Section = $sectionName
            Record = $record
        }
    }
    return $entries
}

function Assert-CpmSelection {
    param(
        [string[]]$PluginIds,
        [string[]]$RemovePluginIds,
        [switch]$PublishManager,
        [switch]$PublishFullCatalog
    )

    if ($PublishFullCatalog -and (@($PluginIds).Count -gt 0 -or @($RemovePluginIds).Count -gt 0)) {
        throw 'PublishFullCatalog cannot be combined with PluginIds or RemovePluginIds.'
    }
    if (-not $PublishFullCatalog -and
        -not $PublishManager -and
        @($PluginIds).Count -eq 0 -and
        @($RemovePluginIds).Count -eq 0) {
        throw 'Specify PluginIds, RemovePluginIds, PublishManager, or PublishFullCatalog.'
    }

    $publishSet = @{}
    foreach ($id in @($PluginIds)) {
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'PluginIds cannot contain an empty value.'
        }
        $normalized = $id.Trim().ToLowerInvariant()
        if ($publishSet.ContainsKey($normalized)) {
            throw "Duplicate PluginIds value: $id"
        }
        $publishSet[$normalized] = $true
    }
    $removeSet = @{}
    foreach ($id in @($RemovePluginIds)) {
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'RemovePluginIds cannot contain an empty value.'
        }
        $normalized = $id.Trim().ToLowerInvariant()
        if ($removeSet.ContainsKey($normalized)) {
            throw "Duplicate RemovePluginIds value: $id"
        }
        if ($publishSet.ContainsKey($normalized)) {
            throw "The same plug-in cannot be published and removed: $id"
        }
        $removeSet[$normalized] = $true
    }
}

function New-CpmCatalogCandidate {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$SourceCatalog,
        [Parameter(Mandatory)][Collections.IDictionary]$TargetCatalog,
        [string[]]$PluginIds = @(),
        [string[]]$RemovePluginIds = @(),
        [switch]$PublishFullCatalog
    )

    if ($PublishFullCatalog) {
        return Copy-CpmIniData -Data $SourceCatalog
    }

    $candidate = Copy-CpmIniData -Data $TargetCatalog
    $sourceEntries = Get-CpmPluginEntries -Catalog $SourceCatalog

    foreach ($id in @($PluginIds)) {
        $normalizedId = $id.Trim().ToLowerInvariant()
        if (-not $sourceEntries.Contains($normalizedId)) {
            throw "Source catalog does not contain plug-in Id: $id"
        }
        $targetEntries = Get-CpmPluginEntries -Catalog $candidate
        if ($targetEntries.Contains($normalizedId)) {
            $candidate.Remove($targetEntries[$normalizedId].Section)
        }
        $sourceEntry = $sourceEntries[$normalizedId]
        $recordCopy = [ordered]@{}
        foreach ($key in $sourceEntry.Record.Keys) {
            $recordCopy[$key] = $sourceEntry.Record[$key]
        }
        $candidate[$sourceEntry.Section] = $recordCopy
    }

    foreach ($id in @($RemovePluginIds)) {
        $normalizedId = $id.Trim().ToLowerInvariant()
        $targetEntries = Get-CpmPluginEntries -Catalog $candidate
        if (-not $targetEntries.Contains($normalizedId)) {
            throw "Target catalog does not contain plug-in Id to remove: $id"
        }
        $candidate.Remove($targetEntries[$normalizedId].Section)
    }
    return $candidate
}

function Get-CpmPublishRecords {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$SourceCatalog,
        [string[]]$PluginIds = @(),
        [switch]$PublishFullCatalog
    )

    $sourceEntries = Get-CpmPluginEntries -Catalog $SourceCatalog
    if ($PublishFullCatalog) {
        return @($sourceEntries.Values | ForEach-Object { $_.Record })
    }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($id in @($PluginIds)) {
        $normalizedId = $id.Trim().ToLowerInvariant()
        if (-not $sourceEntries.Contains($normalizedId)) {
            throw "Source catalog does not contain plug-in Id: $id"
        }
        $records.Add($sourceEntries[$normalizedId].Record)
    }
    return $records.ToArray()
}

function Resolve-CpmRepositoryFile {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RequiredFolder,
        [switch]$MustExist
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Repository path must be relative and contained: $RelativePath"
    }
    $normalized = ($RelativePath -replace '\\','/').TrimStart('/')
    if (-not $normalized.StartsWith(
        "$RequiredFolder/",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Repository path must be inside $RequiredFolder/: $RelativePath"
    }
    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath((Join-Path $root ($normalized -replace '/','\')))
    if (-not $fullPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Repository path escapes the root: $RelativePath"
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Repository file is missing: $fullPath"
    }
    return $fullPath
}

function Copy-CpmImmutablePackage {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Record,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RequiredFolder
    )

    $sourcePath = Resolve-CpmRepositoryFile `
        -RepositoryRoot $SourceRoot `
        -RelativePath $Record.Package `
        -RequiredFolder $RequiredFolder `
        -MustExist
    $targetPath = Resolve-CpmRepositoryFile `
        -RepositoryRoot $TargetRoot `
        -RelativePath $Record.Package `
        -RequiredFolder $RequiredFolder
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $Record.Sha256) {
        throw "Source package hash does not match catalog: $($Record.Package)"
    }

    if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
        $targetHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($targetHash -ne $sourceHash) {
            throw "Refusing to overwrite a different same-name package: $targetPath"
        }
        return [pscustomobject]@{
            Path = $targetPath
            RelativePath = ($Record.Package -replace '\\','/')
            Hash = $sourceHash
            Created = $false
        }
    }

    $targetDirectory = Split-Path $targetPath -Parent
    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath
    $copiedHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($copiedHash -ne $sourceHash) {
        Remove-Item -LiteralPath $targetPath -Force
        throw "Copied package hash mismatch: $targetPath"
    }
    return [pscustomobject]@{
        Path = $targetPath
        RelativePath = ($Record.Package -replace '\\','/')
        Hash = $sourceHash
        Created = $true
    }
}

function New-CpmBackupDirectory {
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][ValidateSet('company','github')][string]$Channel
    )

    $channelRoot = Join-Path ([IO.Path]::GetFullPath($BackupRoot)) $Channel
    New-Item -ItemType Directory -Path $channelRoot -Force | Out-Null
    $directory = Join-Path $channelRoot (
        (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    New-Item -ItemType Directory -Path $directory | Out-Null
    return $directory
}

function Write-CpmPublicationRecord {
    param(
        [Parameter(Mandatory)][string]$BackupDirectory,
        [Parameter(Mandatory)][hashtable]$Record
    )

    $Record['PublishedAt'] = (Get-Date).ToString('o')
    $path = Join-Path $BackupDirectory 'release.json'
    $Record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

Export-ModuleMember -Function @(
    'Assert-CpmSelection',
    'Copy-CpmImmutablePackage',
    'Copy-CpmIniData',
    'Get-CpmPluginEntries',
    'Get-CpmPublishRecords',
    'Get-CpmRepositoryPolicy',
    'New-CpmBackupDirectory',
    'New-CpmCatalogCandidate',
    'Read-CpmIniFile',
    'Resolve-CpmRepositoryFile',
    'Set-CpmIniFileAtomic',
    'Write-CpmPublicationRecord'
)
