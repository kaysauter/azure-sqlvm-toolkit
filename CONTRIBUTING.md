# Contributing

AzureSqlVmToolkit is beta-stage lab software. Contributions should preserve the current safety posture: no production claims, no secrets in source, Bastion-first access, explicit config validation, and testable PowerShell helpers.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `AzureSqlVmToolkit.psd1`, `AzureSqlVmToolkit.psm1` | Module manifest and root module loader. |
| `Public/` | Public command entry points. Keep this surface small and documented. |
| `scripts/` | Internal validation, naming, deployment, guest setup, release, and test helpers. |
| `tests/` | Pester tests for public commands and internal helpers. |
| `schemas/` | Editor-facing JSON schema for `config.yaml`. |
| `docs-site/` | Astro/Starlight documentation site and Slidev pitch deck. |
| `config.yaml` | Tracked sample config. Do not put real tenant, subscription, secret, or host data here. |
| `RELEASE.md` | Release and nightly snapshot checklist. |

## Local Setup

Install PowerShell 7, Git, Node.js, and the PowerShell modules used by the test workflow:

```powershell
Install-Module -Name Az -Scope CurrentUser -Force
Install-Module -Name powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser -Force
Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
```

Install documentation dependencies when working on `docs-site/`:

```bash
cd docs-site
npm ci
```

## Local Files

Use ignored local files for environment-specific settings:

- `config.local.yaml`
- `*.local.yaml`
- `*.local.md`
- `.env`

Do not commit secrets, generated cost notes, screenshots, terminal output, or config values that reveal Azure tenant, subscription, object, IP, host, account, or secret details.

## Development Workflow

1. Create a focused branch for the change.
2. Keep edits scoped to the behavior or documentation being changed.
3. Update tests when behavior changes.
4. Update `schemas/config.schema.json` when the YAML contract changes.
5. Update root docs and Astro docs when command behavior, config fields, security posture, release behavior, or deployment flow changes.
6. Run the smallest relevant check first, then broader checks before publishing.

Use `-Plan` for no-Azure validation and `-WhatIf` only after signing in to Azure:

```powershell
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -SecurityAssessmentAdvice -Plan

Connect-AzAccount
New-AzureSqlVmToolkitDeployment -ConfigFile .\config.local.yaml -WhatIf
```

## Required Checks

Run the local toolkit check before publishing module, script, config, schema, or test changes:

```powershell
.\scripts\Test-Local.ps1 -ConfigFile .\config.yaml
```

If your `config.local.yaml` is complete and safe to use locally, also run:

```powershell
.\scripts\Test-Local.ps1 -ConfigFile .\config.local.yaml
```

For documentation changes, build the site:

```bash
cd docs-site
npm run build
```

For docs dependency changes, also run:

```bash
cd docs-site
npm audit
```

Always run:

```bash
git diff --check
```

## PowerShell Guidelines

- Keep public commands in `Public/`; put reusable implementation in `scripts/`.
- Prefer structured config validation over late deployment failures.
- Prefer injected scriptblocks for Azure calls in internal helpers so behavior can be tested without live Azure.
- Return structured deployment step results for create/reuse/update/skip/drift decisions.
- Treat `-Plan` and `-WhatIf` as different modes. `-Plan` must not require Azure. `-WhatIf` may read Azure state but must not mutate resources.
- Fail early on unsafe drift. Only auto-update drift when the behavior is explicit and tested.
- Keep compatibility behavior in `vm_creation_with_bastion.ps1` aligned with the module command.

## Security Guidelines

- Keep the VM public IP disabled by default.
- Keep sample `securityRules` empty unless a test intentionally validates rejection behavior.
- Reject broad inbound RDP and SQL rules.
- Do not add passwords, keys, tokens, or tenant-specific identifiers to tracked files.
- Keep Key Vault RBAC behavior explicit.
- Treat `softwareInstalls.packages`, `installScript`, and `logonScript` as trusted code inputs.
- Chocolatey package `sha256` values are enforced through `choco install --checksum`.
- PowerShell Gallery package `sha256` values are rejected because the current install path cannot enforce them.
- Package `sourceUri` values are review/provenance references only, not install sources.
- Prefer prepared images or internal package mirrors for stronger environments.

## Documentation Guidelines

Root docs are for GitHub readers:

- `README.md`: overview, quick start, current capabilities, local checks.
- `Getting-Started.md`: longer setup walkthrough.
- `Security.md`: security posture and limits.
- `Licensing.md`: licensing notes.
- `CONTRIBUTING.md`: developer workflow.
- `RELEASE.md`: release and nightly process.

Astro docs under `docs-site/src/content/docs/` are the public documentation site. Keep them aligned with root docs when behavior changes. Build the site before publishing doc changes.

## Release Guidelines

Keep `VERSION`, `AzureSqlVmToolkit.psd1`, and `CHANGELOG.md` aligned for release work. Follow `RELEASE.md` for version rules, tags, prereleases, and nightly snapshots.

Nightly builds may be incomplete or non-functional. Mark them clearly as prerelease snapshots and do not describe them as supported releases.
