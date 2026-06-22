# Azure SQLVM Toolkit

![AI assisted: Codex](https://img.shields.io/badge/AI%20assisted-Codex-111827)
![AI assisted: Claude](https://img.shields.io/badge/AI%20assisted-Claude-D97757)

**Website and documentation:** <https://kaysauter.github.io/azure-sqlvm-toolkit/>

> **Heavy development warning:** AzureSqlVmToolkit is still evolving quickly and is not ready for production use yet. Use it only for demos, labs, and learning environments. Nightly snapshots may be published for visibility and testing, but they can be incomplete or non-functional and should not be treated as releases. Bug reports, security reports, and feature requests are welcome.

AzureSqlVmToolkit ships as a PowerShell module plus YAML config for creating an Azure SQL Server VM lab environment. The original root script remains available as a compatibility entry point.

## Current Capabilities

- Creates or reuses resource groups, VNet, subnet, NSG, NIC, SQL Server VM, Azure Bastion, Key Vault, storage account, and Azure Files share.
- Keeps the SQL VM without a public IP by default. Azure Bastion is the intended RDP path.
- Creates new Key Vaults with RBAC authorization and rejects existing vaults that still use legacy access policies.
- Reuses an existing VM admin password secret from Key Vault by default.
- Generates a lab password only when `-GeneratePassword` is supplied.
- Prints the VM password only when `-ShowPassword` is supplied.
- Uses a system-assigned VM managed identity so the guest can read the storage-key secret.
- Mounts Azure Files in the VM.
- Uploads `restore-databases.ps1` for manual `.bak` restores from the mounted share.
- Provides a module command, no-Azure `-Plan` mode, `-WhatIf` safety mapping, and a local validation script.
- Keeps validation, naming, password, and guest-script helpers in `scripts/AzureSqlVmToolkit.Common.psm1` so they can be tested without deploying Azure resources.

## Quick Start

Install prerequisites:

```powershell
Install-Module -Name Az -Scope CurrentUser -Force
Install-Module -Name powershell-yaml -Scope CurrentUser -Force
```

Create a local config:

```powershell
Copy-Item .\config.yaml .\config.local.yaml
```

Edit `config.local.yaml` before deployment. At minimum, replace placeholder resource names, Key Vault name, storage account name, storage resource group, and VM admin username.

Import the module from the repository:

```powershell
Import-Module .\AzureSqlVmToolkit.psd1 -Force
```

Validate the config:

```powershell
Test-AzureSqlVmToolkitConfig -ConfigFile .\config.local.yaml
```

Preview the resolved plan without Azure calls:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -Plan
```

Deploy with an existing Key Vault password secret:

```powershell
Connect-AzAccount
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice
```

For a disposable lab only, allow the script to generate the missing VM admin password:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -GeneratePassword
```

Use `-ShowPassword` only for controlled demos where console output is acceptable.

## Config Shape

The module and compatibility script read the explicit YAML shape in `config.yaml`. The editor-facing JSON schema is in `schemas/config.schema.json`.

- `resourceGroup`
- `network`
- `securityRules`
- `keyVault`
- `credentials`
- `vm`
- `bastion`
- `storage`
- `softwareInstalls`

The sample config disables the VM public IP and includes no broad inbound RDP or SQL rules:

```yaml
network:
  publicIp:
    enabled: false

securityRules: []
```

If you intentionally enable `network.publicIp.enabled`, keep NSG sources tightly scoped. The script rejects broad inbound `3389` or `1433` rules from `*`, `0.0.0.0/0`, `::/0`, or `Internet`.

## Security Posture

- Do not use this toolkit for production yet.
- Do not put passwords, keys, or tokens in YAML.
- Prefer a pre-created VM admin password secret in Key Vault.
- Treat `-GeneratePassword` as lab/demo convenience only.
- Treat `-ShowPassword` as sensitive console output.
- Review the guest `softwareInstalls.installScript`; it downloads and runs upstream installers inside the VM.
- The storage account key is stored in Key Vault and read by the VM managed identity to mount Azure Files.

See [Security.md](Security.md) for details.

## Local Checks

Run:

```powershell
.\scripts\Test-Local.ps1 -ConfigFile .\config.local.yaml
```

The script parses PowerShell files, validates the module manifest and config schema, validates the config through `-Plan`, runs Pester 5 tests when installed, and runs PSScriptAnalyzer when installed.

For the full local check, install the optional test tooling:

```powershell
Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
```

## Roadmap

These items are documented as goals, not shipped behavior in the tracked toolkit yet:

- Full Azure-aware `-WhatIf` reconciliation for every mutating deployment operation.
- VM size discovery, SQL image discovery, and cost estimate commands.
- Allowlisted sample database installation.
- Config-driven local backup upload with manifest generation.
- Optional First Responder Kit and Ola Hallengren Maintenance Solution installers.
- More mocked and live integration coverage for Azure resource reconciliation.

## Licensing

Review [Licensing.md](Licensing.md) before using SQL Server images or third-party tools. Microsoft SQL Server licensing terms and upstream project licenses remain the user's responsibility.
