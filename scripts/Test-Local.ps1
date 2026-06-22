[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "config.yaml"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

Write-Host "Running PowerShell parser checks..."
$parseFailures = @()
$files = Get-ChildItem -Path $repoRoot -Recurse -File -Include "*.ps1", "*.psm1" |
    Where-Object {
        $_.FullName -notmatch [regex]::Escape((Join-Path $repoRoot "docs-site")) -and
        $_.FullName -notmatch [regex]::Escape((Join-Path $repoRoot ".git"))
    }

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) {
        $parseFailures += [pscustomobject]@{
            Path  = $file.FullName
            Error = ($errors | Out-String).Trim()
        }
    }
}

if ($parseFailures.Count -gt 0) {
    $parseFailures | Format-List
    throw "PowerShell parser checks failed."
}

Write-Host "Validating module manifest..."
Test-ModuleManifest -Path (Join-Path $repoRoot "AzureSqlVmToolkit.psd1") | Out-Null

Write-Host "Validating config schema JSON..."
Get-Content (Join-Path $repoRoot "schemas/config.schema.json") -Raw | ConvertFrom-Json | Out-Null

Write-Host "Running config validation and plan..."
& (Join-Path $repoRoot "vm_creation_with_bastion.ps1") -ConfigFile $ConfigFile -SecurityAssessmentAdvice -Plan

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($pester) {
    Write-Host "Running Pester tests..."
    Import-Module Pester -MinimumVersion 5.0 -Force
    $pesterConfig = New-PesterConfiguration
    $pesterConfig.Run.Path = @(Join-Path $repoRoot "tests")
    $pesterConfig.Run.Exit = $false
    $pesterConfig.Run.PassThru = $true
    $pesterConfig.Output.Verbosity = "Detailed"
    $pesterResult = Invoke-Pester -Configuration $pesterConfig

    if ($pesterResult.FailedCount -gt 0) {
        throw "Pester tests failed."
    }
}
else {
    Write-Host "Pester 5 is not installed; skipping Pester tests."
}

$scriptAnalyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
if ($scriptAnalyzer) {
    Write-Host "Running PSScriptAnalyzer..."
    $analysis = foreach ($file in $files) {
        Invoke-ScriptAnalyzer -Path $file.FullName -Severity Error,Warning
    }
    $blocking = $analysis | Where-Object {
        $_.Severity -eq "Error" -or
        ($_.Severity -eq "Warning" -and $_.RuleName -ne "PSAvoidUsingWriteHost")
    }

    if ($blocking) {
        $blocking | Format-Table -AutoSize
        throw "PSScriptAnalyzer found blocking issues."
    }

    Write-Host "PSScriptAnalyzer completed. Write-Host warnings are allowed for this interactive deployment script."
}
else {
    Write-Host "PSScriptAnalyzer is not installed; skipping analyzer checks."
}

Write-Host "Local checks completed successfully."
