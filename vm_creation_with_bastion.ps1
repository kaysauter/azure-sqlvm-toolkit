[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "", Justification = "The script must bridge Key Vault, Azure Storage key, and VM credential APIs that require SecureString inputs.")]
[CmdletBinding()]
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

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$toolkitModulePath = Join-Path $PSScriptRoot "scripts/AzureSqlVmToolkit.Common.psm1"
Import-Module $toolkitModulePath -Force

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "Missing dependency 'powershell-yaml'. Install it with: Install-Module -Name powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml

$ConfigPath = Resolve-ToolkitConfigPath -Path $ConfigFile
if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
Test-ToolkitConfig -Config $config

$resourceNames = Get-ToolkitResourceNameSet `
    -ResourceGroupName $config.resourceGroup.name `
    -KeyVaultName $config.keyVault.name `
    -StorageAccountName $config.storage.accountName `
    -FileShareName $config.storage.fileShareName `
    -StorageResourceGroupName $config.storage.resourceGroup

$ResourceGroupName = $resourceNames.ResourceGroupName
$Location = $config.resourceGroup.location
$SubnetName = $resourceNames.SubnetName
$VnetName = $resourceNames.VnetName
$PipName = $resourceNames.PipName
$NsgName = $resourceNames.NsgName
$InterfaceName = $resourceNames.InterfaceName
$VMName = $resourceNames.VMName
$BastionSubnetName = $resourceNames.BastionSubnetName
$BastionPipName = $resourceNames.BastionPipName
$BastionName = $resourceNames.BastionName
$KeyVaultName = $resourceNames.KeyVaultName
$StorageAccountName = $resourceNames.StorageAccountName
$FileShareName = $resourceNames.FileShareName
$StorageResourceGroupName = $resourceNames.StorageResourceGroupName
$VmPublicIpEnabled = ConvertTo-BooleanDefault -Value $config.network.publicIp.enabled -Default $false

if ($SecurityAssessmentAdvice -or $Plan) {
    Write-ToolkitSecurityAdvice -Config $config -VmPublicIpEnabled $VmPublicIpEnabled -GeneratePasswordEnabled $GeneratePassword.IsPresent -ShowPasswordEnabled $ShowPassword.IsPresent
}

if ($Plan) {
    Write-ToolkitPlan -Config $config -VmPublicIpEnabled $VmPublicIpEnabled -ResourceGroupName $ResourceGroupName -StorageResourceGroupName $StorageResourceGroupName -VnetName $VnetName -SubnetName $SubnetName -NsgName $NsgName -InterfaceName $InterfaceName -VMName $VMName -BastionName $BastionName -KeyVaultName $KeyVaultName -StorageAccountName $StorageAccountName -FileShareName $FileShareName
    return
}

$currentContext = Get-AzContext
if (-not $currentContext) {
    throw "No Azure context found. Run Connect-AzAccount first."
}
Write-Host "`nUsing subscription: $($currentContext.Subscription.Name)" -ForegroundColor Green

$ResourceGroupParams = @{
    Name     = $ResourceGroupName
    Location = $Location
    Tag      = $config.resourceGroup.tags
}
New-AzResourceGroup @ResourceGroupParams | Out-Null

$storageRg = Get-AzResourceGroup -Name $StorageResourceGroupName -ErrorAction SilentlyContinue
if (-not $storageRg) {
    New-AzResourceGroup -Name $StorageResourceGroupName -Location $Location -Tag $config.resourceGroup.tags | Out-Null
    Write-Host "Storage resource group '$StorageResourceGroupName' created."
}
else {
    Write-Host "Storage resource group '$StorageResourceGroupName' already exists."
}

$OriginalKeyVaultName = $KeyVaultName
$keyVault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
if ($keyVault) {
    if (-not $keyVault.EnableRbacAuthorization) {
        throw "Key Vault '$KeyVaultName' uses legacy access policies. Use an RBAC-enabled vault or a different keyVault.name."
    }
    Write-Host "Key Vault '$KeyVaultName' already exists."
}
else {
    $deleted = Get-AzKeyVault -VaultName $KeyVaultName -Location $Location -InRemovedState -ErrorAction SilentlyContinue
    if ($deleted) {
        $i = 1
        do {
            $KeyVaultName = "$($config.keyVault.name)$i"
            $i++
            $existing = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
            $stillDeleted = Get-AzKeyVault -VaultName $KeyVaultName -Location $Location -InRemovedState -ErrorAction SilentlyContinue
        } while ($existing -or $stillDeleted)
        Write-Host "Original Key Vault name is soft-deleted. Using '$KeyVaultName' instead."
    }

    $keyVault = New-AzKeyVault -Name $KeyVaultName -ResourceGroupName $StorageResourceGroupName -Location $Location -EnableRbacAuthorization
    Write-Host "Key Vault '$KeyVaultName' created with RBAC authorization."
}

$currentUserId = Get-ToolkitCurrentPrincipalId -Context $currentContext
Add-ToolkitRoleAssignment -ObjectId $currentUserId -RoleDefinitionName "Key Vault Secrets Officer" -Scope $keyVault.ResourceId -Confirm:$false
Write-Host "Granted current user Key Vault Secrets Officer on '$KeyVaultName'. Waiting for propagation..."
Start-Sleep -Seconds 30

$VmAdminSecretName = $config.keyVault.vmAdminPasswordSecretName
$existingSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $VmAdminSecretName -ErrorAction SilentlyContinue
$plainPasswordForDisplay = $null

if (-not $existingSecret) {
    if (-not $GeneratePassword) {
        throw "VM admin password secret '$VmAdminSecretName' does not exist in Key Vault '$KeyVaultName'. Pre-create it or rerun with -GeneratePassword for lab/demo use."
    }

    $passwordLength = if ($config.keyVault.passwordLength) { [int]$config.keyVault.passwordLength } else { 24 }
    $plainPasswordForDisplay = Get-ToolkitGeneratedPassword -Length $passwordLength
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "", Justification = "Lab-only generated password must be converted for Key Vault and VM credential APIs.")]
    $SecureVmPassword = ConvertTo-SecureString $plainPasswordForDisplay -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $VmAdminSecretName -SecretValue $SecureVmPassword | Out-Null
    Write-Host "VM admin password generated for lab use and stored in Key Vault as '$VmAdminSecretName'."
}
else {
    $SecureVmPassword = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $VmAdminSecretName).SecretValue
    Write-Host "VM admin password secret already exists in Key Vault."
}

$SubnetConfig = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $config.network.subnet.addressPrefix
$Vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName -ErrorAction SilentlyContinue
if (-not $Vnet) {
    $Vnet = New-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Location $Location -Name $VnetName -AddressPrefix $config.network.vnet.addressPrefix -Subnet $SubnetConfig
    Write-Host "VNet '$VnetName' created."
}
else {
    Write-Host "VNet '$VnetName' already exists."
}

$Pip = $null
if ($VmPublicIpEnabled) {
    $Pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PipName -ErrorAction SilentlyContinue
    if (-not $Pip) {
        $Pip = New-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod $config.network.publicIp.allocationMethod -IdleTimeoutInMinutes $config.network.publicIp.idleTimeoutInMinutes -Name $PipName
        Write-Host "VM public IP '$PipName' created because network.publicIp.enabled is true."
    }
    else {
        Write-Host "VM public IP '$PipName' already exists."
    }
}

$Nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NsgName -ErrorAction SilentlyContinue
if (-not $Nsg) {
    $NsgRules = @()
    foreach ($rule in @($config.securityRules)) {
        if ($null -eq $rule) { continue }
        $NsgRules += New-AzNetworkSecurityRuleConfig `
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

    $NsgParams = @{
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
        Name              = $NsgName
    }
    if ($NsgRules.Count -gt 0) {
        $NsgParams.SecurityRules = $NsgRules
    }
    $Nsg = New-AzNetworkSecurityGroup @NsgParams
    Write-Host "NSG '$NsgName' created."
}
else {
    Write-Host "NSG '$NsgName' already exists."
}

$Interface = Get-AzNetworkInterface -Name $InterfaceName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $Interface) {
    $NicParams = @{
        Name                   = $InterfaceName
        ResourceGroupName      = $ResourceGroupName
        Location               = $Location
        SubnetId               = $Vnet.Subnets[0].Id
        NetworkSecurityGroupId = $Nsg.Id
    }
    if ($Pip) {
        $NicParams.PublicIpAddressId = $Pip.Id
    }
    $Interface = New-AzNetworkInterface @NicParams
    Write-Host "Network interface '$InterfaceName' created."
}
else {
    Write-Host "Network interface '$InterfaceName' already exists."
}

$Cred = New-Object System.Management.Automation.PSCredential ($config.credentials.username, $SecureVmPassword)
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    $VMConfig = New-AzVMConfig -VMName $VMName -VMSize $config.vm.size |
        Set-AzVMOperatingSystem -Windows -ComputerName $VMName -Credential $Cred -ProvisionVMAgent -EnableAutoUpdate |
        Set-AzVMSourceImage -PublisherName $config.vm.image.publisherName -Offer $config.vm.image.offer -Skus $config.vm.image.skus -Version $config.vm.image.version |
        Add-AzVMNetworkInterface -Id $Interface.Id

    New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $VMConfig | Out-Null
    Write-Host "VM '$VMName' created."
}
else {
    Write-Host "VM '$VMName' already exists."
}

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
if (-not $vm.Identity -or -not $vm.Identity.PrincipalId) {
    Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -IdentityType SystemAssigned | Out-Null
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
}
$vmIdentity = $vm.Identity.PrincipalId
Write-Host "Managed identity enabled on VM '$VMName' (PrincipalId: $vmIdentity)"

$vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $ResourceGroupName
if (-not ($vnet.Subnets | Where-Object { $_.Name -eq $BastionSubnetName })) {
    Add-AzVirtualNetworkSubnetConfig -Name $BastionSubnetName -VirtualNetwork $vnet -AddressPrefix $config.bastion.subnetAddressPrefix | Set-AzVirtualNetwork | Out-Null
    Write-Host "Bastion subnet '$BastionSubnetName' added."
}

$BastionPip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $BastionPipName -ErrorAction SilentlyContinue
if (-not $BastionPip) {
    $BastionPip = New-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $BastionPipName -Location $Location -AllocationMethod $config.bastion.publicIp.allocationMethod -IdleTimeoutInMinutes $config.bastion.publicIp.idleTimeoutInMinutes -Sku $config.bastion.publicIp.sku
    Write-Host "Bastion public IP '$BastionPipName' created."
}

$bastion = Get-AzBastion -ResourceGroupName $ResourceGroupName -Name $BastionName -ErrorAction SilentlyContinue
if (-not $bastion) {
    New-AzBastion -ResourceGroupName $ResourceGroupName -Name $BastionName -PublicIpAddressRgName $ResourceGroupName -PublicIpAddressName $BastionPipName -VirtualNetworkRgName $ResourceGroupName -VirtualNetworkName $VnetName -Sku $config.bastion.sku | Out-Null
    Write-Host "Bastion '$BastionName' created."
}
else {
    Write-Host "Bastion '$BastionName' already exists."
}

$storageAccount = Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
if (-not $storageAccount) {
    $storageAccount = New-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -Name $StorageAccountName -Location $Location -SkuName $config.storage.skuName
    Write-Host "Storage account '$StorageAccountName' created."
}
else {
    Write-Host "Storage account '$StorageAccountName' already exists."
}

$StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $StorageResourceGroupName -Name $StorageAccountName)[0].Value
$Context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey

$SecretName = $config.keyVault.storageKeySecretName
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "", Justification = "Azure Storage account key must be converted to SecureString for Key Vault secret API.")]
$SecretValue = ConvertTo-SecureString $StorageAccountKey -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName -SecretValue $SecretValue | Out-Null
Write-Host "Storage account key stored in Key Vault as secret '$SecretName'."

Add-ToolkitRoleAssignment -ObjectId $vmIdentity -RoleDefinitionName "Key Vault Secrets User" -Scope $keyVault.ResourceId -Confirm:$false
Write-Host "VM identity granted Key Vault Secrets User on '$KeyVaultName'."

$fileShare = Get-AzStorageShare -Context $Context -Name $FileShareName -ErrorAction SilentlyContinue
if (-not $fileShare) {
    New-AzStorageShare -Context $Context -Name $FileShareName | Out-Null
    Write-Host "File share '$FileShareName' created."
}
else {
    Write-Host "File share '$FileShareName' already exists."
}

Write-Host "Installing software on VM '$VMName'..."
$installResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName -CommandId "RunPowerShellScript" -ScriptString $config.softwareInstalls.installScript
Write-Host ($installResult.Value | Out-String)

if ($config.softwareInstalls.logonScript) {
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
    $logonResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName -CommandId "RunPowerShellScript" -ScriptString $logonTaskScript -Parameter @{
        LogonScript = $config.softwareInstalls.logonScript
        Username    = $config.credentials.username
    }
    Write-Host ($logonResult.Value | Out-String)
}

Write-Host "Mounting file share '\\$StorageAccountName.file.core.windows.net\$FileShareName' as $($config.storage.driveLetter):\ ..."
$mountScript = Get-ToolkitMountScript
$mountResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName -CommandId "RunPowerShellScript" -ScriptString $mountScript -Parameter @{
    KeyVaultName       = $KeyVaultName
    SecretName         = $SecretName
    StorageAccountName = $StorageAccountName
    FileShareName      = $FileShareName
    DriveLetter        = $config.storage.driveLetter
}
Write-Host ($mountResult.Value | Out-String)

$restoreScriptContent = Get-ToolkitRestoreScriptContent -DriveLetter $config.storage.driveLetter -BackupPath $config.storage.backupPath
$restoreScriptPath = Join-Path $env:TEMP "restore-databases.ps1"
Set-Content -Path $restoreScriptPath -Value $restoreScriptContent
Set-AzStorageFileContent -ShareName $FileShareName -Source $restoreScriptPath -Path "restore-databases.ps1" -Context $Context -Force | Out-Null
Remove-Item $restoreScriptPath
Write-Host "Restore script uploaded to file share as 'restore-databases.ps1'."
Write-Host "After logging into the VM, run: $($config.storage.driveLetter):\restore-databases.ps1" -ForegroundColor Cyan

$stopwatch.Stop()
Write-Host "`nDeployment completed in $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))." -ForegroundColor Green
Write-Host "`nVM Login:" -ForegroundColor Cyan
Write-Host "  Username: $($config.credentials.username)" -ForegroundColor Yellow
if ($ShowPassword) {
    if (-not $plainPasswordForDisplay) {
        $plainPasswordForDisplay = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $VmAdminSecretName -AsPlainText
    }
    Write-Host "  Password: $plainPasswordForDisplay" -ForegroundColor Yellow
}
else {
    Write-Host "  Password: stored in Key Vault secret '$VmAdminSecretName' and not printed." -ForegroundColor Yellow
}

if ($KeyVaultName -ne $OriginalKeyVaultName) {
    Write-Host "`nNote: Key Vault name '$OriginalKeyVaultName' was unavailable (soft-deleted). Created as '$KeyVaultName' instead." -ForegroundColor Yellow
    Write-Host "Update config.yaml with the new name to reuse it on future runs." -ForegroundColor Yellow
}
