# Getting Started

## Prerequisites

1. **PowerShell 7+** with the Azure PowerShell module:

   ```powershell
   Install-Module -Name Az -Scope CurrentUser -Force
   ```

2. **An Azure subscription** with permissions to create resource groups, VMs, Key Vaults, storage accounts, and Bastion hosts.

3. **An active Azure session:**

   ```powershell
   Connect-AzAccount
   ```

   If you have multiple subscriptions, set the one you want:

   ```powershell
   Set-AzContext -SubscriptionName "My Subscription"
   ```

The script will auto-install the `powershell-yaml` module if it's not present.

## Running the script

### Default config

```powershell
.\vm_creation_with_bastion.ps1
```

This reads `config.yaml` from the same directory as the script.

### Custom config file

```powershell
.\vm_creation_with_bastion.ps1 -ConfigFile "path\to\my-config.yaml"
```

Both relative and absolute paths are supported.

## What happens during deployment

The script runs for roughly 15 to 20 minutes and creates resources in this order:

1. **VM resource group**
2. **Storage resource group**  if it doesn't already exist
3. **Key Vault** in the storage resource group (if it doesn't already exist)
4. **VM admin password** generated and stored in Key Vault
5. **VNet, subnet, NSG, NIC, public IP**
6. **SQL Server VM** with system-assigned managed identity
7. **Azure Bastion** with its own subnet and public IP
8. **Storage account and file share** (if they don't already exist)
9. **Storage key** stored in Key Vault
10. **Software installation** on the VM (Chocolatey, VS Code, Git, dbatools, etc.)
11. **File share mount** as a drive letter on the VM (persists across reboots)
12. **Database restore script** uploaded to the file share

## Output

At the end of the deployment, the script prints:

```
Deployment completed in 00:18:42.

VM Login Credentials:
  Username: youradminusername
  Password: <generated-password>
```
Please note that this is not the recommended way to get the password, especially in production. But for demo purposes, it is printed in the console output. In a production environment, you would typically retrieve the password securely from Key Vault when needed.

If the Key Vault name was changed due to a soft-delete conflict, the script will also notify you of the new name.

## Connecting to the VM

1. Go to the Azure portal
2. Navigate to your VM 
3. Click **Connect** > **Bastion**
4. Enter the username and password from the script output

## Restoring databases

After logging into the VM, place your `.bak` files on the mounted drive (`Z:\`) and run:

```powershell
Z:\restore-databases.ps1
```

This restores all `.bak` files to the local SQL Server instance using dbatools. You may want to adapt the script to specify the correct folder path.
