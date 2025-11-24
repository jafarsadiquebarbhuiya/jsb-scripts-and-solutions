# Set your specific subscription context
$subscriptionId = "9dc0b1a6-8062-4d72-b39d-7d45d1b38ab6"
az account set --subscription $subscriptionId
Write-Host "Successfully set subscription context" -ForegroundColor Green

# Retrieve all locks in JSON format and convert to PowerShell object
$allLocksJson = az lock list --output json
$allLocks = $allLocksJson | ConvertFrom-Json

foreach ($lock in $allLocks) {
    Write-Host "Removing lock: $($lock.name) (Level: $($lock.lockType), Scope: $($lock.scope))" -ForegroundColor White
    
    # Attempt deletion by ID first
    az lock delete --ids "$($lock.id)" 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✅ Successfully removed by ID: $($lock.name)" -ForegroundColor Green
    }
    else {
        # Fallback: Attempt deletion based on scope if ID deletion fails
        switch ($lock.scope) {
            "subscription" {
                az lock delete --name "$($lock.name)" --subscription $subscriptionId 
            }
            "resourcegroup" {
                az lock delete --name "$($lock.name)" --resource-group "$($lock.resourceGroupName)"
            }
            "resource" {
                az lock delete --name "$($lock.name)" --resource "$($lock.resourceId)"
            }
        }
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ Successfully removed by scope: $($lock.name)" -ForegroundColor Green
        }
        else {
            Write-Host "  ❌ Failed to remove: $($lock.name)" -ForegroundColor Red
        }
    }
}

Write-Host "Lock removal process completed!" -ForegroundColor Green
