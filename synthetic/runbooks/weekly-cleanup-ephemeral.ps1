<#
.SYNOPSIS
  Weekly housekeeping for synthetic Lifecycle=Ephemeral resources.

.DESCRIPTION
  Scheduled weekly by the §13.6 Automation Account. Backstop for
  demo/04-reset.sh — runs whether or not the operator has invoked the
  manual reset. Deletes orphan public IPs produced by the §13.3
  resource_anomaly red-team scenario whose delete step failed, and
  emits an inventory of every Lifecycle=Ephemeral resource in the
  subscription for operator visibility.

  This runbook does not delete TF-managed synthetic resources — those
  are owned by the synthetic Terraform state and the kill-switch
  (var.enable_synthetic_workload=false) tears them down.

  Section 13.6.
#>

$ErrorActionPreference = 'Continue'

Write-Output "==== weekly-cleanup-ephemeral $(Get-Date -Format o) ===="

# ---------------------------------------------------------------------------
# Managed Identity auth
# ---------------------------------------------------------------------------

Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null

$orgPrefix = if ($env:ORG_PREFIX)  { $env:ORG_PREFIX }  else { 'globaris' }
$envName   = if ($env:ENVIRONMENT) { $env:ENVIRONMENT } else { 'poc' }
$redTeamRg = "rg-synthetic-red-team-$orgPrefix-$envName"

# ---------------------------------------------------------------------------
# 1. Orphan public IP sweep (pip-rt-anomaly-* with no ipConfiguration)
# ---------------------------------------------------------------------------

$orphans = @()
try {
    $orphans = Get-AzPublicIpAddress -ResourceGroupName $redTeamRg `
        | Where-Object { $_.Name -like 'pip-rt-anomaly-*' -and -not $_.IpConfiguration }
} catch {
    Write-Warning "Could not list public IPs in ${redTeamRg}: $_"
}

if ($orphans.Count -gt 0) {
    foreach ($pip in $orphans) {
        Write-Output "Deleting orphan PIP $($pip.Name)"
        try {
            Remove-AzPublicIpAddress -ResourceGroupName $pip.ResourceGroupName -Name $pip.Name -Force | Out-Null
        } catch {
            Write-Warning "Delete failed for $($pip.Name): $_"
        }
    }
} else {
    Write-Output "No orphan PIPs found."
}

# ---------------------------------------------------------------------------
# 2. Lifecycle=Ephemeral inventory (visibility only — no deletes)
# ---------------------------------------------------------------------------

$ephemerals = Get-AzResource -TagName Lifecycle -TagValue Ephemeral
Write-Output "Lifecycle=Ephemeral resource inventory: $($ephemerals.Count) found"
foreach ($r in $ephemerals) {
    Write-Output "  $($r.ResourceType) :: $($r.ResourceGroupName) / $($r.Name)"
}

Write-Output "==== weekly-cleanup-ephemeral complete $(Get-Date -Format o) ===="
