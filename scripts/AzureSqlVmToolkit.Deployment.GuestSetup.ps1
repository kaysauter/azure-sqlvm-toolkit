Set-StrictMode -Version 3.0

# Internal deployment implementation. Import AzureSqlVmToolkit.Deployment.psm1 instead of this file.

function Get-ToolkitGuestInstallScript {
    param([Parameter(Mandatory = $true)][object]$Config)

    $softwareInstalls = Get-ToolkitConfigValue -Config $Config -Path "softwareInstalls"
    $packages = Get-ToolkitConfigValue -Config $softwareInstalls -Path "packages"
    if (-not $packages) {
        return [string](Get-ToolkitConfigValue -Config $softwareInstalls -Path "installScript" -Required)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('$ErrorActionPreference = "Stop"')
    $lines.Add('Set-ExecutionPolicy Bypass -Scope Process -Force')
    $lines.Add('[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12')

    $needsChocolatey = $false
    $needsPowerShellGallery = $false
    foreach ($package in @($packages)) {
        $manager = Get-ToolkitConfigValue -Config $package -Path "manager" -Required
        if ($manager -eq "Chocolatey") {
            $needsChocolatey = $true
        }
        if ($manager -eq "PowerShellGallery") {
            $needsPowerShellGallery = $true
        }
    }

    if ($needsChocolatey) {
        $allowDynamicBootstrap = ConvertTo-BooleanDefault -Value (Get-ToolkitConfigValue -Config $softwareInstalls -Path "allowDynamicBootstrap") -Default $false
        $lines.Add('if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {')
        if ($allowDynamicBootstrap) {
            $bootstrapUrl = Get-ToolkitConfigValue -Config $softwareInstalls -Path "chocolatey.bootstrapUrl"
            if ([string]::IsNullOrWhiteSpace([string]$bootstrapUrl)) {
                $bootstrapUrl = "https://community.chocolatey.org/install.ps1"
            }
            $lines.Add("    `$chocoInstall = Join-Path `$env:TEMP 'install-chocolatey.ps1'")
            $lines.Add("    Invoke-WebRequest -Uri '$bootstrapUrl' -OutFile `$chocoInstall -UseBasicParsing")
            $bootstrapSha256 = Get-ToolkitConfigValue -Config $softwareInstalls -Path "chocolatey.bootstrapSha256"
            if (-not [string]::IsNullOrWhiteSpace([string]$bootstrapSha256)) {
                $lines.Add("    if ((Get-FileHash -Path `$chocoInstall -Algorithm SHA256).Hash -ne '$bootstrapSha256') { throw 'Chocolatey bootstrap SHA-256 mismatch.' }")
            }
            $lines.Add("    & `$chocoInstall")
            $lines.Add("    Remove-Item -Path `$chocoInstall -Force")
            $lines.Add("    `$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')")
        }
        else {
            $lines.Add("    throw 'Chocolatey is required for configured guest packages. Preinstall it in the image or set softwareInstalls.allowDynamicBootstrap to true with a verified bootstrap source.'")
        }
        $lines.Add('}')
    }

    if ($needsPowerShellGallery) {
        $lines.Add("Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force")
        $lines.Add("Set-PSRepository -Name PSGallery -InstallationPolicy Trusted")
    }

    foreach ($package in @($packages)) {
        $manager = Get-ToolkitConfigValue -Config $package -Path "manager" -Required
        $name = Get-ToolkitConfigValue -Config $package -Path "name" -Required
        $version = Get-ToolkitConfigValue -Config $package -Path "version" -Required
        $sha256 = Get-ToolkitConfigValue -Config $package -Path "sha256"
        switch ($manager) {
            "Chocolatey" {
                $command = "choco install $name --version $version -y"
                if (-not [string]::IsNullOrWhiteSpace([string]$sha256)) {
                    $command += " --checksum $sha256 --checksum-type sha256"
                }
                $lines.Add($command)
            }
            "PowerShellGallery" {
                if (-not [string]::IsNullOrWhiteSpace([string]$sha256)) {
                    throw "softwareInstalls.packages[].sha256 is only supported for Chocolatey packages."
                }
                $lines.Add("Install-Module -Name $name -RequiredVersion $version -Scope AllUsers -Force")
            }
        }
    }

    $installScript = Get-ToolkitConfigValue -Config $softwareInstalls -Path "installScript"
    if (-not [string]::IsNullOrWhiteSpace([string]$installScript)) {
        $lines.Add("# Additional configured guest setup")
        $lines.Add([string]$installScript)
    }

    return ($lines -join [Environment]::NewLine)
}

function Ensure-ToolkitGuestSetup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Ensure-* is the internal Azure reconciliation naming convention.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Names,
        [Parameter(Mandatory = $true)][string]$KeyVaultName,
        [Parameter(Mandatory = $false)][object]$StorageContext,
        [scriptblock]$InvokeVmRunCommand = {
            param($ResourceGroupName, $VMName, $ScriptString, $Parameters)
            if ($Parameters) {
                Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName -CommandId "RunPowerShellScript" -ScriptString $ScriptString -Parameter $Parameters
            }
            else {
                Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName -CommandId "RunPowerShellScript" -ScriptString $ScriptString
            }
        },
        [scriptblock]$UploadStorageFile = {
            param($ShareName, $Source, $Path, $Context)
            Set-AzStorageFileContent -ShareName $ShareName -Source $Source -Path $Path -Context $Context -Force
        }
    )

    foreach ($warning in @(Get-ToolkitGuestSetupWarning -Config $Config)) {
        Write-ToolkitWarning -Message $warning
    }

    if (-not $WhatIfPreference -and -not $StorageContext) {
        return Write-ToolkitDeploymentStep -Name "Guest setup" -Status "Skipped" -Message "Storage context is unavailable, so guest setup and restore-helper upload were skipped."
    }

    if ($WhatIfPreference) {
        return Write-ToolkitDeploymentStep -Name "Guest setup" -Status "WouldRun" -Message "Would run guest setup, mount Azure Files, and upload restore helper."
    }

    if ($PSCmdlet.ShouldProcess($Names.VMName, "Run guest software setup")) {
        Write-ToolkitStep -Message "Installing software on VM '$($Names.VMName)'"
        $installScript = Get-ToolkitGuestInstallScript -Config $Config
        $installResult = & $InvokeVmRunCommand $Names.ResourceGroupName $Names.VMName $installScript $null
        Write-ToolkitDetail -Message (($installResult.Value | Out-String).Trim())
    }

    if ($Config.softwareInstalls.logonScript -and $PSCmdlet.ShouldProcess($Names.VMName, "Register logon setup task")) {
        $logonTaskScript = @'
param($LogonScript, $Username)
$ErrorActionPreference = "Stop"
$scriptPath = "C:\setup-logon.ps1"
$selfCleanup = @"
$LogonScript
Unregister-ScheduledTask -TaskName 'SetupLogonTask' -Confirm:`$false
Remove-Item -Path '$scriptPath' -Force
"@
Set-Content -Path $scriptPath -Value $selfCleanup
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $Username
Register-ScheduledTask -TaskName "SetupLogonTask" -Action $action -Trigger $trigger -RunLevel Highest -Force
'@
        $logonResult = & $InvokeVmRunCommand $Names.ResourceGroupName $Names.VMName $logonTaskScript @{
            LogonScript = $Config.softwareInstalls.logonScript
            Username    = $Config.credentials.username
        }
        Write-ToolkitDetail -Message (($logonResult.Value | Out-String).Trim())
    }

    if ($PSCmdlet.ShouldProcess($Names.VMName, "Mount Azure Files share")) {
        Write-ToolkitStep -Message "Mounting file share '\\$($Names.StorageAccountName).file.core.windows.net\$($Names.FileShareName)' as $($Config.storage.driveLetter):\"
        $mountScript = Get-ToolkitMountScript
        $mountResult = & $InvokeVmRunCommand $Names.ResourceGroupName $Names.VMName $mountScript @{
            KeyVaultName       = $KeyVaultName
            SecretName         = $Config.keyVault.storageKeySecretName
            StorageAccountName = $Names.StorageAccountName
            FileShareName      = $Names.FileShareName
            DriveLetter        = $Config.storage.driveLetter
        }
        Write-ToolkitDetail -Message (($mountResult.Value | Out-String).Trim())
    }

    $restoreScriptContent = Get-ToolkitRestoreScriptContent -DriveLetter $Config.storage.driveLetter -BackupPath $Config.storage.backupPath
    $restoreScriptPath = Join-Path $env:TEMP "restore-databases.ps1"
    Set-Content -Path $restoreScriptPath -Value $restoreScriptContent
    try {
        if ($PSCmdlet.ShouldProcess($Names.FileShareName, "Upload restore-databases.ps1")) {
            & $UploadStorageFile $Names.FileShareName $restoreScriptPath "restore-databases.ps1" $StorageContext | Out-Null
        }
    }
    finally {
        Remove-Item $restoreScriptPath -ErrorAction SilentlyContinue
    }

    return Write-ToolkitDeploymentStep -Name "Guest setup" -Status "Updated" -Message "Guest setup completed and restore helper uploaded."
}
