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
        [switch]$Plan,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ErrorLogPath
    )

    $diagnosticContext = @{
        Phase        = "Initialization"
        ResourceType = $null
        ResourceName = $null
    }
    $arguments = @{
        ConfigFile        = $ConfigFile
        DiagnosticContext = $diagnosticContext
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

    $resolvedErrorLogPath = $null
    if ($PSBoundParameters.ContainsKey("ErrorLogPath")) {
        $resolvedErrorLogPath = Resolve-ToolkitErrorLogPath -Path $ErrorLogPath
    }

    $runId = [guid]::NewGuid().ToString()
    $mode = if ($Plan) { "Plan" } elseif ($WhatIfPreference) { "WhatIf" } else { "Deployment" }
    $toolkitVersion = if ($MyInvocation.MyCommand.Module -and $MyInvocation.MyCommand.Module.Version) {
        $MyInvocation.MyCommand.Module.Version.ToString()
    }
    else {
        $null
    }

    try {
        Invoke-AzureSqlVmToolkitDeployment @arguments -WhatIf:$WhatIfPreference
    }
    catch {
        $deploymentError = $_
        if ($resolvedErrorLogPath) {
            try {
                Write-ToolkitErrorLog `
                    -ErrorRecord $deploymentError `
                    -Path $resolvedErrorLogPath `
                    -RunId $runId `
                    -Mode $mode `
                    -DiagnosticContext $diagnosticContext `
                    -ToolkitVersion $toolkitVersion | Out-Null
                $displayLogPath = Protect-ToolkitDiagnosticText -Text ([System.IO.Path]::GetFileName($resolvedErrorLogPath))
                Write-ToolkitError -Message "Deployment failed. Sanitized diagnostics were written to '$displayLogPath' with run ID '$runId'."
            }
            catch {
                try {
                    $logErrorMessage = Protect-ToolkitDiagnosticText -Text $_.Exception.Message
                    Write-Warning "Unable to write the deployment error log: $logErrorMessage" -WarningAction Continue
                }
                catch {
                    [System.Diagnostics.Debug]::WriteLine("Unable to emit the error-log failure warning.")
                }
            }
        }

        $PSCmdlet.ThrowTerminatingError($deploymentError)
    }
}
