Set-StrictMode -Version 3.0

# Internal deployment implementation. Import AzureSqlVmToolkit.Deployment.psm1 instead of this file.

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

