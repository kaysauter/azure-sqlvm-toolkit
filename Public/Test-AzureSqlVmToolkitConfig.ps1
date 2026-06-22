function Test-AzureSqlVmToolkitConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigFile = "config.yaml",

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "Missing dependency 'powershell-yaml'. Install it with: Install-Module -Name powershell-yaml -Scope CurrentUser"
    }
    Import-Module powershell-yaml

    $configPath = Resolve-ToolkitConfigPath -Path $ConfigFile
    if (-not (Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }

    $config = Get-Content $configPath -Raw | ConvertFrom-Yaml
    Test-ToolkitConfig -Config $config

    if ($PassThru) {
        $resourceNames = Get-ToolkitResourceNameSet `
            -ResourceGroupName $config.resourceGroup.name `
            -KeyVaultName $config.keyVault.name `
            -StorageAccountName $config.storage.accountName `
            -FileShareName $config.storage.fileShareName `
            -StorageResourceGroupName $config.storage.resourceGroup

        return [pscustomobject]@{
            Valid         = $true
            ConfigPath    = $configPath
            ResourceNames = $resourceNames
            Config        = $config
        }
    }

    return $true
}
