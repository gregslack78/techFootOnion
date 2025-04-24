param (
    [Parameter(Mandatory = $false)]
    [object]$WebhookData
)

function Login-AzAccount {
    try {
        # This script requires system identity enabled for the automation account with 'Automation Contributor' role assignment on the identity.
        "Logging in to Azure..."
        Connect-AzAccount -Identity
    }
    catch {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

if ($WebhookData) {
    try {

        # Extract the raw body
        Write-Output "Parsing webhook data..."
        # Ensure RequestBody exists before attempting to parse it
        if ($WebhookData.RequestBody -match '({.*?"facets":\[\])') {
            $temp = [regex]::Matches($matches[1], '(\{.*?"data":\[.*?\}\])', 'Singleline')
            $jsonData = $temp.Groups[0].Value
            $jsonData = $jsonData + "}" 
            $json = $jsonData | ConvertFrom-Json
            $data = $json.data
        }
        else {
            throw "Could not find valid JSON block in RequestBody"
        }
        # Continue processing $data...
    }
    catch {
        Write-Error "Error parsing webhook data: $($_.Exception.Message)"
        throw
    }
}

#Get unique assignmentIDs
$uniquePolicyAssignments = @()
$seen = @{}

foreach ($item in $data.policyAssignmentId) {
    #$id = $item.policyAssignmentId
    if (-not $seen.ContainsKey($item)) {
        $seen[$item] = $true
        $uniquePolicyAssignments += $item
    }
}
Write-Output $uniquePolicyAssignments | Format-Table
Write-Output "Found the above $($uniquePolicyAssignments.Count) unique assignment remediation failures"

# Login to Azure
Login-AzAccount

$userToken = (Get-AzAccessToken).Token
$Headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer $($userToken)"
}

foreach ($assignmentId in $uniquePolicyAssignments) {
    #Create remediation name
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $string = "$timestamp$assignmentId"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($string)
    $base64 = [Convert]::ToBase64String($bytes)
    $prefix = $base64.Substring(0, 8)
    $remediationName = "autoRemediate$prefix"

    $body = @{
        properties = @{
            policyAssignmentId = $assignmentId
        }
    }
    $bodyJson = ConvertTo-Json $body -Depth 10 -Compress

    if ($assignmentId -like "*managementgroups*") {
        $segments = $assignmentId -split '/'
        $managementGroupId = $segments[4]
        $url = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$($managementGroupId)/providers/Microsoft.PolicyInsights/remediations/$($remediationName)?api-version=2021-10-01"
        $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $Headers -Body $bodyJson
        Write-Output $response
    }
    elseif ($assignmentId -like "*subscriptions*" -and $assignmentId -notlike "*resourceGroups*") {
        $segments = $assignmentId -split '/'
        $subscriptionId = $segments[2]
        $url = "https://management.azure.com/subscriptions/$($subscriptionId)/providers/Microsoft.PolicyInsights/remediations/$($remediationName)?api-version=2021-10-01"
        $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $Headers -Body $bodyJson
        Write-Output $response
    }
    elseif ($assignmentId -like "*resourcegroups*") {
        $segments = $assignmentId -split '/'
        $subscriptionId = $segments[2]
        $resourceGroupName = $segments[4]
        $url = "https://management.azure.com/subscriptions/$($subscriptionId)/resourceGroups/$($resourceGroupName)/providers/Microsoft.PolicyInsights/remediations/$($remediationName)?api-version=2021-10-01"
        $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $Headers -Body $bodyJson
        Write-Output $response
    }
}

$index = $WebhookData.RequestBody.IndexOf("200https")
if ($index -ge 0) {
    # Add 3 to jump past '200' and start at 'https'
    $callbackUrl = $WebhookData.RequestBody.Substring($index + 3)
    Write-Output $callbackUrl
}
else {
    Write-Output "No callbackURL was found"
}
if ($callbackUrl) {
    $body = @{
        "status"  = "200"
        "message" = "Runbook execution started"
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $callbackUrl -Method Post -Body $body -ContentType "application/json"
        Write-Output $response
        Write-Output "Response sent to Logic App successfully."
    }
    catch {
        Write-Error "Failed to send response to Logic App: $_"
    }
}
else {
    Write-Error "Callback URL not found in webhook request."
}