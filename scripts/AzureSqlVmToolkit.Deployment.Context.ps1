Set-StrictMode -Version 3.0

# Internal deployment implementation. Import AzureSqlVmToolkit.Deployment.psm1 instead of this file.

function Get-ToolkitAzCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Missing Azure PowerShell command '$Name'. Install or update the Az module before deployment."
    }

    return $command
}

function Get-ToolkitPredictedResourceId {
    param(
        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ProviderPath
    )

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        return "/resourceGroups/$ResourceGroupName/providers/$ProviderPath"
    }

    return "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/$ProviderPath"
}

function ConvertTo-ToolkitComparableAzureLocation {
    param([Parameter(Mandatory = $false)][string]$Location)

    if ([string]::IsNullOrWhiteSpace($Location)) {
        return $Location
    }

    return $Location.ToLowerInvariant() -replace '\s', ''
}

function Write-ToolkitDeploymentStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Created", "Reused", "Updated", "Skipped", "DriftDetected", "Failed", "WouldCreate", "WouldUpdate", "WouldRun")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$ResourceId,

        [Parameter(Mandatory = $false)]
        [hashtable]$Detail = @{}
    )

    $result = ConvertTo-ToolkitDeploymentStepResult -Name $Name -Status $Status -Message $Message -ResourceId $ResourceId -Detail $Detail
    Write-ToolkitDeploymentStepResult -Result $result
    return $result
}

function Test-ToolkitStepSkipped {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Step,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Step -and $Step.Status -eq "Skipped") {
        Write-ToolkitWarning -Message $Message
        return $true
    }

    return $false
}

function Get-ToolkitDeploymentContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile
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

    $resourceNames = Get-ToolkitResourceNameSet `
        -ResourceGroupName $config.resourceGroup.name `
        -KeyVaultName $config.keyVault.name `
        -StorageAccountName $config.storage.accountName `
        -FileShareName $config.storage.fileShareName `
        -StorageResourceGroupName $config.storage.resourceGroup

    return [pscustomobject]@{
        ConfigFile             = $ConfigFile
        ConfigPath             = $configPath
        Config                 = $config
        ResourceNames          = $resourceNames
        VmPublicIpEnabled      = ConvertTo-BooleanDefault -Value $config.network.publicIp.enabled -Default $false
        PlainPasswordForDisplay = $null
        EffectiveKeyVaultName  = $resourceNames.KeyVaultName
    }
}

function Get-ToolkitAzureContext {
    param(
        [scriptblock]$GetContext = {
            Get-ToolkitAzCommand -Name "Get-AzContext" | Out-Null
            Get-AzContext
        }
    )

    $currentContext = & $GetContext
    if (-not $currentContext) {
        throw "No Azure context found. Run Connect-AzAccount first."
    }

    return $currentContext
}

