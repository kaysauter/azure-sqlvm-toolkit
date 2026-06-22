Set-StrictMode -Version 3.0

$script:AzureSqlVmToolkitRoot = $PSScriptRoot

$commonModulePath = Join-Path $script:AzureSqlVmToolkitRoot "scripts/AzureSqlVmToolkit.Common.psm1"
Import-Module $commonModulePath -Force

$deploymentModulePath = Join-Path $script:AzureSqlVmToolkitRoot "scripts/AzureSqlVmToolkit.Deployment.psm1"
Import-Module $deploymentModulePath -Force -DisableNameChecking

$publicPath = Join-Path $script:AzureSqlVmToolkitRoot "Public"
if (Test-Path $publicPath) {
    foreach ($file in Get-ChildItem -Path $publicPath -Filter "*.ps1" -File) {
        . $file.FullName
    }
}

Export-ModuleMember -Function @(
    "New-AzureSqlVmToolkitDeployment",
    "Test-AzureSqlVmToolkitConfig"
)
