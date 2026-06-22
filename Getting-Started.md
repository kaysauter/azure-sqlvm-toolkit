# Getting Started

AzureSqlVmToolkit currently deploys through the tracked module command:

```powershell
New-AzureSqlVmToolkitDeployment
```

The original root script, `vm_creation_with_bastion.ps1`, remains available as a compatibility wrapper for existing users.

## Prerequisites

Install PowerShell dependencies:

```powershell
Install-Module -Name Az -Scope CurrentUser -Force
Install-Module -Name powershell-yaml -Scope CurrentUser -Force
```

Sign in before real deployment:

```powershell
Connect-AzAccount
```

The `-Plan` path does not require an Azure context.
The `-WhatIf` path does require an Azure context because it performs read-only Azure lookups before reporting create/reuse/drift decisions.

Import the module from the repository before running module commands:

```powershell
Import-Module .\AzureSqlVmToolkit.psd1 -Force
```

## Prepare Config

Copy the sample config to an ignored local file:

```powershell
Copy-Item .\config.yaml .\config.local.yaml
```

Edit these values before deployment:

- `resourceGroup.name`
- `resourceGroup.location`
- `keyVault.name`
- `storage.resourceGroup`
- `storage.accountName`
- `storage.fileShareName`
- `credentials.username`

The default config keeps the SQL VM private:

```yaml
network:
  publicIp:
    enabled: false

securityRules: []
```

Keep it that way unless you intentionally need direct public access. Broad inbound RDP and SQL rules are rejected by validation.

Validate the YAML before previewing or deploying:

```powershell
Test-AzureSqlVmToolkitConfig -ConfigFile .\config.local.yaml
```

## Password Model

The script expects the VM admin password to live in Key Vault.

Default behavior:

- Reuse `keyVault.vmAdminPasswordSecretName` if it exists.
- Stop if the secret is missing.
- Do not print the password.

Lab-only options:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -GeneratePassword
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -GeneratePassword -ShowPassword
```

Use `-GeneratePassword` only for demos and disposable labs. Use `-ShowPassword` only when console output is controlled.

## Preview

Run a no-Azure plan:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -Plan
```

This validates the YAML and prints the intended resource names, security posture, and restore-helper location.

Run an Azure-aware dry run:

```powershell
Connect-AzAccount
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -WhatIf
```

This queries Azure, reports whether resources would be created, reused, updated, or blocked by drift, and does not perform the mutating actions.

## Deploy

With a pre-created password secret:

```powershell
Connect-AzAccount
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice
```

For a disposable lab where the secret does not exist yet:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -GeneratePassword
```

Deployment creates or reuses:

1. VM resource group.
2. Storage resource group.
3. RBAC-enabled Key Vault.
4. VNet and VM subnet.
5. NSG and NIC.
6. SQL Server VM.
7. System-assigned VM managed identity.
8. Azure Bastion subnet, public IP, and Bastion host.
9. Storage account and Azure Files share.
10. Key Vault secret for the storage account key.
11. Guest setup through Azure VM Run Command.
12. Azure Files mount inside the VM.
13. `restore-databases.ps1` uploaded to the file share.

Existing resources are checked before reuse. Unsafe drift such as wrong VNet/subnet prefixes, wrong NIC attachments, legacy Key Vault access-policy mode, VM size drift, or VM image drift fails early. Safe missing pieces such as NSG rules, managed identity, role assignments, and Bastion subnet are reported as updates.

## Restore `.bak` Files

The current restore helper is simple. Place `.bak` files on the mounted Azure Files share, sign in to the VM through Bastion, then run:

```powershell
Z:\restore-databases.ps1
```

The script restores `.bak` files with dbatools and `-WithReplace`. Review the file share contents before running it.

## Local Validation

Run:

```powershell
.\scripts\Test-Local.ps1 -ConfigFile .\config.local.yaml
```

The check parses PowerShell files, validates the module manifest, checks `VERSION` alignment, validates the config schema, validates config through `-Plan`, runs Pester 5 tests when installed, and runs PSScriptAnalyzer when installed.

For the full local check, install the optional test tooling:

```powershell
Install-Module -Name powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser -Force
Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
```

## Not Implemented Yet

The current tracked toolkit does not yet include:

- VM size, SQL image, or cost estimate commands.
- Built-in sample database restore.
- Config-driven local backup upload.
- First Responder Kit or Maintenance Solution installers.

Those are roadmap items for a future version.
