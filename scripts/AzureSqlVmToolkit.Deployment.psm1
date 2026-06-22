Set-StrictMode -Version 3.0

$commonModulePath = Join-Path $PSScriptRoot "AzureSqlVmToolkit.Common.psm1"
Import-Module $commonModulePath -Force

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

function Ensure-ToolkitResourceGroup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $false)][hashtable]$Tag,
        [scriptblock]$GetResourceGroup = {
            param($Name)
            Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewResourceGroup = {
            param($Name, $Location, $Tag)
            New-AzResourceGroup -Name $Name -Location $Location -Tag $Tag
        }
    )

    $existing = & $GetResourceGroup $Name
    if ($existing) {
        $expectedLocation = ConvertTo-ToolkitComparableAzureLocation -Location $Location
        $actualLocation = ConvertTo-ToolkitComparableAzureLocation -Location $existing.Location
        if ($expectedLocation -ne $actualLocation) {
            $drift = Compare-ToolkitResourceProperty -ResourceName "Resource group '$Name'" -PropertyName "Location" -ExpectedValue $Location -ActualValue $existing.Location -DriftPolicy "Fail"
            Assert-ToolkitNoBlockingDrift -Result $drift
        }
        return Write-ToolkitDeploymentStep -Name "Resource group" -Status "Reused" -Message "'$Name' already exists." -ResourceId $existing.ResourceId -Detail @{ Resource = $existing }
    }

    if ($WhatIfPreference) {
        return Write-ToolkitDeploymentStep -Name "Resource group" -Status "WouldCreate" -Message "Would create '$Name' in '$Location'."
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create resource group")) {
        $created = & $NewResourceGroup $Name $Location $Tag
        return Write-ToolkitDeploymentStep -Name "Resource group" -Status "Created" -Message "'$Name' created." -ResourceId $created.ResourceId -Detail @{ Resource = $created }
    }

    return Write-ToolkitDeploymentStep -Name "Resource group" -Status "Skipped" -Message "'$Name' was not created."
}

function Ensure-ToolkitKeyVault {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $false)][string]$SubscriptionId,
        [scriptblock]$GetKeyVault = {
            param($Name)
            Get-AzKeyVault -VaultName $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$GetRemovedKeyVault = {
            param($Name, $Location)
            Get-AzKeyVault -VaultName $Name -Location $Location -InRemovedState -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewKeyVault = {
            param($Name, $ResourceGroupName, $Location)
            New-AzKeyVault -Name $Name -ResourceGroupName $ResourceGroupName -Location $Location -EnableRbacAuthorization
        }
    )

    $vaultName = $Name
    $existing = & $GetKeyVault $vaultName
    if ($existing) {
        if (-not $existing.EnableRbacAuthorization) {
            throw "Key Vault '$vaultName' uses legacy access policies. Use an RBAC-enabled vault or a different keyVault.name."
        }

        $step = Write-ToolkitDeploymentStep -Name "Key Vault" -Status "Reused" -Message "'$vaultName' already exists." -ResourceId $existing.ResourceId -Detail @{ Resource = $existing; VaultName = $vaultName }
        return [pscustomobject]@{ VaultName = $vaultName; Resource = $existing; Step = $step; OriginalName = $Name }
    }

    $removed = & $GetRemovedKeyVault $vaultName $Location
    if ($removed) {
        $i = 1
        do {
            $vaultName = "$Name$i"
            $i++
            $existing = & $GetKeyVault $vaultName
            $removed = & $GetRemovedKeyVault $vaultName $Location
        } while ($existing -or $removed)
        Write-ToolkitWarning -Message "Original Key Vault name '$Name' is soft-deleted. Using '$vaultName' instead."
    }

    $resourceId = Get-ToolkitPredictedResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ProviderPath "Microsoft.KeyVault/vaults/$vaultName"
    if ($WhatIfPreference) {
        $step = Write-ToolkitDeploymentStep -Name "Key Vault" -Status "WouldCreate" -Message "Would create RBAC-enabled vault '$vaultName'." -ResourceId $resourceId -Detail @{ VaultName = $vaultName }
        return [pscustomobject]@{ VaultName = $vaultName; Resource = [pscustomobject]@{ ResourceId = $resourceId; VaultName = $vaultName; EnableRbacAuthorization = $true }; Step = $step; OriginalName = $Name }
    }

    if ($PSCmdlet.ShouldProcess($vaultName, "Create RBAC-enabled Key Vault")) {
        $created = & $NewKeyVault $vaultName $ResourceGroupName $Location
        $step = Write-ToolkitDeploymentStep -Name "Key Vault" -Status "Created" -Message "'$vaultName' created with RBAC authorization." -ResourceId $created.ResourceId -Detail @{ Resource = $created; VaultName = $vaultName }
        return [pscustomobject]@{ VaultName = $vaultName; Resource = $created; Step = $step; OriginalName = $Name }
    }

    $step = Write-ToolkitDeploymentStep -Name "Key Vault" -Status "Skipped" -Message "'$vaultName' was not created." -ResourceId $resourceId -Detail @{ VaultName = $vaultName }
    return [pscustomobject]@{ VaultName = $vaultName; Resource = [pscustomobject]@{ ResourceId = $resourceId; VaultName = $vaultName }; Step = $step; OriginalName = $Name }
}

function Ensure-ToolkitRoleAssignment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [Parameter(Mandatory = $true)][string]$RoleDefinitionName,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    if ($WhatIfPreference) {
        return Write-ToolkitDeploymentStep -Name "Role assignment" -Status "WouldUpdate" -Message "Would ensure '$RoleDefinitionName' for '$ObjectId' on '$Scope'." -ResourceId $Scope
    }

    if ($PSCmdlet.ShouldProcess($Scope, "Ensure role '$RoleDefinitionName' for '$ObjectId'")) {
        Add-ToolkitRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope -Confirm:$false
        return Write-ToolkitDeploymentStep -Name "Role assignment" -Status "Updated" -Message "Ensured '$RoleDefinitionName' for '$ObjectId'." -ResourceId $Scope
    }

    return Write-ToolkitDeploymentStep -Name "Role assignment" -Status "Skipped" -Message "Role '$RoleDefinitionName' was not assigned to '$ObjectId'." -ResourceId $Scope
}

function Ensure-ToolkitVmAdminPasswordSecret {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "", Justification = "Lab-only generated password must be converted for Key Vault and VM credential APIs.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$VaultName,
        [Parameter(Mandatory = $true)][string]$SecretName,
        [Parameter(Mandatory = $true)][int]$PasswordLength,
        [Parameter(Mandatory = $true)][switch]$GeneratePassword,
        [scriptblock]$GetSecret = {
            param($VaultName, $SecretName)
            Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -ErrorAction SilentlyContinue
        },
        [scriptblock]$SetSecret = {
            param($VaultName, $SecretName, $SecretValue)
            Set-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -SecretValue $SecretValue
        }
    )

    $existing = & $GetSecret $VaultName $SecretName
    if ($existing) {
        $securePassword = if ($WhatIfPreference) {
            ConvertTo-SecureString "WhatIf-Existing-Password-Placeholder1!" -AsPlainText -Force
        }
        else {
            (Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName).SecretValue
        }
        $step = Write-ToolkitDeploymentStep -Name "VM admin secret" -Status "Reused" -Message "'$SecretName' already exists in Key Vault." -Detail @{ SecretName = $SecretName }
        return [pscustomobject]@{ SecretValue = $securePassword; PlainTextForDisplay = $null; Step = $step }
    }

    if (-not $GeneratePassword) {
        throw "VM admin password secret '$SecretName' does not exist in Key Vault '$VaultName'. Pre-create it or rerun with -GeneratePassword for lab/demo use."
    }

    if ($WhatIfPreference) {
        $placeholder = ConvertTo-SecureString "WhatIf-Password-Placeholder-Not-Used1!" -AsPlainText -Force
        $step = Write-ToolkitDeploymentStep -Name "VM admin secret" -Status "WouldCreate" -Message "Would generate and store lab password secret '$SecretName'." -Detail @{ SecretName = $SecretName }
        return [pscustomobject]@{ SecretValue = $placeholder; PlainTextForDisplay = $null; Step = $step }
    }

    $plainPassword = Get-ToolkitGeneratedPassword -Length $PasswordLength
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    if ($PSCmdlet.ShouldProcess($SecretName, "Store generated VM admin password in Key Vault '$VaultName'")) {
        & $SetSecret $VaultName $SecretName $securePassword | Out-Null
        $step = Write-ToolkitDeploymentStep -Name "VM admin secret" -Status "Created" -Message "Generated lab password stored as '$SecretName'." -Detail @{ SecretName = $SecretName }
        return [pscustomobject]@{ SecretValue = $securePassword; PlainTextForDisplay = $plainPassword; Step = $step }
    }

    $step = Write-ToolkitDeploymentStep -Name "VM admin secret" -Status "Skipped" -Message "'$SecretName' was not created." -Detail @{ SecretName = $SecretName }
    return [pscustomobject]@{ SecretValue = $securePassword; PlainTextForDisplay = $plainPassword; Step = $step }
}

function Ensure-ToolkitVirtualNetwork {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Names,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $false)][string]$SubscriptionId,
        [scriptblock]$GetVirtualNetwork = {
            param($ResourceGroupName, $Name)
            Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewSubnetConfig = {
            param($SubnetName, $AddressPrefix)
            New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $AddressPrefix
        },
        [scriptblock]$NewVirtualNetwork = {
            param($ResourceGroupName, $Location, $Name, $AddressPrefix, $SubnetConfig)
            New-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Location $Location -Name $Name -AddressPrefix $AddressPrefix -Subnet $SubnetConfig
        },
        [scriptblock]$AddSubnet = {
            param($VirtualNetwork, $SubnetName, $AddressPrefix)
            Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $VirtualNetwork -AddressPrefix $AddressPrefix | Set-AzVirtualNetwork
        }
    )

    $resourceId = Get-ToolkitPredictedResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $Names.ResourceGroupName -ProviderPath "Microsoft.Network/virtualNetworks/$($Names.VnetName)"
    $subnetId = "$resourceId/subnets/$($Names.SubnetName)"
    $vnet = & $GetVirtualNetwork $Names.ResourceGroupName $Names.VnetName
    if (-not $vnet) {
        if ($WhatIfPreference) {
            $step = Write-ToolkitDeploymentStep -Name "Virtual network" -Status "WouldCreate" -Message "Would create '$($Names.VnetName)' and subnet '$($Names.SubnetName)'." -ResourceId $resourceId -Detail @{ SubnetId = $subnetId }
            return [pscustomobject]@{ Resource = [pscustomobject]@{ Id = $resourceId; Subnets = @([pscustomobject]@{ Name = $Names.SubnetName; Id = $subnetId }) }; SubnetId = $subnetId; Step = $step }
        }

        if ($PSCmdlet.ShouldProcess($Names.VnetName, "Create virtual network")) {
            $subnetConfig = & $NewSubnetConfig $Names.SubnetName $Config.network.subnet.addressPrefix
            $vnet = & $NewVirtualNetwork $Names.ResourceGroupName $Location $Names.VnetName $Config.network.vnet.addressPrefix $subnetConfig
            $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $Names.SubnetName } | Select-Object -First 1
            $step = Write-ToolkitDeploymentStep -Name "Virtual network" -Status "Created" -Message "'$($Names.VnetName)' created." -ResourceId $vnet.Id -Detail @{ Resource = $vnet; SubnetId = $subnet.Id }
            return [pscustomobject]@{ Resource = $vnet; SubnetId = $subnet.Id; Step = $step }
        }

        $step = Write-ToolkitDeploymentStep -Name "Virtual network" -Status "Skipped" -Message "'$($Names.VnetName)' was not created." -ResourceId $resourceId -Detail @{ SubnetId = $subnetId }
        return [pscustomobject]@{ Resource = $null; SubnetId = $subnetId; Step = $step }
    }

    $prefix = ($vnet.AddressSpace.AddressPrefixes | Select-Object -First 1)
    $drift = Compare-ToolkitResourceProperty -ResourceName "Virtual network '$($Names.VnetName)'" -PropertyName "AddressPrefix" -ExpectedValue $Config.network.vnet.addressPrefix -ActualValue $prefix -DriftPolicy "Fail"
    Assert-ToolkitNoBlockingDrift -Result $drift

    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $Names.SubnetName } | Select-Object -First 1
    if (-not $subnet) {
        if ($WhatIfPreference) {
            $step = Write-ToolkitDeploymentStep -Name "Virtual network subnet" -Status "WouldUpdate" -Message "Would add subnet '$($Names.SubnetName)' to '$($Names.VnetName)'." -ResourceId $subnetId -Detail @{ SubnetId = $subnetId }
            return [pscustomobject]@{ Resource = $vnet; SubnetId = $subnetId; Step = $step }
        }

        if ($PSCmdlet.ShouldProcess($Names.VnetName, "Add subnet '$($Names.SubnetName)'")) {
            $vnet = & $AddSubnet $vnet $Names.SubnetName $Config.network.subnet.addressPrefix
            $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $Names.SubnetName } | Select-Object -First 1
            $step = Write-ToolkitDeploymentStep -Name "Virtual network subnet" -Status "Updated" -Message "Subnet '$($Names.SubnetName)' added." -ResourceId $subnet.Id -Detail @{ Resource = $vnet; SubnetId = $subnet.Id }
            return [pscustomobject]@{ Resource = $vnet; SubnetId = $subnet.Id; Step = $step }
        }

        $step = Write-ToolkitDeploymentStep -Name "Virtual network subnet" -Status "Skipped" -Message "Subnet '$($Names.SubnetName)' was not added." -ResourceId $subnetId -Detail @{ Resource = $vnet; SubnetId = $subnetId }
        return [pscustomobject]@{ Resource = $vnet; SubnetId = $subnetId; Step = $step }
    }

    $subnetDrift = Compare-ToolkitResourceProperty -ResourceName "Subnet '$($Names.SubnetName)'" -PropertyName "AddressPrefix" -ExpectedValue $Config.network.subnet.addressPrefix -ActualValue $subnet.AddressPrefix -DriftPolicy "Fail"
    Assert-ToolkitNoBlockingDrift -Result $subnetDrift

    $step = Write-ToolkitDeploymentStep -Name "Virtual network" -Status "Reused" -Message "'$($Names.VnetName)' and '$($Names.SubnetName)' already match config." -ResourceId $vnet.Id -Detail @{ Resource = $vnet; SubnetId = $subnet.Id }
    return [pscustomobject]@{ Resource = $vnet; SubnetId = $subnet.Id; Step = $step }
}

function Ensure-ToolkitPublicIpAddress {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $false)][string]$AllocationMethod = "Static",
        [Parameter(Mandatory = $false)][int]$IdleTimeoutInMinutes = 4,
        [Parameter(Mandatory = $false)][string]$Sku,
        [Parameter(Mandatory = $false)][string]$SubscriptionId,
        [scriptblock]$GetPublicIpAddress = {
            param($ResourceGroupName, $Name)
            Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewPublicIpAddress = {
            param($ResourceGroupName, $Location, $Name, $AllocationMethod, $IdleTimeoutInMinutes, $Sku)
            $params = @{
                ResourceGroupName      = $ResourceGroupName
                Location               = $Location
                Name                   = $Name
                AllocationMethod       = $AllocationMethod
                IdleTimeoutInMinutes   = $IdleTimeoutInMinutes
            }
            if (-not [string]::IsNullOrWhiteSpace($Sku)) {
                $params.Sku = $Sku
            }
            New-AzPublicIpAddress @params
        }
    )

    $existing = & $GetPublicIpAddress $ResourceGroupName $Name
    if ($existing) {
        $allocation = if ($existing.PublicIpAllocationMethod) { $existing.PublicIpAllocationMethod } else { $existing.IpAddressAllocationMethod }
        $drift = Compare-ToolkitResourceProperty -ResourceName "Public IP '$Name'" -PropertyName "AllocationMethod" -ExpectedValue $AllocationMethod -ActualValue $allocation -DriftPolicy "Fail"
        Assert-ToolkitNoBlockingDrift -Result $drift
        return Write-ToolkitDeploymentStep -Name "Public IP" -Status "Reused" -Message "'$Name' already exists." -ResourceId $existing.Id -Detail @{ Resource = $existing }
    }

    $resourceId = Get-ToolkitPredictedResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ProviderPath "Microsoft.Network/publicIPAddresses/$Name"
    if ($WhatIfPreference) {
        return Write-ToolkitDeploymentStep -Name "Public IP" -Status "WouldCreate" -Message "Would create '$Name'." -ResourceId $resourceId -Detail @{ Resource = [pscustomobject]@{ Id = $resourceId } }
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create public IP address")) {
        $created = & $NewPublicIpAddress $ResourceGroupName $Location $Name $AllocationMethod $IdleTimeoutInMinutes $Sku
        return Write-ToolkitDeploymentStep -Name "Public IP" -Status "Created" -Message "'$Name' created." -ResourceId $created.Id -Detail @{ Resource = $created }
    }

    return Write-ToolkitDeploymentStep -Name "Public IP" -Status "Skipped" -Message "'$Name' was not created." -ResourceId $resourceId
}

function Ensure-ToolkitNetworkSecurityGroup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Names,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $false)][string]$SubscriptionId,
        [scriptblock]$GetNetworkSecurityGroup = {
            param($ResourceGroupName, $Name)
            Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewNetworkSecurityGroup = {
            param($Params)
            New-AzNetworkSecurityGroup @Params
        },
        [scriptblock]$UpdateNetworkSecurityGroup = {
            param($NetworkSecurityGroup, $Rules)
            foreach ($rule in $Rules) {
                Add-AzNetworkSecurityRuleConfig `
                    -NetworkSecurityGroup $NetworkSecurityGroup `
                    -Name $rule.name `
                    -Protocol $rule.protocol `
                    -Direction $rule.direction `
                    -Priority $rule.priority `
                    -SourceAddressPrefix $rule.sourceAddressPrefix `
                    -SourcePortRange $rule.sourcePortRange `
                    -DestinationAddressPrefix $rule.destinationAddressPrefix `
                    -DestinationPortRange $rule.destinationPortRange `
                    -Access $rule.access | Out-Null
            }
            Set-AzNetworkSecurityGroup -NetworkSecurityGroup $NetworkSecurityGroup
        }
    )

    $resourceId = Get-ToolkitPredictedResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $Names.ResourceGroupName -ProviderPath "Microsoft.Network/networkSecurityGroups/$($Names.NsgName)"
    $nsg = & $GetNetworkSecurityGroup $Names.ResourceGroupName $Names.NsgName
    if (-not $nsg) {
        if ($WhatIfPreference) {
            return Write-ToolkitDeploymentStep -Name "Network security group" -Status "WouldCreate" -Message "Would create '$($Names.NsgName)'." -ResourceId $resourceId -Detail @{ Resource = [pscustomobject]@{ Id = $resourceId } }
        }

        if ($PSCmdlet.ShouldProcess($Names.NsgName, "Create network security group")) {
            $nsgRules = @()
            foreach ($rule in @($Config.securityRules)) {
                if ($null -eq $rule) { continue }
                $nsgRules += New-AzNetworkSecurityRuleConfig `
                    -Name $rule.name `
                    -Protocol $rule.protocol `
                    -Direction $rule.direction `
                    -Priority $rule.priority `
                    -SourceAddressPrefix $rule.sourceAddressPrefix `
                    -SourcePortRange $rule.sourcePortRange `
                    -DestinationAddressPrefix $rule.destinationAddressPrefix `
                    -DestinationPortRange $rule.destinationPortRange `
                    -Access $rule.access
            }

            $params = @{
                ResourceGroupName = $Names.ResourceGroupName
                Location          = $Location
                Name              = $Names.NsgName
            }
            if ($nsgRules.Count -gt 0) {
                $params.SecurityRules = $nsgRules
            }
            $nsg = & $NewNetworkSecurityGroup $params
            return Write-ToolkitDeploymentStep -Name "Network security group" -Status "Created" -Message "'$($Names.NsgName)' created." -ResourceId $nsg.Id -Detail @{ Resource = $nsg }
        }

        return Write-ToolkitDeploymentStep -Name "Network security group" -Status "Skipped" -Message "'$($Names.NsgName)' was not created." -ResourceId $resourceId
    }

    $missingRules = @()
    foreach ($rule in @($Config.securityRules)) {
        if ($null -eq $rule) { continue }
        $existingRule = $nsg.SecurityRules | Where-Object { $_.Name -eq $rule.name } | Select-Object -First 1
        if (-not $existingRule) {
            $missingRules += $rule
            continue
        }

        $ruleComparisons = @(
            @{ Property = "Protocol"; ConfigPath = "protocol" },
            @{ Property = "Direction"; ConfigPath = "direction" },
            @{ Property = "Priority"; ConfigPath = "priority" },
            @{ Property = "SourceAddressPrefix"; ConfigPath = "sourceAddressPrefix" },
            @{ Property = "SourcePortRange"; ConfigPath = "sourcePortRange" },
            @{ Property = "DestinationAddressPrefix"; ConfigPath = "destinationAddressPrefix" },
            @{ Property = "DestinationPortRange"; ConfigPath = "destinationPortRange" },
            @{ Property = "Access"; ConfigPath = "access" }
        )
        foreach ($comparison in $ruleComparisons) {
            $expected = Get-ToolkitConfigValue -Config $rule -Path $comparison.ConfigPath
            $actual = $existingRule.($comparison.Property)
            $drift = Compare-ToolkitResourceProperty -ResourceName "NSG rule '$($rule.name)'" -PropertyName $comparison.Property -ExpectedValue $expected -ActualValue $actual -DriftPolicy "Fail"
            Assert-ToolkitNoBlockingDrift -Result $drift
        }
    }

    if ($missingRules.Count -gt 0) {
        if ($WhatIfPreference) {
            return Write-ToolkitDeploymentStep -Name "Network security group" -Status "WouldUpdate" -Message "Would add $($missingRules.Count) missing NSG rule(s) to '$($Names.NsgName)'." -ResourceId $nsg.Id -Detail @{ Resource = $nsg; MissingRules = $missingRules.Count }
        }

        if ($PSCmdlet.ShouldProcess($Names.NsgName, "Add missing NSG rules")) {
            $nsg = & $UpdateNetworkSecurityGroup $nsg $missingRules
            return Write-ToolkitDeploymentStep -Name "Network security group" -Status "Updated" -Message "Added $($missingRules.Count) missing NSG rule(s)." -ResourceId $nsg.Id -Detail @{ Resource = $nsg; MissingRules = $missingRules.Count }
        }

        return Write-ToolkitDeploymentStep -Name "Network security group" -Status "Skipped" -Message "Missing NSG rules were not added to '$($Names.NsgName)'." -ResourceId $nsg.Id -Detail @{ Resource = $nsg; MissingRules = $missingRules.Count }
    }

    return Write-ToolkitDeploymentStep -Name "Network security group" -Status "Reused" -Message "'$($Names.NsgName)' already matches config." -ResourceId $nsg.Id -Detail @{ Resource = $nsg }
}

function Ensure-ToolkitNetworkInterface {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$Names,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string]$SubnetId,
        [Parameter(Mandatory = $true)][string]$NetworkSecurityGroupId,
        [Parameter(Mandatory = $false)][string]$PublicIpAddressId,
        [Parameter(Mandatory = $false)][string]$SubscriptionId,
        [scriptblock]$GetNetworkInterface = {
            param($ResourceGroupName, $Name)
            Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewNetworkInterface = {
            param($Params)
            New-AzNetworkInterface @Params
        }
    )

    $resourceId = Get-ToolkitPredictedResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $Names.ResourceGroupName -ProviderPath "Microsoft.Network/networkInterfaces/$($Names.InterfaceName)"
    $nic = & $GetNetworkInterface $Names.ResourceGroupName $Names.InterfaceName
    if ($nic) {
        $ipConfig = $nic.IpConfigurations | Select-Object -First 1
        $subnetDrift = Compare-ToolkitResourceProperty -ResourceName "Network interface '$($Names.InterfaceName)'" -PropertyName "SubnetId" -ExpectedValue $SubnetId -ActualValue $ipConfig.Subnet.Id -DriftPolicy "Fail"
        Assert-ToolkitNoBlockingDrift -Result $subnetDrift
        $nsgDrift = Compare-ToolkitResourceProperty -ResourceName "Network interface '$($Names.InterfaceName)'" -PropertyName "NetworkSecurityGroupId" -ExpectedValue $NetworkSecurityGroupId -ActualValue $nic.NetworkSecurityGroup.Id -DriftPolicy "Fail"
        Assert-ToolkitNoBlockingDrift -Result $nsgDrift
        return Write-ToolkitDeploymentStep -Name "Network interface" -Status "Reused" -Message "'$($Names.InterfaceName)' already matches config." -ResourceId $nic.Id -Detail @{ Resource = $nic }
    }

    if ($WhatIfPreference) {
        return Write-ToolkitDeploymentStep -Name "Network interface" -Status "WouldCreate" -Message "Would create '$($Names.InterfaceName)'." -ResourceId $resourceId -Detail @{ Resource = [pscustomobject]@{ Id = $resourceId } }
    }

    if ($PSCmdlet.ShouldProcess($Names.InterfaceName, "Create network interface")) {
        $params = @{
            Name                   = $Names.InterfaceName
            ResourceGroupName      = $Names.ResourceGroupName
            Location               = $Location
            SubnetId               = $SubnetId
            NetworkSecurityGroupId = $NetworkSecurityGroupId
        }
        if (-not [string]::IsNullOrWhiteSpace($PublicIpAddressId)) {
            $params.PublicIpAddressId = $PublicIpAddressId
        }
        $nic = & $NewNetworkInterface $params
        return Write-ToolkitDeploymentStep -Name "Network interface" -Status "Created" -Message "'$($Names.InterfaceName)' created." -ResourceId $nic.Id -Detail @{ Resource = $nic }
    }

    return Write-ToolkitDeploymentStep -Name "Network interface" -Status "Skipped" -Message "'$($Names.InterfaceName)' was not created." -ResourceId $resourceId
}

function Ensure-ToolkitVirtualMachine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Names,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string]$NetworkInterfaceId,
        [Parameter(Mandatory = $true)][securestring]$AdminPassword,
        [Parameter(Mandatory = $false)][string]$SubscriptionId,
        [scriptblock]$GetVm = {
            param($ResourceGroupName, $Name)
            Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewVm = {
            param($ResourceGroupName, $Location, $VmConfig)
            New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $VmConfig
        }
    )

    $resourceId = Get-ToolkitPredictedResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $Names.ResourceGroupName -ProviderPath "Microsoft.Compute/virtualMachines/$($Names.VMName)"
    $vm = & $GetVm $Names.ResourceGroupName $Names.VMName
    if ($vm) {
        $sizeDrift = Compare-ToolkitResourceProperty -ResourceName "VM '$($Names.VMName)'" -PropertyName "Size" -ExpectedValue $Config.vm.size -ActualValue $vm.HardwareProfile.VmSize -DriftPolicy "Fail"
        Assert-ToolkitNoBlockingDrift -Result $sizeDrift
        $image = $vm.StorageProfile.ImageReference
        foreach ($field in @("Publisher", "Offer", "Sku", "Version")) {
            $expectedPath = switch ($field) {
                "Publisher" { "vm.image.publisherName" }
                "Offer" { "vm.image.offer" }
                "Sku" { "vm.image.skus" }
                "Version" { "vm.image.version" }
            }
            $expected = Get-ToolkitConfigValue -Config $Config -Path $expectedPath
            $actual = $image.$field
            if ($field -eq "Version" -and [string]$expected -eq "latest") {
                continue
            }
            $drift = Compare-ToolkitResourceProperty -ResourceName "VM '$($Names.VMName)'" -PropertyName "Image$field" -ExpectedValue $expected -ActualValue $actual -DriftPolicy "Fail"
            Assert-ToolkitNoBlockingDrift -Result $drift
        }
        return Write-ToolkitDeploymentStep -Name "Virtual machine" -Status "Reused" -Message "'$($Names.VMName)' already matches size and image config." -ResourceId $vm.Id -Detail @{ Resource = $vm }
    }

    if ($WhatIfPreference) {
        return Write-ToolkitDeploymentStep -Name "Virtual machine" -Status "WouldCreate" -Message "Would create '$($Names.VMName)'." -ResourceId $resourceId -Detail @{ Resource = [pscustomobject]@{ Id = $resourceId } }
    }

    if ($PSCmdlet.ShouldProcess($Names.VMName, "Create SQL Server VM")) {
        $credential = New-Object System.Management.Automation.PSCredential ($Config.credentials.username, $AdminPassword)
        $vmConfig = New-AzVMConfig -VMName $Names.VMName -VMSize $Config.vm.size |
            Set-AzVMOperatingSystem -Windows -ComputerName $Names.VMName -Credential $credential -ProvisionVMAgent -EnableAutoUpdate |
            Set-AzVMSourceImage -PublisherName $Config.vm.image.publisherName -Offer $Config.vm.image.offer -Skus $Config.vm.image.skus -Version $Config.vm.image.version |
            Add-AzVMNetworkInterface -Id $NetworkInterfaceId

        & $NewVm $Names.ResourceGroupName $Location $vmConfig | Out-Null
        $vm = & $GetVm $Names.ResourceGroupName $Names.VMName
        return Write-ToolkitDeploymentStep -Name "Virtual machine" -Status "Created" -Message "'$($Names.VMName)' created." -ResourceId $vm.Id -Detail @{ Resource = $vm }
    }

    return Write-ToolkitDeploymentStep -Name "Virtual machine" -Status "Skipped" -Message "'$($Names.VMName)' was not created." -ResourceId $resourceId
}

function Ensure-ToolkitVmManagedIdentity {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $false)][object]$VirtualMachine,
        [scriptblock]$GetVm = {
            param($ResourceGroupName, $Name)
            Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
        },
        [scriptblock]$UpdateVm = {
            param($ResourceGroupName, $VirtualMachine)
            Update-AzVM -ResourceGroupName $ResourceGroupName -VM $VirtualMachine -IdentityType SystemAssigned
        }
    )

    $vm = if ($VirtualMachine) { $VirtualMachine } else { & $GetVm $ResourceGroupName $VMName }
    if ($vm.Identity -and $vm.Identity.PrincipalId) {
        return Write-ToolkitDeploymentStep -Name "VM managed identity" -Status "Reused" -Message "Managed identity already enabled on '$VMName'." -ResourceId $vm.Id -Detail @{ PrincipalId = $vm.Identity.PrincipalId; Resource = $vm }
    }

    if ($WhatIfPreference) {
        return Write-ToolkitDeploymentStep -Name "VM managed identity" -Status "WouldUpdate" -Message "Would enable system-assigned managed identity on '$VMName'." -ResourceId $vm.Id -Detail @{ PrincipalId = "whatif-principal-id"; Resource = $vm }
    }

    if ($PSCmdlet.ShouldProcess($VMName, "Enable system-assigned managed identity")) {
        & $UpdateVm $ResourceGroupName $vm | Out-Null
        $vm = & $GetVm $ResourceGroupName $VMName
        return Write-ToolkitDeploymentStep -Name "VM managed identity" -Status "Updated" -Message "Managed identity enabled on '$VMName'." -ResourceId $vm.Id -Detail @{ PrincipalId = $vm.Identity.PrincipalId; Resource = $vm }
    }

    return Write-ToolkitDeploymentStep -Name "VM managed identity" -Status "Skipped" -Message "Managed identity was not enabled on '$VMName'." -ResourceId $vm.Id -Detail @{ Resource = $vm }
}

function Ensure-ToolkitBastion {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Names,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $false)][string]$SubscriptionId,
        [scriptblock]$GetVirtualNetwork = {
            param($ResourceGroupName, $Name)
            Get-AzVirtualNetwork -Name $Name -ResourceGroupName $ResourceGroupName
        },
        [scriptblock]$AddSubnet = {
            param($VirtualNetwork, $SubnetName, $AddressPrefix)
            Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $VirtualNetwork -AddressPrefix $AddressPrefix | Set-AzVirtualNetwork
        },
        [scriptblock]$GetBastion = {
            param($ResourceGroupName, $Name)
            Get-AzBastion -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewBastion = {
            param($ResourceGroupName, $Name, $PublicIpAddressName, $VirtualNetworkName, $Sku)
            New-AzBastion -ResourceGroupName $ResourceGroupName -Name $Name -PublicIpAddressRgName $ResourceGroupName -PublicIpAddressName $PublicIpAddressName -VirtualNetworkRgName $ResourceGroupName -VirtualNetworkName $VirtualNetworkName -Sku $Sku
        }
    )

    $vnet = & $GetVirtualNetwork $Names.ResourceGroupName $Names.VnetName
    if (-not $vnet) {
        if (-not $WhatIfPreference) {
            throw "Virtual network '$($Names.VnetName)' was not found before Bastion reconciliation."
        }

        $vnetId = Get-ToolkitPredictedResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $Names.ResourceGroupName -ProviderPath "Microsoft.Network/virtualNetworks/$($Names.VnetName)"
        $vnet = [pscustomobject]@{
            Id      = $vnetId
            Subnets = @()
        }
    }

    $bastionSubnet = $vnet.Subnets | Where-Object { $_.Name -eq $Names.BastionSubnetName } | Select-Object -First 1
    if (-not $bastionSubnet) {
        $subnetId = "$($vnet.Id)/subnets/$($Names.BastionSubnetName)"
        if ($WhatIfPreference) {
            Write-ToolkitDeploymentStep -Name "Bastion subnet" -Status "WouldUpdate" -Message "Would add '$($Names.BastionSubnetName)'." -ResourceId $subnetId | Out-Null
        }
        elseif ($PSCmdlet.ShouldProcess($Names.VnetName, "Add Bastion subnet")) {
            $vnet = & $AddSubnet $vnet $Names.BastionSubnetName $Config.bastion.subnetAddressPrefix
            Write-ToolkitDeploymentStep -Name "Bastion subnet" -Status "Updated" -Message "'$($Names.BastionSubnetName)' added." -ResourceId $subnetId | Out-Null
        }
        else {
            return Write-ToolkitDeploymentStep -Name "Bastion subnet" -Status "Skipped" -Message "'$($Names.BastionSubnetName)' was not added." -ResourceId $subnetId
        }
    }
    else {
        $subnetDrift = Compare-ToolkitResourceProperty -ResourceName "Bastion subnet '$($Names.BastionSubnetName)'" -PropertyName "AddressPrefix" -ExpectedValue $Config.bastion.subnetAddressPrefix -ActualValue $bastionSubnet.AddressPrefix -DriftPolicy "Fail"
        Assert-ToolkitNoBlockingDrift -Result $subnetDrift
    }

    $pipStep = Ensure-ToolkitPublicIpAddress `
        -Name $Names.BastionPipName `
        -ResourceGroupName $Names.ResourceGroupName `
        -Location $Location `
        -AllocationMethod $Config.bastion.publicIp.allocationMethod `
        -IdleTimeoutInMinutes $Config.bastion.publicIp.idleTimeoutInMinutes `
        -Sku $Config.bastion.publicIp.sku `
        -SubscriptionId $SubscriptionId `
        -WhatIf:$WhatIfPreference

    $bastion = & $GetBastion $Names.ResourceGroupName $Names.BastionName
    if ($bastion) {
        $skuName = if ($bastion.Sku.Name) { $bastion.Sku.Name } else { $bastion.Sku }
        $drift = Compare-ToolkitResourceProperty -ResourceName "Bastion '$($Names.BastionName)'" -PropertyName "Sku" -ExpectedValue $Config.bastion.sku -ActualValue $skuName -DriftPolicy "Fail"
        Assert-ToolkitNoBlockingDrift -Result $drift
        return Write-ToolkitDeploymentStep -Name "Bastion" -Status "Reused" -Message "'$($Names.BastionName)' already exists." -ResourceId $bastion.Id -Detail @{ Resource = $bastion; PublicIp = $pipStep }
    }

    $resourceId = Get-ToolkitPredictedResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $Names.ResourceGroupName -ProviderPath "Microsoft.Network/bastionHosts/$($Names.BastionName)"
    if ($WhatIfPreference) {
        return Write-ToolkitDeploymentStep -Name "Bastion" -Status "WouldCreate" -Message "Would create '$($Names.BastionName)'." -ResourceId $resourceId -Detail @{ PublicIp = $pipStep }
    }

    if ($PSCmdlet.ShouldProcess($Names.BastionName, "Create Azure Bastion")) {
        & $NewBastion $Names.ResourceGroupName $Names.BastionName $Names.BastionPipName $Names.VnetName $Config.bastion.sku | Out-Null
        $bastion = & $GetBastion $Names.ResourceGroupName $Names.BastionName
        return Write-ToolkitDeploymentStep -Name "Bastion" -Status "Created" -Message "'$($Names.BastionName)' created." -ResourceId $bastion.Id -Detail @{ Resource = $bastion; PublicIp = $pipStep }
    }

    return Write-ToolkitDeploymentStep -Name "Bastion" -Status "Skipped" -Message "'$($Names.BastionName)' was not created." -ResourceId $resourceId
}

function Ensure-ToolkitStorage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "", Justification = "Azure Storage account key must be converted to SecureString for Key Vault secret API.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Names,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string]$KeyVaultName,
        [Parameter(Mandatory = $false)][string]$SubscriptionId,
        [scriptblock]$GetStorageAccount = {
            param($ResourceGroupName, $Name)
            Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewStorageAccount = {
            param($ResourceGroupName, $Name, $Location, $SkuName)
            New-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location -SkuName $SkuName
        },
        [scriptblock]$GetStorageAccountKey = {
            param($ResourceGroupName, $Name)
            Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $Name
        },
        [scriptblock]$GetStorageShare = {
            param($Context, $Name)
            Get-AzStorageShare -Context $Context -Name $Name -ErrorAction SilentlyContinue
        },
        [scriptblock]$NewStorageShare = {
            param($Context, $Name)
            New-AzStorageShare -Context $Context -Name $Name
        }
    )

    $resourceId = Get-ToolkitPredictedResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $Names.StorageResourceGroupName -ProviderPath "Microsoft.Storage/storageAccounts/$($Names.StorageAccountName)"
    $account = & $GetStorageAccount $Names.StorageResourceGroupName $Names.StorageAccountName
    $accountStep = $null
    if ($account) {
        $skuName = if ($account.Sku.Name) { $account.Sku.Name } else { $account.SkuName }
        $drift = Compare-ToolkitResourceProperty -ResourceName "Storage account '$($Names.StorageAccountName)'" -PropertyName "SkuName" -ExpectedValue $Config.storage.skuName -ActualValue $skuName -DriftPolicy "Warn"
        if ($drift.Status -eq "DriftDetected") {
            Write-ToolkitDrift -Message $drift.Message
        }
        $accountStep = Write-ToolkitDeploymentStep -Name "Storage account" -Status "Reused" -Message "'$($Names.StorageAccountName)' already exists." -ResourceId $account.Id -Detail @{ Resource = $account }
    }
    else {
        if ($WhatIfPreference) {
            $accountStep = Write-ToolkitDeploymentStep -Name "Storage account" -Status "WouldCreate" -Message "Would create '$($Names.StorageAccountName)'." -ResourceId $resourceId
            $account = [pscustomobject]@{ Id = $resourceId }
        }
        elseif ($PSCmdlet.ShouldProcess($Names.StorageAccountName, "Create storage account")) {
            $account = & $NewStorageAccount $Names.StorageResourceGroupName $Names.StorageAccountName $Location $Config.storage.skuName
            $accountStep = Write-ToolkitDeploymentStep -Name "Storage account" -Status "Created" -Message "'$($Names.StorageAccountName)' created." -ResourceId $account.Id -Detail @{ Resource = $account }
        }
        else {
            $accountStep = Write-ToolkitDeploymentStep -Name "Storage account" -Status "Skipped" -Message "'$($Names.StorageAccountName)' was not created." -ResourceId $resourceId
            return [pscustomobject]@{ Account = $null; Context = $null; AccountKey = $null; AccountStep = $accountStep; ShareStep = $null }
        }
    }

    if ($WhatIfPreference) {
        $shareStep = Write-ToolkitDeploymentStep -Name "Storage share" -Status "WouldCreate" -Message "Would ensure file share '$($Names.FileShareName)'." -ResourceId "$resourceId/fileServices/default/shares/$($Names.FileShareName)"
        return [pscustomobject]@{ Account = $account; Context = $null; AccountKey = $null; AccountStep = $accountStep; ShareStep = $shareStep }
    }

    $accountKey = (& $GetStorageAccountKey $Names.StorageResourceGroupName $Names.StorageAccountName)[0].Value
    $context = New-AzStorageContext -StorageAccountName $Names.StorageAccountName -StorageAccountKey $accountKey
    $secretValue = ConvertTo-SecureString $accountKey -AsPlainText -Force
    if ($PSCmdlet.ShouldProcess($Config.keyVault.storageKeySecretName, "Store storage account key in Key Vault '$KeyVaultName'")) {
        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $Config.keyVault.storageKeySecretName -SecretValue $secretValue | Out-Null
        Write-ToolkitDeploymentStep -Name "Storage key secret" -Status "Updated" -Message "Storage account key stored as '$($Config.keyVault.storageKeySecretName)'." | Out-Null
    }

    $share = & $GetStorageShare $context $Names.FileShareName
    if ($share) {
        $shareStep = Write-ToolkitDeploymentStep -Name "Storage share" -Status "Reused" -Message "'$($Names.FileShareName)' already exists."
    }
    elseif ($PSCmdlet.ShouldProcess($Names.FileShareName, "Create Azure Files share")) {
        & $NewStorageShare $context $Names.FileShareName | Out-Null
        $shareStep = Write-ToolkitDeploymentStep -Name "Storage share" -Status "Created" -Message "'$($Names.FileShareName)' created."
    }
    else {
        $shareStep = Write-ToolkitDeploymentStep -Name "Storage share" -Status "Skipped" -Message "'$($Names.FileShareName)' was not created."
    }

    return [pscustomobject]@{ Account = $account; Context = $context; AccountKey = $accountKey; AccountStep = $accountStep; ShareStep = $shareStep }
}

function Get-ToolkitGuestInstallScript {
    param([Parameter(Mandatory = $true)][object]$Config)

    $softwareInstalls = Get-ToolkitConfigValue -Config $Config -Path "softwareInstalls"
    $packages = Get-ToolkitConfigValue -Config $softwareInstalls -Path "packages"
    if (-not $packages) {
        return [string](Get-ToolkitConfigValue -Config $softwareInstalls -Path "installScript" -Required)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('$ErrorActionPreference = "Stop"')
    $lines.Add('Set-ExecutionPolicy Bypass -Scope Process -Force')
    $lines.Add('[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12')

    $needsChocolatey = $false
    $needsPowerShellGallery = $false
    foreach ($package in @($packages)) {
        $manager = Get-ToolkitConfigValue -Config $package -Path "manager" -Required
        if ($manager -eq "Chocolatey") {
            $needsChocolatey = $true
        }
        if ($manager -eq "PowerShellGallery") {
            $needsPowerShellGallery = $true
        }
    }

    if ($needsChocolatey) {
        $allowDynamicBootstrap = ConvertTo-BooleanDefault -Value (Get-ToolkitConfigValue -Config $softwareInstalls -Path "allowDynamicBootstrap") -Default $false
        $lines.Add('if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {')
        if ($allowDynamicBootstrap) {
            $bootstrapUrl = Get-ToolkitConfigValue -Config $softwareInstalls -Path "chocolatey.bootstrapUrl"
            if ([string]::IsNullOrWhiteSpace([string]$bootstrapUrl)) {
                $bootstrapUrl = "https://community.chocolatey.org/install.ps1"
            }
            $lines.Add("    `$chocoInstall = Join-Path `$env:TEMP 'install-chocolatey.ps1'")
            $lines.Add("    Invoke-WebRequest -Uri '$bootstrapUrl' -OutFile `$chocoInstall -UseBasicParsing")
            $bootstrapSha256 = Get-ToolkitConfigValue -Config $softwareInstalls -Path "chocolatey.bootstrapSha256"
            if (-not [string]::IsNullOrWhiteSpace([string]$bootstrapSha256)) {
                $lines.Add("    if ((Get-FileHash -Path `$chocoInstall -Algorithm SHA256).Hash -ne '$bootstrapSha256') { throw 'Chocolatey bootstrap SHA-256 mismatch.' }")
            }
            $lines.Add("    & `$chocoInstall")
            $lines.Add("    Remove-Item -Path `$chocoInstall -Force")
            $lines.Add("    `$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')")
        }
        else {
            $lines.Add("    throw 'Chocolatey is required for configured guest packages. Preinstall it in the image or set softwareInstalls.allowDynamicBootstrap to true with a verified bootstrap source.'")
        }
        $lines.Add('}')
    }

    if ($needsPowerShellGallery) {
        $lines.Add("Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force")
        $lines.Add("Set-PSRepository -Name PSGallery -InstallationPolicy Trusted")
    }

    foreach ($package in @($packages)) {
        $manager = Get-ToolkitConfigValue -Config $package -Path "manager" -Required
        $name = Get-ToolkitConfigValue -Config $package -Path "name" -Required
        $version = Get-ToolkitConfigValue -Config $package -Path "version" -Required
        switch ($manager) {
            "Chocolatey" {
                $lines.Add("choco install $name --version $version -y")
            }
            "PowerShellGallery" {
                $lines.Add("Install-Module -Name $name -RequiredVersion $version -Scope AllUsers -Force")
            }
        }
    }

    $installScript = Get-ToolkitConfigValue -Config $softwareInstalls -Path "installScript"
    if (-not [string]::IsNullOrWhiteSpace([string]$installScript)) {
        $lines.Add("# Additional configured guest setup")
        $lines.Add([string]$installScript)
    }

    return ($lines -join [Environment]::NewLine)
}

function Ensure-ToolkitGuestSetup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Names,
        [Parameter(Mandatory = $true)][string]$KeyVaultName,
        [Parameter(Mandatory = $false)][object]$StorageContext,
        [scriptblock]$InvokeVmRunCommand = {
            param($ResourceGroupName, $VMName, $ScriptString, $Parameters)
            if ($Parameters) {
                Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName -CommandId "RunPowerShellScript" -ScriptString $ScriptString -Parameter $Parameters
            }
            else {
                Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName -CommandId "RunPowerShellScript" -ScriptString $ScriptString
            }
        },
        [scriptblock]$UploadStorageFile = {
            param($ShareName, $Source, $Path, $Context)
            Set-AzStorageFileContent -ShareName $ShareName -Source $Source -Path $Path -Context $Context -Force
        }
    )

    foreach ($warning in @(Get-ToolkitGuestSetupWarning -Config $Config)) {
        Write-ToolkitWarning -Message $warning
    }

    if (-not $WhatIfPreference -and -not $StorageContext) {
        return Write-ToolkitDeploymentStep -Name "Guest setup" -Status "Skipped" -Message "Storage context is unavailable, so guest setup and restore-helper upload were skipped."
    }

    if ($WhatIfPreference) {
        return Write-ToolkitDeploymentStep -Name "Guest setup" -Status "WouldRun" -Message "Would run guest setup, mount Azure Files, and upload restore helper."
    }

    if ($PSCmdlet.ShouldProcess($Names.VMName, "Run guest software setup")) {
        Write-ToolkitStep -Message "Installing software on VM '$($Names.VMName)'"
        $installScript = Get-ToolkitGuestInstallScript -Config $Config
        $installResult = & $InvokeVmRunCommand $Names.ResourceGroupName $Names.VMName $installScript $null
        Write-ToolkitDetail -Message (($installResult.Value | Out-String).Trim())
    }

    if ($Config.softwareInstalls.logonScript -and $PSCmdlet.ShouldProcess($Names.VMName, "Register logon setup task")) {
        $logonTaskScript = @'
param($LogonScript, $Username)
$ErrorActionPreference = "Stop"
$scriptPath = "C:\setup-logon.ps1"
$selfCleanup = @"
$LogonScript
Unregister-ScheduledTask -TaskName 'SetupLogonTask' -Confirm:`$false
Remove-Item -Path '$scriptPath' -Force
"@
Set-Content -Path $scriptPath -Value $selfCleanup
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $Username
Register-ScheduledTask -TaskName "SetupLogonTask" -Action $action -Trigger $trigger -RunLevel Highest -Force
'@
        $logonResult = & $InvokeVmRunCommand $Names.ResourceGroupName $Names.VMName $logonTaskScript @{
            LogonScript = $Config.softwareInstalls.logonScript
            Username    = $Config.credentials.username
        }
        Write-ToolkitDetail -Message (($logonResult.Value | Out-String).Trim())
    }

    if ($PSCmdlet.ShouldProcess($Names.VMName, "Mount Azure Files share")) {
        Write-ToolkitStep -Message "Mounting file share '\\$($Names.StorageAccountName).file.core.windows.net\$($Names.FileShareName)' as $($Config.storage.driveLetter):\"
        $mountScript = Get-ToolkitMountScript
        $mountResult = & $InvokeVmRunCommand $Names.ResourceGroupName $Names.VMName $mountScript @{
            KeyVaultName       = $KeyVaultName
            SecretName         = $Config.keyVault.storageKeySecretName
            StorageAccountName = $Names.StorageAccountName
            FileShareName      = $Names.FileShareName
            DriveLetter        = $Config.storage.driveLetter
        }
        Write-ToolkitDetail -Message (($mountResult.Value | Out-String).Trim())
    }

    $restoreScriptContent = Get-ToolkitRestoreScriptContent -DriveLetter $Config.storage.driveLetter -BackupPath $Config.storage.backupPath
    $restoreScriptPath = Join-Path $env:TEMP "restore-databases.ps1"
    Set-Content -Path $restoreScriptPath -Value $restoreScriptContent
    try {
        if ($PSCmdlet.ShouldProcess($Names.FileShareName, "Upload restore-databases.ps1")) {
            & $UploadStorageFile $Names.FileShareName $restoreScriptPath "restore-databases.ps1" $StorageContext | Out-Null
        }
    }
    finally {
        Remove-Item $restoreScriptPath -ErrorAction SilentlyContinue
    }

    return Write-ToolkitDeploymentStep -Name "Guest setup" -Status "Updated" -Message "Guest setup completed and restore helper uploaded."
}

function Invoke-AzureSqlVmToolkitDeployment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "", Justification = "WhatIf placeholder and lab generated credentials are never persisted outside the documented Key Vault flow.")]
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
        [switch]$Plan
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $deployment = Get-ToolkitDeploymentContext -ConfigFile $ConfigFile
    $config = $deployment.Config
    $names = $deployment.ResourceNames
    $location = $config.resourceGroup.location

    if ($SecurityAssessmentAdvice -or $Plan -or $WhatIfPreference) {
        Write-ToolkitSecurityAdvice -Config $config -VmPublicIpEnabled $deployment.VmPublicIpEnabled -GeneratePasswordEnabled $GeneratePassword.IsPresent -ShowPasswordEnabled $ShowPassword.IsPresent
    }

    if ($Plan) {
        Write-ToolkitPlan `
            -Config $config `
            -VmPublicIpEnabled $deployment.VmPublicIpEnabled `
            -ResourceGroupName $names.ResourceGroupName `
            -StorageResourceGroupName $names.StorageResourceGroupName `
            -VnetName $names.VnetName `
            -SubnetName $names.SubnetName `
            -NsgName $names.NsgName `
            -InterfaceName $names.InterfaceName `
            -VMName $names.VMName `
            -BastionName $names.BastionName `
            -KeyVaultName $names.KeyVaultName `
            -StorageAccountName $names.StorageAccountName `
            -FileShareName $names.FileShareName
        return
    }

    $currentContext = Get-ToolkitAzureContext
    Write-ToolkitSuccess -Message "Using subscription: $($currentContext.Subscription.Name)"
    $subscriptionId = $currentContext.Subscription.Id

    Ensure-ToolkitResourceGroup -Name $names.ResourceGroupName -Location $location -Tag $config.resourceGroup.tags -WhatIf:$WhatIfPreference | Out-Null
    Ensure-ToolkitResourceGroup -Name $names.StorageResourceGroupName -Location $location -Tag $config.resourceGroup.tags -WhatIf:$WhatIfPreference | Out-Null

    $keyVaultResult = Ensure-ToolkitKeyVault `
        -Name $names.KeyVaultName `
        -ResourceGroupName $names.StorageResourceGroupName `
        -Location $location `
        -SubscriptionId $subscriptionId `
        -WhatIf:$WhatIfPreference
    $effectiveKeyVaultName = $keyVaultResult.VaultName

    $currentUserId = Get-ToolkitCurrentPrincipalId -Context $currentContext
    Ensure-ToolkitRoleAssignment -ObjectId $currentUserId -RoleDefinitionName "Key Vault Secrets Officer" -Scope $keyVaultResult.Resource.ResourceId -WhatIf:$WhatIfPreference | Out-Null
    if (-not $WhatIfPreference) {
        Write-ToolkitInfo -Message "Waiting 30 seconds for Key Vault RBAC propagation."
        Start-Sleep -Seconds 30
    }

    $passwordResult = Ensure-ToolkitVmAdminPasswordSecret `
        -VaultName $effectiveKeyVaultName `
        -SecretName $config.keyVault.vmAdminPasswordSecretName `
        -PasswordLength ([int]$config.keyVault.passwordLength) `
        -GeneratePassword:$GeneratePassword `
        -WhatIf:$WhatIfPreference

    $vnetResult = Ensure-ToolkitVirtualNetwork -Config $config -Names $names -Location $location -SubscriptionId $subscriptionId -WhatIf:$WhatIfPreference
    if (Test-ToolkitStepSkipped -Step $vnetResult.Step -Message "Stopping deployment because the virtual network step was skipped.") {
        return
    }

    $publicIpId = $null
    if ($deployment.VmPublicIpEnabled) {
        $publicIpStep = Ensure-ToolkitPublicIpAddress `
            -Name $names.PipName `
            -ResourceGroupName $names.ResourceGroupName `
            -Location $location `
            -AllocationMethod $config.network.publicIp.allocationMethod `
            -IdleTimeoutInMinutes $config.network.publicIp.idleTimeoutInMinutes `
            -SubscriptionId $subscriptionId `
            -WhatIf:$WhatIfPreference
        if ($publicIpStep.Detail.Resource) {
            $publicIpId = $publicIpStep.Detail.Resource.Id
        }
        elseif ($publicIpStep.ResourceId) {
            $publicIpId = $publicIpStep.ResourceId
        }
    }

    $nsgStep = Ensure-ToolkitNetworkSecurityGroup -Config $config -Names $names -Location $location -SubscriptionId $subscriptionId -WhatIf:$WhatIfPreference
    if (Test-ToolkitStepSkipped -Step $nsgStep -Message "Stopping deployment because the network security group step was skipped.") {
        return
    }
    $nsgId = if ($nsgStep.Detail.Resource) { $nsgStep.Detail.Resource.Id } else { $nsgStep.ResourceId }

    $nicStep = Ensure-ToolkitNetworkInterface `
        -Names $names `
        -Location $location `
        -SubnetId $vnetResult.SubnetId `
        -NetworkSecurityGroupId $nsgId `
        -PublicIpAddressId $publicIpId `
        -SubscriptionId $subscriptionId `
        -WhatIf:$WhatIfPreference
    if (Test-ToolkitStepSkipped -Step $nicStep -Message "Stopping deployment because the network interface step was skipped.") {
        return
    }
    $nicId = if ($nicStep.Detail.Resource) { $nicStep.Detail.Resource.Id } else { $nicStep.ResourceId }

    $vmStep = Ensure-ToolkitVirtualMachine `
        -Config $config `
        -Names $names `
        -Location $location `
        -NetworkInterfaceId $nicId `
        -AdminPassword $passwordResult.SecretValue `
        -SubscriptionId $subscriptionId `
        -WhatIf:$WhatIfPreference
    if (Test-ToolkitStepSkipped -Step $vmStep -Message "Stopping deployment because the virtual machine step was skipped.") {
        return
    }
    $vm = if ($vmStep.Detail.Resource) { $vmStep.Detail.Resource } else { [pscustomobject]@{ Id = $vmStep.ResourceId; Identity = $null } }

    $identityStep = Ensure-ToolkitVmManagedIdentity -ResourceGroupName $names.ResourceGroupName -VMName $names.VMName -VirtualMachine $vm -WhatIf:$WhatIfPreference
    if (Test-ToolkitStepSkipped -Step $identityStep -Message "Stopping deployment because the VM managed identity step was skipped.") {
        return
    }
    $vmIdentity = $identityStep.Detail.PrincipalId

    Ensure-ToolkitBastion -Config $config -Names $names -Location $location -SubscriptionId $subscriptionId -WhatIf:$WhatIfPreference | Out-Null

    $storageResult = Ensure-ToolkitStorage `
        -Config $config `
        -Names $names `
        -Location $location `
        -KeyVaultName $effectiveKeyVaultName `
        -SubscriptionId $subscriptionId `
        -WhatIf:$WhatIfPreference

    if (-not [string]::IsNullOrWhiteSpace([string]$vmIdentity)) {
        Ensure-ToolkitRoleAssignment -ObjectId $vmIdentity -RoleDefinitionName "Key Vault Secrets User" -Scope $keyVaultResult.Resource.ResourceId -WhatIf:$WhatIfPreference | Out-Null
    }
    else {
        Write-ToolkitWarning -Message "VM identity principal ID was not available; skipping Key Vault Secrets User assignment."
    }

    Ensure-ToolkitGuestSetup -Config $config -Names $names -KeyVaultName $effectiveKeyVaultName -StorageContext $storageResult.Context -WhatIf:$WhatIfPreference | Out-Null

    $stopwatch.Stop()
    Write-ToolkitSuccess -Message "Deployment completed in $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))."
    Write-ToolkitStep -Message "VM Login"
    Write-ToolkitDetail -Message "Username: $($config.credentials.username)"
    if ($ShowPassword) {
        $plainPassword = $passwordResult.PlainTextForDisplay
        if (-not $plainPassword -and -not $WhatIfPreference) {
            $plainPassword = Get-AzKeyVaultSecret -VaultName $effectiveKeyVaultName -Name $config.keyVault.vmAdminPasswordSecretName -AsPlainText
        }
        Write-ToolkitWarning -Message "Password: $plainPassword"
    }
    else {
        Write-ToolkitDetail -Message "Password: stored in Key Vault secret '$($config.keyVault.vmAdminPasswordSecretName)' and not printed."
    }

    if ($effectiveKeyVaultName -ne $names.KeyVaultName) {
        Write-ToolkitWarning -Message "Key Vault name '$($names.KeyVaultName)' was unavailable. Created or planned as '$effectiveKeyVaultName'. Update config.yaml with the new name to reuse it."
    }
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
