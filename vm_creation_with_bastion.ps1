[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "config.yaml",

    [Parameter(Mandatory = $false)]
    [switch]$GeneratePassword,

    [Parameter(Mandatory = $false)]
    [switch]$ShowPassword,

    [Parameter(Mandatory = $false)]
    [switch]$SecurityAssessmentAdvice,

    [Parameter(Mandatory = $false)]
    [switch]$Plan,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ErrorLogPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$moduleManifestPath = Join-Path $PSScriptRoot "AzureSqlVmToolkit.psd1"
Import-Module $moduleManifestPath -Force

$arguments = @{
    ConfigFile = $ConfigFile
}

if ($GeneratePassword) {
    $arguments.GeneratePassword = $true
}

if ($ShowPassword) {
    $arguments.ShowPassword = $true
}

if ($SecurityAssessmentAdvice) {
    $arguments.SecurityAssessmentAdvice = $true
}

if ($Plan) {
    $arguments.Plan = $true
}

if ($PSBoundParameters.ContainsKey("ErrorLogPath")) {
    $arguments.ErrorLogPath = $ErrorLogPath
}

New-AzureSqlVmToolkitDeployment @arguments -WhatIf:$WhatIfPreference
