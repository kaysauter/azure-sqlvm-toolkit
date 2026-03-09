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

### Display the admin password in the console

By default, the generated VM admin password is **not** printed to the console. It is stored securely in Azure Key Vault and can be retrieved from there at any time.

If you explicitly want the password printed to the console (e.g., for a quick demo or local test), use the `-OutputAdminPassword` flag:

```powershell
.\vm_creation_with_bastion.ps1 -OutputAdminPassword
```

> **Security note:** Displaying secrets in console output is not recommended in production environments because the password may be captured in shell history, logs, or screen recordings.

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
  Password: (stored securely in Key Vault 'Your-Key-Vault-Name' as secret 'vm-admin-password')
  Tip: Use -OutputAdminPassword to display the password in the console (not recommended).
```

The admin password is stored in Azure Key Vault and is not displayed by default. To retrieve it, open the Key Vault in the Azure portal and read the secret named after `keyVault.vmAdminPasswordSecretName` in your `config.yaml`.

If you want the password printed directly to the console (for example, during a quick local demo), pass the `-OutputAdminPassword` flag:

```powershell
.\vm_creation_with_bastion.ps1 -OutputAdminPassword
```

> **Security note:** Displaying secrets in console output is not recommended for production use.

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
