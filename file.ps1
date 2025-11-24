# -----------------------------------------------------------------------------
# Azure Deployment Cleanup & Lock Management Script
# -----------------------------------------------------------------------------

# --- Variables ---
$subscriptionId = "9dc0b1a6-8062-4d72-b39d-7d45d1b38ab6"
$numberOfDeploymentsToKeep = 0  # Number of recent deployments to keep per Resource Group

# -----------------------------------------------------------------------------
# 1. Set Context
# -----------------------------------------------------------------------------
Write-Host "Setting subscription context to subscription is set
$currentSub = az account show --query "id" -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or $currentSub -ne $subscriptionId) {
    Write-Error "Failed to set subscription context. Please ensure you're logged in with 'az login'"
    exit 1
}

Write-Host "Successfully set subscription context" -ForegroundColor Green

# Initialize arrays to store AND REMOVING RESOURCE LOCKS ===" -ForegroundColor Green

try {
    Write-Host "Identifying resource locks across subscription." -ForegroundColor Cyan
    $allLocksJson = az lock list --output json 2>$null
    
    if ($allLocksJson -and $allLocksJson -ne "[]") {
        $allLocks = $allLocksJson | ConvertFrom-Json
        
        foreach ($lock in $allLocks) {
            $lockInfo = @{
                id                = $lock.id
                name              = $lock.name
                level             = $lock.level
                notes             = $lock.notes
                resourceId        = $lock.id -replace "/providers/Microsoft\.Authorization/locks/[^/]+$", ""
                scope             = ""
                resourceGroupName = ""
            }
            
            $idParts = $lock.id -split '/'
            
            if ($idParts.Count -eq 4) {
                $lockInfo.scope = "subscription"
            }
            elseif ($idParts.Count -eq 6) {[4]
            }
            else {
                $lockInfo.scope = "resource" 
                $lockInfo.resourceGroupName = $idParts[4]
            }
            
            $allOriginalLocks += $lockInfo
        }

        Write-Host "Removing all resource locks." -ForegroundColor Cyan
        
        foreach ($lockInfo in $allOriginalLocks) {
            Write-Host "Removing lock: $($lockInfo.name) (Level: $($lockInfo.level), Scope: $($lockInfo.scope))" -ForegroundColor White
            
            $deleteSuccess = $false
            
            # Method 1: Use lock ID
            az lock delete --ids "$($lockInfo.id)" 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host " ✅ Successfully removed by ID: $($lockInfo.name)" -ForegroundColor Green
                $deleteSuccess = $true
            }
            else {
                # Method 2: Use scope-specific deletion
                switch ($lockInfo.scope) {
                    "subscription" {
                        az lock delete --name "$($lockInfo.name)" --subscription $subscriptionId 2>$null
                    }
                    "resourcegroup" {
                        az lock delete --name "$($lockInfo.name)" --resource-group "$($lockInfo.resourceGroupName)" 2>$null
                    }
                    "resource" {
                        az lock delete --name "$($lockInfo.name)" --resource "$($lockInfo.resourceId)" 2>$null
                    }
                }
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host " ✅ Successfully removed by scope: $($lockInfo.name)" -ForegroundColor Green
                    $deleteSuccess = $true
                }
                else {
                    Write-Host " ❌ Failed to remove: $($lockInfo.name)" -ForegroundColor Red
                }
            }

            if (-not $deleteSuccess) {
                Write-Warning "Could not remove lock: $($lockInfo.name). Manual intervention may be required."
            }
        }
        
        Write-Host "Lock removal process completed!" -ForegroundColor Green
        
        # Wait longer for Azure to propagate the lock changes
        Start-Sleep -Seconds 20
    }
    else {
        Write-Host "No locks found in the subscription." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Error during lock identification/removal: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n=== PHASE 2: DELETING OLD DEPLOYMENTS ===" -ForegroundColor Green

try {
    # Get all resource groups for deployment cleanup
    Write-Host "Retrieving resource groups." -ForegroundColor Cyan
    $resourceGroupsJson = az group list --query "[].name" -o json 2>$null
    
    if ($resourceGroupsJson -and $resourceGroupsJson -ne "[]") {
        $resourceGroups = $resourceGroupsJson | ConvertFrom-Json
        
        foreach ($rgName in $resourceGroups) {
            Write-Host "`nProcessing deployments in Resource Group: $rgName" -ForegroundColor Cyan
            
            # Get all deployments in the resource group
            $deploymentsJson = az deployment group list --resource-group $rgName --query "[].{name:name,timestamp:properties.timestamp}" -o json 2>$null
            
            if ($deploymentsJson -and $deploymentsJson -ne "[]") {
                $deployments = $deploymentsJson | ConvertFrom-Json | Sort-Object timestamp -Descending
                
                if ($deployments.Count -gt $numberOfDeploymentsToKeep) {
                    $deploymentsToDelete = $deployments | Select-Object -Skip $numberOfDeploymentsToKeep
                    
                    Write-Host "Deleting $($deploymentsToDelete.Count) old deployments" -ForegroundColor Yellow
                    
                    foreach ($deployment in $deploymentsToDelete) {
                        Write-Host "Deleting deployment: $($deployment.name) (Created: $($deployment.timestamp))" -ForegroundColor White
                        
                        # First attempt with --no-wait
                        az deployment group delete --resource-group $rgName --name $deployment.name --no-wait 2>$null
                        
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host " ✅ Successfully initiated deletion: $($deployment.name)" -ForegroundColor Green
                        }
                        else {
                            Write-Host " ⚠️  First attempt failed, trying synchronous deletion." -ForegroundColor Yellow
                            
                            # Second attempt without --no-wait
                            az deployment group delete --resource-group $rgName --name $deployment.name 2>$null
                            
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host " ✅ Successfully deleted (sync): $($deployment.name)" -ForegroundColor Green
                            }
                            else {
                                Write-Warning "❌ Failed to delete deployment: $($deployment.name) - Check for remaining locks or dependencies"
                            }
                        }
                    }
                }
                else {
                    Write-Host "No deployments to delete (
    }
    
    # Also clean up subscription-level deployments
    Write-Host "`nProcessing subscriptionname:name,timestamp:properties.timestamp}" -o json 2>$null
    
    if ($subDeploymentsJson -and $subDeploymentsJson -ne "[]") {
        $subscriptionDeployments = $subDeploymentsJson | ConvertFrom-Json | Sort-Object timestamp -Descending
        
        if ($subscriptionDeployments.Count -gt $numberOfDeploymentsToKeep) {
            $subDeploymentsToDelete = $subscriptionDeployments | Select-Object -Skip $numberOfDeploymentsToKeep
            
            Write-Host "Deleting $($submentsToDelete) {
                Write-Host "Deleting subscription deployment: $($deployment.name)" -ForegroundColor White
                
                az deployment sub delete --name $deployment.name --no-wait 2>$null
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host " ✅ Successfully initiated deletion: $($deployment.name)" -ForegroundColor Green
                }
                else {
                    Write-Warning "❌ Failed to delete subscription deployment: $($deployment.name)"
                }
            }
        }
        else {
            Write-Host "No subscription deployments to delete" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "No subscription-level deployments found" -ForegroundColor Yellow
    }
    
    # Wait for deployment deletions to complete
    Start-Sleep -Seconds 20
}
catch {
    Write-Error "Error during deployment cleanup: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n=== PHASE 3: RESTORING RESOURCE LOCKS ===" -ForegroundColor Green

try {
    if ($allOriginalLocks.Count -gt 0) {
        Write-Host "Restoring previously identified locks." -ForegroundColor Cyan
        
        foreach ($lockInfo in $allOriginalLocks) {
            Write-Host "Restoring lock: $($lockInfo.name) (Scope: $($lockInfo.scope))" -ForegroundColor White
            
            # Prepare notes parameter
            $notesParam = if ($lockInfo.notes -and ($lockInfo.notes.ToString().Trim() -ne "")) { 
                $lockInfo.notes.ToString().Trim() 
            }
            else { 
                "Restored by automation script" 
            }
            
            switch ($lockInfo.scope) {
                "subscription" {
                    az lock create --name "$($lockInfo.name)" --lock-type "$($lockInfo.level)" --notes "$notesParam" --subscription $subscriptionId 2>$null
                }
                "resourcegroup" {
                    az lock create --name "$($lockInfo.name)" --lock-type "$($lockInfo.level)" --notes "$notesParam" --resource-group "$($lockInfo.resourceGroupName)" 2>$null
                }
                "resource" {
                    az lock create --name "$($lockInfo.name)" --lock-type "$($lockInfo.level)" --notes "$notesParam" --resource "$($lockInfo.resourceId)" 2>$null
                }
            }
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host " ✅ Successfully restored: $($lockInfo.name)" -ForegroundColor Green
            }
            else {
                Write-Warning "❌ Failed to restore: $($lockInfo.name)"
            }
        }
        
        Write-Host "Lock restoration process completed!" -ForegroundColor Green
    }
    else {
        Write-Host "No locks to restore." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Error during lock restoration: $($_.Exception.Message)"
}

Write-Host "`n=== SCRIPT EXECUTION COMPLETED ===" -ForegroundColor Green
