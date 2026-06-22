[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter(Mandatory = $false)]
    [string]$ExpectedTag
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$versionPath = Join-Path $RepositoryRoot "VERSION"
$manifestPath = Join-Path $RepositoryRoot "AzureSqlVmToolkit.psd1"

if (-not (Test-Path $versionPath)) {
    throw "VERSION file not found."
}

$version = (Get-Content $versionPath -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') {
    throw "VERSION '$version' is not a valid SemVer value."
}

$manifest = Import-PowerShellDataFile -Path $manifestPath
$manifestVersion = [string]$manifest.ModuleVersion
if ($manifestVersion -ne $version) {
    throw "VERSION '$version' does not match AzureSqlVmToolkit.psd1 ModuleVersion '$manifestVersion'."
}

if (-not [string]::IsNullOrWhiteSpace($ExpectedTag)) {
    $expectedVersionTag = "v$version"
    if ($ExpectedTag -ne $expectedVersionTag) {
        throw "Release tag '$ExpectedTag' does not match VERSION '$expectedVersionTag'."
    }
}

[pscustomobject]@{
    Version = $version
    Tag     = "v$version"
}
