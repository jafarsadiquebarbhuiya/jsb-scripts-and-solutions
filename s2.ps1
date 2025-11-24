# Set the subscription context
$subscriptionId = "9dc0b1a6-8062-4d72-b39d-7d45d1b38ab6"
az account set --subscription $subscriptionId
Write-Host "Successfully set subscription context" -ForegroundColor Green

# Get list of all resource groups
$resourceGroupsJson = az group list --query "[].name" -o json
$resourceGroups = $resourceGroupsJson | ConvertFrom-Json

foreach ($rgName in $resourceGroups) {
    Write-Host "`nProcessing deployments in Resource Group: $rgName" -ForegroundColor Cyan
    
    # Get deployments for the current group
    $deploymentsJson = az deployment group list --resource-group $rgName --query "[].{name:name}" -o json
    $deployments = $deploymentsJson | ConvertFrom-Json
    
    foreach ($deployment in $deployments) {
        Write-Host "Deleting deployment: $($deployment.name)" -ForegroundColor White
        
        # Delete the deployment without waiting for the operation to finish
        az deployment group delete --resource-group $rgName --name $deployment.name --no-wait 2>$null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ Successfully initiated deletion: $($deployment.name)" -ForegroundColor Green
        }
        else {
            Write-Warning "❌ Failed to delete deployment: $($deployment.name)"
        }
    }
}

Write-Host "Deployment deletion process completed!" -ForegroundColor Green
