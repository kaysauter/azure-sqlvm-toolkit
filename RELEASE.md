# Release Process

AzureSqlVmToolkit uses SemVer-style versions in `VERSION` and `AzureSqlVmToolkit.psd1`.

## Version Rules

- Patch: documentation, tests, or compatible fixes.
- Minor: new commands, config fields, or deployment behavior that remains backward-compatible.
- Major: breaking config, command, or deployment behavior.
- Nightly snapshots may be pushed for visibility, but they are not releases and may be incomplete or non-functional.

## Before Tagging

1. Update `VERSION`.
2. Update `AzureSqlVmToolkit.psd1` `ModuleVersion`.
3. Update `CHANGELOG.md`.
4. Run:

```powershell
.\scripts\Test-Version.ps1
.\scripts\Test-Local.ps1 -ConfigFile .\config.yaml
```

5. Build docs if documentation changed:

```bash
cd docs-site
npm ci
npm audit --audit-level=moderate
npm run build
```

## Release Tag

Create a tag that matches `VERSION`:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The `Release toolkit` workflow validates the tag, runs local checks, builds the documentation site, packages the module, and creates a GitHub release.

## Manual Prerelease

Use the `Release toolkit` workflow from GitHub Actions with `prerelease` enabled. The workflow uses the current `VERSION` file and creates the matching `vX.Y.Z` release.

## Nightly Snapshot Guidance

For a nightly, non-functional snapshot:

- Use a branch name such as `nightly/YYYY-MM-DD` or a prerelease version such as `0.3.0-nightly.20260622`.
- Keep the README heavy-development warning visible.
- Mark GitHub releases as prerelease.
- Do not treat nightly artifacts as supported releases.
