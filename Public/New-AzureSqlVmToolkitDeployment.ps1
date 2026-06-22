function New-AzureSqlVmToolkitDeployment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "", Justification = "This public command wraps an interactive deployment script.")]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigFile = "config.yaml",

        [Parameter(Mandatory = $false)]
        [switch]$GeneratePassword,

        [Parameter(Mandatory = $false)]
        [switch]$ShowPassword,

        [Parameter(Mandatory = $false)]
        [switch]$SecurityAssessmentAdvice,

        [Parameter(Mandatory = $false)]
        [switch]$Plan
    )

    $deploymentScript = Join-Path $script:AzureSqlVmToolkitRoot "vm_creation_with_bastion.ps1"
    if (-not (Test-Path $deploymentScript)) {
        throw "Deployment script not found: $deploymentScript"
    }

    $arguments = @{
        ConfigFile = $ConfigFile
    }

    if ($GeneratePassword) {
        $arguments.GeneratePassword = $true
    }

    if ($ShowPassword) {
        $arguments.ShowPassword = $true
    }

    if ($SecurityAssessmentAdvice) {
        $arguments.SecurityAssessmentAdvice = $true
    }

    if ($Plan -or $WhatIfPreference) {
        $arguments.Plan = $true
        if ($WhatIfPreference) {
            $arguments.SecurityAssessmentAdvice = $true
        }

        & $deploymentScript @arguments

        if ($WhatIfPreference) {
            $PSCmdlet.ShouldProcess($ConfigFile, "Run Azure SQL VM Toolkit deployment") | Out-Null
        }
        return
    }

    if ($PSCmdlet.ShouldProcess($ConfigFile, "Run Azure SQL VM Toolkit deployment")) {
        & $deploymentScript @arguments
    }
}
