@{
    RootModule        = 'AzureSqlVmToolkit.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '6CEB2094-8596-4834-94DB-A2E33F53AD9F'
    Author            = 'Kay Sauter'
    CompanyName       = 'Unknown'
    Copyright         = '(c) Kay Sauter. All rights reserved.'
    Description       = 'Lab-focused toolkit for deploying Azure SQL Server VM environments.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'New-AzureSqlVmToolkitDeployment',
        'Test-AzureSqlVmToolkitConfig'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags       = @('Azure', 'SQL', 'SQLVM', 'Bastion', 'KeyVault', 'Lab')
            LicenseUri = 'https://github.com/kaysauter/azure-sqlvm-toolkit/blob/main/LICENSE'
            ProjectUri = 'https://github.com/kaysauter/azure-sqlvm-toolkit'
        }
    }
}
