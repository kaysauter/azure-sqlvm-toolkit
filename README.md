# Azure SQLVM toolkit
Automate a fully configured SQL Server VM deployment on Azure using a single PowerShell script driven by a YAML configuration file. Includes Azure Bastion, Key Vault, Azure Files integration, and automated tool installation.

> **Beta Notice:** This project is currently in beta. The code is provided as-is, without any warranty or guarantee of any kind, express or implied. Use at your own risk.

# Automated PowerShell Deployment: Azure SQL Server VM

A single PowerShell script that deploys a fully configured SQL Server 2022 development VM on Azure, including networking, Azure Bastion, Key Vault, Azure Files, and automated software installation.

## What it does

- Provisions a Windows Server edition of your choice, as specified in config.yaml
- Configures Azure Bastion for secure RDP access (no exposed RDP port)
- Creates and manages an Azure Key Vault for secrets (VM password, storage keys)
- Sets up an Azure Files share and mounts it as a drive letter on the VM
- Installs development tools via Chocolatey (VS Code, Git, PowerShell 7, dbatools, etc.)
- Uploads a database restore script for one-command `.bak` file restoration
- Uses managed identity so the VM retrieves secrets at runtime with no hardcoded credentials

## Quick start

Setup your configurations in config.yaml, then run:

```powershell
Connect-AzAccount
.\vm_creation_with_bastion.ps1
```

See [Getting Started](Getting-Started.md) for full prerequisites and setup.

## Important used projects
- [dbatools](https://dbatools.io)
- [Chocolatey](https://chocolatey.org/) 
