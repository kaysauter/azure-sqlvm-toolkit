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

Describe "Structured error logging" {
    It "redacts credentials, tokens, SAS signatures, and user-info passwords" {
        $password = "CanaryPassword!42"
        $bearerToken = "token-" + ("a" * 32)
        $githubToken = "ghp_" + ("b" * 36)
        $sasSignature = "sas-signature-" + ("c" * 24)
        $unlabelledSecret = "Xy9!aB3_cD4-eF5.gH6+iJ7=kL8mN0pQ2rS"
        $basicCredential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("user:password"))
        $environmentSecret = "abc123"
        $secretValue = "short-value"
        $sharedKey = "shared-key-12345"
        $proxyKey = "digestkey"
        $auxiliaryToken = "auxiliarytoken"
        $secondaryAuxiliaryToken = "secondarytoken"
        $digestUsername = "guest"
        $digestResponse = "zzzzzz"
        $apimKey = "deadbeefcafebabe"
        $functionKey = "functionkey"
        $privateKeyBody = "private-key-body-" + ("e" * 48)
        $encryptedPrivateKey = "-----BEGIN " + "ENCRYPTED PRIVATE KEY-----`n$privateKeyBody`n-----END " + "ENCRYPTED PRIVATE KEY-----"
        $text = @"
Password=$password Authorization: Bearer $bearerToken token=$githubToken https://user:$password@example.test/file?sig=$sasSignature value $unlabelledSecret
{"Authorization":"Basic $basicCredential"} AZURE_CLIENT_SECRET=$environmentSecret SecretValue: $secretValue
Authorization: SharedKey account:$sharedKey
Proxy-Authorization: Digest $proxyKey
Authorization: Digest username="$digestUsername", response="$digestResponse"
x-ms-authorization-auxiliary: Bearer $auxiliaryToken, Bearer $secondaryAuxiliaryToken
Ocp-Apim-Subscription-Key: $apimKey
x-functions-key: $functionKey
$encryptedPrivateKey
"@

        $protected = Protect-ToolkitDiagnosticText -Text $text

        $protected | Should -Not -Match ([regex]::Escape($password))
        $protected | Should -Not -Match ([regex]::Escape($bearerToken))
        $protected | Should -Not -Match ([regex]::Escape($githubToken))
        $protected | Should -Not -Match ([regex]::Escape($sasSignature))
        $protected | Should -Not -Match ([regex]::Escape($unlabelledSecret))
        $protected | Should -Not -Match ([regex]::Escape($basicCredential))
        $protected | Should -Not -Match ([regex]::Escape($environmentSecret))
        $protected | Should -Not -Match ([regex]::Escape($secretValue))
        $protected | Should -Not -Match ([regex]::Escape($sharedKey))
        $protected | Should -Not -Match ([regex]::Escape($proxyKey))
        $protected | Should -Not -Match ([regex]::Escape($auxiliaryToken))
        $protected | Should -Not -Match ([regex]::Escape($secondaryAuxiliaryToken))
        $protected | Should -Not -Match ([regex]::Escape($digestUsername))
        $protected | Should -Not -Match ([regex]::Escape($digestResponse))
        $protected | Should -Not -Match ([regex]::Escape($apimKey))
        $protected | Should -Not -Match ([regex]::Escape($functionKey))
        $protected | Should -Not -Match ([regex]::Escape($privateKeyBody))
        $protected | Should -Match "\[REDACTED"
        Protect-ToolkitDiagnosticText -Text "MySqlVmProd2026-WestEurope" | Should -Be "MySqlVmProd2026-WestEurope"
    }

    It "normalizes the destination without changing the filesystem" {
        $path = Join-Path $TestDrive "nested/errors.jsonl"

        $resolved = Resolve-ToolkitErrorLogPath -Path $path

        $resolved | Should -Be ([System.IO.Path]::GetFullPath($path))
        Test-Path (Split-Path -Parent $path) | Should -BeFalse
        Test-Path $path | Should -BeFalse
    }

    It "rejects a directory as an error log file" {
        { Resolve-ToolkitErrorLogPath -Path $TestDrive } | Should -Throw -ExpectedMessage "*points to a directory*"
    }

    It "uses one chmod executable when the command resolves to multiple paths" -Skip:$IsWindows {
        $chmodCommand = Get-Command -Name "chmod" -CommandType Application | Select-Object -First 1
        Mock -CommandName Get-Command -ModuleName AzureSqlVmToolkit.Common -ParameterFilter {
            $Name -eq "chmod" -and $CommandType -eq [System.Management.Automation.CommandTypes]::Application
        } -MockWith {
            @($chmodCommand, $chmodCommand)
        }
        $path = Join-Path $TestDrive "multiple-chmod-paths.jsonl"
        $errorRecord = try {
            throw "Multiple chmod paths test failed."
        }
        catch {
            $_
        }

        Write-ToolkitErrorLog -ErrorRecord $errorRecord -Path $path -RunId "multiple-chmod" -Mode "Plan" | Out-Null

        Test-Path -LiteralPath $path | Should -BeTrue
        Should -Invoke -CommandName Get-Command -ModuleName AzureSqlVmToolkit.Common -Exactly 1
    }

    It "preserves backslashes in Unix error log paths" -Skip:$IsWindows {
        $directory = [System.IO.Path]::Combine($TestDrive, 'backslash\component')
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        $path = [System.IO.Path]::Combine($directory, 'errors.jsonl')
        $redirectedPath = [System.IO.Path]::Combine($TestDrive, 'backslash', 'component', 'errors.jsonl')
        $errorRecord = try {
            throw "Unix path test failed."
        }
        catch {
            $_
        }

        Write-ToolkitErrorLog -ErrorRecord $errorRecord -Path $path -RunId "unix-path" -Mode "Plan" | Out-Null

        [System.IO.File]::Exists($path) | Should -BeTrue
        [System.IO.File]::Exists($redirectedPath) | Should -BeFalse
    }

    It "writes append-only JSONL records without sensitive values" {
        $password = "CanaryPassword!42"
        $sasSignature = "sas-signature-" + ("d" * 24)
        $correlationId = "b6eb6d9f-ff40-4f4d-b3e3-a61af6f5d451"
        $errorRecord = try {
            throw "Password=$password request id: $correlationId https://example.test/file?sig=$sasSignature"
        }
        catch {
            $_
        }
        $path = Join-Path $TestDrive "errors/deployment.jsonl"
        $context = @{
            Phase        = "Virtual machine"
            ResourceType = "Microsoft.Compute/virtualMachines"
            ResourceName = "toolkit-vm"
        }

        Write-ToolkitErrorLog -ErrorRecord $errorRecord -Path $path -RunId "run-1" -Mode "Deployment" -DiagnosticContext $context -ToolkitVersion "0.2.0" | Out-Null
        Write-ToolkitErrorLog -ErrorRecord $errorRecord -Path $path -RunId "run-2" -Mode "Deployment" -DiagnosticContext $context -ToolkitVersion "0.2.0" | Out-Null

        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 2
        $first = $lines[0] | ConvertFrom-Json
        $first.schemaVersion | Should -Be 1
        $first.runId | Should -Be "run-1"
        $first.phase | Should -Be "Virtual machine"
        $first.resource.type | Should -Be "Microsoft.Compute/virtualMachines"
        $first.resource.name | Should -Be "toolkit-vm"
        $first.azureCorrelationId | Should -Be $correlationId
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Not -Match ([regex]::Escape($password))
        $raw | Should -Not -Match ([regex]::Escape($sasSignature))

        if (-not $IsWindows) {
            $item = Get-Item -LiteralPath $path
            if ($item.PSObject.Properties["UnixFileMode"]) {
                [int]$item.UnixFileMode | Should -Be 384
            }
        }
    }

    It "extracts the Azure request ID from <Spelling>" -TestCases @(
        @{ Spelling = "CorrelationId"; Prefix = "CorrelationId" },
        @{ Spelling = "correlation-id"; Prefix = "correlation-id" },
        @{ Spelling = "RequestId"; Prefix = "RequestId" },
        @{ Spelling = "x-ms-request-id"; Prefix = "x-ms-request-id" }
    ) {
        param($Spelling, $Prefix)

        $correlationId = "9f608db8-43ad-47d9-b8e6-78812d423be1"
        $errorRecord = try {
            throw "$Prefix`: $correlationId"
        }
        catch {
            $_
        }

        $record = ConvertTo-ToolkitErrorLogRecord -ErrorRecord $errorRecord -RunId "request-id-test" -Mode "WhatIf"

        $record.azureCorrelationId | Should -Be $correlationId -Because "$Spelling should be recognized"
    }

    It "serializes concurrent writers through real and alias paths" {
        $directory = Join-Path $TestDrive "concurrent"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $path = Join-Path $directory "errors.jsonl"
        New-Item -ItemType File -Path $path -Force | Out-Null
        $aliasPath = $path
        if (-not $IsWindows) {
            $aliasPath = Join-Path $directory "errors-alias.jsonl"
            New-Item -ItemType SymbolicLink -Path $aliasPath -Target $path | Out-Null
        }
        $jobs = @()

        try {
            $jobs = @(1..6 | ForEach-Object {
                $commonModulePathForJob = $modulePath
                $indexForJob = $_
                $errorLogPathForJob = if ($_ % 2 -eq 0) { $aliasPath } else { $path }
                Start-Job -ScriptBlock {
                    Import-Module $using:commonModulePathForJob -Force
                    $errorRecord = try {
                        throw "Concurrent worker $using:indexForJob failed."
                    }
                    catch {
                        $_
                    }

                    Write-ToolkitErrorLog `
                        -ErrorRecord $errorRecord `
                        -Path $using:errorLogPathForJob `
                        -RunId "worker-$using:indexForJob" `
                        -Mode "Deployment" | Out-Null
                }
            })

            Wait-Job -Job $jobs -Timeout 60 | Out-Null
            @($jobs | Where-Object State -ne "Completed").Count | Should -Be 0
            $jobs | Receive-Job -ErrorAction Stop | Out-Null
        }
        finally {
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }

        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 6
        $records = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        @($records.runId | Sort-Object -Unique).Count | Should -Be 6
    }

    It "serializes writers through a backslash-named Unix directory alias before the log file exists" -Skip:$IsWindows {
        $directory = Join-Path $TestDrive "directory-alias-concurrent"
        $realDirectory = Join-Path $directory "real"
        $aliasDirectory = [System.IO.Path]::Combine($directory, 'alias\name')
        New-Item -ItemType Directory -Path $realDirectory -Force | Out-Null
        $linkCommand = Get-Command -Name 'ln' -CommandType Application | Select-Object -First 1
        & $linkCommand.Source '-s' $realDirectory $aliasDirectory
        $LASTEXITCODE | Should -Be 0
        $path = Join-Path $realDirectory "errors.jsonl"
        $aliasPath = [System.IO.Path]::Combine($aliasDirectory, "errors.jsonl")
        $gatePath = Join-Path $directory "start.gate"
        $jobs = @()

        try {
            $jobs = @(1..12 | ForEach-Object {
                $commonModulePathForJob = $modulePath
                $indexForJob = $_
                $errorLogPathForJob = if ($_ % 2 -eq 0) { $aliasPath } else { $path }
                Start-Job -ScriptBlock {
                    Import-Module $using:commonModulePathForJob -Force
                    while (-not (Test-Path -LiteralPath $using:gatePath)) {
                        Start-Sleep -Milliseconds 10
                    }
                    $errorRecord = try {
                        throw "Directory alias worker $using:indexForJob failed."
                    }
                    catch {
                        $_
                    }

                    Write-ToolkitErrorLog `
                        -ErrorRecord $errorRecord `
                        -Path $using:errorLogPathForJob `
                        -RunId "directory-worker-$using:indexForJob" `
                        -Mode "Deployment" | Out-Null
                }
            })
            New-Item -ItemType File -Path $gatePath | Out-Null

            Wait-Job -Job $jobs -Timeout 60 | Out-Null
            @($jobs | Where-Object State -ne "Completed").Count | Should -Be 0
            $jobs | Receive-Job -ErrorAction Stop | Out-Null
        }
        finally {
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }

        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 12
        $records = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        @($records.runId | Sort-Object -Unique).Count | Should -Be 12
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
