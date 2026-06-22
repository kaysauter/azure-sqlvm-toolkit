BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot "scripts/AzureSqlVmToolkit.Common.psm1") -Force
    Import-Module (Join-Path $repoRoot "scripts/AzureSqlVmToolkit.Deployment.psm1") -Force -DisableNameChecking

    function Get-DeploymentTestConfig {
        return @{
            network          = @{
                vnet     = @{ addressPrefix = "192.168.0.0/16" }
                subnet   = @{ addressPrefix = "192.168.1.0/24" }
                publicIp = @{
                    allocationMethod     = "Static"
                    idleTimeoutInMinutes = 4
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
            securityRules    = @(
                @{
                    name                     = "allow-app"
                    protocol                 = "Tcp"
                    direction                = "Inbound"
                    priority                 = 1000
                    sourceAddressPrefix      = "10.0.0.0/24"
                    sourcePortRange          = "*"
                    destinationAddressPrefix = "*"
                    destinationPortRange     = "443"
                    access                   = "Allow"
                }
            )
            softwareInstalls = @{
                allowDynamicBootstrap = $true
                chocolatey            = @{
                    bootstrapUrl = "https://community.chocolatey.org/install.ps1"
                }
                packages              = @(
                    @{
                        manager = "Chocolatey"
                        name    = "git.install"
                        version = "2.54.0"
                    },
                    @{
                        manager = "PowerShellGallery"
                        name    = "dbatools"
                        version = "2.7.25"
                    }
                )
                installScript         = "Import-Module dbatools"
            }
        }
    }
}

Describe "Deployment Ensure functions" {
    It "reports missing resource groups as WhatIf creates without calling Azure create" {
        $created = [System.Collections.Generic.List[string]]::new()

        $result = Ensure-ToolkitResourceGroup `
            -Name "toolkit-rg" `
            -Location "switzerlandnorth" `
            -Tag @{} `
            -GetResourceGroup { $null } `
            -NewResourceGroup { param($Name) $created.Add($Name) } `
            -WhatIf

        $result.Status | Should -Be "WouldCreate"
        $created.Count | Should -Be 0
    }

    It "fails early when an existing resource group has immutable drift" {
        {
            Ensure-ToolkitResourceGroup `
                -Name "toolkit-rg" `
                -Location "switzerlandnorth" `
                -Tag @{} `
                -GetResourceGroup { [pscustomobject]@{ ResourceId = "/rg"; Location = "westeurope" } } `
                -NewResourceGroup { throw "should not create" }
        } | Should -Throw -ExpectedMessage "*drift on Location*"
    }

    It "reuses resource groups when Azure returns a normalized location" {
        $result = Ensure-ToolkitResourceGroup `
            -Name "toolkit-rg" `
            -Location "Switzerland North" `
            -Tag @{} `
            -GetResourceGroup { [pscustomobject]@{ ResourceId = "/rg"; Location = "switzerlandnorth" } } `
            -NewResourceGroup { throw "should not create" }

        $result.Status | Should -Be "Reused"
    }

    It "creates a missing virtual network through injected Azure commands" {
        $config = Get-DeploymentTestConfig
        $names = [pscustomobject]@{
            ResourceGroupName = "toolkit-rg"
            VnetName          = "toolkit-rg-vnet"
            SubnetName        = "toolkit-rg-subnet"
        }

        $result = Ensure-ToolkitVirtualNetwork `
            -Config $config `
            -Names $names `
            -Location "switzerlandnorth" `
            -GetVirtualNetwork { $null } `
            -NewSubnetConfig {
                param($SubnetName, $AddressPrefix)
                [pscustomobject]@{ Name = $SubnetName; AddressPrefix = $AddressPrefix }
            } `
            -NewVirtualNetwork {
                param($ResourceGroupName, $Location, $Name, $AddressPrefix, $SubnetConfig)
                [pscustomobject]@{
                    Id           = "/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualNetworks/$Name"
                    Location     = $Location
                    AddressSpace = [pscustomobject]@{ AddressPrefixes = @($AddressPrefix) }
                    Subnets      = @([pscustomobject]@{ Name = $SubnetConfig.Name; AddressPrefix = $SubnetConfig.AddressPrefix; Id = "/subnet" })
                }
            }

        $result.Step.Status | Should -Be "Created"
        $result.SubnetId | Should -Be "/subnet"
    }

    It "reports a missing virtual network as a WhatIf create" {
        $config = Get-DeploymentTestConfig
        $names = [pscustomobject]@{
            ResourceGroupName = "toolkit-rg"
            VnetName          = "toolkit-rg-vnet"
            SubnetName        = "toolkit-rg-subnet"
        }

        $result = Ensure-ToolkitVirtualNetwork `
            -Config $config `
            -Names $names `
            -Location "switzerlandnorth" `
            -GetVirtualNetwork { $null } `
            -NewVirtualNetwork { throw "should not create" } `
            -WhatIf

        $result.Step.Status | Should -Be "WouldCreate"
        $result.SubnetId | Should -Match "/subnets/toolkit-rg-subnet$"
    }

    It "reports missing NSG rules as an Azure-aware WhatIf update" {
        $names = [pscustomobject]@{
            ResourceGroupName = "toolkit-rg"
            NsgName           = "toolkit-rg-nsg"
        }
        $nsg = [pscustomobject]@{
            Id            = "/nsg"
            SecurityRules = @()
        }

        $result = Ensure-ToolkitNetworkSecurityGroup `
            -Config (Get-DeploymentTestConfig) `
            -Names $names `
            -Location "switzerlandnorth" `
            -GetNetworkSecurityGroup { $nsg } `
            -NewNetworkSecurityGroup { throw "should not create" } `
            -UpdateNetworkSecurityGroup { throw "should not update" } `
            -WhatIf

        $result.Status | Should -Be "WouldUpdate"
        $result.Detail.MissingRules | Should -Be 1
    }

    It "fails early when an existing NSG rule drifts on destination port" {
        $names = [pscustomobject]@{
            ResourceGroupName = "toolkit-rg"
            NsgName           = "toolkit-rg-nsg"
        }
        $nsg = [pscustomobject]@{
            Id            = "/nsg"
            SecurityRules = @(
                [pscustomobject]@{
                    Name                     = "allow-app"
                    Protocol                 = "Tcp"
                    Direction                = "Inbound"
                    Priority                 = 1000
                    SourceAddressPrefix      = "10.0.0.0/24"
                    SourcePortRange          = "*"
                    DestinationAddressPrefix = "*"
                    DestinationPortRange     = "80"
                    Access                   = "Allow"
                }
            )
        }

        {
            Ensure-ToolkitNetworkSecurityGroup `
                -Config (Get-DeploymentTestConfig) `
                -Names $names `
                -Location "switzerlandnorth" `
                -GetNetworkSecurityGroup { $nsg } `
                -NewNetworkSecurityGroup { throw "should not create" } `
                -UpdateNetworkSecurityGroup { throw "should not update" }
        } | Should -Throw -ExpectedMessage "*DestinationPortRange*"
    }

    It "fails early when an existing NIC points at the wrong subnet" {
        $names = [pscustomobject]@{
            ResourceGroupName = "toolkit-rg"
            InterfaceName     = "toolkit-rg-nic"
        }
        $nic = [pscustomobject]@{
            Id                   = "/nic"
            NetworkSecurityGroup = [pscustomobject]@{ Id = "/nsg" }
            IpConfigurations     = @(
                [pscustomobject]@{
                    Subnet = [pscustomobject]@{ Id = "/wrong-subnet" }
                }
            )
        }

        {
            Ensure-ToolkitNetworkInterface `
                -Names $names `
                -Location "switzerlandnorth" `
                -SubnetId "/expected-subnet" `
                -NetworkSecurityGroupId "/nsg" `
                -GetNetworkInterface { $nic } `
                -NewNetworkInterface { throw "should not create" }
        } | Should -Throw -ExpectedMessage "*SubnetId*"
    }

    It "allows reruns when config uses latest image version and Azure stores a concrete version" {
        $config = Get-DeploymentTestConfig
        $config.credentials = @{ username = "toolkitadmin" }
        $config.vm = @{
            size  = "Standard_DS13_V2"
            image = @{
                publisherName = "MicrosoftSQLServer"
                offer         = "sql2022-ws2022"
                skus          = "sqldev-gen2"
                version       = "latest"
            }
        }
        $names = [pscustomobject]@{
            ResourceGroupName = "toolkit-rg"
            VMName            = "toolkit-rg-vm"
        }
        $vm = [pscustomobject]@{
            Id              = "/vm"
            HardwareProfile = [pscustomobject]@{ VmSize = "Standard_DS13_V2" }
            StorageProfile  = [pscustomobject]@{
                ImageReference = [pscustomobject]@{
                    Publisher = "MicrosoftSQLServer"
                    Offer     = "sql2022-ws2022"
                    Sku       = "sqldev-gen2"
                    Version   = "16.0.250101"
                }
            }
        }
        $password = [securestring]::new()

        $result = Ensure-ToolkitVirtualMachine `
            -Config $config `
            -Names $names `
            -Location "switzerlandnorth" `
            -NetworkInterfaceId "/nic" `
            -AdminPassword $password `
            -GetVm { $vm } `
            -NewVm { throw "should not create" }

        $result.Status | Should -Be "Reused"
    }

    It "skips guest setup when storage context is unavailable" {
        $names = [pscustomobject]@{
            ResourceGroupName   = "toolkit-rg"
            VMName              = "toolkit-rg-vm"
            StorageAccountName  = "toolkitstore01"
            FileShareName       = "sqlbackupshare"
        }

        $result = Ensure-ToolkitGuestSetup `
            -Config (Get-DeploymentTestConfig) `
            -Names $names `
            -KeyVaultName "toolkit-kv" `
            -StorageContext $null `
            -InvokeVmRunCommand { throw "should not run guest commands" } `
            -UploadStorageFile { throw "should not upload" }

        $result.Status | Should -Be "Skipped"
    }

    It "skips Bastion creation when the Bastion public IP step is skipped" {
        $config = Get-DeploymentTestConfig
        $names = [pscustomobject]@{
            ResourceGroupName  = "toolkit-rg"
            VnetName           = "toolkit-rg-vnet"
            BastionSubnetName  = "AzureBastionSubnet"
            BastionPipName     = "toolkit-rg-bastion-pip"
            BastionName        = "toolkit-rg-bastion"
        }
        $vnet = [pscustomobject]@{
            Id      = "/subscriptions/000/resourceGroups/toolkit-rg/providers/Microsoft.Network/virtualNetworks/toolkit-rg-vnet"
            Subnets = @(
                [pscustomobject]@{
                    Name          = "AzureBastionSubnet"
                    AddressPrefix = "192.168.2.0/24"
                    Id            = "/bastionSubnet"
                }
            )
        }

        $result = Ensure-ToolkitBastion `
            -Config $config `
            -Names $names `
            -Location "switzerlandnorth" `
            -SubscriptionId "000" `
            -GetVirtualNetwork { $vnet } `
            -EnsurePublicIpAddress {
                param($Name)
                [pscustomobject]@{
                    Name       = "Bastion public IP"
                    Status     = "Skipped"
                    Message    = "'$Name' was not created."
                    ResourceId = "/publicIp"
                    Detail     = @{}
                }
            } `
            -GetBastion { throw "should not query bastion" } `
            -NewBastion { throw "should not create bastion" }

        $result.Status | Should -Be "Skipped"
        $result.ResourceId | Should -Be "/subscriptions/000/resourceGroups/toolkit-rg/providers/Microsoft.Network/bastionHosts/toolkit-rg-bastion"
    }
}

Describe "Guest install script generation" {
    It "generates pinned package commands from package metadata" {
        $config = Get-DeploymentTestConfig
        $sha256 = "b" * 64
        $config.softwareInstalls.packages[0]["sha256"] = $sha256

        $script = Get-ToolkitGuestInstallScript -Config $config

        $script | Should -Match "choco install git.install --version 2.54.0 -y"
        $script | Should -Match "--checksum $sha256 --checksum-type sha256"
        $script | Should -Match "Install-Module -Name dbatools -RequiredVersion 2.7.25"
        $script | Should -Match "Import-Module dbatools"
    }

    It "rejects PowerShell Gallery package SHA-256 values during script generation" {
        $config = Get-DeploymentTestConfig
        $config.softwareInstalls.packages[1]["sha256"] = "c" * 64

        { Get-ToolkitGuestInstallScript -Config $config } | Should -Throw -ExpectedMessage "*sha256 is only supported for Chocolatey*"
    }
}
