function New-AzureSqlVmToolkitDeployment {
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
        $arguments.Plan = $Plan.IsPresent
    }

    if ($WhatIfPreference) {
        $arguments.SecurityAssessmentAdvice = $true
    }

    if (-not $Plan -and -not $WhatIfPreference -and -not $PSCmdlet.ShouldProcess($ConfigFile, "Run Azure SQL VM Toolkit deployment")) {
        return
    }

    Invoke-AzureSqlVmToolkitDeployment @arguments -WhatIf:$WhatIfPreference
}
