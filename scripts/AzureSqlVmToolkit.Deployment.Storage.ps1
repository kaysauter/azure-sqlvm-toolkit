Set-StrictMode -Version 3.0

# Internal deployment implementation. Import AzureSqlVmToolkit.Deployment.psm1 instead of this file.

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

