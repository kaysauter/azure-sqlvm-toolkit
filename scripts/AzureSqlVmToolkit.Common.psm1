Set-StrictMode -Version 3.0

function Resolve-ToolkitConfigPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path (Split-Path -Parent $PSScriptRoot) $Path)
}

function Get-ToolkitConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Required
    )

    $current = $Config
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $current) {
            if ($Required) {
                throw "Missing required config value: $Path"
            }
            return $null
        }

        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($part)) {
                if ($Required) {
                    throw "Missing required config value: $Path"
                }
                return $null
            }
            $current = $current[$part]
            continue
        }

        $property = $current.PSObject.Properties[$part]
        if (-not $property) {
            if ($Required) {
                throw "Missing required config value: $Path"
            }
            return $null
        }
        $current = $property.Value
    }

    if ($Required -and ($null -eq $current -or [string]::IsNullOrWhiteSpace([string]$current))) {
        throw "Missing required config value: $Path"
    }

    return $current
}

function Test-RequiredValue {
    param(
        [object]$Value,
        [string]$Name
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Missing required config value: $Name"
    }
}

function Test-NamePattern {
    param(
        [string]$Value,
        [string]$Name,
        [string]$Pattern,
        [int]$MinLength = 1,
        [int]$MaxLength = 80
    )

    Test-RequiredValue -Value $Value -Name $Name

    if ($Value.Length -lt $MinLength -or $Value.Length -gt $MaxLength -or $Value -notmatch $Pattern) {
        throw "Invalid $Name '$Value'."
    }
}

function Test-AllowedValue {
    param(
        [object]$Value,
        [string]$Name,
        [string[]]$AllowedValues
    )

    Test-RequiredValue -Value $Value -Name $Name

    if ([string]$Value -notin $AllowedValues) {
        throw "Invalid $Name '$Value'. Allowed values: $($AllowedValues -join ', ')."
    }
}

function Test-IntegerRange {
    param(
        [object]$Value,
        [string]$Name,
        [int]$Minimum,
        [int]$Maximum
    )

    Test-RequiredValue -Value $Value -Name $Name

    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or $number -lt $Minimum -or $number -gt $Maximum) {
        throw "Invalid $Name '$Value'. Use an integer from $Minimum to $Maximum."
    }
}

function Test-BooleanConfigValue {
    param(
        [object]$Value,
        [string]$Name
    )

    Test-RequiredValue -Value $Value -Name $Name

    $parsed = $false
    if (-not [bool]::TryParse([string]$Value, [ref]$parsed)) {
        throw "$Name must be true or false."
    }
}

function Test-AddressPrefix {
    param(
        [string]$Value,
        [string]$Name
    )

    Test-RequiredValue -Value $Value -Name $Name

    if ($Value -notmatch '^([^/]+)/(\d{1,2})$') {
        throw "Invalid $Name '$Value'. Use an IPv4 CIDR prefix such as 192.168.1.0/24."
    }

    $address = $Matches[1]
    $prefixLength = [int]$Matches[2]
    $parsedAddress = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($address, [ref]$parsedAddress) -or
        $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $prefixLength -lt 0 -or
        $prefixLength -gt 32) {
        throw "Invalid $Name '$Value'. Use an IPv4 CIDR prefix such as 192.168.1.0/24."
    }
}

function Test-BackupPath {
    param([string]$Value)

    Test-RequiredValue -Value $Value -Name "storage.backupPath"

    if ($Value -match '(^[A-Za-z]:)|(^\\\\)|\.\.|["''`;&|<>*?]') {
        throw "Invalid storage.backupPath '$Value'. Use '\', '/folder', or a simple relative folder under the mounted share."
    }
}

function Get-ToolkitRuleValueList {
    param(
        [object]$Rule,
        [string]$SingleName,
        [string]$PluralName
    )

    $values = @()
    $single = Get-ToolkitConfigValue -Config $Rule -Path $SingleName
    $plural = Get-ToolkitConfigValue -Config $Rule -Path $PluralName

    if ($null -ne $single) {
        $values += [string]$single
    }

    if ($null -ne $plural) {
        foreach ($value in @($plural)) {
            $values += [string]$value
        }
    }

    return $values
}

function Test-BroadInboundRule {
    param([object]$Rule)

    $direction = Get-ToolkitConfigValue -Config $Rule -Path "direction" -Required
    $access = Get-ToolkitConfigValue -Config $Rule -Path "access" -Required
    $name = Get-ToolkitConfigValue -Config $Rule -Path "name" -Required
    $sources = Get-ToolkitRuleValueList -Rule $Rule -SingleName "sourceAddressPrefix" -PluralName "sourceAddressPrefixes"
    $ports = Get-ToolkitRuleValueList -Rule $Rule -SingleName "destinationPortRange" -PluralName "destinationPortRanges"
    $broadSources = @("*", "0.0.0.0/0", "::/0", "Internet")
    $sensitivePorts = @("3389", "1433")

    foreach ($source in $sources) {
        foreach ($port in $ports) {
            if ($direction -eq "Inbound" -and
                $access -eq "Allow" -and
                $broadSources -contains $source -and
                $sensitivePorts -contains $port) {
                throw "Unsafe inbound rule '$name' exposes port $port from '$source'. Restrict the source prefix or remove the rule."
            }
        }
    }
}

function Test-ToolkitConfig {
    param([object]$Config)

    $requiredPaths = @(
        "resourceGroup.name",
        "resourceGroup.location",
        "network.vnet.addressPrefix",
        "network.subnet.addressPrefix",
        "network.publicIp.enabled",
        "network.publicIp.allocationMethod",
        "network.publicIp.idleTimeoutInMinutes",
        "keyVault.name",
        "keyVault.storageKeySecretName",
        "keyVault.vmAdminPasswordSecretName",
        "keyVault.passwordLength",
        "credentials.username",
        "vm.size",
        "vm.image.publisherName",
        "vm.image.offer",
        "vm.image.skus",
        "vm.image.version",
        "bastion.subnetAddressPrefix",
        "bastion.sku",
        "bastion.publicIp.allocationMethod",
        "bastion.publicIp.idleTimeoutInMinutes",
        "bastion.publicIp.sku",
        "storage.resourceGroup",
        "storage.accountName",
        "storage.skuName",
        "storage.fileShareName",
        "storage.driveLetter",
        "storage.backupPath",
        "softwareInstalls.installScript"
    )

    foreach ($path in $requiredPaths) {
        Get-ToolkitConfigValue -Config $Config -Path $path -Required | Out-Null
    }

    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "resourceGroup.name" -Required) -Name "resourceGroup.name" -Pattern '^[A-Za-z0-9._()\-]{1,90}$' -MaxLength 90
    Test-AddressPrefix -Value (Get-ToolkitConfigValue -Config $Config -Path "network.vnet.addressPrefix" -Required) -Name "network.vnet.addressPrefix"
    Test-AddressPrefix -Value (Get-ToolkitConfigValue -Config $Config -Path "network.subnet.addressPrefix" -Required) -Name "network.subnet.addressPrefix"
    Test-BooleanConfigValue -Value (Get-ToolkitConfigValue -Config $Config -Path "network.publicIp.enabled" -Required) -Name "network.publicIp.enabled"
    Test-AllowedValue -Value (Get-ToolkitConfigValue -Config $Config -Path "network.publicIp.allocationMethod" -Required) -Name "network.publicIp.allocationMethod" -AllowedValues @("Static", "Dynamic")
    Test-IntegerRange -Value (Get-ToolkitConfigValue -Config $Config -Path "network.publicIp.idleTimeoutInMinutes" -Required) -Name "network.publicIp.idleTimeoutInMinutes" -Minimum 4 -Maximum 30
    Test-AddressPrefix -Value (Get-ToolkitConfigValue -Config $Config -Path "bastion.subnetAddressPrefix" -Required) -Name "bastion.subnetAddressPrefix"
    Test-AllowedValue -Value (Get-ToolkitConfigValue -Config $Config -Path "bastion.sku" -Required) -Name "bastion.sku" -AllowedValues @("Basic", "Standard", "Premium")
    Test-AllowedValue -Value (Get-ToolkitConfigValue -Config $Config -Path "bastion.publicIp.allocationMethod" -Required) -Name "bastion.publicIp.allocationMethod" -AllowedValues @("Static")
    Test-IntegerRange -Value (Get-ToolkitConfigValue -Config $Config -Path "bastion.publicIp.idleTimeoutInMinutes" -Required) -Name "bastion.publicIp.idleTimeoutInMinutes" -Minimum 4 -Maximum 30
    Test-AllowedValue -Value (Get-ToolkitConfigValue -Config $Config -Path "bastion.publicIp.sku" -Required) -Name "bastion.publicIp.sku" -AllowedValues @("Standard")
    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "keyVault.name" -Required) -Name "keyVault.name" -Pattern '^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$' -MinLength 3 -MaxLength 24
    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "keyVault.storageKeySecretName" -Required) -Name "keyVault.storageKeySecretName" -Pattern '^[A-Za-z0-9-]{1,127}$' -MaxLength 127
    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "keyVault.vmAdminPasswordSecretName" -Required) -Name "keyVault.vmAdminPasswordSecretName" -Pattern '^[A-Za-z0-9-]{1,127}$' -MaxLength 127
    Test-IntegerRange -Value (Get-ToolkitConfigValue -Config $Config -Path "keyVault.passwordLength" -Required) -Name "keyVault.passwordLength" -Minimum 12 -Maximum 128
    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "storage.resourceGroup" -Required) -Name "storage.resourceGroup" -Pattern '^[A-Za-z0-9._()\-]{1,90}$' -MaxLength 90
    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "storage.accountName" -Required) -Name "storage.accountName" -Pattern '^[a-z0-9]{3,24}$' -MinLength 3 -MaxLength 24
    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "storage.fileShareName" -Required) -Name "storage.fileShareName" -Pattern '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$' -MinLength 3 -MaxLength 63
    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "storage.skuName" -Required) -Name "storage.skuName" -Pattern '^[A-Za-z0-9_]+$' -MaxLength 64
    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "credentials.username" -Required) -Name "credentials.username" -Pattern '^[A-Za-z][A-Za-z0-9._-]{0,19}$' -MaxLength 20
    Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path "storage.driveLetter" -Required) -Name "storage.driveLetter" -Pattern '^[A-Z]$' -MinLength 1 -MaxLength 1
    Test-BackupPath -Value (Get-ToolkitConfigValue -Config $Config -Path "storage.backupPath" -Required)

    foreach ($field in @("vm.size", "vm.image.publisherName", "vm.image.offer", "vm.image.skus", "vm.image.version")) {
        Test-NamePattern -Value (Get-ToolkitConfigValue -Config $Config -Path $field -Required) -Name $field -Pattern '^[A-Za-z0-9._-]+$' -MaxLength 128
    }

    foreach ($rule in @(Get-ToolkitConfigValue -Config $Config -Path "securityRules")) {
        if ($null -eq $rule) { continue }
        Test-NamePattern -Value (Get-ToolkitConfigValue -Config $rule -Path "name" -Required) -Name "securityRules[].name" -Pattern '^[A-Za-z0-9._-]{1,80}$'
        Test-AllowedValue -Value (Get-ToolkitConfigValue -Config $rule -Path "protocol" -Required) -Name "securityRules[].protocol" -AllowedValues @("Tcp", "Udp", "Icmp", "*")
        Test-AllowedValue -Value (Get-ToolkitConfigValue -Config $rule -Path "direction" -Required) -Name "securityRules[].direction" -AllowedValues @("Inbound", "Outbound")
        Test-IntegerRange -Value (Get-ToolkitConfigValue -Config $rule -Path "priority" -Required) -Name "securityRules[].priority" -Minimum 100 -Maximum 4096
        Test-AllowedValue -Value (Get-ToolkitConfigValue -Config $rule -Path "access" -Required) -Name "securityRules[].access" -AllowedValues @("Allow", "Deny")
        Test-RequiredValue -Value (Get-ToolkitConfigValue -Config $rule -Path "sourceAddressPrefix" -Required) -Name "securityRules[].sourceAddressPrefix"
        Test-RequiredValue -Value (Get-ToolkitConfigValue -Config $rule -Path "sourcePortRange" -Required) -Name "securityRules[].sourcePortRange"
        Test-RequiredValue -Value (Get-ToolkitConfigValue -Config $rule -Path "destinationAddressPrefix" -Required) -Name "securityRules[].destinationAddressPrefix"
        Test-RequiredValue -Value (Get-ToolkitConfigValue -Config $rule -Path "destinationPortRange" -Required) -Name "securityRules[].destinationPortRange"
        Test-BroadInboundRule -Rule $rule
    }
}

function ConvertTo-BooleanDefault {
    param(
        [object]$Value,
        [bool]$Default
    )

    if ($null -eq $Value) {
        return $Default
    }

    return [System.Convert]::ToBoolean($Value)
}

function Get-ToolkitGeneratedPassword {
    param([int]$Length)

    if ($Length -lt 12) {
        throw "Password length must be at least 12."
    }

    $lower = "abcdefghijklmnopqrstuvwxyz"
    $upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    $digits = "0123456789"
    $special = "!@#$%^&*()-_=+[]{}|;:,.<>?"
    $groups = @($lower, $upper, $digits, $special)
    $allChars = $lower + $upper + $digits + $special

    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($group in $groups) {
        $chars.Add($group[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($group.Length)])
    }

    while ($chars.Count -lt $Length) {
        $chars.Add($allChars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($allChars.Length)])
    }

    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]
        $chars[$i] = $chars[$j]
        $chars[$j] = $tmp
    }

    return -join $chars
}

function Get-ToolkitResourceNameSet {
    param(
        [string]$ResourceGroupName,
        [string]$KeyVaultName,
        [string]$StorageAccountName,
        [string]$FileShareName,
        [string]$StorageResourceGroupName
    )

    Test-RequiredValue -Value $ResourceGroupName -Name "resourceGroup.name"

    return [pscustomobject]@{
        ResourceGroupName        = $ResourceGroupName
        Location                 = $null
        SubnetName               = "$ResourceGroupName-subnet"
        VnetName                 = "$ResourceGroupName-vnet"
        PipName                  = "$ResourceGroupName-pip"
        NsgName                  = "$ResourceGroupName-nsg"
        InterfaceName            = "$ResourceGroupName-nic"
        VMName                   = "$ResourceGroupName-vm"
        BastionSubnetName        = "AzureBastionSubnet"
        BastionPipName           = "$ResourceGroupName-bastion-pip"
        BastionName              = "$ResourceGroupName-bastion"
        KeyVaultName             = $KeyVaultName
        StorageAccountName       = $StorageAccountName
        FileShareName            = $FileShareName
        StorageResourceGroupName = $StorageResourceGroupName
    }
}

function ConvertTo-ToolkitDeploymentStepResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Created", "Reused", "Updated", "Skipped", "DriftDetected", "Failed")]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$ResourceId,

        [Parameter(Mandatory = $false)]
        [hashtable]$Detail = @{}
    )

    return [pscustomobject]@{
        PSTypeName = "AzureSqlVmToolkit.DeploymentStepResult"
        Name       = $Name
        Status     = $Status
        Message    = $Message
        ResourceId = $ResourceId
        Detail     = $Detail
    }
}

function Compare-ToolkitResourceProperty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceName,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [Parameter(Mandatory = $false)]
        [object]$ExpectedValue,

        [Parameter(Mandatory = $false)]
        [object]$ActualValue,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Fail", "Update", "Warn", "Ignore")]
        [string]$DriftPolicy = "Fail"
    )

    if ([string]$ExpectedValue -eq [string]$ActualValue) {
        return ConvertTo-ToolkitDeploymentStepResult `
            -Name $ResourceName `
            -Status "Reused" `
            -Message "$PropertyName matches expected value." `
            -Detail @{
                Property = $PropertyName
                Expected = $ExpectedValue
                Actual   = $ActualValue
                Policy   = $DriftPolicy
            }
    }

    $message = "$ResourceName has drift on $PropertyName. Expected '$ExpectedValue' but found '$ActualValue'."
    $status = if ($DriftPolicy -eq "Update") { "Updated" } elseif ($DriftPolicy -eq "Ignore") { "Skipped" } else { "DriftDetected" }

    return ConvertTo-ToolkitDeploymentStepResult `
        -Name $ResourceName `
        -Status $status `
        -Message $message `
        -Detail @{
            Property = $PropertyName
            Expected = $ExpectedValue
            Actual   = $ActualValue
            Policy   = $DriftPolicy
        }
}

function Write-ToolkitSecurityAdvice {
    param(
        [object]$Config,
        [bool]$VmPublicIpEnabled,
        [bool]$GeneratePasswordEnabled,
        [bool]$ShowPasswordEnabled
    )

    Write-Host "`nSecurity assessment advice:" -ForegroundColor Cyan
    if ($VmPublicIpEnabled) {
        Write-Warning "network.publicIp.enabled is true. Prefer Azure Bastion-only access for lab VMs."
    }
    else {
        Write-Host "  VM public IP: disabled" -ForegroundColor Green
    }

    if ($GeneratePasswordEnabled) {
        Write-Warning "-GeneratePassword creates a lab password in PowerShell. Use an approved secret workflow for production or sensitive environments."
    }
    else {
        Write-Host "  VM password generation: existing Key Vault secret required" -ForegroundColor Green
    }

    if ($ShowPasswordEnabled) {
        Write-Warning "-ShowPassword prints the VM password to the console. Use only in controlled demos."
    }
    else {
        Write-Host "  VM password output: disabled" -ForegroundColor Green
    }

    foreach ($rule in @(Get-ToolkitConfigValue -Config $Config -Path "securityRules")) {
        if ($null -eq $rule) { continue }
        Write-Host "  NSG rule: $(Get-ToolkitConfigValue -Config $rule -Path 'name') $(Get-ToolkitConfigValue -Config $rule -Path 'direction') $(Get-ToolkitConfigValue -Config $rule -Path 'access') $(Get-ToolkitConfigValue -Config $rule -Path 'destinationPortRange') from $(Get-ToolkitConfigValue -Config $rule -Path 'sourceAddressPrefix')"
    }
}

function Write-ToolkitPlan {
    param(
        [object]$Config,
        [bool]$VmPublicIpEnabled,
        [string]$ResourceGroupName,
        [string]$StorageResourceGroupName,
        [string]$VnetName,
        [string]$SubnetName,
        [string]$NsgName,
        [string]$InterfaceName,
        [string]$VMName,
        [string]$BastionName,
        [string]$KeyVaultName,
        [string]$StorageAccountName,
        [string]$FileShareName
    )

    Write-Host "`nDeployment plan:" -ForegroundColor Cyan
    Write-Host "  Location: $(Get-ToolkitConfigValue -Config $Config -Path 'resourceGroup.location')"
    Write-Host "  Resource group: $ResourceGroupName"
    Write-Host "  Storage resource group: $StorageResourceGroupName"
    Write-Host "  VNet/subnet: $VnetName / $SubnetName"
    Write-Host "  NSG/NIC/VM: $NsgName / $InterfaceName / $VMName"
    Write-Host "  VM public IP: $VmPublicIpEnabled"
    Write-Host "  Bastion: $BastionName"
    Write-Host "  Key Vault: $KeyVaultName"
    Write-Host "  Storage account/share: $StorageAccountName / $FileShareName"
    Write-Host "  Restore helper: restore-databases.ps1 for .bak files on $(Get-ToolkitConfigValue -Config $Config -Path 'storage.driveLetter'):$(Get-ToolkitConfigValue -Config $Config -Path 'storage.backupPath')"
}

function Add-ToolkitRoleAssignment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectId,

        [Parameter(Mandatory = $true)]
        [string]$RoleDefinitionName,

        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [scriptblock]$GetRoleAssignment = {
            param($ObjectId, $RoleDefinitionName, $Scope)
            Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope -ErrorAction SilentlyContinue
        },

        [scriptblock]$NewRoleAssignment = {
            param($ObjectId, $RoleDefinitionName, $Scope)
            New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope
        }
    )

    $existing = & $GetRoleAssignment $ObjectId $RoleDefinitionName $Scope
    if ($existing) {
        return
    }

    if ($PSCmdlet.ShouldProcess($Scope, "Assign $RoleDefinitionName to $ObjectId")) {
        & $NewRoleAssignment $ObjectId $RoleDefinitionName $Scope | Out-Null
    }
}

function Get-ToolkitCurrentPrincipalId {
    param(
        [object]$Context,

        [scriptblock]$GetSignedInUser = {
            Get-AzADUser -SignedIn
        },

        [scriptblock]$GetServicePrincipal = {
            param($ApplicationId)
            Get-AzADServicePrincipal -ApplicationId $ApplicationId
        }
    )

    if (-not $Context) {
        throw "No Azure context found. Run Connect-AzAccount first."
    }

    $accountType = [string]$Context.Account.Type
    if ($accountType -eq "User") {
        $user = & $GetSignedInUser
        if (-not $user -or -not $user.Id) {
            throw "Unable to resolve the signed-in user's object ID."
        }
        return $user.Id
    }

    if ($accountType -eq "ServicePrincipal") {
        $principal = & $GetServicePrincipal $Context.Account.Id
        if (-not $principal -or -not $principal.Id) {
            throw "Unable to resolve service principal object ID for application ID '$($Context.Account.Id)'."
        }
        return $principal.Id
    }

    throw "Unsupported Azure account type '$accountType'. Use a user or service principal context."
}

function Get-ToolkitMountScript {
    return @'
param($KeyVaultName, $SecretName, $StorageAccountName, $FileShareName, $DriveLetter)
$ErrorActionPreference = "Stop"
$scriptPath = "C:\mount-fileshare.ps1"
$mountCode = @"
param(
    [Parameter(Mandatory = `$true)][string]`$KeyVaultName,
    [Parameter(Mandatory = `$true)][string]`$SecretName,
    [Parameter(Mandatory = `$true)][string]`$StorageAccountName,
    [Parameter(Mandatory = `$true)][string]`$FileShareName,
    [Parameter(Mandatory = `$true)][ValidatePattern('^[A-Z]$')][string]`$DriveLetter
)

`$ErrorActionPreference = "Stop"
`$tokenResponse = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https://vault.azure.net' -Headers @{ Metadata = "true" }
`$kvToken = `$tokenResponse.access_token
`$secretResponse = Invoke-RestMethod -Uri "https://`$KeyVaultName.vault.azure.net/secrets/`$SecretName`?api-version=7.4" -Headers @{ Authorization = "Bearer `$kvToken" }
`$storageKey = `$secretResponse.value
`$secPassword = ConvertTo-SecureString `$storageKey -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential ("localhost\`$StorageAccountName", `$secPassword)
`$localPath = "`${DriveLetter}:"
`$existing = Get-SmbGlobalMapping -LocalPath `$localPath -ErrorAction SilentlyContinue
if (`$existing) {
    Remove-SmbGlobalMapping -LocalPath `$localPath -Force
}
New-SmbGlobalMapping -RemotePath "\\`$StorageAccountName.file.core.windows.net\`$FileShareName" -Credential `$cred -LocalPath `$localPath -Persistent `$true
"@

Set-Content -Path $scriptPath -Value $mountCode
& $scriptPath -KeyVaultName $KeyVaultName -SecretName $SecretName -StorageAccountName $StorageAccountName -FileShareName $FileShareName -DriveLetter $DriveLetter

$argument = "-ExecutionPolicy Bypass -File `"$scriptPath`" -KeyVaultName `"$KeyVaultName`" -SecretName `"$SecretName`" -StorageAccountName `"$StorageAccountName`" -FileShareName `"$FileShareName`" -DriveLetter `"$DriveLetter`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "MountAzureFileShare" -Action $action -Trigger $trigger -Principal $principal -Force
'@
}

function Get-ToolkitRestoreScriptContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveLetter,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath
    )

    Test-NamePattern -Value $DriveLetter -Name "storage.driveLetter" -Pattern '^[A-Z]$' -MinLength 1 -MaxLength 1
    Test-BackupPath -Value $BackupPath

    return @"
Import-Module dbatools
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value `$true
`$backupFiles = Get-ChildItem -Path "$DriveLetter`:$BackupPath" -Filter "*.bak" -ErrorAction SilentlyContinue
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
}

Export-ModuleMember -Function @(
    "Resolve-ToolkitConfigPath",
    "Get-ToolkitConfigValue",
    "Test-ToolkitConfig",
    "ConvertTo-BooleanDefault",
    "Get-ToolkitGeneratedPassword",
    "Get-ToolkitResourceNameSet",
    "ConvertTo-ToolkitDeploymentStepResult",
    "Compare-ToolkitResourceProperty",
    "Write-ToolkitSecurityAdvice",
    "Write-ToolkitPlan",
    "Add-ToolkitRoleAssignment",
    "Get-ToolkitCurrentPrincipalId",
    "Get-ToolkitMountScript",
    "Get-ToolkitRestoreScriptContent"
)
