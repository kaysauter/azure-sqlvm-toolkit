Set-StrictMode -Version 3.0

# Internal deployment implementation. Import AzureSqlVmToolkit.Deployment.psm1 instead of this file.

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

