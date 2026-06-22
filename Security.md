# Security

AzureSqlVmToolkit is beta-stage lab software. Do not use it for production or regulated environments without a separate security review.

## Current Defaults

The tracked script and sample config now use these safer lab defaults:

- The SQL VM does not receive a public IP unless `network.publicIp.enabled: true`.
- `securityRules` is empty in the sample config.
- Broad inbound RDP and SQL rules are rejected by validation.
- Required YAML fields are schema-checked before any Azure write operation.
- New Key Vaults are created with RBAC authorization.
- Existing legacy access-policy Key Vaults are rejected.
- Missing VM admin passwords are not generated unless `-GeneratePassword` is supplied.
- VM passwords are not printed unless `-ShowPassword` is supplied.
- Azure-aware `-WhatIf` reads existing resources and reports create/reuse/update/drift decisions before writes.

Preview the posture without Azure calls:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -Plan
```

Preview the Azure reconciliation path after signing in:

```powershell
Connect-AzAccount
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -WhatIf
```

## Network Access

Azure Bastion is the intended RDP path. Keep:

```yaml
network:
  publicIp:
    enabled: false

securityRules: []
```

If you enable a VM public IP for a lab, restrict NSG source prefixes to known IP ranges. The script rejects inbound `3389` or `1433` rules from `*`, `0.0.0.0/0`, `::/0`, or `Internet`.

## Password Handling

Preferred flow:

1. Generate the VM admin password through an approved secret workflow.
2. Store it in Key Vault using the name from `keyVault.vmAdminPasswordSecretName`.
3. Run deployment without `-GeneratePassword`.

Lab-only flow:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -GeneratePassword
```

`-GeneratePassword` creates a password in PowerShell and stores it in Key Vault. It is better than committing a password to YAML, but it is not a production-grade credential workflow.

`-ShowPassword` prints the VM password to the console. Use it only for controlled demos because terminal scrollback, logs, screenshots, or shared notes can capture it.

## Key Vault And Identity

New Key Vaults are created with RBAC authorization. The script resolves user and service-principal Azure contexts for Key Vault RBAC assignment. It assigns:

- `Key Vault Secrets Officer` to the signed-in user.
- `Key Vault Secrets User` to the VM managed identity.

The VM managed identity reads the storage-key secret so the guest can mount Azure Files. That storage key is powerful and should be treated as sensitive.

## Guest Setup

The current config contains structured package metadata plus PowerShell hooks that run inside the VM through Azure VM Run Command. The sample pins versions for Git, PowerShell, Tabular Editor, and dbatools. Chocolatey package `sha256` values are enforced when configured; PowerShell Gallery package checksums are rejected because the current install path cannot enforce them.

This is acceptable for demos and learning environments. For higher-trust environments:

- Pin package versions.
- Set `softwareInstalls.allowDynamicBootstrap: false` and use a prepared image or internal package source.
- Mirror or verify installer content and add Chocolatey bootstrap/package SHA-256 values where available.
- Review every command in `softwareInstalls.installScript`.
- Keep `softwareInstalls.logonScript` minimal and trusted.

## Restore Helper

The toolkit uploads `restore-databases.ps1` to the Azure Files share. It restores `.bak` files from the mounted share using dbatools and `-WithReplace`.

The restore helper is manual. Review the share contents before running it in the VM.

## Local Files

Keep local-only files out of commits:

- `config.local.yaml`
- `*.local.yaml`
- `*.local.md`
- `.env`
- screenshots that reveal Azure tenant, subscription, IP, object, or secret values

The repository ignores those local patterns.

## Known Limits

- No production hardening claim.
- No live Azure integration test evidence in CI yet.
- Not every drift state is auto-corrected; unsafe drift is blocked or reported for manual remediation.
- No automated vulnerability scan of guest-installed software.
- No formal penetration test evidence.

Run `.\scripts\Test-Local.ps1` before publishing changes. The check covers parser validation, module manifest validation, version alignment, schema parsing, no-Azure plan validation, Pester tests when available, and PSScriptAnalyzer when available.
