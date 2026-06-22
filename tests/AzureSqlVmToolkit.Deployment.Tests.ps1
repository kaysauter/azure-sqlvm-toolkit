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
}

Describe "Guest install script generation" {
    It "generates pinned package commands from package metadata" {
        $script = Get-ToolkitGuestInstallScript -Config (Get-DeploymentTestConfig)

        $script | Should -Match "choco install git.install --version 2.54.0 -y"
        $script | Should -Match "Install-Module -Name dbatools -RequiredVersion 2.7.25"
        $script | Should -Match "Import-Module dbatools"
    }
}
