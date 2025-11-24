param(
    [string]$SubscriptionId = "xxxxxxxxxxxxxxxxxxxxxxxxxx",
    [int]$DeploymentThreshold = 1,
    [int]$DeleteCount = 1
)

Write-Output "Starting cleanup..."
az account set --subscription $SubscriptionId

Write-Output "Fetching all resource groups..."
$rgs = az group list --subscription $SubscriptionId | ConvertFrom-Json

$allLocks = @()

# Get locks for each RG
foreach ($rg in $rgs) {
    $rgLocks = az lock list -g $rg.name | ConvertFrom-Json
    if ($rgLocks) { $allLocks += $rgLocks }
}

if (-not $allLocks) {
    Write-Output "No locks found. Exiting."
    exit
}

# Group locks by RG
$grouped = $allLocks | Group-Object -Property resourceGroup

foreach ($group in $grouped) {

    $rgName = $group.Name

    Write-Output ""
    Write-Output "==============================="
    Write-Output "Processing Resource Group: $rgName"
    Write-Output "==============================="

    $rgLocks = $group.Group

    # Save lock info
    $savedLocks = foreach ($lock in $rgLocks) {
        [PSCustomObject]@{
            Id    = $lock.id
            Name  = $lock.name
            Level = $lock.level
            Notes = $lock.notes
        }
    }

    # Remove locks
    foreach ($lock in $savedLocks) {
        Write-Output "Removing lock: $($lock.Name)"
        az lock delete --ids $lock.Id | Out-Null
    }

    # Deployment cleanup (correct command)
    Write-Output "Checking deployments..."
    $deployments = az deployment group list -g $rgName | ConvertFrom-Json

    if (-not $deployments) {
        Write-Output "No deployments found. Skipping."
        continue
    }

    $count = $deployments.Count
    Write-Output "Total RG deployments: $count"

    if ($count -ge $DeploymentThreshold) {

        Write-Output "Threshold exceeded. Deleting $DeleteCount oldest deployments..."
        $sorted = $deployments | Sort-Object timestamp

        if ($DeleteCount -gt $sorted.Count) {
            $DeleteCount = $sorted.Count
        }

        $deleteList = $sorted[0..($DeleteCount - 1)]

        foreach ($d in $deleteList) {
            Write-Output "Deleting RG deployment: $($d.name)"
            az deployment group delete -g $rgName -n $($d.name) | Out-Null
        }
    }

    # Reapply locks
    Write-Output "Reapplying locks..."
    foreach ($lock in $savedLocks) {
        az lock create `
            --name $lock.Name `
            --resource-group $rgName `
            --lock-type $lock.Level `
            --notes $lock.Notes | Out-Null
    }

    Write-Output "Completed RG: $rgName"
}

Write-Output ""
Write-Output "Cleanup completed successfully."
