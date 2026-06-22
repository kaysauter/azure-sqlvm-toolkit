# Azure SQLVM Toolkit

![AI assisted: Codex](https://img.shields.io/badge/AI%20assisted-Codex-111827)
![AI assisted: Claude](https://img.shields.io/badge/AI%20assisted-Claude-D97757)

Automate a SQL Server VM development environment on Azure from a YAML config and a PowerShell module. The toolkit creates or reuses the Azure resources around the VM, keeps Bastion-first access as the default, stores operational secrets in Key Vault, mounts Azure Files inside the guest, and can optionally install sample databases and SQL community tooling.

**Website and documentation:** <https://kaysauter.github.io/azure-sqlvm-toolkit/>

> **Heavy development warning:** AzureSqlVmToolkit is still evolving quickly and is not ready for production use yet. Use it only for demos, labs, and learning environments. Nightly snapshots may be published for visibility and testing, but they can be incomplete or non-functional and should not be treated as releases. Bug reports, security reports, and feature requests are welcome.

## Current capabilities

- Deploys a SQL Server VM with a generated or configured naming model.
- Uses SQL Server 2022 Developer on Windows Server 2022 by default.
- Creates resource groups, VNet, subnet, NSG, NIC, SQL VM, Azure Bastion, Key Vault, storage account, and Azure Files share.
- Keeps the VM without a public IP by default; Azure Bastion is the intended RDP path.
- Requires Key Vault RBAC authorization and rejects legacy Key Vault access-policy mode.
- Uses a system-assigned VM managed identity so the guest can read only the storage-key secret it needs.
- Mounts Azure Files in the VM and uploads `restore-databases.ps1` for manual `.bak` restores from the mounted share.
- Optionally uploads local `.bak`, `.trn`, `.dif`, and `.diff` files to Azure Files and generates a manual restore script.
- Optionally downloads and restores allowlisted sample databases with `-InstallSampleDb`.
- Optionally installs Brent Ozar's First Responder Kit with `-InstallFirstResponderKit`.
- Optionally installs Ola Hallengren's SQL Server Maintenance Solution with `-InstallMaintenanceSolution`.
- Provides VM size discovery, SQL image discovery, subscription-aware cost estimates, config validation, name resolution, security assessment output, `-Plan`, and `-WhatIf`.
- Aims for idempotent reruns by creating missing resources and reusing existing ones where possible. Full drift correction is not implemented yet.

Review [Security](Security.md) and [Licensing](Licensing.md) before using the toolkit outside a disposable lab.

## Quick start

Install the PowerShell dependencies:

```powershell
Install-Module -Name Az -Scope CurrentUser -Force
Install-Module -Name powershell-yaml -Scope CurrentUser -Force
Get-Module -ListAvailable -Name Az
Get-Module -ListAvailable -Name powershell-yaml
```

Copy the sample config to an ignored local config:

```powershell
Copy-Item .\config.yaml .\config.local.yaml
```

Start with a minimal config:

```yaml
project:
  name: "sqlvm-demo"
  environment: "dev"
  location: "Switzerland North"
  uniqueSuffix: "demo01"
```

Import the toolkit from this repository:

```powershell
Import-Module .\AzureSqlVmToolkit.psd1 -Force
Get-Module -Name AzureSqlVmToolkit
Get-Command -Module AzureSqlVmToolkit
```

Discover VM and SQL image options, then export a local cost estimate:

```powershell
Connect-AzAccount
Get-AzureSqlVmToolkitVmSize -Location "Switzerland North" -Category GeneralPurpose -MinVcpu 4 -MinMemoryGB 16 -IncludeCost
Get-AzureSqlVmToolkitSqlImage -Location "Switzerland North" -SqlVersion 2022 -Edition Developer
Export-AzureSqlVmToolkitCostEstimate -ConfigFile .\config.local.yaml -OutputPath .\cost-estimate.local.md
```

Preview, dry-run, and deploy:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -GeneratePassword -Plan
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -GeneratePassword -WhatIf
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -GeneratePassword
```

Cost reports should stay local. The repository ignores `*.local.md`, `config.local.yaml`, and `*.local.yaml`.

## Configuration model

The recommended config is sparse. Required values are intentionally few:

- `project.name`
- `project.location`

Recommended values:

- `project.environment`
- `project.uniqueSuffix`

Everything else has a default. Add values only when you want to change the default, or use `naming.overrides` when you need specific resource names:

```yaml
naming:
  overrides:
    resourceGroupName: "rg-my-existing-lab"
    keyVaultName: "kv-my-existing-lab-42"
    storageAccountName: "stmyexistinglab42"
```

Legacy explicit configs using `resourceGroup.name`, `keyVault.name`, and `storage.accountName` still work.

Optional local backup upload is configured in YAML rather than with a deployment flag:

```yaml
localBackups:
  enabled: true
  uploadRoot: "local-backups"
  replaceExisting: false
  sources:
    - name: "demo"
      path: "C:\\SqlBackups\\Demo"
      recurse: true
      include:
        - "*.bak"
        - "*.trn"
        - "*.dif"
        - "*.diff"
```

When enabled, deployment uploads matching backup files to Azure Files and creates `restore-local-backups.ps1` beside them. Run that generated script inside the VM without parameters to preview the restore, then with `-Execute` to restore.

## Complete flag reference

PowerShell common parameters such as `-Verbose`, `-Debug`, and `-ErrorAction` are inherited by advanced functions and are not repeated in every table. `-WhatIf` and `-Confirm` are listed where the command supports PowerShell `ShouldProcess`.

### `New-AzureSqlVmToolkitDeployment`

Main deployment command.

```powershell
New-AzureSqlVmToolkitDeployment `
  [-ConfigFile <string>] `
  [-SecurityAssessmentAdvice] `
  [-ShowPassword] `
  [-GeneratePassword] `
  [-Plan] `
  [-InstallSampleDb <string[]>] `
  [-InstallFirstResponderKit] `
  [-FirstResponderKitDatabase <string>] `
  [-InstallMaintenanceSolution] `
  [-MaintenanceSolutionDatabase <string>] `
  [-InstallMaintenanceSolutionJobs] `
  [-MaintenanceSolutionBackupLocation <string>] `
  [-MaintenanceSolutionCleanupTime <int>] `
  [-WhatIf] `
  [-Confirm]
```

| Flag | Default | Notes |
| --- | --- | --- |
| `-ConfigFile` | `config.yaml` | YAML config to use. |
| `-SecurityAssessmentAdvice` | off | Prints security findings before plan, WhatIf, or deployment. With an Azure context, WhatIf/deploy also checks selected existing Azure NIC public-IP and NSG exposure. |
| `-ShowPassword` | off | Prints the VM admin password at the end of deployment. Use only for controlled demos. |
| `-GeneratePassword` | off | Allows the toolkit to generate a missing VM admin password in PowerShell and store it in Key Vault. Without this flag, a missing password secret stops deployment. |
| `-Plan` | off | Prints a config-derived deployment plan and exits. Does not query Azure. |
| `-InstallSampleDb` | none | Downloads and restores selected allowlisted sample databases inside the VM. Alias: `-InstallSampleDatabase`. |
| `-InstallFirstResponderKit` | off | Installs Brent Ozar's First Responder Kit diagnostic stored procedures. Aliases: `-InstallBrentOzarScripts`, `-InstallBrentOzarFirstResponderKit`. |
| `-FirstResponderKitDatabase` | `master` | Database where First Responder Kit procedures are installed. |
| `-InstallMaintenanceSolution` | off | Installs Ola Hallengren's SQL Server Maintenance Solution stored procedures. Aliases: `-InstallOlaHallengrenScripts`, `-InstallOlaMaintenanceSolution`. |
| `-MaintenanceSolutionDatabase` | `master` | Database where Maintenance Solution objects are installed. |
| `-InstallMaintenanceSolutionJobs` | off | Also installs SQL Agent jobs for maintenance tasks. Review schedules and backup storage first. |
| `-MaintenanceSolutionBackupLocation` | empty | Backup root path for Maintenance Solution SQL Agent jobs. Only used when jobs are installed. |
| `-MaintenanceSolutionCleanupTime` | `0` | Backup retention in hours for Maintenance Solution cleanup jobs. Valid range: `0` to `100000`. |
| `-WhatIf` | off | Dry-runs mutating operations through PowerShell `ShouldProcess`. |
| `-Confirm` | PowerShell default | Prompts before mutating operations when confirmation is requested. |

Allowed `-InstallSampleDb` values:

- `AdventureWorks2022`
- `AdventureWorksLT2022`
- `AdventureWorksDW2022`
- `WideWorldImporters`
- `StackOverflowMini`
- `ChicagoParkingTickets`
- `Contoso10K`

### Read-only discovery and planning commands

| Command | Flags |
| --- | --- |
| `Get-AzureSqlVmToolkitVmSize` | `-Location <string>` required, `-Category <string[]>`, `-MinVcpu <int>`, `-MinMemoryGB <int>`, `-IncludeRestricted`, `-IncludeCost`, `-MonthlyHours <int>`, `-PriceSheetItem <object[]>` advanced test hook. |
| `Get-AzureSqlVmToolkitSqlImage` | `-Location <string>` required, `-SqlVersion <string>`, `-Edition <string[]>`, `-Offer <string>`, `-PublisherName <string>`. |
| `Get-AzureSqlVmToolkitCostEstimate` | `-ConfigFile <string>`, `-Config <object>`, `-MonthlyHours <int>`, `-PriceSheetItem <object[]>` advanced test hook, `-SubscriptionName <string>` advanced test hook, `-SubscriptionId <string>` advanced test hook. |
| `Import-AzureSqlVmToolkitConfig` | `-ConfigFile <string>`. |
| `Get-AzureSqlVmToolkitSampleDatabase` | No toolkit-specific flags. |
| `Resolve-AzureSqlVmToolkitNames` | `-ConfigFile <string>`, `-Config <object>`. |
| `Test-AzureSqlVmToolkitConfig` | `-ConfigFile <string>`, `-Config <object>`. |
| `Test-AzureSqlVmToolkitSecurity` | `-ConfigFile <string>`, `-Config <object>`, `-GeneratePassword`, `-ShowPassword`. |
| `Write-AzureSqlVmToolkitSecurityAssessment` | `-Assessment <object[]>` required. |

Allowed `-Category` values for `Get-AzureSqlVmToolkitVmSize`:

- `Burstable`
- `GeneralPurpose`
- `ComputeOptimized`
- `MemoryOptimized`
- `StorageOptimized`
- `GPU`
- `HighPerformanceCompute`
- `Unknown`

Allowed `-Edition` values for `Get-AzureSqlVmToolkitSqlImage`:

- `Developer`
- `Express`
- `Web`
- `Standard`
- `Enterprise`
- `Unknown`

`-MonthlyHours` accepts `1` to `8784`. The default is `730`.

### Cost estimate export command

```powershell
Export-AzureSqlVmToolkitCostEstimate `
  [-ConfigFile <string>] `
  [-Config <object>] `
  [-Estimate <object>] `
  [-OutputPath <string>] `
  [-MonthlyHours <int>] `
  [-Force] `
  [-WhatIf] `
  [-Confirm]
```

| Flag | Default | Notes |
| --- | --- | --- |
| `-ConfigFile` | `config.yaml` | YAML config to estimate when `-Config` or `-Estimate` is not supplied. |
| `-Config` | none | In-memory config object. |
| `-Estimate` | none | Existing estimate object from `Get-AzureSqlVmToolkitCostEstimate`. |
| `-OutputPath` | `.\cost-estimate.local.md` | Markdown report path. Prefer ignored `*.local.md` files. |
| `-MonthlyHours` | `730` | Hours used when generating a new estimate. Valid range: `1` to `8784`. |
| `-Force` | off | Overwrite an existing output file. |
| `-WhatIf` | off | Shows the report write operation without writing the file. |
| `-Confirm` | PowerShell default | Prompts before writing when confirmation is requested. |

### Helper scripts and generated guest scripts

| Script | Flags |
| --- | --- |
| `.\examples\vm_creation_with_bastion.ps1` | Compatibility wrapper. Supports the same deployment flags as `New-AzureSqlVmToolkitDeployment`, including `-WhatIf`. Prefer the module command for automation. |
| `.\scripts\Test-Local.ps1` | `-ConfigFile <string>`. Parses PowerShell files, validates the manifest and config, resolves names, runs `-Plan`, and runs Pester or PSScriptAnalyzer when installed. |
| `restore-local-backups.ps1` inside the VM | `-Execute`. Without `-Execute`, it previews the restore command shape. With `-Execute`, it runs `Restore-DbaDatabase`. |

## Common workflows

List optional sample databases:

```powershell
Get-AzureSqlVmToolkitSampleDatabase
```

Install one or more sample databases during deployment:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -InstallSampleDb AdventureWorks2022, StackOverflowMini
```

Install Brent Ozar's First Responder Kit:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -InstallFirstResponderKit `
  -FirstResponderKitDatabase master
```

Install Ola Hallengren's SQL Server Maintenance Solution without jobs:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -InstallMaintenanceSolution `
  -MaintenanceSolutionDatabase master
```

Install Maintenance Solution jobs only after reviewing backup storage and retention:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -InstallMaintenanceSolution `
  -InstallMaintenanceSolutionJobs `
  -MaintenanceSolutionBackupLocation "Z:\SqlBackups" `
  -MaintenanceSolutionCleanupTime 168
```

## Security posture

- The VM has no public IP by default.
- Azure Bastion is the intended entry point.
- Key Vault RBAC authorization is required.
- Legacy Key Vault access-policy mode is rejected in config and on existing vault reuse.
- Missing VM admin passwords are not generated unless `-GeneratePassword` is supplied.
- VM passwords are stored in Key Vault and are not printed unless `-ShowPassword` is supplied.
- `-SecurityAssessmentAdvice` flags public IP exposure, broad inbound RDP or SQL rules, non-RBAC Key Vault configuration, password-generation posture, password-printing posture, sample downloads, local backup upload, and optional SQL community tools.
- Guest setup downloads installers and upstream scripts for lab convenience. Production use should pin, mirror, or verify approved artifacts before execution.
- Existing resources are reused when found, but full drift correction is not implemented yet. Review `-Plan` and `-WhatIf` before reruns.

## Local testing

Run local checks from the repository root:

```powershell
.\scripts\Test-Local.ps1 -ConfigFile .\config.local.yaml
```

The script parses PowerShell files, validates the module manifest, validates config, resolves names, runs the deployment plan, and runs Pester or PSScriptAnalyzer if those tools are installed.

## More local documentation

- [Getting Started](Getting-Started.md)
- [Security](Security.md)
- [Licensing](Licensing.md)

## Roadmap

The current implementation is PowerShell-first. Future versions may add Bicep and Terraform deployment paths in the same beginner-friendly toolkit, while keeping naming, preview, security guidance, and assessment output consistent across deployment engines.

## License and credits

This project is licensed under the MIT License.

Main developer: Kay Sauter.

Contributors will be credited by name unless consent for that is not given.

Important used projects and sources include dbatools, Chocolatey, Brent Ozar's First Responder Kit, Ola Hallengren's SQL Server Maintenance Solution, Microsoft SQL Server sample databases, Brent Ozar's Stack Overflow database, Daniel Hutmacher's Chicago database, and SQLBI Contoso Data Generator.
