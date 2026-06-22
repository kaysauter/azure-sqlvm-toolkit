Set-StrictMode -Version 3.0

# Internal deployment implementation. Import AzureSqlVmToolkit.Deployment.psm1 instead of this file.

function Invoke-AzureSqlVmToolkitDeployment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "", Justification = "WhatIf placeholder and lab generated credentials are never persisted outside the documented Key Vault flow.")]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSShouldProcess", "", Justification = "This orchestration function delegates ShouldProcess decisions to the internal Ensure-* reconciliation functions.")]
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

    $resourceGroupStep = Ensure-ToolkitResourceGroup -Name $names.ResourceGroupName -Location $location -Tag $config.resourceGroup.tags -WhatIf:$WhatIfPreference
    if (Test-ToolkitStepSkipped -Step $resourceGroupStep -Message "Stopping deployment because the workload resource group step was skipped.") {
        return
    }

    $storageResourceGroupStep = Ensure-ToolkitResourceGroup -Name $names.StorageResourceGroupName -Location $location -Tag $config.resourceGroup.tags -WhatIf:$WhatIfPreference
    if (Test-ToolkitStepSkipped -Step $storageResourceGroupStep -Message "Stopping deployment because the storage resource group step was skipped.") {
        return
    }

    $keyVaultResult = Ensure-ToolkitKeyVault `
        -Name $names.KeyVaultName `
        -ResourceGroupName $names.StorageResourceGroupName `
        -Location $location `
        -SubscriptionId $subscriptionId `
        -WhatIf:$WhatIfPreference
    if (Test-ToolkitStepSkipped -Step $keyVaultResult -Message "Stopping deployment because the Key Vault step was skipped.") {
        return
    }
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
        if (Test-ToolkitStepSkipped -Step $publicIpStep -Message "Stopping deployment because the requested VM public IP step was skipped.") {
            return
        }
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

    $bastionStep = Ensure-ToolkitBastion -Config $config -Names $names -Location $location -SubscriptionId $subscriptionId -WhatIf:$WhatIfPreference
    if (Test-ToolkitStepSkipped -Step $bastionStep -Message "Bastion setup was skipped; continuing with storage and guest setup.") {
        Write-ToolkitDetail -Message "Deployment will continue without configured Bastion access."
    }

    $storageResult = Ensure-ToolkitStorage `
        -Config $config `
        -Names $names `
        -Location $location `
        -KeyVaultName $effectiveKeyVaultName `
        -SubscriptionId $subscriptionId `
        -WhatIf:$WhatIfPreference

    $runGuestSetup = $false
    if (Test-ToolkitStepSkipped -Step $storageResult.AccountStep -Message "Storage account setup was skipped; guest setup will be skipped.") {
        Write-ToolkitDeploymentStep -Name "Guest setup" -Status "Skipped" -Message "Storage account was not available, so guest setup and restore-helper upload were skipped." | Out-Null
    }
    elseif (Test-ToolkitStepSkipped -Step $storageResult.ShareStep -Message "Storage share setup was skipped; guest setup will be skipped.") {
        Write-ToolkitDeploymentStep -Name "Guest setup" -Status "Skipped" -Message "Storage share was not available, so guest setup and restore-helper upload were skipped." | Out-Null
    }
    else {
        $runGuestSetup = $true
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$vmIdentity)) {
        Ensure-ToolkitRoleAssignment -ObjectId $vmIdentity -RoleDefinitionName "Key Vault Secrets User" -Scope $keyVaultResult.Resource.ResourceId -WhatIf:$WhatIfPreference | Out-Null
    }
    else {
        Write-ToolkitWarning -Message "VM identity principal ID was not available; skipping Key Vault Secrets User assignment."
    }

    if ($runGuestSetup) {
        Ensure-ToolkitGuestSetup -Config $config -Names $names -KeyVaultName $effectiveKeyVaultName -StorageContext $storageResult.Context -WhatIf:$WhatIfPreference | Out-Null
    }

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
