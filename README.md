# Azure SQLVM Toolkit

![AI assisted: Codex](https://img.shields.io/badge/AI%20assisted-Codex-111827)
![AI assisted: Claude](https://img.shields.io/badge/AI%20assisted-Claude-D97757)

**Website and documentation:** <https://kaysauter.github.io/azure-sqlvm-toolkit/>

> **Project direction:** Azure SQLVM Toolkit remains the current implementation focused on Azure SQL VM. A broader successor, [Azure Data Lab Toolkit](https://github.com/kaysauter/Azure-Data-Lab-Toolkit), is being started with Azure SQL VM as its first target. It is planned to expand later to Azure SQL Database, Azure SQL Managed Instance, Microsoft Fabric, PostgreSQL, storage, Git and CI/CD integrations, and PowerShell, Bicep, and Terraform deployment engines. This successor functionality has not shipped yet.

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
- Provides a module command, no-Azure `-Plan` mode, Azure-aware `-WhatIf`, and a local validation script.
- Writes sanitized JSONL diagnostics on terminating failures only when `-ErrorLogPath` is supplied.
- Keeps validation, naming, password, release, and guest-script helpers in `scripts/` so they can be tested without deploying Azure resources.
- Uses internal `Ensure-*` functions for Azure create/reuse decisions and early drift handling.
- Tracks release versions through `VERSION`, `AzureSqlVmToolkit.psd1`, `CHANGELOG.md`, and the `Release toolkit` workflow.

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

Preview Azure-aware create/reuse/drift decisions after signing in:

```powershell
Connect-AzAccount
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -WhatIf
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

To capture structured diagnostics for a failed plan, WhatIf, or deployment, opt in with `-ErrorLogPath`:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -Plan `
  -ErrorLogPath .\test-results\errors\deployment.jsonl
```

The toolkit creates the JSONL file only if the command terminates with an error. Use a private, user-controlled directory and review the file before sharing it.

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

The sample `softwareInstalls` section uses structured package metadata for pinned package versions and keeps `installScript` as an additional custom hook.
Chocolatey package `sha256` values are enforced through `choco install --checksum`; PowerShell Gallery package `sha256` values are rejected because the current install path cannot enforce them.
Package `sourceUri` values are review/provenance references only, not install sources.

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
- Treat `-ErrorLogPath` output as sensitive operational data even though known credential patterns are redacted.
- Review `softwareInstalls.packages`, `allowDynamicBootstrap`, and `installScript`; guest setup still runs inside the VM with deployment-time trust in the configured package sources.
- The storage account key is stored in Key Vault and read by the VM managed identity to mount Azure Files.

See [Security.md](Security.md) for details.

## Developing

Developer workflow, repository layout, test expectations, documentation rules, and security guidelines are documented in [CONTRIBUTING.md](CONTRIBUTING.md).

## Local Checks

Run:

```powershell
.\scripts\Test-Local.ps1 -ConfigFile .\config.local.yaml
```

The script parses PowerShell files, validates the module manifest and config schema, validates the config through `-Plan`, runs Pester 5 tests when installed, and runs PSScriptAnalyzer when installed.
It also verifies that `VERSION` matches the module manifest.

For the full local check, install the optional test tooling:

```powershell
Install-Module -Name powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser -Force
Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
```

## Roadmap

These items are documented as goals, not shipped behavior in the tracked toolkit yet:

- VM size discovery, SQL image discovery, and cost estimate commands.
- Allowlisted sample database installation.
- Config-driven local backup upload with manifest generation.
- Optional First Responder Kit and Ola Hallengren Maintenance Solution installers.
- More live integration coverage for Azure resource reconciliation.
- Long-term Bicep and Terraform deployment paths.

## Licensing

Review [Licensing.md](Licensing.md) before using SQL Server images or third-party tools. Microsoft SQL Server licensing terms and upstream project licenses remain the user's responsibility.
