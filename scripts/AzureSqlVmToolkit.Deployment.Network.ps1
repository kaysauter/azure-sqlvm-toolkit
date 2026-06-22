Set-StrictMode -Version 3.0

# Internal deployment implementation. Import AzureSqlVmToolkit.Deployment.psm1 instead of this file.

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

