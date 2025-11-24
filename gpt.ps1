# Requires: Az.Accounts, Az.Resources
# Connect-AzAccount  # Uncomment if not logged in

# ==============================
# Config
# ==============================
$SubscriptionId = "9dc0b1a6-8062-4d72-b39d-7d45d1b38ab6"
$ResourceGroups = @("demo-rg")   # Add more RGs if needed
$WhatIf = $false         # true = dry run, no changes
$VerboseLogging = $true

# ==============================
# Context
# ==============================
if ($VerboseLogging) {
    Write-Host "Setting context to subscription: $SubscriptionId" -ForegroundColor Cyan
}
Set-AzContext -Subscription $SubscriptionId | Out-Null

# ==============================
# Helper: show current locks on an RG
# ==============================
function Show-RgLocks {
    param(
        [Parameter(Mandatory = $true)][string] $RgName
    )

    Write-Host "Current locks on RG '$RgName':" -ForegroundColor Cyan
    $locks = Get-AzResourceLock -ResourceGroupName $RgName -ErrorAction SilentlyContinue
    if (-not $locks) {
        Write-Host "  (none)" -ForegroundColor DarkYellow
    }
    else {
        $locks | Select-Object Name, ResourceId, LockId, LockLevel, Level, Notes | Format-Table -AutoSize
    }
}

# ==============================
# Main per-RG logic
# ==============================
foreach ($rgName in $ResourceGroups) {

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Processing resource group: $rgName" -ForegroundColor Cyan

    $rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$rgName"

    # 0. Show locks at start
    Show-RgLocks -RgName $rgName

    # ---------------------------------------------------------
    # 1. Get ALL locks under this RG scope
    # ---------------------------------------------------------
    if ($VerboseLogging) {
        Write-Host "Retrieving all locks under scope '$rgScope'..." -ForegroundColor Cyan
    }

    $allLocksInRg = Get-AzResourceLock -Scope $rgScope -ErrorAction SilentlyContinue

    if (-not $allLocksInRg) {
        Write-Host "No locks found under scope '$rgScope'." -ForegroundColor DarkYellow
    }
    else {
        Write-Host "Raw locks returned under '$rgScope': $($allLocksInRg.Count)" -ForegroundColor Green
    }

    # ---------------------------------------------------------
    # 2. Classify locks:
    #    - locks ON the RG itself
    #    - locks under child resources (deployments, etc.)
    # ---------------------------------------------------------
    $rgLevelLocks = @()
    $childResourceLocks = @()

    foreach ($lock in $allLocksInRg) {

        # ResourceId of the lock resource:
        #   /subscriptions/.../resourceGroups/demo-rg/providers/Microsoft.Authorization/locks/<name>
        $lockResourceId = $lock.ResourceId

        # The actual locked scope is the parent of the lock resource:
        #   /subscriptions/.../resourceGroups/demo-rg
        $lockedScope = $lockResourceId -replace "/providers/Microsoft\.Authorization/locks/[^/]+$", ""

        # Determine lock level from LockLevel or Level
        $lockLevel = $null
        if ($lock.PSObject.Properties['LockLevel']) {
            $lockLevel = $lock.LockLevel
        }
        elseif ($lock.PSObject.Properties['Level']) {
            $lockLevel = $lock.Level
        }

        $lockInfo = [PSCustomObject]@{
            LockName    = $lock.Name
            LockId      = $lock.LockId
            LockedScope = $lockedScope
            LockLevel   = $lockLevel
            LockNotes   = $lock.Notes
        }

        if ($lockedScope -ieq $rgScope) {
            $rgLevelLocks += $lockInfo
        }
        else {
            $childResourceLocks += $lockInfo
        }
    }

    Write-Host "Locks whose scope IS the RG:" -ForegroundColor Cyan
    if ($rgLevelLocks.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor DarkYellow
    }
    else {
        $rgLevelLocks | Select-Object LockName, LockedScope, LockLevel | Format-Table -AutoSize
    }

    Write-Host "Locks whose scope is a CHILD resource under the RG:" -ForegroundColor Cyan
    if ($childResourceLocks.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor DarkYellow
    }
    else {
        $childResourceLocks | Select-Object LockName, LockedScope, LockLevel | Format-Table -AutoSize
    }

    # ---------------------------------------------------------
    # 3. Remove RG-level locks (these are the ones blocking RG deployments)
    # ---------------------------------------------------------
    $removedLocks = @()

    if ($rgLevelLocks.Count -gt 0) {
        Write-Host "Removing RG-level locks for '$rgName'..." -ForegroundColor Yellow

        foreach ($l in $rgLevelLocks) {
            if ($WhatIf) {
                Write-Host "[WhatIf] Would remove lock '$($l.LockName)' at scope '$($l.LockedScope)'" -ForegroundColor Yellow
            }
            else {
                Write-Host "Removing lock '$($l.LockName)' at scope '$($l.LockedScope)'" -ForegroundColor Yellow
                # Remove by name+scope, with Force
                Remove-AzResourceLock -LockName $l.LockName -Scope $l.LockedScope -Force -ErrorAction Stop
            }
            $removedLocks += $l
        }
    }
    else {
        Write-Host "No RG-level locks to remove for '$rgName'." -ForegroundColor DarkYellow
    }

    # (Optional) Also remove locks on deployments themselves if you want
    if ($childResourceLocks.Count -gt 0) {
        Write-Host "Removing child-resource locks under '$rgName' (including deployment-level locks)..." -ForegroundColor Yellow

        foreach ($l in $childResourceLocks) {
            if ($WhatIf) {
                Write-Host "[WhatIf] Would remove child lock '$($l.LockName)' at scope '$($l.LockedScope)'" -ForegroundColor Yellow
            }
            else {
                Write-Host "Removing child lock '$($l.LockName)' at scope '$($l.LockedScope)'" -ForegroundColor Yellow
                Remove-AzResourceLock -LockName $l.LockName -Scope $l.LockedScope -Force -ErrorAction Stop
            }
            $removedLocks += $l
        }
    }

    Write-Host "Locks removed in this run for '$rgName': $($removedLocks.Count)" -ForegroundColor Green

    # Show locks after removal
    Show-RgLocks -RgName $rgName

    # ---------------------------------------------------------
    # 4. Delete all deployments in the RG
    # ---------------------------------------------------------
    Write-Host "Looking for deployments in RG '$rgName'..." -ForegroundColor Cyan
    $deployments = Get-AzResourceGroupDeployment -ResourceGroupName $rgName -ErrorAction SilentlyContinue

    if (-not $deployments) {
        Write-Host "No deployments found in RG '$rgName'." -ForegroundColor DarkYellow
    }
    else {
        foreach ($dep in $deployments) {
            if ($WhatIf) {
                Write-Host "[WhatIf] Would remove deployment '$($dep.DeploymentName)' in RG '$rgName'" -ForegroundColor Yellow
            }
            else {
                Write-Host "Removing deployment '$($dep.DeploymentName)' in RG '$rgName'" -ForegroundColor Yellow
                Remove-AzResourceGroupDeployment -ResourceGroupName $rgName -Name $dep.DeploymentName -ErrorAction Stop
            }
        }
    }

    # ---------------------------------------------------------
    # 5. Recreate removed locks
    # ---------------------------------------------------------
    if ($removedLocks.Count -gt 0) {
        Write-Host "Recreating locks that were removed for '$rgName'..." -ForegroundColor Cyan

        foreach ($l in $removedLocks) {
            if ([string]::IsNullOrWhiteSpace($l.LockLevel)) {
                Write-Host "Skipping recreation of lock '$($l.LockName)' at scope '$($l.LockedScope)' because LockLevel is empty." -ForegroundColor Red
                continue
            }

            if ($WhatIf) {
                Write-Host "[WhatIf] Would recreate lock '$($l.LockName)' at scope '$($l.LockedScope)' (Level: $($l.LockLevel))" -ForegroundColor Yellow
            }
            else {
                Write-Host "Recreating lock '$($l.LockName)' at scope '$($l.LockedScope)' (Level: $($l.LockLevel))" -ForegroundColor Yellow
                New-AzResourceLock `
                    -LockName  $l.LockName `
                    -LockLevel $l.LockLevel `
                    -LockNotes $l.LockNotes `
                    -Scope     $l.LockedScope | Out-Null
            }
        }
    }
    else {
        Write-Host "No locks were removed, so nothing to recreate for '$rgName'." -ForegroundColor DarkYellow
    }

    # Final state of locks
    Show-RgLocks -RgName $rgName

    Write-Host "Finished processing RG '$rgName'." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
}

Write-Host "All requested resource groups processed." -ForegroundColor Cyan
