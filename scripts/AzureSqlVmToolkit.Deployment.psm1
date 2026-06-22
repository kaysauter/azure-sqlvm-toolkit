Set-StrictMode -Version 3.0

$commonModulePath = Join-Path $PSScriptRoot "AzureSqlVmToolkit.Common.psm1"
Import-Module $commonModulePath -Force

foreach ($moduleName in @(
    "AzureSqlVmToolkit.Deployment.Context.ps1",
    "AzureSqlVmToolkit.Deployment.Network.ps1",
    "AzureSqlVmToolkit.Deployment.Compute.ps1",
    "AzureSqlVmToolkit.Deployment.Security.ps1",
    "AzureSqlVmToolkit.Deployment.Storage.ps1",
    "AzureSqlVmToolkit.Deployment.GuestSetup.ps1",
    "AzureSqlVmToolkit.Deployment.Orchestration.ps1"
)) {
    $modulePath = Join-Path $PSScriptRoot $moduleName
    . $modulePath
}

Export-ModuleMember -Function @(
    "Invoke-AzureSqlVmToolkitDeployment",
    "Get-ToolkitDeploymentContext",
    "Ensure-ToolkitResourceGroup",
    "Ensure-ToolkitKeyVault",
    "Ensure-ToolkitRoleAssignment",
    "Ensure-ToolkitVmAdminPasswordSecret",
    "Ensure-ToolkitVirtualNetwork",
    "Ensure-ToolkitPublicIpAddress",
    "Ensure-ToolkitNetworkSecurityGroup",
    "Ensure-ToolkitNetworkInterface",
    "Ensure-ToolkitVirtualMachine",
    "Ensure-ToolkitVmManagedIdentity",
    "Ensure-ToolkitBastion",
    "Ensure-ToolkitStorage",
    "Ensure-ToolkitGuestSetup",
    "Get-ToolkitGuestInstallScript"
)
