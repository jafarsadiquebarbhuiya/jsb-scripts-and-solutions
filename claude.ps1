# Variables Configuration
$subscriptionId = "9dc0b1a6-8062-4d72-b39d-7d45d1b38ab6"
$numberOfDeploymentsToKeep = 0

# Set the subscription context
Write-Host "Setting subscription context to: $subscriptionId" -ForegroundColor Yellow
az account set --subscription $subscriptionId

# Check if logged in and subscription is set
$currentSub = az account show --query "id" -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or $currentSub -ne $subscriptionId) {
    Write-Error "Failed to set subscription context. Please ensure you're logged in with 'az login'"
    exit 1
}

Write-Host "Successfully set subscription context" -ForegroundColor Green

# Initialize arrays to store lock information
$allOriginalLocks = @()

Write-Host "`n=== PHASE 1: IDENTIFYING AND REMOVING RESOURCE LOCKS ===" -ForegroundColor Green

try {
    Write-Host "Identifying resource locks across subscription..." -ForegroundColor Cyan
    
    # Get all locks with verbose output for debugging
    Write-Host "Retrieving all locks in subscription..." -ForegroundColor White
    $allLocksJson = az lock list --output json 2>$null
    
    # Debug: Show raw JSON response
    Write-Host "Debug - Raw locks JSON length: $($allLocksJson.Length)" -ForegroundColor Gray
    
    if ($allLocksJson -and $allLocksJson -ne "[]" -and $allLocksJson.Length -gt 2) {
        $allLocks = $allLocksJson | ConvertFrom-Json
        Write-Host "Debug - Parsed $($allLocks.Count) locks from JSON" -ForegroundColor Gray
        
        # Store original lock information for restoration
        foreach ($lock in $allLocks) {
            Write-Host "Debug - Processing lock: $($lock.name) at $($lock.id)" -ForegroundColor Gray
            
            $lockInfo = @{
                id                = $lock.id
                name              = $lock.name
                level             = $lock.level
                notes             = $lock.notes
                resourceId        = ""
                scope             = ""
                resourceGroupName = ""
            }
            
            # Extract resource ID by removing the lock part
            $lockInfo.resourceId = $lock.id -replace "/providers/Microsoft\.Authorization/locks/[^/]+$", ""
            
            # Determine the scope type more accurately
            $idParts = $lock.id -split '/'
            
            if ($idParts.Count -eq 4) {
                # /subscriptions/{id}
                $lockInfo.scope = "subscription"
            }
            elseif ($idParts.Count -eq 6) {
                # /subscriptions/{id}/resourceGroups/{name}
                $lockInfo.scope = "resourcegroup"
                $lockInfo.resourceGroupName = $idParts[4]
            }
            else {
                # Resource level
                $lockInfo.scope = "resource" 
                $lockInfo.resourceGroupName = $idParts[4]
            }
            
            Write-Host "Debug - Lock scope determined: $($lockInfo.scope)" -ForegroundColor Gray
            $allOriginalLocks += $lockInfo
        }
        
        # Categorize for display
        $subscriptionLocks = $allOriginalLocks | Where-Object { $_.scope -eq "subscription" }
        $resourceGroupLocks = $allOriginalLocks | Where-Object { $_.scope -eq "resourcegroup" }
        $resourceLocks = $allOriginalLocks | Where-Object { $_.scope -eq "resource" }
        
        # Display summary of found locks
        $totalLocks = $allOriginalLocks.Count
        Write-Host "`nLock Summary:" -ForegroundColor Green
        Write-Host "- Subscription locks: $($subscriptionLocks.Count)" -ForegroundColor White
        Write-Host "- Resource Group locks: $($resourceGroupLocks.Count)" -ForegroundColor White
        Write-Host "- Resource locks: $($resourceLocks.Count)" -ForegroundColor White
        Write-Host "- Total locks found: $totalLocks" -ForegroundColor Yellow
        
        # Show detailed lock information
        Write-Host "`nDetailed Lock Information:" -ForegroundColor Cyan
        foreach ($lockInfo in $allOriginalLocks) {
            Write-Host "  Lock: $($lockInfo.name) | Level: $($lockInfo.level) | Scope: $($lockInfo.scope)" -ForegroundColor White
            Write-Host "    ID: $($lockInfo.id)" -ForegroundColor Gray
        }
        
        # Remove all locks with better error handling
        Write-Host "`nRemoving all resource locks..." -ForegroundColor Cyan
        
        foreach ($lockInfo in $allOriginalLocks) {
            Write-Host "Removing lock: $($lockInfo.name) (Level: $($lockInfo.level), Scope: $($lockInfo.scope))" -ForegroundColor White
            
            # Try different deletion methods based on scope
            $deleteSuccess = $false
            
            # Method 1: Use lock ID
            Write-Host "  Attempting deletion by ID..." -ForegroundColor Gray
            az lock delete --ids "$($lockInfo.id)" 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ Successfully removed by ID: $($lockInfo.name)" -ForegroundColor Green
                $deleteSuccess = $true
            }
            else {
                # Method 2: Use scope-specific deletion
                Write-Host "  ID deletion failed, trying scope-specific deletion..." -ForegroundColor Gray
                
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
                    Write-Host "  ✅ Successfully removed by scope: $($lockInfo.name)" -ForegroundColor Green
                    $deleteSuccess = $true
                }
                else {
                    Write-Host "  ❌ Failed to remove: $($lockInfo.name)" -ForegroundColor Red
                }
            }
            
            if (-not $deleteSuccess) {
                Write-Warning "Could not remove lock: $($lockInfo.name). Manual intervention may be required."
            }
        }
        
        Write-Host "Lock removal process completed!" -ForegroundColor Green
        
        # Wait longer for Azure to propagate the lock changes
        Write-Host "Waiting for lock changes to propagate..." -ForegroundColor Yellow
        Start-Sleep -Seconds 20
        
        # Verify locks are actually removed
        Write-Host "Verifying locks are removed..." -ForegroundColor Cyan
        $remainingLocksJson = az lock list --output json 2>$null
        if ($remainingLocksJson -and $remainingLocksJson -ne "[]" -and $remainingLocksJson.Length -gt 2) {
            $remainingLocks = $remainingLocksJson | ConvertFrom-Json
            Write-Host "⚠️  Warning: $($remainingLocks.Count) locks still remain!" -ForegroundColor Yellow
            foreach ($lock in $remainingLocks) {
                Write-Host "  Remaining: $($lock.name)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "✅ All locks successfully removed!" -ForegroundColor Green
        }
        
    }
    else {
        Write-Host "No locks found in the subscription." -ForegroundColor Yellow
        $totalLocks = 0
    }
}
catch {
    Write-Error "Error during lock identification/removal: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n=== PHASE 2: DELETING OLD DEPLOYMENTS ===" -ForegroundColor Green

try {
    # Get all resource groups for deployment cleanup
    Write-Host "Retrieving resource groups..." -ForegroundColor Cyan
    $resourceGroupsJson = az group list --query "[].name" -o json 2>$null
    
    if ($resourceGroupsJson -and $resourceGroupsJson -ne "[]") {
        $resourceGroups = $resourceGroupsJson | ConvertFrom-Json
        
        foreach ($rgName in $resourceGroups) {
            Write-Host "`nProcessing deployments in Resource Group: $rgName" -ForegroundColor Cyan
            
            # Get all deployments in the resource group
            $deploymentsJson = az deployment group list --resource-group $rgName --query "[].{name:name,timestamp:properties.timestamp}" -o json 2>$null
            
            if ($deploymentsJson -and $deploymentsJson -ne "[]") {
                $deployments = $deploymentsJson | ConvertFrom-Json | Sort-Object timestamp -Descending
                
                Write-Host "Found $($deployments.Count) total deployments" -ForegroundColor White
                
                if ($deployments.Count -gt $numberOfDeploymentsToKeep) {
                    # Calculate deployments to delete
                    $deploymentsToDelete = $deployments | Select-Object -Skip $numberOfDeploymentsToKeep
                    
                    Write-Host "Keeping $numberOfDeploymentsToKeep most recent deployments" -ForegroundColor Yellow
                    Write-Host "Deleting $($deploymentsToDelete.Count) old deployments" -ForegroundColor Yellow
                    
                    # Delete old deployments with retry logic
                    foreach ($deployment in $deploymentsToDelete) {
                        Write-Host "Deleting deployment: $($deployment.name) (Created: $($deployment.timestamp))" -ForegroundColor White
                        
                        # First attempt with --no-wait
                        az deployment group delete --resource-group $rgName --name $deployment.name --no-wait 2>$null
                        
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "  ✅ Successfully initiated deletion: $($deployment.name)" -ForegroundColor Green
                        }
                        else {
                            Write-Host "  ⚠️  First attempt failed, trying synchronous deletion..." -ForegroundColor Yellow
                            
                            # Second attempt without --no-wait
                            az deployment group delete --resource-group $rgName --name $deployment.name 2>$null
                            
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "  ✅ Successfully deleted (sync): $($deployment.name)" -ForegroundColor Green
                            }
                            else {
                                Write-Warning "❌ Failed to delete deployment: $($deployment.name) - Check for remaining locks or dependencies"
                            }
                        }
                    }
                }
                else {
                    Write-Host "No deployments to delete (total: $($deployments.Count), keeping: $numberOfDeploymentsToKeep)" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "No deployments found in resource group: $rgName" -ForegroundColor Yellow
            }
        }
    }
    
    # Also clean up subscription-level deployments
    Write-Host "`nProcessing subscription-level deployments..." -ForegroundColor Cyan
    $subDeploymentsJson = az deployment sub list --query "[].{name:name,timestamp:properties.timestamp}" -o json 2>$null
    
    if ($subDeploymentsJson -and $subDeploymentsJson -ne "[]") {
        $subscriptionDeployments = $subDeploymentsJson | ConvertFrom-Json | Sort-Object timestamp -Descending
        
        Write-Host "Found $($subscriptionDeployments.Count) subscription-level deployments" -ForegroundColor White
        
        if ($subscriptionDeployments.Count -gt $numberOfDeploymentsToKeep) {
            $subDeploymentsToDelete = $subscriptionDeployments | Select-Object -Skip $numberOfDeploymentsToKeep
            
            Write-Host "Deleting $($subDeploymentsToDelete.Count) old subscription deployments" -ForegroundColor Yellow
            
            foreach ($deployment in $subDeploymentsToDelete) {
                Write-Host "Deleting subscription deployment: $($deployment.name)" -ForegroundColor White
                
                az deployment sub delete --name $deployment.name --no-wait 2>$null
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✅ Successfully initiated deletion: $($deployment.name)" -ForegroundColor Green
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
    if ($allOriginalLocks.Count -gt 0) {
        Write-Host "`nWaiting for deployment deletions to complete before restoring locks..." -ForegroundColor Yellow
        Start-Sleep -Seconds 20
    }
}
catch {
    Write-Error "Error during deployment cleanup: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n=== PHASE 3: RESTORING RESOURCE LOCKS ===" -ForegroundColor Green

try {
    if ($allOriginalLocks.Count -gt 0) {
        Write-Host "Restoring previously identified locks..." -ForegroundColor Cyan
        
        foreach ($lockInfo in $allOriginalLocks) {
            Write-Host "Restoring lock: $($lockInfo.name) (Scope: $($lockInfo.scope))" -ForegroundColor White
            
            # Prepare notes parameter
            $notesParam = if ($lockInfo.notes -and ($lockInfo.notes.ToString().Trim() -ne "")) { 
                $lockInfo.notes.ToString().Trim() 
            }
            else { 
                "Restored by automation script" 
            }
            
            try {
                $restoreSuccess = $false
                
                switch ($lockInfo.scope) {
                    "subscription" {
                        Write-Host "  Restoring subscription lock..." -ForegroundColor Gray
                        az lock create --name "$($lockInfo.name)" --lock-type "$($lockInfo.level)" --notes "$notesParam" --subscription $subscriptionId 2>$null
                    }
                    "resourcegroup" {
                        Write-Host "  Restoring resource group lock..." -ForegroundColor Gray
                        az lock create --name "$($lockInfo.name)" --lock-type "$($lockInfo.level)" --notes "$notesParam" --resource-group "$($lockInfo.resourceGroupName)" 2>$null
                    }
                    "resource" {
                        Write-Host "  Restoring resource lock..." -ForegroundColor Gray
                        az lock create --name "$($lockInfo.name)" --lock-type "$($lockInfo.level)" --notes "$notesParam" --resource "$($lockInfo.resourceId)" 2>$null
                    }
                }
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✅ Successfully restored: $($lockInfo.name)" -ForegroundColor Green
                    $restoreSuccess = $true
                }
                else {
                    Write-Host "  ❌ Failed to restore: $($lockInfo.name)" -ForegroundColor Red
                }
                
                if (-not $restoreSuccess) {
                    Write-Warning "Could not restore lock: $($lockInfo.name). Manual restoration may be required."
                }
            }
            catch {
                Write-Warning "Exception restoring lock $($lockInfo.name): $($_.Exception.Message)"
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
    Write-Warning "Some locks may not have been restored. Please review manually."
}

Write-Host "`n=== SCRIPT EXECUTION COMPLETED ===" -ForegroundColor Green
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "- Original locks found: $($allOriginalLocks.Count)" -ForegroundColor White
Write-Host "- Deployments kept per resource group: $numberOfDeploymentsToKeep" -ForegroundColor White

# Final verification with detailed output
Write-Host "`nFinal Verification..." -ForegroundColor Cyan
$finalLocksJson = az lock list --output json 2>$null
if ($finalLocksJson -and $finalLocksJson -ne "[]" -and $finalLocksJson.Length -gt 2) {
    $finalLocks = $finalLocksJson | ConvertFrom-Json
    Write-Host "Current total locks in subscription: $($finalLocks.Count)" -ForegroundColor Yellow
    
    Write-Host "Current locks:" -ForegroundColor White
    foreach ($lock in $finalLocks) {
        Write-Host "  - $($lock.name) ($($lock.level))" -ForegroundColor Gray
    }
    
    if ($finalLocks.Count -eq $allOriginalLocks.Count) {
        Write-Host "✅ All locks successfully restored!" -ForegroundColor Green
    }
    else {
        Write-Host "⚠️  Lock count mismatch. Original: $($allOriginalLocks.Count), Current: $($finalLocks.Count)" -ForegroundColor Yellow
    }
}
else {
    if ($allOriginalLocks.Count -eq 0) {
        Write-Host "✅ No locks to restore - status correct!" -ForegroundColor Green
    }
    else {
        Write-Host "⚠️  No locks currently in subscription, but $($allOriginalLocks.Count) were expected to be restored" -ForegroundColor Yellow
    }
}

Write-Host "`n🎉 Enhanced script execution completed!" -ForegroundColor Green
