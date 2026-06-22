---
theme: default
title: AzureSqlVmToolkit Pitch
info: |
  A short pitch deck for explaining AzureSqlVmToolkit to beginners, reviewers,
  and teams evaluating Azure SQL Server VM lab automation.
author: Kay Sauter
colorSchema: dark
transition: slide-left
mdc: true
download: false
---

<style>
:root {
	--slidev-theme-primary: #38bdf8;
}

.slidev-layout {
	background:
		radial-gradient(circle at 15% 20%, rgba(56, 189, 248, 0.20), transparent 28rem),
		linear-gradient(135deg, #06111f 0%, #111827 48%, #182033 100%);
	color: #e5edf8;
}

.slidev-layout h1,
.slidev-layout h2 {
	color: #ffffff;
	letter-spacing: 0;
}

.slidev-layout strong {
	color: #7dd3fc;
}

.slidev-layout a {
	color: #7dd3fc;
}

.eyebrow {
	color: #7dd3fc;
	font-size: 0.85rem;
	font-weight: 700;
	letter-spacing: 0.08em;
	text-transform: uppercase;
}

.pitch-grid {
	display: grid;
	gap: 1rem;
	grid-template-columns: repeat(2, minmax(0, 1fr));
	margin-top: 1.5rem;
}

.pitch-card {
	background: rgba(15, 23, 42, 0.72);
	border: 1px solid rgba(148, 163, 184, 0.26);
	border-radius: 8px;
	padding: 1rem;
}

.warning {
	background: rgba(127, 29, 29, 0.72);
	border: 1px solid rgba(252, 165, 165, 0.58);
	border-radius: 8px;
	padding: 1rem;
}

.flow-image {
	background: rgba(255, 255, 255, 0.92);
	border-radius: 8px;
	padding: 1rem;
}

.muted {
	color: #cbd5e1;
}
</style>

<div class="eyebrow">Azure SQL Server VM labs, with fewer sharp edges</div>

# AzureSqlVmToolkit

Create repeatable Azure SQL Server VM learning environments with **clear plans**, **security-minded defaults**, and **beginner-friendly configuration**.

In this deck, we use **AzSQLVMKit** from this point on.

<div class="mt-10 flex items-center gap-8">
	<img :src="'./toolkit-logo.svg'" alt="AzureSqlVmToolkit logo" class="h-32 w-32" />
	<div class="text-2xl muted">A PowerShell-first toolkit for demos, labs, and teaching Azure SQL Server VM concepts.</div>
</div>

---

<div class="eyebrow">The problem</div>

# Azure SQL VM demos are easy to get wrong

<div class="pitch-grid">
	<div class="pitch-card">
		<h3>Too many choices</h3>
		<p>VM size, image, networking, identity, secrets, storage, and naming all arrive at once.</p>
	</div>
	<div class="pitch-card">
		<h3>Hidden risk</h3>
		<p>Public IPs, weak secret workflows, SQL licensing, and surprise cost can hide in a beginner setup.</p>
	</div>
	<div class="pitch-card">
		<h3>Hard to repeat</h3>
		<p>Manual portal work is difficult to review, teach, rerun, or improve over time.</p>
	</div>
	<div class="pitch-card">
		<h3>Too much ceremony</h3>
		<p>Production IaC patterns can be heavy when the immediate goal is a safe learning environment.</p>
	</div>
</div>

---

<div class="eyebrow">The pitch</div>

# A guided SQL Server VM lab factory

AzSQLVMKit turns a short local YAML file into a transparent deployment flow:

1. resolve names and defaults
2. show a plan before doing anything
3. validate security-sensitive choices
4. create the Azure resources
5. help the user connect through Bastion
6. prepare optional samples, tools, and manual restore helpers

---

<div class="eyebrow">Core idea</div>

# Preview first, deploy second

```powershell
New-AzureSqlVmToolkitDeployment `
  -ConfigFile .\config.local.yaml `
  -SecurityAssessmentAdvice `
  -Plan
```

The plan is the conversation starter: it shows generated names, intended resources, security advice, optional features, and backup upload intent before Azure resources are created.

---

<div class="eyebrow">Deployment flow</div>

# From local config to working lab

<div class="flow-image mt-8">
	<img :src="'./toolkit-flow.svg'" alt="AzureSqlVmToolkit deployment flow" />
</div>

---

<div class="eyebrow">What gets deployed</div>

# The useful pieces, assembled together

<div class="pitch-grid">
	<div class="pitch-card"><strong>Compute</strong><br />SQL Server VM with system-assigned managed identity.</div>
	<div class="pitch-card"><strong>Access</strong><br />Azure Bastion for RDP without a VM public IP.</div>
	<div class="pitch-card"><strong>Secrets</strong><br />Key Vault for VM password and storage-key handling.</div>
	<div class="pitch-card"><strong>Storage</strong><br />Azure Files share mounted in the VM for setup artifacts and local backups.</div>
	<div class="pitch-card"><strong>Guest setup</strong><br />Chocolatey, PowerShell helpers, dbatools, and restore scripts.</div>
	<div class="pitch-card"><strong>Optional content</strong><br />Sample databases and community SQL maintenance/diagnostic tools.</div>
</div>

---

<div class="eyebrow">Security posture</div>

# Security-minded defaults, with visible tradeoffs

- no public IP on the VM by default
- Bastion is the intended access path
- Key Vault RBAC is the default secret model
- password generation requires the explicit `-GeneratePassword` flag
- password output requires the explicit `-ShowPassword` flag
- local backup restore is manual in v1, avoiding SYSTEM-user auto-restore

---

<div class="eyebrow">Important status</div>

# Heavy development, not production yet

<div class="warning">
AzSQLVMKit is currently beta-stage software in heavy development. It is intended for demos, labs, and learning environments today. The goal after beta is a production-ready release with stronger validation, tests, documentation, and security review maturity.
</div>

---

<div class="eyebrow">Cost and licensing awareness</div>

# The toolkit should slow people down before spend

- VM size discovery helps users find available sizes before deploying
- SQL image discovery makes edition choices visible
- cost estimates are local reports, not hidden guesswork
- SQL Server licensing remains the user's responsibility
- Microsoft licensing documentation is definitive

---

<div class="eyebrow">Local backup restore v1</div>

# Useful now, conservative by design

The v1 local backup flow uploads selected `.bak`, `.trn`, `.dif`, and `.diff` files to Azure Files, writes a `manifest.json`, and generates `restore-local-backups.ps1`.

The generated script previews by default and restores only when the user runs:

```powershell
.\restore-local-backups.ps1 -Execute
```

---

<div class="eyebrow">Who benefits</div>

# A better first mile for SQL on Azure VMs

<div class="pitch-grid">
	<div class="pitch-card"><strong>Beginners</strong><br />Start from a short config and learn each resource by seeing the plan.</div>
	<div class="pitch-card"><strong>Instructors</strong><br />Repeat the same lab setup across workshops with fewer manual steps.</div>
	<div class="pitch-card"><strong>Reviewers</strong><br />Discuss config, naming, costs, and security posture before deployment.</div>
	<div class="pitch-card"><strong>Future maintainers</strong><br />Use the PowerShell implementation as a bridge toward Bicep or Terraform paths.</div>
</div>

---

<div class="eyebrow">How to explain it in one sentence</div>

# The talk track

> AzSQLVMKit is a PowerShell-first way to create safer, repeatable Azure SQL Server VM lab environments, with plans, defaults, docs, and warnings designed for people who are still learning the platform.

---

<div class="eyebrow">Call to action</div>

# Try the plan, then discuss the tradeoffs

1. clone the repo
2. copy the sample config into an ignored local config
3. run `-Plan`
4. read the security and licensing warnings
5. deploy only when the choices are understood

The project welcomes bug reports, security reports, docs feedback, and production-readiness ideas.
