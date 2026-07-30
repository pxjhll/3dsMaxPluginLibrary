[CmdletBinding()]
param(
    [string]$RepositoryPath = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Import-Module (Join-Path $PSScriptRoot 'RepositoryPublishing.psm1') -Force
$policy = Get-CpmRepositoryPolicy

$root = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\')
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Repository directory not found: $root"
}

function ConvertFrom-IniLines([string[]]$Lines) {
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

function Read-IniSections([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing repository catalog: $Path"
    }
    return ConvertFrom-IniLines @(Get-Content -LiteralPath $Path)
}

function Resolve-RepositoryPackage([string]$RelativePath) {
    if ([IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Package path must be repository-relative: $RelativePath"
    }
    $packagePath = [IO.Path]::GetFullPath(
        (Join-Path $root ($RelativePath -replace '/', '\'))
    )
    if (-not $packagePath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package path escapes the repository: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw "Package file is missing: $packagePath"
    }
    return $packagePath
}

function Test-BundleRecord(
    [string]$Section,
    [Collections.IDictionary]$Record,
    [ValidateSet('Child','Manager')]
    [string]$Channel
) {
    foreach ($requiredKey in @(
        'Id','Name','Version','Type','Package','BundleName',
        'UpgradeCode','Sha256','Author','Log'
    )) {
        if (-not $Record.Contains($requiredKey) -or
            [string]::IsNullOrWhiteSpace($Record[$requiredKey])) {
            throw "$Section is missing $requiredKey"
        }
    }
    if ($Record.Type -ne 'bundle') {
        throw "$Section is not Type=bundle"
    }
    if ($Record.Id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "$Section Id must use lowercase letters, digits, and hyphens"
    }
    if ($Section -ne "Plugin.$($Record.Id)") {
        throw "$Section name must match Id: Plugin.$($Record.Id)"
    }
    if ($Record.Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "$Section Version must use x.y.z format"
    }
    if ($Record.BundleName -notmatch '^[^\\/]+\.bundle$') {
        throw "$Section BundleName must be one .bundle directory name"
    }
    if ($Record.Sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "$Section Sha256 must contain exactly 64 lowercase hexadecimal characters"
    }
    $requiredPackagePrefix = if ($Channel -eq 'Manager') {
        "$($policy.ManagerPackageDirectory)/"
    }
    else {
        "$($policy.ChildPackageDirectory)/"
    }
    if (-not $Record.Package.StartsWith(
        $requiredPackagePrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Section Package must be inside $requiredPackagePrefix"
    }
    if ($Record.Package -notmatch (
        [regex]::Escape("_v$($Record.Version).bundle.zip") + '$'
    )) {
        throw "$Section Package filename must include catalog Version"
    }
    if ($Channel -eq 'Child') {
        if (-not $Record.Contains('Tags') -or [string]::IsNullOrWhiteSpace($Record.Tags)) {
            throw "$Section is missing Tags"
        }
        $allowedTags = @($policy.AllowedTags)
        $tags = @($Record.Tags -split '\|' | ForEach-Object { $_.Trim() })
        if ($tags.Count -eq 0 -or @($tags | Where-Object {
            [string]::IsNullOrWhiteSpace($_) -or $_ -notin $allowedTags
        }).Count -ne 0) {
            throw "$Section Tags must use repository-policy.json values separated by |"
        }
        if (($tags | Select-Object -Unique).Count -ne $tags.Count) {
            throw "$Section contains duplicate Tags"
        }
    }
    try {
        [void][Guid]::Parse($Record.UpgradeCode)
    }
    catch {
        throw "$Section UpgradeCode is not a valid GUID"
    }

    $packagePath = Resolve-RepositoryPackage $Record.Package
    $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $Record.Sha256) {
        throw "$Section SHA-256 mismatch"
    }

    $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        $xmlEntry = $archive.GetEntry("$($Record.BundleName)/PackageContents.xml")
        $catalogEntry = $archive.GetEntry("$($Record.BundleName)/Contents/catalog.ini")
        if ($null -eq $xmlEntry -or $null -eq $catalogEntry) {
            throw "$Section Bundle root is incomplete"
        }
        $forbiddenEntries = @($archive.Entries | Where-Object {
            $leaf = [IO.Path]::GetFileName($_.FullName)
            $leaf -match '^(install|uninstall)\.ms$' -or $leaf -match '\.mzp$'
        })
        if ($forbiddenEntries.Count -ne 0) {
            throw "$Section Bundle contains obsolete installer content: $($forbiddenEntries[0].FullName)"
        }
        $reader = [IO.StreamReader]::new($xmlEntry.Open(), [Text.Encoding]::UTF8, $true)
        try {
            [xml]$packageXml = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $catalogReader = [IO.StreamReader]::new(
            $catalogEntry.Open(),
            [Text.Encoding]::UTF8,
            $true
        )
        try {
            $bundleCatalog = ConvertFrom-IniLines @(
                $catalogReader.ReadToEnd() -split '\r?\n'
            )
        }
        finally {
            $catalogReader.Dispose()
        }
        $bundlePluginSections = @(
            $bundleCatalog.Keys | Where-Object { $_ -like 'Plugin.*' }
        )
        if ($bundlePluginSections.Count -ne 1) {
            throw "$Section Bundle catalog must contain exactly one plug-in section"
        }
        $bundleRecord = $bundleCatalog[$bundlePluginSections[0]]
        foreach ($identityKey in @(
            'Id','Name','Version','Type','BundleName','UpgradeCode',
            'MinMaxVersion','MaxMaxVersion','Log'
        )) {
            if ($bundleRecord[$identityKey] -ne $Record[$identityKey]) {
                throw "$Section $identityKey does not match the Bundle catalog"
            }
        }
        foreach ($optionalRunKey in @('MacroCategory','MacroName')) {
            if ($Record.Contains($optionalRunKey) -and
                $bundleRecord[$optionalRunKey] -ne $Record[$optionalRunKey]) {
                throw "$Section $optionalRunKey does not match the Bundle catalog"
            }
        }

        $applicationPackage = $packageXml.ApplicationPackage
        if ($applicationPackage.AppVersion -ne $Record.Version) {
            throw "$Section AppVersion does not match catalog Version"
        }
        if ($applicationPackage.UpgradeCode -ne $Record.UpgradeCode) {
            throw "$Section UpgradeCode does not match PackageContents.xml"
        }
        foreach ($components in @($applicationPackage.Components)) {
            if ([string]::IsNullOrWhiteSpace($components.RuntimeRequirements.SeriesMax)) {
                throw "$Section component is missing SeriesMax"
            }
            foreach ($entry in @($components.ComponentEntry)) {
                $modulePath = $entry.ModuleName -replace '^\./',''
                if ($null -eq $archive.GetEntry("$($Record.BundleName)/$modulePath")) {
                    throw "$Section is missing component entry: $modulePath"
                }
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

$catalogSections = Read-IniSections (Join-Path $root 'catalog.ini')
$pluginSections = @($catalogSections.Keys | Where-Object { $_ -like 'Plugin.*' })
if ($pluginSections.Count -lt 1) {
    throw 'catalog.ini contains no child plug-ins'
}
if (@($pluginSections | Where-Object {
    $catalogSections[$_].Id -eq $policy.ManagerPluginId
}).Count -ne 0) {
    throw 'The manager must not be published in catalog.ini'
}

$upgradeCodes = @{}
$pluginIds = @{}
foreach ($section in $pluginSections) {
    $record = $catalogSections[$section]
    Test-BundleRecord $section $record Child
    $normalizedId = $record.Id.ToLowerInvariant()
    if ($pluginIds.ContainsKey($normalizedId)) {
        throw "Duplicate child Id: $($record.Id)"
    }
    $pluginIds[$normalizedId] = $section
    if ($upgradeCodes.ContainsKey($record.UpgradeCode)) {
        throw "Duplicate child UpgradeCode: $($record.UpgradeCode)"
    }
    $upgradeCodes[$record.UpgradeCode] = $record.Id
}

$managerSections = Read-IniSections (Join-Path $root 'manager.ini')
$managerPluginSections = @($managerSections.Keys | Where-Object { $_ -like 'Plugin.*' })
if ($managerPluginSections.Count -ne 1) {
    throw "Expected one manager update entry, found $($managerPluginSections.Count)"
}
$managerSection = $managerPluginSections[0]
$managerRecord = $managerSections[$managerSection]
if ($managerRecord.Id -ne $policy.ManagerPluginId) {
    throw "manager.ini must contain only $($policy.ManagerPluginId)"
}
Test-BundleRecord $managerSection $managerRecord Manager
if ($upgradeCodes.ContainsKey($managerRecord.UpgradeCode)) {
    throw 'The manager UpgradeCode duplicates a child plug-in UpgradeCode'
}

Write-Output (
    "Verified $($pluginSections.Count) child bundles and 1 manager update bundle " +
    "in $root"
)
