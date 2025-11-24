# Variables Configuration
$subscriptionId = "xxxxxxxxxxxxxxxxxxxxxxxxxx"

# Set the subscription context
Write-Host "Setting subscription context to: $subscriptionId" -ForegroundColor Yellow
az account set --subscription $subscriptionId

# Check if logged in and subscription is set
$currentSub = az account show --query "id" -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or $currentSub -ne $subscriptionId) {
    Write-Error "Failed to set subscription context. Please ensure you're logged in with 'az login'."
    exit 1
}
Write-Host "Successfully set subscription context." -ForegroundColor Green

Write-Host "`n=== LOCKING ALL RESOURCES ===" -ForegroundColor Green

# Load all resource groups
$resourceGroupsJson = az group list --query "[].name" -o json
$resourceGroups = $resourceGroupsJson | ConvertFrom-Json

foreach ($rgName in $resourceGroups) {
    Write-Host "Processing Resource Group: $rgName" -ForegroundColor Cyan

    # Get all resources in the resource group
    $resourcesJson = az resource list --resource-group $rgName --query "[].{id:id, name:name}" -o json
    $resources = $resourcesJson | ConvertFrom-Json

    foreach ($resource in $resources) {
        Write-Host "Applying lock to resource: $($resource.name) (ID: $($resource.id))" -ForegroundColor White
        
        # Attempt to create a lock on the resource
        az lock create --name "$($resource.name)-lock" --lock-type "ReadOnly" --resource "$($resource.id)" 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ Successfully applied lock to: $($resource.name)" -ForegroundColor Green
        }
        else {
            Write-Warning "  ❌ Failed to apply lock to: $($resource.name)" 
        }
    }
}

Write-Host "Locking process completed!" -ForegroundColor Green
