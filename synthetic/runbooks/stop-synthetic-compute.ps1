<#
.SYNOPSIS
  Emergency stop of synthetic compute when the §13.6 cost-guardrails budget
  forecasted notification trips.

.DESCRIPTION
  Triggered by the action group webhook attached to the Forecasted-100%
  notification on the synthetic-layer subscription budget. Authenticates as
  the Automation Account's system-assigned Managed Identity (granted
  Contributor on every synthetic resource group), then:

    1. Stops every currently-executing Container Apps Job in every
       synthetic resource group via the Microsoft.App/jobs/{name}/stop
       management endpoint.
    2. Deallocates every VM tagged Lifecycle=Ephemeral (the §13.4 oversized
       VM is the only one today, but the loop tolerates future additions).

  Section 13.6.
#>

param([object]$WebhookData)

$ErrorActionPreference = 'Continue'
$VerbosePreference = 'Continue'

Write-Output "==== stop-synthetic-compute triggered $(Get-Date -Format o) ===="

if ($WebhookData) {
    Write-Output "Webhook payload size: $($WebhookData.RequestBody.Length) bytes"
}

# ---------------------------------------------------------------------------
# Managed Identity auth
# ---------------------------------------------------------------------------

Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null

# ---------------------------------------------------------------------------
# Resolve synthetic RG names (env-var overrideable)
# ---------------------------------------------------------------------------

$orgPrefix  = if ($env:ORG_PREFIX)  { $env:ORG_PREFIX }  else { 'globaris' }
$envName    = if ($env:ENVIRONMENT) { $env:ENVIRONMENT } else { 'poc' }

$syntheticRgs = @(
    "rg-synthetic-corp-a1-$orgPrefix-$envName"
    "rg-synthetic-online-p1-$orgPrefix-$envName"
    "rg-synthetic-red-team-$orgPrefix-$envName"
    "rg-synthetic-red-team-$orgPrefix-$envName-secondary"
    "rg-synthetic-cost-patterns-$orgPrefix-$envName"
)

# ---------------------------------------------------------------------------
# 1. Stop in-flight Container Apps Jobs
# ---------------------------------------------------------------------------

$token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
$jobApiVersion = '2024-03-01'
$stoppedJobs = 0

foreach ($rg in $syntheticRgs) {
    Write-Output "Scanning RG: $rg"
    $jobs = Get-AzResource -ResourceGroupName $rg -ResourceType 'Microsoft.App/jobs' -ErrorAction SilentlyContinue
    foreach ($job in $jobs) {
        $stopUri = "https://management.azure.com$($job.ResourceId)/stop?api-version=$jobApiVersion"
        Write-Output "  Stopping CAJ $($job.Name) ..."
        try {
            Invoke-RestMethod -Method POST `
                              -Uri $stopUri `
                              -Headers @{ Authorization = "Bearer $token" } `
                              -Body '{}' `
                              -ContentType 'application/json' | Out-Null
            $stoppedJobs++
        } catch {
            Write-Warning "  Stop failed for $($job.Name): $_"
        }
    }
}

Write-Output "Stopped $stoppedJobs Container Apps Jobs."

# ---------------------------------------------------------------------------
# 2. Deallocate Lifecycle=Ephemeral VMs
# ---------------------------------------------------------------------------

$deallocated = 0
$vms = Get-AzVM
foreach ($vm in $vms) {
    if ($vm.Tags -and $vm.Tags['Lifecycle'] -eq 'Ephemeral') {
        Write-Output "Deallocating VM $($vm.Name) (RG: $($vm.ResourceGroupName))"
        try {
            Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -NoWait | Out-Null
            $deallocated++
        } catch {
            Write-Warning "Deallocate failed for $($vm.Name): $_"
        }
    }
}

Write-Output "Deallocated $deallocated VMs."
Write-Output "==== stop-synthetic-compute complete $(Get-Date -Format o) ===="
