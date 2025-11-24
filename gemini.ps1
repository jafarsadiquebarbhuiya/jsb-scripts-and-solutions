# Variables Configuration
$subscriptionId = "9dc0b1a6-8062-4d72-b39d-7d45d1b38ab6"
$numberOfDeploymentsToKeep = 0  # Number of recent deployments to keep per Resource Group

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
                resourceId        = ""
                scope             = ""
                resourceGroupName = ""
            }
            
            $lockInfo.resourceId = $lock.id -replace "/providers/Microsoft\.Authorization/locks/[^/]+$", ""
            $idParts = $lock.id -split '/'
            
            if ($idParts.Count -eq 4) {
                $lockInfo.scope = "subscription"
            }
            elseif ($idParts.Count -eq 6) {
                $lockInfo.scope = "resourcegroup"
                $lockInfo.resourceGroupName = $idParts[4]
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
            
            Write-Host "  Attempting deletion by ID." -ForegroundColor Gray
            az lock delete --ids "$($lockInfo.id)" 2>$null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ Successfully removed by ID: $($lockInfo.name)" -ForegroundColor Green
                $deleteSuccess = $true
            }
            else {
                Write-Host "  ID deletion failed, trying scope-specific deletion." -ForegroundColor Gray
                
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
                    Write-Host " ❌ Failed to remove: $($lockInfo.name)" -ForegroundColor Red
                }
            }
            
            if (-not $deleteSuccess) {
                Write-Warning "Could not remove lock: $($lockInfo.name). Manual intervention may be required."
            }
        }
        
        Write-Host "Lock removal process completed!" -ForegroundColor Green
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
    Write-Host "Retrieving resource groups." -ForegroundColor Cyan
    $resourceGroupsJson = az group list --query "[].name" -o json 2>$null
    
    if ($resourceGroupsJson -and $resourceGroupsJson -ne "[]") {
        $resourceGroups = $resourceGroupsJson | ConvertFrom-Json
        
        foreach ($rgName in $resourceGroups) {
            Write-Host "`nProcessing deployments in Resource Group: $rgName" -ForegroundColor Cyan
            $deploymentsJson = az deployment group list --resource-group $rgName --query "[].{name:name,timestamp:properties.timestamp}" -o json 2>$null
            
            if ($deploymentsJson -and $deploymentsJson -ne "[]") {
                $deployments = $deploymentsJson | ConvertFrom-Json | Sort-Object timestamp -Descending
                
                if ($deployments.Count -gt $numberOfDeploymentsToKeep) {
                    $deploymentsToDelete = $deployments | Select-Object -Skip $numberOfDeploymentsToKeep
                    
                    Write-Host "Deleting $($deploymentsToDelete.Count) old deployments" -ForegroundColor Yellow
                    
                    foreach ($deployment in $deploymentsToDelete) {
                        Write-Host "Deleting deployment: $($deployment.name) (Created: $($deployment.timestamp))" -ForegroundColor White
                        az deployment group delete --resource-group $rgName --name $deployment.name --no-wait 2>$null
                        
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host " ✅ Successfully initiated deletion: $($deployment.name)" -ForegroundColor Green
                        }
                        else {
                            Write-Host " ⚠️  First attempt failed, trying synchronous deletion." -ForegroundColor Yellow
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
                    Write-Host "No deployments to delete (keeping: $numberOfDeploymentsToKeep)" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "No deployments found in resource group: $rgName" -ForegroundColor Yellow
            }
        }
    }
    
    Write-Host "`nProcessing subscription-level deployments." -ForegroundColor Cyan
    $subDeploymentsJson = az deployment sub list --query "[].{name:name,timestamp:properties.timestamp}" -o json 2>$null
    
    if ($subDeploymentsJson -and $subDeploymentsJson -ne "[]") {
        $subscriptionDeployments = $subDeploymentsJson | ConvertFrom-Json | Sort-Object timestamp -Descending
        
        if ($subscriptionDeployments.Count -gt $numberOfDeploymentsToKeep) {
            $subDeploymentsToDelete = $subscriptionDeployments | Select-Object -Skip $numberOfDeploymentsToKeep
            
            Write-Host "Deleting $($subDeploymentsToDelete.Count) old subscription deployments" -ForegroundColor Yellow
            
            foreach ($deployment in $subDeploymentsToDelete) {
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
                    $restoreSuccess = $true
                }
                else {
                    Write-Host " ❌ Failed to restore: $($lockInfo.name)" -ForegroundColor Red
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
