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

    $allowDynamicBootstrap = Get-ToolkitConfigValue -Config $Config -Path "softwareInstalls.allowDynamicBootstrap"
    if ($null -ne $allowDynamicBootstrap) {
        Test-BooleanConfigValue -Value $allowDynamicBootstrap -Name "softwareInstalls.allowDynamicBootstrap"
    }

    $bootstrapSha256 = Get-ToolkitConfigValue -Config $Config -Path "softwareInstalls.chocolatey.bootstrapSha256"
    if ($null -ne $bootstrapSha256 -and [string]$bootstrapSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "softwareInstalls.chocolatey.bootstrapSha256 must be a SHA-256 hex digest."
    }

    foreach ($package in @(Get-ToolkitConfigValue -Config $Config -Path "softwareInstalls.packages")) {
        if ($null -eq $package) { continue }
        Test-AllowedValue -Value (Get-ToolkitConfigValue -Config $package -Path "manager" -Required) -Name "softwareInstalls.packages[].manager" -AllowedValues @("Chocolatey", "PowerShellGallery")
        $manager = Get-ToolkitConfigValue -Config $package -Path "manager" -Required
        Test-NamePattern -Value (Get-ToolkitConfigValue -Config $package -Path "name" -Required) -Name "softwareInstalls.packages[].name" -Pattern '^[A-Za-z0-9._-]{1,128}$' -MaxLength 128
        Test-NamePattern -Value (Get-ToolkitConfigValue -Config $package -Path "version" -Required) -Name "softwareInstalls.packages[].version" -Pattern '^[A-Za-z0-9._+-]{1,64}$' -MaxLength 64
        $sha256 = Get-ToolkitConfigValue -Config $package -Path "sha256"
        if ($null -ne $sha256 -and [string]$sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "softwareInstalls.packages[].sha256 must be a SHA-256 hex digest."
        }
        if ($null -ne $sha256 -and [string]$manager -eq "PowerShellGallery") {
            throw "softwareInstalls.packages[].sha256 is only supported for Chocolatey packages."
        }
    }

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
        [ValidateSet("Created", "Reused", "Updated", "Skipped", "DriftDetected", "Failed", "WouldCreate", "WouldUpdate", "WouldRun")]
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

function Protect-ToolkitDiagnosticText {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $null
    }

    $result = [string]$Text
    if (-not [string]::IsNullOrWhiteSpace($HOME)) {
        $result = $result.Replace($HOME, "~")
    }

    $redactions = @(
        @{
            Pattern     = '(?is)-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----.*?-----END (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'
            Replacement = '[REDACTED PRIVATE KEY]'
        },
        @{
            Pattern     = '(?i)("(?:Authorization|Proxy-Authorization|x-ms-authorization-auxiliary|Ocp-Apim-Subscription-Key|x-functions-key|x-api-key|api-key|x-auth-token|x-zumo-auth)"\s*:\s*")(?:(?:\\.)|[^"\\])*(")'
            Replacement = '$1[REDACTED]$2'
        },
        @{
            Pattern     = '(?i)(''(?:Authorization|Proxy-Authorization|x-ms-authorization-auxiliary|Ocp-Apim-Subscription-Key|x-functions-key|x-api-key|api-key|x-auth-token|x-zumo-auth)''\s*:\s*'')(?:(?:\\.)|[^''\\])*('')'
            Replacement = '$1[REDACTED]$2'
        },
        @{
            Pattern     = '(?im)((?<!["''])\b(?:Authorization|Proxy-Authorization|x-ms-authorization-auxiliary|Ocp-Apim-Subscription-Key|x-functions-key|x-api-key|api-key|x-auth-token|x-zumo-auth)\b\s*[:=]\s*)[^\r\n]+'
            Replacement = '$1[REDACTED]'
        },
        @{
            Pattern     = '(?i)([?&](?:sig|token|code|key|secret|password|client_secret|access_token|refresh_token)=)[^&#\s]+'
            Replacement = '$1[REDACTED]'
        },
        @{
            Pattern     = '(?i)(\b(?:Password|Passwd|Pwd|Secret|SecretValue|Secret_Value|AccountKey|Account_Key|SharedAccessKey|Shared_Access_Key|SecretAccessKey|Secret_Access_Key|ClientSecret|Client_Secret|ApiKey|Api_Key|AccessToken|Access_Token|RefreshToken|Refresh_Token|Credential|(?:[A-Z][A-Z0-9]*[_-])+(?:PASSWORD|PASSWD|PWD|SECRET|SECRET[_-]?VALUE|TOKEN|API[_-]?KEY|ACCOUNT[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIAL))\s*=\s*)(?:"[^"]*"|''[^'']*''|[^;\s''"]+)'
            Replacement = '$1[REDACTED]'
        },
        @{
            Pattern     = '(?i)(["'']?(?:password|passwd|pwd|secret|secret[_-]?value|client[_-]?secret|api[_-]?key|access[_-]?token|refresh[_-]?token|account[_-]?key|sharedaccesskey|secretaccesskey|private[_-]?key|credential|(?:[A-Z][A-Z0-9]*[_-])+(?:PASSWORD|PASSWD|PWD|SECRET|SECRET[_-]?VALUE|TOKEN|API[_-]?KEY|ACCOUNT[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIAL))["'']?\s*:\s*)(?:"[^"]*"|''[^'']*''|[^,;\s}\]]+)'
            Replacement = '$1[REDACTED]'
        },
        @{
            Pattern     = '(?i)(-{1,2}(?:Password|Secret|SecretValue|ClientSecret|ApiKey|AccessToken|RefreshToken|AccountKey|StorageKey|Credential)\s+)(?:"[^"]*"|''[^'']*''|\S+)'
            Replacement = '$1[REDACTED]'
        },
        @{
            Pattern     = '(?i)([a-z][a-z0-9+.-]*://[^:/@\s]+:)[^@\s/]+(@)'
            Replacement = '$1[REDACTED]$2'
        },
        @{
            Pattern     = '(?i)\b(?:gh[pousr]_[A-Za-z0-9]{20,255}|github_pat_[A-Za-z0-9_]{20,255}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{30,}|npm_[A-Za-z0-9]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})\b'
            Replacement = '[REDACTED TOKEN]'
        }
    )

    foreach ($redaction in $redactions) {
        $result = [regex]::Replace($result, $redaction.Pattern, $redaction.Replacement)
    }

    $highEntropyEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param([System.Text.RegularExpressions.Match]$Match)

        $value = $Match.Value
        if (
            -not [regex]::IsMatch($value, '[a-z]') -or
            -not [regex]::IsMatch($value, '[A-Z]') -or
            -not [regex]::IsMatch($value, '[0-9]') -or
            -not [regex]::IsMatch($value, '[+=!@#$%^&*~]')
        ) {
            return $value
        }

        $frequencies = @{}
        foreach ($character in $value.ToCharArray()) {
            $key = [string]$character
            $frequencies[$key] = 1 + [int]$frequencies[$key]
        }

        $entropy = 0.0
        foreach ($count in $frequencies.Values) {
            $probability = [double]$count / $value.Length
            $entropy -= $probability * [Math]::Log($probability, 2)
        }

        if ($entropy -ge 4.0) {
            return '[REDACTED HIGH-ENTROPY VALUE]'
        }

        return $value
    }
    $result = [regex]::Replace(
        $result,
        '(?<![A-Za-z0-9])[A-Za-z0-9+_=!@#$%^&*.~\-]{24,}(?![A-Za-z0-9])',
        $highEntropyEvaluator
    )

    return $result
}

function Resolve-ToolkitErrorLogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    try {
        $candidatePath = $Path
        $homePrefix = "~$([System.IO.Path]::DirectorySeparatorChar)"
        if ($candidatePath -eq '~') {
            $candidatePath = $HOME
        }
        elseif ($candidatePath.StartsWith($homePrefix, [System.StringComparison]::Ordinal)) {
            $candidatePath = [System.IO.Path]::Combine($HOME, $candidatePath.Substring($homePrefix.Length))
        }

        if ([System.IO.Path]::IsPathRooted($candidatePath)) {
            $resolvedPath = [System.IO.Path]::GetFullPath($candidatePath)
        }
        else {
            $currentLocation = Get-Location
            if ($currentLocation.Provider.Name -ne 'FileSystem') {
                throw "The current PowerShell location is not a file-system location."
            }
            $resolvedPath = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($currentLocation.ProviderPath, $candidatePath)
            )
        }
    }
    catch {
        throw "Error log path '$Path' is not a valid file-system path: $($_.Exception.Message)"
    }

    if ([System.IO.Directory]::Exists($resolvedPath)) {
        throw "Error log path '$Path' points to a directory. Specify a file path."
    }

    $parentPath = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        throw "Error log path '$Path' does not have a valid parent directory."
    }

    return $resolvedPath
}

function Resolve-ToolkitErrorLogTargetPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathComparer = if ($IsWindows) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparer]::Ordinal
    }
    $visitedPaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    $visitedPaths.Add($fullPath) | Out-Null
    $readLinkPath = $null
    if (-not $IsWindows) {
        $readLinkPath = @('/usr/bin/readlink', '/bin/readlink') |
            Where-Object { [System.IO.File]::Exists($_) } |
            Select-Object -First 1
        if (-not $readLinkPath) {
            $readLinkCommand = Get-Command -Name 'readlink' -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($readLinkCommand) {
                $readLinkPath = $readLinkCommand.Source
            }
        }
        if (-not $readLinkPath) {
            throw "Unable to resolve the error log path because the readlink utility is unavailable."
        }
    }

    for ($linkDepth = 0; $linkDepth -lt 64; $linkDepth++) {
        $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
        $relativePath = $fullPath.Substring($rootPath.Length)
        $pathSeparators = @([System.IO.Path]::DirectorySeparatorChar)
        if ([System.IO.Path]::AltDirectorySeparatorChar -ne [System.IO.Path]::DirectorySeparatorChar) {
            $pathSeparators += [System.IO.Path]::AltDirectorySeparatorChar
        }
        $segments = @($relativePath.Split(
            [char[]]$pathSeparators,
            [System.StringSplitOptions]::RemoveEmptyEntries
        ))
        $currentPath = $rootPath
        $linkResolved = $false

        for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
            $candidatePath = [System.IO.Path]::Combine($currentPath, $segments[$segmentIndex])
            $targetValue = $null
            $itemFullName = $candidatePath
            if ($IsWindows) {
                $item = Get-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
                if (-not $item) {
                    $currentPath = $candidatePath
                    continue
                }

                $itemFullName = $item.FullName
                $linkTypeProperty = $item.PSObject.Properties['LinkType']
                if (-not $linkTypeProperty -or [string]::IsNullOrWhiteSpace([string]$linkTypeProperty.Value)) {
                    $currentPath = $itemFullName
                    continue
                }

                $targetProperty = $item.PSObject.Properties['Target']
                if ($targetProperty -and $null -ne $targetProperty.Value) {
                    $targetValue = [string]@($targetProperty.Value)[0]
                }
            }
            else {
                $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = $readLinkPath
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $startInfo.ArgumentList.Add($candidatePath)
                $process = [System.Diagnostics.Process]::new()
                $process.StartInfo = $startInfo
                try {
                    if (-not $process.Start()) {
                        throw "Unable to start readlink while preparing the error log."
                    }
                    $linkOutput = $process.StandardOutput.ReadToEnd()
                    $null = $process.StandardError.ReadToEnd()
                    $process.WaitForExit()
                    if ($process.ExitCode -ne 0) {
                        $currentPath = $candidatePath
                        continue
                    }

                    if ($linkOutput.EndsWith("`n", [System.StringComparison]::Ordinal)) {
                        $linkOutput = $linkOutput.Substring(0, $linkOutput.Length - 1)
                    }
                    $targetValue = $linkOutput
                }
                finally {
                    $process.Dispose()
                }
            }
            if ([string]::IsNullOrWhiteSpace($targetValue)) {
                throw "Unable to resolve symbolic link '$candidatePath' while preparing the error log."
            }

            $targetPath = if ([System.IO.Path]::IsPathRooted($targetValue)) {
                $targetValue
            }
            else {
                [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($itemFullName), $targetValue)
            }
            for ($remainingIndex = $segmentIndex + 1; $remainingIndex -lt $segments.Count; $remainingIndex++) {
                $targetPath = [System.IO.Path]::Combine($targetPath, $segments[$remainingIndex])
            }

            $fullPath = [System.IO.Path]::GetFullPath($targetPath)
            if (-not $visitedPaths.Add($fullPath)) {
                throw "A symbolic-link cycle was detected while preparing error log path '$Path'."
            }
            $linkResolved = $true
            break
        }

        if (-not $linkResolved) {
            return [System.IO.Path]::GetFullPath($currentPath)
        }
    }

    throw "Error log path '$Path' contains too many symbolic-link levels."
}

function Get-ToolkitErrorLogMutexName {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $lockIdentity = if ($IsWindows) { $Path.ToUpperInvariant() } else { $Path }
    $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($lockIdentity)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $pathHash = -join ($sha256.ComputeHash($pathBytes) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha256.Dispose()
    }

    return "AzureSqlVmToolkit.ErrorLog.$pathHash"
}

function Set-ToolkitErrorLogFilePermission {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "The caller explicitly opted into the diagnostic file, which must be restricted before sensitive metadata is written.")]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($IsWindows) {
        $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetOwner($owner)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @(
            $owner,
            [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18"),
            [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
        )) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return
    }

    $chmodPath = Get-Command -Name "chmod" -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Path
    if ([string]::IsNullOrWhiteSpace($chmodPath)) {
        throw "Unable to restrict error log permissions because chmod is unavailable."
    }

    & $chmodPath "600" $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to restrict error log permissions for '$Path'."
    }
}

function ConvertTo-ToolkitErrorLogRecord {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Deployment", "Plan", "WhatIf")]
        [string]$Mode,

        [Parameter(Mandatory = $false)]
        [hashtable]$DiagnosticContext = @{},

        [Parameter(Mandatory = $false)]
        [string]$ToolkitVersion
    )

    $rawErrorDetails = if ($ErrorRecord.ErrorDetails) { $ErrorRecord.ErrorDetails.Message } else { $null }
    $exceptionMessage = Protect-ToolkitDiagnosticText -Text $ErrorRecord.Exception.Message
    $errorDetails = Protect-ToolkitDiagnosticText -Text $rawErrorDetails
    $correlationSource = "$($ErrorRecord.Exception.Message) $rawErrorDetails"
    $correlationMatch = [regex]::Match(
        $correlationSource,
        '(?i)\b(?:(?:x-ms-)?(?:correlation|tracking|request)(?:-request)?)[\s_-]*id\s*[:=]\s*["'']?(?<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
    )
    $correlationId = if ($correlationMatch.Success) { $correlationMatch.Groups['id'].Value } else { $null }

    $sourceFile = $null
    $sourceLine = $null
    if ($ErrorRecord.InvocationInfo) {
        if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.InvocationInfo.ScriptName)) {
            $sourceFile = Split-Path -Leaf $ErrorRecord.InvocationInfo.ScriptName
        }
        if ($ErrorRecord.InvocationInfo.ScriptLineNumber -gt 0) {
            $sourceLine = $ErrorRecord.InvocationInfo.ScriptLineNumber
        }
    }

    return [ordered]@{
        schemaVersion      = 1
        timestampUtc       = [DateTime]::UtcNow.ToString('o')
        runId              = $RunId
        toolkitVersion     = $ToolkitVersion
        command            = 'New-AzureSqlVmToolkitDeployment'
        mode               = $Mode
        phase              = Protect-ToolkitDiagnosticText -Text ([string]$DiagnosticContext['Phase'])
        resource           = [ordered]@{
            type = Protect-ToolkitDiagnosticText -Text ([string]$DiagnosticContext['ResourceType'])
            name = Protect-ToolkitDiagnosticText -Text ([string]$DiagnosticContext['ResourceName'])
        }
        error              = [ordered]@{
            exceptionType   = $ErrorRecord.Exception.GetType().FullName
            message         = $exceptionMessage
            details         = $errorDetails
            errorId         = Protect-ToolkitDiagnosticText -Text $ErrorRecord.FullyQualifiedErrorId
            category        = [string]$ErrorRecord.CategoryInfo.Category
            target          = Protect-ToolkitDiagnosticText -Text ([string]$ErrorRecord.CategoryInfo.TargetName)
            scriptStackTrace = Protect-ToolkitDiagnosticText -Text $ErrorRecord.ScriptStackTrace
        }
        source             = [ordered]@{
            file = Protect-ToolkitDiagnosticText -Text $sourceFile
            line = $sourceLine
        }
        azureCorrelationId = $correlationId
        runtime            = [ordered]@{
            powershellVersion = $PSVersionTable.PSVersion.ToString()
            edition           = $PSVersionTable.PSEdition
        }
    }
}

function Write-ToolkitErrorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Deployment", "Plan", "WhatIf")]
        [string]$Mode,

        [Parameter(Mandatory = $false)]
        [hashtable]$DiagnosticContext = @{},

        [Parameter(Mandatory = $false)]
        [string]$ToolkitVersion
    )

    $resolvedPath = Resolve-ToolkitErrorLogPath -Path $Path
    $record = ConvertTo-ToolkitErrorLogRecord `
        -ErrorRecord $ErrorRecord `
        -RunId $RunId `
        -Mode $Mode `
        -DiagnosticContext $DiagnosticContext `
        -ToolkitVersion $ToolkitVersion
    $jsonLine = ($record | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($jsonLine)

    $targetPath = Resolve-ToolkitErrorLogTargetPath -Path $resolvedPath
    $parentPath = [System.IO.Path]::GetDirectoryName($targetPath)
    if (-not [System.IO.Directory]::Exists($parentPath)) {
        [System.IO.Directory]::CreateDirectory($parentPath) | Out-Null
    }
    if (-not [System.IO.Directory]::Exists($parentPath)) {
        throw "The error log parent path '$parentPath' is not a directory."
    }
    if ([System.IO.Directory]::Exists($targetPath)) {
        throw "Error log path '$targetPath' points to a directory. Specify a file path."
    }

    $mutexName = Get-ToolkitErrorLogMutexName -Path $targetPath
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    $stream = $null
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }

        if (-not $lockTaken) {
            throw "Timed out waiting to write the error log '$targetPath'."
        }

        for ($openAttempt = 1; $openAttempt -le 20; $openAttempt++) {
            try {
                $stream = [System.IO.FileStream]::new(
                    $targetPath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::Read
                )
                break
            }
            catch [System.IO.IOException] {
                if ($openAttempt -eq 20) {
                    throw
                }
                Start-Sleep -Milliseconds (25 * $openAttempt)
            }
        }

        Set-ToolkitErrorLogFilePermission -Path $targetPath
        $stream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        return [pscustomobject]$record
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
        if ($lockTaken) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Write-ToolkitMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "", Justification = "The toolkit is an interactive deployment command and uses color to distinguish message intent.")]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Info", "Step", "Success", "Warning", "Error", "Drift", "Detail", "Plan", "WhatIf")]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $colors = @{
        Info    = "Cyan"
        Step    = "Blue"
        Success = "Green"
        Warning = "Yellow"
        Error   = "Red"
        Drift   = "Magenta"
        Detail  = "DarkGray"
        Plan    = "DarkCyan"
        WhatIf  = "DarkMagenta"
    }

    $prefixes = @{
        Info    = "[info]"
        Step    = "[step]"
        Success = "[ok]"
        Warning = "[warn]"
        Error   = "[error]"
        Drift   = "[drift]"
        Detail  = "  -"
        Plan    = "[plan]"
        WhatIf  = "[whatif]"
    }

    Write-Host "$($prefixes[$Kind]) $Message" -ForegroundColor $colors[$Kind]
}

function Write-ToolkitInfo {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-ToolkitMessage -Kind "Info" -Message $Message
}

function Write-ToolkitStep {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-ToolkitMessage -Kind "Step" -Message $Message
}

function Write-ToolkitSuccess {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-ToolkitMessage -Kind "Success" -Message $Message
}

function Write-ToolkitWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-ToolkitMessage -Kind "Warning" -Message $Message
}

function Write-ToolkitError {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-ToolkitMessage -Kind "Error" -Message $Message
}

function Write-ToolkitDrift {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-ToolkitMessage -Kind "Drift" -Message $Message
}

function Write-ToolkitDetail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-ToolkitMessage -Kind "Detail" -Message $Message
}

function Write-ToolkitWhatIf {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-ToolkitMessage -Kind "WhatIf" -Message $Message
}

function Write-ToolkitDeploymentStepResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    $message = if ([string]::IsNullOrWhiteSpace($Result.Message)) {
        "$($Result.Name): $($Result.Status)"
    }
    else {
        "$($Result.Name): $($Result.Message)"
    }

    switch ($Result.Status) {
        "Created" { Write-ToolkitSuccess -Message $message }
        "Reused" { Write-ToolkitInfo -Message $message }
        "Updated" { Write-ToolkitSuccess -Message $message }
        "Skipped" { Write-ToolkitDetail -Message $message }
        "DriftDetected" { Write-ToolkitDrift -Message $message }
        "Failed" { Write-ToolkitError -Message $message }
        "WouldCreate" { Write-ToolkitWhatIf -Message $message }
        "WouldUpdate" { Write-ToolkitWhatIf -Message $message }
        "WouldRun" { Write-ToolkitWhatIf -Message $message }
        default { Write-ToolkitInfo -Message $message }
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

function Assert-ToolkitNoBlockingDrift {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    if ($Result.Status -eq "DriftDetected" -and $Result.Detail.Policy -eq "Fail") {
        throw $Result.Message
    }
}

function Get-ToolkitGuestSetupWarning {
    param([object]$Config)

    $warnings = @()
    $softwareInstalls = Get-ToolkitConfigValue -Config $Config -Path "softwareInstalls"
    $packages = Get-ToolkitConfigValue -Config $softwareInstalls -Path "packages"
    $allowDynamicBootstrap = ConvertTo-BooleanDefault -Value (Get-ToolkitConfigValue -Config $softwareInstalls -Path "allowDynamicBootstrap") -Default $false

    if ($allowDynamicBootstrap) {
        $warnings += "softwareInstalls.allowDynamicBootstrap is true. The guest can download bootstrap tooling at deployment time."
    }

    if ($packages) {
        foreach ($package in @($packages)) {
            $name = Get-ToolkitConfigValue -Config $package -Path "name"
            $version = Get-ToolkitConfigValue -Config $package -Path "version"
            $checksum = Get-ToolkitConfigValue -Config $package -Path "sha256"
            if ([string]::IsNullOrWhiteSpace([string]$version)) {
                $warnings += "Guest package '$name' does not declare a pinned version."
            }
            if ([string]::IsNullOrWhiteSpace([string]$checksum)) {
                $warnings += "Guest package '$name' does not declare a SHA-256 checksum or source verification value."
            }
        }
    }
    else {
        $warnings += "softwareInstalls.packages is not configured. The toolkit will run the legacy installScript and cannot verify every downloaded tool."
    }

    return $warnings
}

function Write-ToolkitSecurityAdvice {
    param(
        [object]$Config,
        [bool]$VmPublicIpEnabled,
        [bool]$GeneratePasswordEnabled,
        [bool]$ShowPasswordEnabled
    )

    Write-ToolkitStep -Message "Security assessment advice"
    if ($VmPublicIpEnabled) {
        Write-ToolkitWarning -Message "network.publicIp.enabled is true. Prefer Azure Bastion-only access for lab VMs."
    }
    else {
        Write-ToolkitSuccess -Message "VM public IP: disabled"
    }

    if ($GeneratePasswordEnabled) {
        Write-ToolkitWarning -Message "-GeneratePassword creates a lab password in PowerShell. Use an approved secret workflow for production or sensitive environments."
    }
    else {
        Write-ToolkitSuccess -Message "VM password generation: existing Key Vault secret required"
    }

    if ($ShowPasswordEnabled) {
        Write-ToolkitWarning -Message "-ShowPassword prints the VM password to the console. Use only in controlled demos."
    }
    else {
        Write-ToolkitSuccess -Message "VM password output: disabled"
    }

    foreach ($warning in @(Get-ToolkitGuestSetupWarning -Config $Config)) {
        Write-ToolkitWarning -Message $warning
    }

    foreach ($rule in @(Get-ToolkitConfigValue -Config $Config -Path "securityRules")) {
        if ($null -eq $rule) { continue }
        Write-ToolkitDetail -Message "NSG rule: $(Get-ToolkitConfigValue -Config $rule -Path 'name') $(Get-ToolkitConfigValue -Config $rule -Path 'direction') $(Get-ToolkitConfigValue -Config $rule -Path 'access') $(Get-ToolkitConfigValue -Config $rule -Path 'destinationPortRange') from $(Get-ToolkitConfigValue -Config $rule -Path 'sourceAddressPrefix')"
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

    Write-ToolkitMessage -Kind "Plan" -Message "Deployment plan"
    Write-ToolkitDetail -Message "Location: $(Get-ToolkitConfigValue -Config $Config -Path 'resourceGroup.location')"
    Write-ToolkitDetail -Message "Resource group: $ResourceGroupName"
    Write-ToolkitDetail -Message "Storage resource group: $StorageResourceGroupName"
    Write-ToolkitDetail -Message "VNet/subnet: $VnetName / $SubnetName"
    Write-ToolkitDetail -Message "NSG/NIC/VM: $NsgName / $InterfaceName / $VMName"
    Write-ToolkitDetail -Message "VM public IP: $VmPublicIpEnabled"
    Write-ToolkitDetail -Message "Bastion: $BastionName"
    Write-ToolkitDetail -Message "Key Vault: $KeyVaultName"
    Write-ToolkitDetail -Message "Storage account/share: $StorageAccountName / $FileShareName"
    Write-ToolkitDetail -Message "Restore helper: restore-databases.ps1 for .bak files on $(Get-ToolkitConfigValue -Config $Config -Path 'storage.driveLetter'):$(Get-ToolkitConfigValue -Config $Config -Path 'storage.backupPath')"
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
    "Protect-ToolkitDiagnosticText",
    "Resolve-ToolkitErrorLogPath",
    "ConvertTo-ToolkitErrorLogRecord",
    "Write-ToolkitErrorLog",
    "Compare-ToolkitResourceProperty",
    "Assert-ToolkitNoBlockingDrift",
    "Write-ToolkitMessage",
    "Write-ToolkitInfo",
    "Write-ToolkitStep",
    "Write-ToolkitSuccess",
    "Write-ToolkitWarning",
    "Write-ToolkitError",
    "Write-ToolkitDrift",
    "Write-ToolkitDetail",
    "Write-ToolkitWhatIf",
    "Write-ToolkitDeploymentStepResult",
    "Get-ToolkitGuestSetupWarning",
    "Write-ToolkitSecurityAdvice",
    "Write-ToolkitPlan",
    "Add-ToolkitRoleAssignment",
    "Get-ToolkitCurrentPrincipalId",
    "Get-ToolkitMountScript",
    "Get-ToolkitRestoreScriptContent"
)
