# Getting Started

> **Heavy development warning:** AzureSqlVmToolkit is still evolving quickly and is not ready for production use yet. Use it only for demos, labs, and learning environments. Nightly snapshots may be published for visibility and testing, but they can be incomplete or non-functional and should not be treated as releases. Bug reports, security reports, and feature requests are very welcome.

## Prerequisites

1. **PowerShell 7+** with the Azure PowerShell and YAML modules:

   ```powershell
   Install-Module -Name Az -Scope CurrentUser -Force
   Install-Module -Name powershell-yaml -Scope CurrentUser -Force
   Get-Module -ListAvailable -Name Az
   Get-Module -ListAvailable -Name powershell-yaml
   ```

   `Az` is Microsoft's Azure PowerShell module. It does not install `AzureSqlVmToolkit`.

2. **An Azure subscription** with permissions to create resource groups, VMs, Key Vaults, storage accounts, and Bastion hosts.

3. **An active Azure session:**

   ```powershell
   Connect-AzAccount
   ```

   If you have multiple subscriptions, set the one you want:

   ```powershell
   Set-AzContext -SubscriptionName "My Subscription"
   ```

The toolkit requires `powershell-yaml` to parse configuration, but it does not install modules for you.

## Install AzureSqlVmToolkit

### Option 1: use the cloned repository

This is the recommended development workflow today. Clone or open the repository, then import the module manifest by path:

```powershell
Set-Location /Users/kaysauter/Developer/azure-sqlvm-toolkit
Import-Module .\AzureSqlVmToolkit.psd1 -Force
```

Check whether it is imported in the current PowerShell session:

```powershell
Get-Module -Name AzureSqlVmToolkit
Get-Command -Module AzureSqlVmToolkit
```

This does not install the toolkit globally. It only loads the module into the current PowerShell session.

### Option 2: install locally from the repository

If you want `AzureSqlVmToolkit` to show up in `Get-Module -ListAvailable`, copy the module files into your current-user PowerShell module path.

```powershell
$modulePath = ($env:PSModulePath -split [IO.Path]::PathSeparator)[0]
$target = Join-Path $modulePath "AzureSqlVmToolkit"

New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item .\AzureSqlVmToolkit.psd1, .\AzureSqlVmToolkit.psm1, .\config.yaml, .\LICENSE -Destination $target -Force
Copy-Item .\Public, .\Private, .\templates -Destination $target -Recurse -Force
```

Open a new PowerShell session, then check and import by module name:

```powershell
Get-Module -ListAvailable -Name AzureSqlVmToolkit
Import-Module AzureSqlVmToolkit -Force
Get-Command -Module AzureSqlVmToolkit
```

When you change files in the repository, repeat the copy step so the installed local copy stays current. For active development, importing `.\AzureSqlVmToolkit.psd1` by path is simpler.

### Option 3: install from a PowerShell repository

This will work after the toolkit is published to PowerShell Gallery or another registered PowerShell repository:

```powershell
Install-Module -Name AzureSqlVmToolkit -Scope CurrentUser
Import-Module AzureSqlVmToolkit
```

Until then, use Option 1 or Option 2.

## Check module availability

Validate the module manifest:

```powershell
Test-ModuleManifest -Path .\AzureSqlVmToolkit.psd1
```

Check whether it is imported in the current PowerShell session:

```powershell
Get-Module -Name AzureSqlVmToolkit
Get-Command -Module AzureSqlVmToolkit
```

To check whether the module is installed on your PowerShell module path:

```powershell
Get-Module -ListAvailable -Name AzureSqlVmToolkit
```

If that returns nothing, the module is not globally installed. You can still use the cloned repository by importing `.\AzureSqlVmToolkit.psd1`.

## Configuration

The default configuration is intentionally small:

```yaml
project:
  name: "sqlvm-demo"
  environment: "dev"
  location: "Switzerland North"
  uniqueSuffix: "demo01"
```

The toolkit derives resource names from this project block. `-Plan` shows each resolved name and whether it was derived, explicitly configured, or set through `naming.overrides`.

Use overrides only when you need exact names:

```yaml
naming:
  overrides:
    resourceGroupName: "rg-my-existing-lab"
    keyVaultName: "kv-my-existing-lab-42"
    storageAccountName: "stmyexistinglab42"
```

Legacy explicit configs still work, but the sparse `project:` shape is the recommended beginner path.

Copy the sample config to an ignored local config before running previews or deployments:

```powershell
Copy-Item .\config.yaml .\config.local.yaml
```

The repo ignores `config.local.yaml` and the wider `*.local.yaml` pattern. Use `config.local.yaml` for your everyday local config, and use names like `demo.local.yaml` or `switzerland-dev.local.yaml` when you want multiple local variants for different subscriptions, regions, or test scenarios.

The repo also ignores `*.local.md`, `.env`, and `test-results/` for local-only reports, environment values, and generated test output. Local YAML files are for non-secret deployment settings such as project names, regions, suffixes, optional resource-name overrides, sizing choices, and feature flags. Keep passwords, keys, and tokens in Key Vault or another managed secret store.

The toolkit does not generate a missing VM admin password unless you explicitly pass `-GeneratePassword`. That flag is useful for disposable demos and labs, but for production or sensitive environments you should pre-create the Key Vault secret through your approved password generation, storage, and rotation process and omit `-GeneratePassword`.

The toolkit also does not print the VM password to the shell by default. If you intentionally want the password shown in the deployment output for a controlled demo, pass `-ShowPassword`. Treat that as a separate opt-in from `-GeneratePassword`.

Read the standalone [Security](Security.md) and [Licensing](Licensing.md) chapters before using the toolkit outside a disposable lab.

## Choose size, image, and estimate cost

After signing in with `Connect-AzAccount`, use helper commands to discover available VM sizes and SQL Server images for your active subscription and region:

```powershell
Get-AzureSqlVmToolkitVmSize `
  -Location "Switzerland North" `
  -Category GeneralPurpose `
  -MinVcpu 4 `
  -MinMemoryGB 16 `
  -IncludeCost

Get-AzureSqlVmToolkitSqlImage `
  -Location "Switzerland North" `
  -SqlVersion 2022 `
  -Edition Developer
```

Put the selected values in `config.local.yaml`:

```yaml
vm:
  size: "Standard_D4s_v5"
  image:
    publisherName: "MicrosoftSQLServer"
    offer: "sql2022-ws2022"
    skus: "sqldev-gen2"
    version: "latest"
```

Then export a local Markdown cost estimate:

```powershell
Export-AzureSqlVmToolkitCostEstimate `
  -ConfigFile .\config.local.yaml `
  -OutputPath .\cost-estimate.local.md
```

The total includes only matched subscription price-sheet items. Usage-based costs such as Azure Files capacity, transactions, backups, snapshots, disk choices, and bandwidth are listed separately. The repository ignores `*.local.md`, so local cost reports stay out of source control.

## Choose the Bastion SKU

The default config uses Azure Bastion Basic:

```yaml
bastion:
  sku: "Basic"
```

Microsoft's [Azure Bastion overview](https://learn.microsoft.com/en-us/azure/bastion/bastion-overview) and [SKU comparison](https://learn.microsoft.com/en-us/azure/bastion/bastion-sku-comparison) describe four SKUs: Developer, Basic, Standard, and Premium. The toolkit currently creates the dedicated Bastion shape, so use Basic, Standard, or Premium in YAML. Developer uses shared infrastructure and is not a current toolkit deployment shape.

Use `Standard` when you want to evaluate native-client access, file transfer, shareable links, IP-based connections, custom ports, or host scaling. Use `Premium` when audit-oriented features such as session recording or private-only Bastion designs matter, but note that the toolkit only sets the SKU today; those advanced settings still need Azure follow-up.

## Preview the deployment plan

At this point, you should already have installed or imported `AzureSqlVmToolkit` and created `config.local.yaml`.

Run the local checks:

```powershell
.\scripts\Test-Local.ps1 -ConfigFile .\config.local.yaml
```

If you opened a new PowerShell session, import the module again:

```powershell
Import-Module .\AzureSqlVmToolkit.psd1
```

Check the current session:

```powershell
Get-Module -Name AzureSqlVmToolkit
Get-Command -Module AzureSqlVmToolkit
```

Run the deployment plan:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -GeneratePassword -Plan
```

`-Plan` is the beginner-friendly preview. It reads the YAML, prints the deployment plan, and does not query Azure or create resources.

Review any password-related security advice carefully. Without `-GeneratePassword`, the toolkit reuses an existing Key Vault secret and stops if the secret is missing. With `-GeneratePassword`, the built-in password is generated in PowerShell and should not be treated as production-grade. The password is still not printed unless you also pass `-ShowPassword`.

`-WhatIf` uses PowerShell `ShouldProcess`. With an Azure context, it can check existing resources and dry-run each create/update step. Without an Azure context, it falls back to config-derived WhatIf operations.

`-SecurityAssessmentAdvice` flags settings such as a requested VM public IP, internet-sourced RDP or SQL rules, non-RBAC Key Vault configuration, password-generation posture, and password-printing posture. It does not make the PowerShell-generated VM password a production-grade secret.

Existing resources are reused when found. The current toolkit creates missing resources and performs selected checks, but it does not fully reconcile drift on existing VMs, NSGs, Bastion hosts, or storage accounts yet.

The deployment aims to be idempotent: reruns should create missing resources, reuse existing resources, and continue from already-created parts where possible.

## Dry run with WhatIf

After signing in to Azure, run the Azure-aware dry run:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -GeneratePassword -WhatIf
```

## Optional sample databases

You can list the allowlisted sample databases before choosing one:

```powershell
Get-AzureSqlVmToolkitSampleDatabase
```

Preview selected samples in the deployment plan with `-InstallSampleDb`:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -Plan `
  -InstallSampleDb AdventureWorks2022
```

Deploy selected samples with:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -InstallSampleDb AdventureWorks2022
```

You can pass multiple values:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -InstallSampleDb AdventureWorks2022, StackOverflowMini
```

The toolkit downloads the selected database backups inside the VM and restores them to the local SQL Server instance. Reruns skip a restore when the target database already exists.

Only code-defined sample names are accepted. Review each source, license, size, and attribution requirement before deployment. Credit the original publishers and contributors, such as Microsoft, Brent Ozar Unlimited, Daniel Hutmacher, SQLBI, Marco Russo, and Stack Exchange contributors where applicable.

Some samples are large and can increase Azure runtime cost while downloading and restoring. Built-in sample downloads use VM-local storage under `C:\SQLSampleDatabases`; manually uploaded `.bak` files on the mounted Azure Files share consume file-share storage.

## Optional local backups

You can upload one or more local SQL Server backup folders or files to the Azure Files share during deployment. Add `localBackups` to `config.local.yaml`:

```yaml
localBackups:
  enabled: true
  uploadRoot: "local-backups"
  replaceExisting: false
  sources:
    - name: "demo"
      path: "C:\\SqlBackups\\Demo"
      recurse: true
```

By default, the toolkit matches `*.bak`, `*.trn`, `*.dif`, and `*.diff`. Each deployment creates a new timestamped folder under `local-backups`, preflights the Azure Files destination, and refuses to overwrite existing uploaded backup files.

The toolkit uploads `manifest.json` and `restore-local-backups.ps1` beside the backups. Restore execution is manual by design to avoid running database restores as the VM SYSTEM account. After deployment, log into the VM and run the generated script path printed by the toolkit:

```powershell
Z:\local-backups\<timestamp>-<nonce>\restore-local-backups.ps1
Z:\local-backups\<timestamp>-<nonce>\restore-local-backups.ps1 -Execute
```

The first command previews the restore. The second command restores with dbatools. Set `replaceExisting: true` only when you intentionally want the generated script to use dbatools overwrite behavior.

## Optional First Responder Kit

You can also install Brent Ozar's First Responder Kit diagnostic stored procedures, including `sp_Blitz`, `sp_BlitzCache`, `sp_BlitzFirst`, `sp_BlitzIndex`, and related tools:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -Plan `
  -InstallFirstResponderKit
```

Deploy with:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -InstallFirstResponderKit
```

The toolkit installs the First Responder Kit into `master` by default using dbatools inside the VM. To install into a different utility database, use `-FirstResponderKitDatabase`.

Review Brent Ozar Unlimited's source, license, and support expectations before enabling this. The installer downloads and runs upstream SQL scripts during deployment.

## Optional Maintenance Solution

You can install Ola Hallengren's SQL Server Maintenance Solution stored procedures:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -Plan `
  -InstallMaintenanceSolution
```

Deploy with:

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -GeneratePassword `
  -InstallMaintenanceSolution
```

The toolkit installs into `master` by default using dbatools inside the VM. To use a different maintenance database, pass `-MaintenanceSolutionDatabase`.

SQL Agent jobs are separate opt-in:

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

Only enable jobs after reviewing schedules, backup location, retention, and storage capacity. Maintenance backups can consume significant VM disk, Azure Files, or network-share storage.

## Deploy

Only run the real deployment after reviewing `-Plan` and `-WhatIf`:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -GeneratePassword
```

The deployment can take 15 to 20 minutes. For sensitive environments, omit `-GeneratePassword` and use a credential created by your approved secret-management workflow.

## Running the example compatibility script

### Default config

```powershell
.\examples\vm_creation_with_bastion.ps1 -ConfigFile .\config.local.yaml
```

This passes your ignored local config to the example wrapper.

### Custom config file

```powershell
.\examples\vm_creation_with_bastion.ps1 -ConfigFile "path\to\my-config.yaml"
```

Both relative and absolute paths are supported.

The script also supports the module flags:

```powershell
.\examples\vm_creation_with_bastion.ps1 -SecurityAssessmentAdvice -Plan
.\examples\vm_creation_with_bastion.ps1 -SecurityAssessmentAdvice -WhatIf
```

Use `-GeneratePassword` only when you intentionally accept the toolkit's PowerShell-side lab password generator. Without it, the toolkit reuses an existing Key Vault secret and stops if the secret is missing.

Use `-ShowPassword` only for demo scenarios where printing the VM password to the console is acceptable. If the password was created with `-GeneratePassword`, do not rely on that path for production or regulated environments.

AzureSqlVmToolkit requires Key Vault RBAC authorization. Do not set `keyVault.useRbacAuthorization` to `false`; existing Key Vaults that still use legacy access policies must be migrated to RBAC authorization or replaced with an RBAC-enabled vault before deployment.

The sample guest setup lives under `templates/guest/`. It downloads the Chocolatey bootstrap script to disk before executing it. That is safer than piping downloaded content through `Invoke-Expression`, but production scenarios should still pin or verify installer content.

## Local testing

Keep environment-specific Azure values in `config.local.yaml` or another `*.local.yaml` file. Both patterns are ignored by git, so you can keep multiple local configs for different labs, regions, or test scenarios without committing them. Generated cost reports should use a name such as `cost-estimate.local.md`; `*.local.md` is ignored too.

Run non-mutating local checks with:

```powershell
.\scripts\Test-Local.ps1
```

To test your local config without committing it:

```powershell
.\scripts\Test-Local.ps1 -ConfigFile .\config.local.yaml
```

## What happens during deployment

The script runs for roughly 15 to 20 minutes and creates resources in this order:

1. **VM resource group**
2. **Storage resource group**  if it doesn't already exist
3. **Key Vault** in the storage resource group (if it doesn't already exist), using RBAC authorization by default
4. **VM admin password** reused from Key Vault, or generated in PowerShell only when `-GeneratePassword` is supplied for lab/demo convenience
5. **VNet, subnet, NSG, NIC**, without a VM public IP by default
6. **SQL Server VM** with system-assigned managed identity
7. **Azure Bastion** with its own subnet and public IP
8. **Storage account and file share** (if they don't already exist)
9. **Storage key** stored in Key Vault
10. **Software installation** on the VM (Chocolatey, VS Code, Git, dbatools, etc.)
11. **File share mount** as a drive letter on the VM (persists across reboots)
12. **Config-driven local backups** uploaded to Azure Files when `localBackups.enabled` is true
13. **Manual local-backup restore script** generated beside uploaded backups when local backups are enabled
14. **Optional sample database install** when `-InstallSampleDb` is supplied

The default VM image is SQL Server 2022 Developer on Windows Server 2022. Review [Licensing](Licensing.md) and the linked Microsoft terms before deploying SQL Server images for your scenario.

## Output

At the end of the deployment, the module prints:

```
Deployment completed in 00:18:42.

VM Login Credentials:
  Username: youradminusername
  Password secret: vm-admin-password in Key Vault 'Your-Key-Vault-Name'
  Password: not printed. Re-run with -ShowPassword only for demo scenarios.
```

By default the VM password is not printed. Retrieve it securely from Key Vault when needed, or use `-ShowPassword` only for a controlled demo.

If you supplied `-GeneratePassword`, remember that the password was generated in PowerShell. For production or sensitive use, replace this with an approved secret-generation, storage, and rotation workflow.

If the Key Vault name was changed due to a soft-delete conflict, the script will also notify you of the new name.

## Connecting to the VM

1. Go to the Azure portal
2. Navigate to your VM 
3. Click **Connect** > **Bastion**
4. Enter the username from the deployment output and the password from Key Vault

For real environments, use a password that came from your approved secret process rather than the toolkit's PowerShell-generated lab password.

## Restoring databases

For config-driven local backup upload, use `localBackups`. The toolkit prints the generated `restore-local-backups.ps1` path after deployment. Run it once without parameters to preview, then again with `-Execute` to restore.

For ad hoc manual `.bak` files, log into the VM, place the files on the mounted drive (`Z:\`), and run:

```powershell
Z:\restore-databases.ps1
```

This restores all `.bak` files under the configured `storage.backupPath` to the local SQL Server instance using dbatools. Set `storage.backupPath` to `\` for the share root, or to a relative folder path under the mounted drive.

For built-in sample databases, prefer `-InstallSampleDb`; it uses the toolkit's allowlisted catalog and skip-if-existing behavior.

## Project direction

AzureSqlVmToolkit is PowerShell-first today. The module is being shaped so Bicep and Terraform deployment paths can be added later without losing beginner-friendly defaults, explicit secret-generation warnings, or security assessment output.

## License and contributors

This project is MIT licensed. Kay Sauter is the main developer. Contributors will be credited by name unless consent for that is not given.
