BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:manifestPath = Join-Path $repoRoot "AzureSqlVmToolkit.psd1"
    $script:schemaPath = Join-Path $repoRoot "schemas/config.schema.json"
    Import-Module $script:manifestPath -Force
}

Describe "AzureSqlVmToolkit module manifest" {
    It "has a valid module manifest" {
        $manifest = Test-ModuleManifest -Path $manifestPath

        $manifest.Name | Should -Be "AzureSqlVmToolkit"
        $manifest.ExportedFunctions.Keys | Should -Contain "New-AzureSqlVmToolkitDeployment"
        $manifest.ExportedFunctions.Keys | Should -Contain "Test-AzureSqlVmToolkitConfig"
    }

    It "exports the public command surface" {
        $commands = Get-Command -Module AzureSqlVmToolkit

        $commands.Name | Should -Contain "New-AzureSqlVmToolkitDeployment"
        $commands.Name | Should -Contain "Test-AzureSqlVmToolkitConfig"
    }
}

Describe "Test-AzureSqlVmToolkitConfig" {
    It "returns true for the sample config" {
        Test-AzureSqlVmToolkitConfig -ConfigFile (Join-Path $repoRoot "config.yaml") | Should -BeTrue
    }

    It "returns config metadata with PassThru" {
        $result = Test-AzureSqlVmToolkitConfig -ConfigFile (Join-Path $repoRoot "config.yaml") -PassThru

        $result.Valid | Should -BeTrue
        $result.ResourceNames.VMName | Should -Be "your-resource-group-name-vm"
        $result.ConfigPath | Should -Match "config.yaml"
    }
}

Describe "New-AzureSqlVmToolkitDeployment" {
    It "supports ShouldProcess" {
        $command = Get-Command New-AzureSqlVmToolkitDeployment

        $command.Parameters.Keys | Should -Contain "WhatIf"
        $command.Parameters.Keys | Should -Contain "Confirm"
    }

    It "runs the no-Azure plan path through the public command" {
        { New-AzureSqlVmToolkitDeployment -ConfigFile (Join-Path $repoRoot "config.yaml") -SecurityAssessmentAdvice -Plan } | Should -Not -Throw
    }

    It "keeps WhatIf separate from the no-Azure plan path" {
        $command = Get-Command New-AzureSqlVmToolkitDeployment

        $command.Parameters.Keys | Should -Contain "Plan"
        $command.Parameters.Keys | Should -Contain "WhatIf"
    }

    It "exposes structured error logging as an opt-in parameter" {
        $command = Get-Command New-AzureSqlVmToolkitDeployment

        $command.Parameters.Keys | Should -Contain "ErrorLogPath"
    }

    It "logs plan failures and preserves the terminating error" {
        $missingConfig = Join-Path $TestDrive "missing-config.yaml"
        $errorLog = Join-Path $TestDrive "logs/plan-errors.jsonl"

        { New-AzureSqlVmToolkitDeployment -ConfigFile $missingConfig -Plan -ErrorLogPath $errorLog } |
            Should -Throw -ExpectedMessage "*Configuration file not found*"

        $record = Get-Content -LiteralPath $errorLog | Select-Object -First 1 | ConvertFrom-Json
        $record.schemaVersion | Should -Be 1
        $record.mode | Should -Be "Plan"
        $record.phase | Should -Be "Configuration"
        $record.command | Should -Be "New-AzureSqlVmToolkitDeployment"
    }

    It "logs WhatIf failures without changing the original error" {
        $missingConfig = Join-Path $TestDrive "missing-whatif-config.yaml"
        $errorLog = Join-Path $TestDrive "logs/whatif-errors.jsonl"

        { New-AzureSqlVmToolkitDeployment -ConfigFile $missingConfig -WhatIf -ErrorLogPath $errorLog } |
            Should -Throw -ExpectedMessage "*Configuration file not found*"

        $record = Get-Content -LiteralPath $errorLog | Select-Object -First 1 | ConvertFrom-Json
        $record.mode | Should -Be "WhatIf"
        $record.phase | Should -Be "Configuration"
    }

    It "does not create an error-log directory for a successful plan" {
        $errorLog = Join-Path $TestDrive "unused-plan-log/errors.jsonl"

        New-AzureSqlVmToolkitDeployment `
            -ConfigFile (Join-Path $repoRoot "config.yaml") `
            -Plan `
            -ErrorLogPath $errorLog

        Test-Path (Split-Path -Parent $errorLog) | Should -BeFalse
        Test-Path $errorLog | Should -BeFalse
    }

    It "preserves the deployment error when diagnostic writing also fails" {
        $missingConfig = Join-Path $TestDrive "missing-logger-failure.yaml"
        $baselineError = try {
            New-AzureSqlVmToolkitDeployment -ConfigFile $missingConfig -Plan
        }
        catch {
            $_
        }
        Mock -ModuleName AzureSqlVmToolkit -CommandName Write-ToolkitErrorLog -MockWith {
            throw "Simulated diagnostic writer failure."
        }

        $previousWarningPreference = $WarningPreference
        try {
            $WarningPreference = "Stop"
            $loggedError = try {
                New-AzureSqlVmToolkitDeployment `
                    -ConfigFile $missingConfig `
                    -Plan `
                    -ErrorLogPath (Join-Path $TestDrive "logger-failure/errors.jsonl")
            }
            catch {
                $_
            }
        }
        finally {
            $WarningPreference = $previousWarningPreference
        }

        $loggedError.Exception.Message | Should -Be $baselineError.Exception.Message
        $loggedError.Exception.GetType().FullName | Should -Be $baselineError.Exception.GetType().FullName
        $loggedError.FullyQualifiedErrorId | Should -Be $baselineError.FullyQualifiedErrorId
        $loggedError.CategoryInfo.Category | Should -Be $baselineError.CategoryInfo.Category
    }
}

Describe "config.schema.json" {
    It "is valid JSON and describes the required top-level config sections" {
        $schema = Get-Content $schemaPath -Raw | ConvertFrom-Json

        $schema.title | Should -Be "AzureSqlVmToolkit configuration"
        $schema.required | Should -Contain "resourceGroup"
        $schema.required | Should -Contain "network"
        $schema.required | Should -Contain "keyVault"
        $schema.required | Should -Contain "storage"
        $schema.required | Should -Contain "softwareInstalls"
    }

    It "documents the same public Bastion SKUs as the PowerShell validator" {
        $schema = Get-Content $schemaPath -Raw | ConvertFrom-Json

        $schema.properties.bastion.properties.sku.enum | Should -Contain "Basic"
        $schema.properties.bastion.properties.sku.enum | Should -Contain "Standard"
        $schema.properties.bastion.properties.sku.enum | Should -Contain "Premium"
        $schema.properties.bastion.properties.sku.enum | Should -Not -Contain "Developer"
    }
}
