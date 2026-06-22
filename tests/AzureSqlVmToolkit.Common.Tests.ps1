BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot "scripts/AzureSqlVmToolkit.Common.psm1"
    Import-Module $modulePath -Force

    function Get-ValidToolkitConfig {
        return @{
            resourceGroup    = @{
                name     = "toolkit-rg"
                location = "Switzerland North"
                tags     = @{ Purpose = "Test" }
            }
            network          = @{
                vnet     = @{ addressPrefix = "192.168.0.0/16" }
                subnet   = @{ addressPrefix = "192.168.1.0/24" }
                publicIp = @{
                    enabled              = $false
                    allocationMethod     = "Static"
                    idleTimeoutInMinutes = 4
                }
            }
            securityRules    = @()
            keyVault         = @{
                name                      = "toolkit-kv-test"
                storageKeySecretName      = "storage-account-key"
                vmAdminPasswordSecretName = "vm-admin-password"
                passwordLength            = 24
            }
            credentials      = @{
                username = "toolkitadmin"
            }
            vm               = @{
                size  = "Standard_DS13_V2"
                image = @{
                    publisherName = "MicrosoftSQLServer"
                    offer         = "sql2022-ws2022"
                    skus          = "sqldev-gen2"
                    version       = "latest"
                }
            }
            bastion          = @{
                subnetAddressPrefix = "192.168.2.0/24"
                sku                 = "Basic"
                publicIp            = @{
                    allocationMethod     = "Static"
                    idleTimeoutInMinutes = 4
                    sku                  = "Standard"
                }
            }
            storage          = @{
                resourceGroup = "toolkit-storage-rg"
                accountName   = "toolkitstore01"
                skuName       = "Standard_LRS"
                fileShareName = "sqlbackupshare"
                driveLetter   = "Z"
                backupPath    = "\"
            }
            softwareInstalls = @{
                installScript = "Write-Host 'install'"
                logonScript   = "Write-Host 'logon'"
            }
        }
    }
}

Describe "Test-ToolkitConfig" {
    It "accepts the valid sample shape" {
        $config = Get-ValidToolkitConfig

        { Test-ToolkitConfig -Config $config } | Should -Not -Throw
    }

    It "reports missing required values with the config path" {
        $config = Get-ValidToolkitConfig
        $config.network.publicIp.Remove("enabled")

        { Test-ToolkitConfig -Config $config } | Should -Throw -ExpectedMessage "*network.publicIp.enabled*"
    }

    It "rejects invalid IPv4 CIDR prefixes" {
        $config = Get-ValidToolkitConfig
        $config.network.vnet.addressPrefix = "999.168.0.0/99"

        { Test-ToolkitConfig -Config $config } | Should -Throw -ExpectedMessage "*network.vnet.addressPrefix*"
    }

    It "rejects broad inbound RDP rules" {
        $config = Get-ValidToolkitConfig
        $config.securityRules = @(
            @{
                name                     = "allow-rdp"
                protocol                 = "Tcp"
                direction                = "Inbound"
                priority                 = 1000
                sourceAddressPrefix      = "*"
                sourcePortRange          = "*"
                destinationAddressPrefix = "*"
                destinationPortRange     = "3389"
                access                   = "Allow"
            }
        )

        { Test-ToolkitConfig -Config $config } | Should -Throw -ExpectedMessage "*exposes port 3389*"
    }

    It "rejects traversal and UNC backup paths" {
        $config = Get-ValidToolkitConfig
        $config.storage.backupPath = "..\backup"

        { Test-ToolkitConfig -Config $config } | Should -Throw -ExpectedMessage "*storage.backupPath*"

        $config.storage.backupPath = "\\server\share"
        { Test-ToolkitConfig -Config $config } | Should -Throw -ExpectedMessage "*storage.backupPath*"
    }

    It "requires the NSG fields consumed by deployment" {
        $config = Get-ValidToolkitConfig
        $config.securityRules = @(
            @{
                name                     = "allow-app"
                protocol                 = "Tcp"
                direction                = "Inbound"
                priority                 = 1000
                sourceAddressPrefix      = "10.0.0.0/24"
                sourcePortRange          = "*"
                destinationAddressPrefix = "*"
                access                   = "Allow"
            }
        )

        { Test-ToolkitConfig -Config $config } | Should -Throw -ExpectedMessage "*destinationPortRange*"
    }

    It "rejects the Bastion Developer SKU because this script deploys the dedicated Bastion shape" {
        $config = Get-ValidToolkitConfig
        $config.bastion.sku = "Developer"

        { Test-ToolkitConfig -Config $config } | Should -Throw -ExpectedMessage "*bastion.sku*"
    }

    It "rejects PowerShell Gallery package SHA-256 values because they are not enforced" {
        $config = Get-ValidToolkitConfig
        $sha256 = "a" * 64
        $config.softwareInstalls["packages"] = @(
            @{
                manager = "PowerShellGallery"
                name    = "dbatools"
                version = "2.7.25"
                sha256  = $sha256
            }
        )

        { Test-ToolkitConfig -Config $config } | Should -Throw -ExpectedMessage "*sha256 is only supported for Chocolatey*"
    }
}

Describe "Generated password" {
    It "uses the requested length and includes every required character class" {
        $password = Get-ToolkitGeneratedPassword -Length 32

        $password.Length | Should -Be 32
        $password | Should -Match "[a-z]"
        $password | Should -Match "[A-Z]"
        $password | Should -Match "\d"
        $password | Should -Match "[^a-zA-Z0-9]"
    }

    It "rejects short password lengths" {
        { Get-ToolkitGeneratedPassword -Length 8 } | Should -Throw -ExpectedMessage "*at least 12*"
    }
}

Describe "Resource naming" {
    It "builds deterministic names from the configured resource group" {
        $names = Get-ToolkitResourceNameSet `
            -ResourceGroupName "demo-rg" `
            -KeyVaultName "demo-kv" `
            -StorageAccountName "demostore" `
            -FileShareName "sqlbackupshare" `
            -StorageResourceGroupName "storage-rg"

        $names.VnetName | Should -Be "demo-rg-vnet"
        $names.SubnetName | Should -Be "demo-rg-subnet"
        $names.PipName | Should -Be "demo-rg-pip"
        $names.BastionSubnetName | Should -Be "AzureBastionSubnet"
        $names.StorageResourceGroupName | Should -Be "storage-rg"
    }
}

Describe "Deployment step result and drift comparison" {
    It "creates a structured deployment step result" {
        $result = ConvertTo-ToolkitDeploymentStepResult `
            -Name "Key Vault" `
            -Status "Created" `
            -Message "Created Key Vault." `
            -ResourceId "/subscriptions/000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv" `
            -Detail @{ Kind = "KeyVault" }

        $result.PSObject.TypeNames[0] | Should -Be "AzureSqlVmToolkit.DeploymentStepResult"
        $result.Name | Should -Be "Key Vault"
        $result.Status | Should -Be "Created"
        $result.Detail.Kind | Should -Be "KeyVault"
    }

    It "marks matching resource properties as reused" {
        $result = Compare-ToolkitResourceProperty `
            -ResourceName "VNet" `
            -PropertyName "AddressPrefix" `
            -ExpectedValue "192.168.0.0/16" `
            -ActualValue "192.168.0.0/16"

        $result.Status | Should -Be "Reused"
        $result.Detail.Policy | Should -Be "Fail"
    }

    It "marks drift according to policy" {
        $fail = Compare-ToolkitResourceProperty `
            -ResourceName "VNet" `
            -PropertyName "AddressPrefix" `
            -ExpectedValue "192.168.0.0/16" `
            -ActualValue "10.0.0.0/16"

        $update = Compare-ToolkitResourceProperty `
            -ResourceName "NSG" `
            -PropertyName "Rules" `
            -ExpectedValue "configured" `
            -ActualValue "missing" `
            -DriftPolicy "Update"

        $ignore = Compare-ToolkitResourceProperty `
            -ResourceName "Storage" `
            -PropertyName "Sku" `
            -ExpectedValue "Standard_LRS" `
            -ActualValue "Standard_GRS" `
            -DriftPolicy "Ignore"

        $fail.Status | Should -Be "DriftDetected"
        $update.Status | Should -Be "Updated"
        $ignore.Status | Should -Be "Skipped"
    }
}

Describe "Role assignment helper" {
    It "does not create a duplicate assignment when one exists" {
        $created = [System.Collections.Generic.List[string]]::new()

        Add-ToolkitRoleAssignment `
            -ObjectId "object-id" `
            -RoleDefinitionName "Key Vault Secrets User" `
            -Scope "/subscriptions/000/resourceGroups/rg" `
            -GetRoleAssignment { [pscustomobject]@{ Id = "existing" } } `
            -NewRoleAssignment { param($ObjectId) $created.Add($ObjectId) } `
            -Confirm:$false

        $created.Count | Should -Be 0
    }

    It "creates a missing assignment through the injected Azure command" {
        $created = [System.Collections.Generic.List[string]]::new()

        Add-ToolkitRoleAssignment `
            -ObjectId "object-id" `
            -RoleDefinitionName "Key Vault Secrets User" `
            -Scope "/subscriptions/000/resourceGroups/rg" `
            -GetRoleAssignment { $null } `
            -NewRoleAssignment { param($ObjectId) $created.Add($ObjectId) } `
            -Confirm:$false

        $created | Should -Contain "object-id"
    }
}

Describe "Azure principal resolution" {
    It "resolves a user object id" {
        $context = [pscustomobject]@{
            Account = [pscustomobject]@{
                Type = "User"
                Id   = "person@example.com"
            }
        }

        $id = Get-ToolkitCurrentPrincipalId `
            -Context $context `
            -GetSignedInUser { [pscustomobject]@{ Id = "user-object-id" } } `
            -GetServicePrincipal { throw "should not be called" }

        $id | Should -Be "user-object-id"
    }

    It "resolves a service principal object id from the application id" {
        $context = [pscustomobject]@{
            Account = [pscustomobject]@{
                Type = "ServicePrincipal"
                Id   = "application-id"
            }
        }

        $id = Get-ToolkitCurrentPrincipalId `
            -Context $context `
            -GetSignedInUser { throw "should not be called" } `
            -GetServicePrincipal { param($ApplicationId) [pscustomobject]@{ Id = "object-for-$ApplicationId" } }

        $id | Should -Be "object-for-application-id"
    }
}

Describe "Guest script builders" {
    It "keeps the mount script parameterized" {
        $script = Get-ToolkitMountScript

        $script | Should -Match 'param\(\$KeyVaultName, \$SecretName, \$StorageAccountName, \$FileShareName, \$DriveLetter\)'
        $script | Should -Not -Match "Invoke-Expression"
    }

    It "builds a restore helper for the configured mounted backup path" {
        $script = Get-ToolkitRestoreScriptContent -DriveLetter "Z" -BackupPath "\"

        $script | Should -Match 'Get-ChildItem -Path "Z:\\'
        $script | Should -Match "Restore-DbaDatabase"
    }
}
