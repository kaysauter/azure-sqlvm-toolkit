# Changelog

All notable changes to AzureSqlVmToolkit are tracked here.

## 0.2.0 - Unreleased

### Added

- Azure-aware deployment reconciliation internals behind `Ensure-*` functions.
- Azure-aware `-WhatIf` path that queries Azure state instead of mapping to the offline `-Plan` path.
- Structured drift result handling for resource groups, virtual networks, subnets, NSGs, NICs, VMs, Bastion, storage, and role assignments.
- Colored CLI output categories for plan, WhatIf, info, success, warning, error, drift, step, and detail messages.
- Structured guest package metadata in `config.yaml` and `schemas/config.schema.json`.
- Generated guest install script support for pinned Chocolatey and PowerShell Gallery package versions.
- `VERSION` source-of-truth file plus manifest version alignment checks.
- GitHub release workflow that validates version metadata, runs local checks, builds docs, packages the module, and creates a release from `vX.Y.Z` tags.
- Contributor guide covering repository layout, local setup, development workflow, checks, security rules, documentation expectations, and release guidance.
- Opt-in `-ErrorLogPath` support for sanitized JSONL diagnostics on terminating plan, WhatIf, and deployment failures.
- Deployment phase and resource context tracking for structured failure diagnostics.

### Changed

- The legacy `vm_creation_with_bastion.ps1` script is now a compatibility wrapper around the module command.
- `New-AzureSqlVmToolkitDeployment -WhatIf` now requires an Azure context because it performs read-only Azure reconciliation.
- The sample guest setup pins package versions for Git, PowerShell, Tabular Editor, and dbatools.
- Deployment orchestration now stops cleanly when critical resource steps are skipped and skips guest setup when storage prerequisites are unavailable.
- Bastion creation now skips cleanly when the Bastion public IP step is skipped.
- GitHub Actions install pinned PowerShell module versions for repeatable test and release runs.
- README and Astro documentation now describe package checksum behavior, contributor workflow, and current development guidance.
- Root and Astro documentation now describe structured error-log usage, automation, and handling requirements.

### Security

- Existing resources with unsafe or immutable drift now fail earlier instead of being silently reused.
- Guest setup now distinguishes pinned package metadata from unverified legacy script execution.
- Chocolatey package `sha256` values are enforced through `choco install --checksum`; PowerShell Gallery package `sha256` values are rejected because the current install path cannot enforce them.
- Diagnostic logs redact known secret patterns, use restrictive file permissions, and preserve the original deployment error if logging fails.

## 0.1.0

### Added

- Initial module manifest and public command surface.
- Config validation, naming helpers, password generation, role-assignment helpers, and guest script builders.
- Local validation script and Pester coverage.
- Documentation site and GitHub Pages deployment workflow.
