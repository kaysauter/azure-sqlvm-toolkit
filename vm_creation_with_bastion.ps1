#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute, Az.KeyVault, Az.Storage
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "config.yaml"
)

$ErrorActionPreference = 'Stop'

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {

# Load configuration from YAML
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Install-Module -Name powershell-yaml -Force -Scope CurrentUser -MinimumVersion '0.4.7'
}
Import-Module powershell-yaml

if (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigPath = Join-Path $PSScriptRoot $ConfigFile
}
else {
    $ConfigPath = $ConfigFile
}

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

# Validate required configuration values
$requiredPaths = @(
    'resourceGroup.name', 'resourceGroup.location',
    'keyVault.name', 'keyVault.vmAdminPasswordSecretName', 'keyVault.storageKeySecretName',
    'storage.accountName', 'storage.fileShareName', 'storage.resourceGroup', 'storage.driveLetter',
    'network.vnet.addressPrefix', 'network.subnet.addressPrefix',
    'credentials.username',
    'vm.size',
    'bastion.subnetAddressPrefix', 'bastion.sku'
)
foreach ($path in $requiredPaths) {
    $parts = $path -split '\.'
    $value = $config
    foreach ($part in $parts) { $value = $value.$part }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required configuration value missing: $path"
    }
}

# Use the default subscription from the current Azure context
$currentContext = Get-AzContext
if (-not $currentContext) {
    Write-Error "No Azure context found. Run Connect-AzAccount first."
    exit 1
}
Write-Host "`nUsing subscription: $($currentContext.Subscription.Name)" -ForegroundColor Green

# Variables from config
$ResourceGroupName = $config.resourceGroup.name
$Location = $config.resourceGroup.location
$SubnetName = $ResourceGroupName + "subnet"
$VnetName = $ResourceGroupName + "vnet"
$NsgName = $ResourceGroupName + "nsg"
$InterfaceName = $ResourceGroupName + "int"
$VMName = $ResourceGroupName + "VM"
$BastionSubnetName = "AzureBastionSubnet"
$BastionPipName = $ResourceGroupName + "bastionpip"
$BastionName = $ResourceGroupName + "bastion"
$KeyVaultName = $config.keyVault.name
$StorageAccountName = $config.storage.accountName
$FileShareName = $config.storage.fileShareName
$StorageResourceGroupName = $config.storage.resourceGroup

# Resource Group
$existingRg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $existingRg) {
    $ResourceGroupParams = @{
        Name     = $ResourceGroupName
        Location = $Location
        Tag      = $config.resourceGroup.tags
    }
    New-AzResourceGroup @ResourceGroupParams | Out-Null
    Write-Host "Resource group '$ResourceGroupName' created."
} else {
    Write-Host "Resource group '$ResourceGroupName' already exists."
}

# Storage Resource Group (separate from VM to survive VM RG deletion)
$storageRg = Get-AzResourceGroup -Name $StorageResourceGroupName -ErrorAction SilentlyContinue
if (-not $storageRg) {
    New-AzResourceGroup -Name $StorageResourceGroupName -Location $Location -Tag $config.resourceGroup.tags | Out-Null
    Write-Host "Storage resource group '$StorageResourceGroupName' created."
}
else {
    Write-Host "Storage resource group '$StorageResourceGroupName' already exists."
}

# Key Vault
$OriginalKeyVaultName = $KeyVaultName
$keyVault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
if ($keyVault) {
    Write-Host "Key Vault '$KeyVaultName' already exists."
}
else {
    # If a soft-deleted vault with the same name exists, increment the name
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
    New-AzKeyVault -Name $KeyVaultName -ResourceGroupName $StorageResourceGroupName -Location $Location `
        -DisableRbacAuthorization -EnablePurgeProtection
    Write-Host "Key Vault '$KeyVaultName' created."

    # Wait for Key Vault DNS to propagate
    Write-Host "Waiting for Key Vault DNS to propagate..."
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $resolves = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
        if ($resolves) { break }
        Start-Sleep -Seconds 10
    }
}

# Grant current user access to Key Vault secrets
$currentUserId = (Get-AzADUser -SignedIn).Id
Set-AzKeyVaultAccessPolicy -VaultName $KeyVaultName -ObjectId $currentUserId `
    -PermissionsToSecrets Get, Set, List | Out-Null
Write-Host "Granted current user access to Key Vault secrets. Waiting for propagation..."
Start-Sleep -Seconds 30

# Generate and store VM admin password in Key Vault
$VmAdminSecretName = $config.keyVault.vmAdminPasswordSecretName
$existingSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $VmAdminSecretName -ErrorAction SilentlyContinue
if (-not $existingSecret) {
    $passwordLength = if ($config.keyVault.passwordLength) { $config.keyVault.passwordLength } else { 24 }
    $lower = 'abcdefghijklmnopqrstuvwxyz'
    $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $digits = '0123456789'
    $special = '!@#$%^&*()-_=+[]{}|;:,.<>?'
    $allChars = $lower + $upper + $digits + $special

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    # Use rejection sampling to eliminate modulo bias
    $charCount = $allChars.Length
    # Find the largest multiple of $charCount that fits in a byte (0..255)
    $maxUnbiased = [Math]::Floor(256 / $charCount) * $charCount
    $password = [char[]]::new($passwordLength)
    $buf = [byte[]]::new(1)
    for ($i = 0; $i -lt $passwordLength; $i++) {
        do {
            $rng.GetBytes($buf)
        } while ($buf[0] -ge $maxUnbiased)
        $password[$i] = $allChars[$buf[0] % $charCount]
    }
    # Guarantee at least one of each required character type using rejection sampling
    $charSets = @($lower, $upper, $digits, $special)
    $posBuf = [byte[]]::new(1)
    for ($s = 0; $s -lt $charSets.Count; $s++) {
        $set = $charSets[$s]
        # Pick a secure random position
        $maxPos = [Math]::Floor(256 / $passwordLength) * $passwordLength
        do { $rng.GetBytes($posBuf) } while ($posBuf[0] -ge $maxPos)
        $pos = $posBuf[0] % $passwordLength
        # Pick a secure random char from the set
        $maxChar = [Math]::Floor(256 / $set.Length) * $set.Length
        do { $rng.GetBytes($buf) } while ($buf[0] -ge $maxChar)
        $password[$pos] = $set[$buf[0] % $set.Length]
    }
    $rng.Dispose()
    $plainPassword = -join $password
    $SecureVmPassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $VmAdminSecretName -SecretValue $SecureVmPassword | Out-Null
    Write-Host "VM admin password generated and stored in Key Vault as '$VmAdminSecretName'."
}
else {
    $plainPassword = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $VmAdminSecretName -AsPlainText
    $SecureVmPassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    Write-Host "VM admin password already exists in Key Vault."
}

# Networking - VNet
$existingVnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $existingVnet) {
    $SubnetConfig = New-AzVirtualNetworkSubnetConfig -Name $SubnetName `
        -AddressPrefix $config.network.subnet.addressPrefix

    $Vnet = New-AzVirtualNetwork -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -Name $VnetName -AddressPrefix $config.network.vnet.addressPrefix `
        -Subnet $SubnetConfig
    Write-Host "Virtual network '$VnetName' created."
} else {
    $Vnet = $existingVnet
    Write-Host "Virtual network '$VnetName' already exists."
}

# Network Security Group
$existingNsg = Get-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $existingNsg) {
    $NsgRules = @()
    foreach ($rule in $config.securityRules) {
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

    $Nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName `
        -Location $Location -Name $NsgName -SecurityRules $NsgRules
    Write-Host "Network security group '$NsgName' created."
} else {
    $Nsg = $existingNsg
    Write-Host "Network security group '$NsgName' already exists."
}

# Network Interface
$existingInterface = Get-AzNetworkInterface -Name $InterfaceName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $existingInterface) {
    $Interface = New-AzNetworkInterface -Name $InterfaceName `
        -ResourceGroupName $ResourceGroupName -Location $Location `
        -SubnetId $VNet.Subnets[0].Id `
        -NetworkSecurityGroupId $Nsg.Id
    Write-Host "Network interface '$InterfaceName' created."
} else {
    $Interface = $existingInterface
    Write-Host "Network interface '$InterfaceName' already exists."
}

# VM Credentials
$Cred = New-Object System.Management.Automation.PSCredential `
($config.credentials.username, $SecureVmPassword)

# Virtual Machine
$existingVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
if (-not $existingVm) {
    $VMConfig = New-AzVMConfig -VMName $VMName -VMSize $config.vm.size |
    Set-AzVMOperatingSystem -Windows -ComputerName $VMName `
        -Credential $Cred -ProvisionVMAgent -EnableAutoUpdate |
    Set-AzVMSourceImage `
        -PublisherName $config.vm.image.publisherName `
        -Offer $config.vm.image.offer `
        -Skus $config.vm.image.skus `
        -Version $config.vm.image.version |
    Add-AzVMNetworkInterface -Id $Interface.Id

    New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $VMConfig | Out-Null
    Write-Host "Virtual machine '$VMName' created."
} else {
    Write-Host "Virtual machine '$VMName' already exists."
}

# Enable system-assigned managed identity on the VM
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -IdentityType SystemAssigned | Out-Null
$vmIdentity = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName).Identity.PrincipalId
Write-Host "Managed identity enabled on VM '$VMName' (PrincipalId: $vmIdentity)"

# Azure Bastion
$vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $ResourceGroupName
Add-AzVirtualNetworkSubnetConfig -Name $BastionSubnetName `
    -VirtualNetwork $vnet -AddressPrefix $config.bastion.subnetAddressPrefix | Set-AzVirtualNetwork | Out-Null

$BastionPip = New-AzPublicIpAddress -ResourceGroupName $ResourceGroupName `
    -Name $BastionPipName -Location $Location `
    -AllocationMethod $config.bastion.publicIp.allocationMethod `
    -IdleTimeoutInMinutes $config.bastion.publicIp.idleTimeoutInMinutes `
    -Sku $config.bastion.publicIp.sku

$existingBastion = Get-AzBastion -ResourceGroupName $ResourceGroupName -Name $BastionName -ErrorAction SilentlyContinue
if (-not $existingBastion) {
    New-AzBastion -ResourceGroupName $ResourceGroupName -Name $BastionName `
        -PublicIpAddressRgName $ResourceGroupName -PublicIpAddressName $BastionPipName `
        -VirtualNetworkRgName $ResourceGroupName -VirtualNetworkName $VnetName `
        -Sku $config.bastion.sku | Out-Null
    Write-Host "Bastion '$BastionName' created."
} else {
    Write-Host "Bastion '$BastionName' already exists."
}

# Storage Account & File Share
$storageAccount = Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName `
    -Name $StorageAccountName -ErrorAction SilentlyContinue
if (-not $storageAccount) {
    New-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -Name $StorageAccountName `
        -Location $Location -SkuName $config.storage.skuName | Out-Null
    Write-Host "Storage account '$StorageAccountName' created."
}
else {
    Write-Host "Storage account '$StorageAccountName' already exists."
}

$StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $StorageResourceGroupName `
        -Name $StorageAccountName)[0].Value
$Context = New-AzStorageContext -StorageAccountName $StorageAccountName `
    -StorageAccountKey $StorageAccountKey

# Store storage key in Key Vault
$SecretName = $config.keyVault.storageKeySecretName
$SecretValue = ConvertTo-SecureString $StorageAccountKey -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName -SecretValue $SecretValue | Out-Null
Write-Host "Storage account key stored in Key Vault as secret '$SecretName'."

# Grant VM managed identity access to Key Vault secrets
Set-AzKeyVaultAccessPolicy -VaultName $KeyVaultName -ObjectId $vmIdentity `
    -PermissionsToSecrets Get | Out-Null
Write-Host "VM identity granted 'Get' access to Key Vault secrets."

$fileShare = Get-AzStorageShare -Context $Context -Name $FileShareName `
    -ErrorAction SilentlyContinue
if (-not $fileShare) {
    New-AzStorageShare -Context $Context -Name $FileShareName | Out-Null
    Write-Host "File share '$FileShareName' created."
}
else {
    Write-Host "File share '$FileShareName' already exists."
}

# VM Extensions
Write-Host "Installing software on VM '$VMName'..."
$installResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName `
    -CommandId 'RunPowerShellScript' -ScriptString $config.softwareInstalls.installScript
Write-Host ($installResult.Value | Out-String)

# Register logon script (runs once at first user logon for user-context installs)
if ($config.softwareInstalls.logonScript) {
    $logonTaskScript = @'
param($LogonScript, $Username)
New-Item -Path 'C:\ProgramData\AzureSetup' -ItemType Directory -Force | Out-Null
$scriptPath = "C:\ProgramData\AzureSetup\setup-logon.ps1"
$selfCleanup = @"
$LogonScript
Unregister-ScheduledTask -TaskName 'SetupLogonTask' -Confirm:`$false
Remove-Item -Path '$scriptPath' -Force
"@
Set-Content -Path $scriptPath -Value $selfCleanup
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File $scriptPath"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $Username
Register-ScheduledTask -TaskName "SetupLogonTask" -Action $action -Trigger $trigger -RunLevel Highest
'@
    $logonResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName `
        -CommandId 'RunPowerShellScript' -ScriptString $logonTaskScript `
        -Parameter @{
        LogonScript = $config.softwareInstalls.logonScript
        Username    = $config.credentials.username
    }
    Write-Host ($logonResult.Value | Out-String)
}

# Mount Azure File Share (VM retrieves storage key from Key Vault via managed identity)
Write-Host "Mounting file share '\\$StorageAccountName.file.core.windows.net\$FileShareName' as $($config.storage.driveLetter):\ ..."
$mountScript = @'
param($KeyVaultName, $SecretName, $StorageAccountName, $FileShareName, $DriveLetter)
$mountCode = @"
`$tokenResponse = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https://vault.azure.net' -Headers @{Metadata="true"}
`$kvToken = `$tokenResponse.access_token
`$secretResponse = Invoke-RestMethod -Uri "https://$KeyVaultName.vault.azure.net/secrets/$SecretName`?api-version=7.4" -Headers @{Authorization="Bearer `$kvToken"}
`$storageKey = `$secretResponse.value
`$secPassword = ConvertTo-SecureString `$storageKey -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential ("localhost\$StorageAccountName", `$secPassword)
`$existing = Get-SmbGlobalMapping -LocalPath "${DriveLetter}:" -ErrorAction SilentlyContinue
if (`$existing) { Remove-SmbGlobalMapping -LocalPath "${DriveLetter}:" -Force }
New-SmbGlobalMapping -RemotePath "\\$StorageAccountName.file.core.windows.net\$FileShareName" -Credential `$cred -LocalPath "${DriveLetter}:" -Persistent `$true
"@

# Run the mount now
$mountBlock = [ScriptBlock]::Create($mountCode)
& $mountBlock

# Register as a startup scheduled task so it survives reboots
New-Item -Path 'C:\ProgramData\AzureSetup' -ItemType Directory -Force | Out-Null
$scriptPath = "C:\ProgramData\AzureSetup\mount-fileshare.ps1"
Set-Content -Path $scriptPath -Value $mountCode
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File $scriptPath"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "MountAzureFileShare" -Action $action -Trigger $trigger -Principal $principal -Force
'@
$mountResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName `
    -CommandId 'RunPowerShellScript' -ScriptString $mountScript `
    -Parameter @{
    KeyVaultName       = $KeyVaultName
    SecretName         = $SecretName
    StorageAccountName = $StorageAccountName
    FileShareName      = $FileShareName
    DriveLetter        = $config.storage.driveLetter
}
Write-Host ($mountResult.Value | Out-String)

# Upload restore script to file share
$restoreScriptContent = @"
Import-Module dbatools
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value `$true
`$backupFiles = Get-ChildItem -Path "$($config.storage.driveLetter):$($config.storage.backupPath)" -Filter "*.bak" -ErrorAction SilentlyContinue
if (-not `$backupFiles) {
    Write-Host "No .bak files found." -ForegroundColor Yellow
    return
}
foreach (`$bak in `$backupFiles) {
    Write-Host "Restoring `$(`$bak.BaseName)..." -ForegroundColor Cyan
    try {
        Restore-DbaDatabase -SqlInstance "localhost" -Path `$bak.FullName -WithReplace
        Write-Host "`$(`$bak.BaseName) restored successfully." -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to restore `$(`$bak.BaseName): `$_"
    }
}
Write-Host "`nAll restores completed." -ForegroundColor Green
"@
$restoreScriptPath = Join-Path $env:TEMP "restore-databases.ps1"
Set-Content -Path $restoreScriptPath -Value $restoreScriptContent
Set-AzStorageFileContent -ShareName $FileShareName -Source $restoreScriptPath `
    -Path "restore-databases.ps1" -Context $Context -Force | Out-Null
Remove-Item $restoreScriptPath
Write-Host "Restore script uploaded to file share as 'restore-databases.ps1'."
Write-Host "After logging into the VM, run: $($config.storage.driveLetter):\restore-databases.ps1" -ForegroundColor Cyan

$stopwatch.Stop()
Write-Host "`nDeployment completed in $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))." -ForegroundColor Green
Write-Host "`nVM Login Credentials:" -ForegroundColor Cyan
Write-Host "  Username: $($config.credentials.username)" -ForegroundColor Yellow
Write-Host "  Password: stored in Key Vault '$KeyVaultName' as secret '$VmAdminSecretName'" -ForegroundColor Yellow

if ($KeyVaultName -ne $OriginalKeyVaultName) {
    Write-Host "`nNote: Key Vault name '$OriginalKeyVaultName' was unavailable (soft-deleted). Created as '$KeyVaultName' instead." -ForegroundColor Yellow
    Write-Host "Update config.yaml with the new name to reuse it on future runs." -ForegroundColor Yellow
}

}
catch {
    Write-Host "`nDeployment failed with error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host "`nPlease review and manually clean up any partially created resources in resource group '$ResourceGroupName'." -ForegroundColor Yellow
    exit 1
}
finally {
    # Clear sensitive variables from memory
    if ($null -ne $plainPassword) { $plainPassword = $null }
    if ($null -ne $StorageAccountKey) { $StorageAccountKey = $null }
    if ($null -ne $SecureVmPassword) { $SecureVmPassword = $null }
    if ($null -ne $Cred) { $Cred = $null }
}
