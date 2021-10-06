
param
(
    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $PipelineName,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $DisplayName,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $Owner,

    [Parameter(Mandatory=$false)]
    [Int]
    $PipelineDefinitionId = 21,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $SourceBranch,

    [Parameter(Mandatory=$false)]
    [System.String]
    $PipelineParameters,

    [Parameter(Mandatory=$false)]
    [System.String]
    $PipelineType,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $StorageAccountName,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $StorageAccountKey,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $FunctionsVersion,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $DevOpsUserName,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $DevOpsUserPAT,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $OrganizationName,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $ProjectName
)

# Assumption: Parameters are grouped by key value pairs. These should be defined as follow:
#             "key1=value1;key2=value2;key3=value3;"
#
function ParsePipelineParameters
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $PipelineParameters
    )

    $result = @{}

    $keyValuePairs = $PipelineParameters -split ";"
    foreach ($keyValuePair in $keyValuePairs)
    {
        $keyValuePair = $keyValuePair.Trim()

        if ($keyValuePair)
        {
            $parts = @($keyValuePair -split "=")

            if ($parts.Count -ne 2)
            {
                WriteLog "Invalid key value pair: $keyValuePair" -Throw
            }

            $keyName = $parts[0].Trim()
            $value = $parts[1].Trim()

            # Boolean assignment value
            if ($value -eq "true" -or $value -eq "false")
            {
                $value = [System.Convert]::ToBoolean($value)
            }

            $result[$keyName] = $value
        }
    }
    
    return $result
}

function WriteLog
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Message,

        [Switch]
        $Warning,

        [Switch]
        $Throw
    )

    $Message = (GetDatePST).ToString("G")  + " -- $Message"

    if ($Throw)
    {
        throw $Message
    }
    else
    {
        Write-Host $Message
    }
}

function GetAuthenticationHeader
{
    $user = $DevOpsUserName
    $token = $DevOpsUserPAT
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $user, $token)))
    $authHeader = @{Authorization=("Basic {0}" -f $base64AuthInfo)}
    return $authHeader
}

function WaitForPipelineToComplete
{
    Param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $BuildUrl,        
        $WaitTimeInSeconds = 10,
        $MaxNumberOfTries = 360
    )

    $authHeader = GetAuthenticationHeader

    $response = $null    
    $tries = 1

    while ($true)
    {
        Start-Sleep -Seconds $WaitTimeInSeconds

        $currentWaitTimeInMinutes = [Math]::Round(($tries*$WaitTimeInSeconds)/60, 2)

        if (($currentWaitTimeInMinutes) % 1 -eq 0)
        {
            WriteLog -Message "Pipeline status: $($response.status)..."
            WriteLog -Message "Wait time in minutes: $($currentWaitTimeInMinutes)"
        }

        $response = Invoke-RestMethod -Method Get -Uri $BuildUrl -Headers $authHeader -MaximumRetryCount 3 -RetryIntervalSec 1 -ErrorAction SilentlyContinue
        if (-not ($response.status -eq "inProgress" -or $response.status -eq "notStarted"))
        {
            WriteLog -Message "Pipeline status: $($response.status)"
            return $response
        }

        if ($tries -ge $MaxNumberOfTries)
        {
            WriteLog -Message "Pipeline execution did not complete in $currentWaitTimeInMinutes minutes. See link for current status: $BuildUrl" -Throw
        }

        $tries++
    }
}

function GetDevOpsServiceUrl
{
    <#
    Docs: https://docs.microsoft.com/en-us/rest/api/azure/devops/?view=azure-devops-rest-6.1
    instance of the form https://dev.azure.com/{organization}/_apis[/{area}]/{resource}?api-version={version}
    #>
    return "https://dev.azure.com/${OrganizationName}/${ProjectName}"
}

function GetProjectUrl
{
    return "https://${OrganizationName}.visualstudio.com/${ProjectName}"
}

function InvokeDevOpsPipeline
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [PipelineDefinition]
        $PipelineDefinition,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $StorageAccountName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $StorageAccountKey,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $FunctionsVersion
    )

    $serviceUrl = GetDevOpsServiceUrl
    $devOpsUrl =  $serviceUrl + "/_apis/build/builds?api-version=5.0"
    $requestBody = $pipelineDefinition.RequestBody | ConvertTo-Json

    $projectUrl = GetProjectUrl
    
    $buildresponse = $null
    $buildStatusUrl = $null
    $pipelineViewUrl = $null
    $pipelineResult = $null

    $folderName = $pipelineDefinition.Name.Replace(" ","")
    $badgesFolderPath = Join-Path $PSScriptRoot $folderName

    try
    {
        $invocationTime = (GetDatePST).ToString("G") + " (PST)"

        WriteLog -Message "Queueing pipeline '$($pipelineDefinition.Name)'"

        $authHeader = GetAuthenticationHeader
        $buildresponse = Invoke-RestMethod -Method Post `
                                           -ContentType application/json `
                                           -Uri $devOpsUrl `
                                           -Body $requestBody `
                                           -Headers $authHeader `
                                           -MaximumRetryCount 3 `
                                           -RetryIntervalSec 1 `
                                           -ErrorAction Stop

        $buildStatusUrl =  $buildresponse.url
        WriteLog -Message "Build Status Url: $buildStatusUrl"

        $pipelineViewUrl = $projectUrl + "/_build/results?buildId=$($buildresponse.Id)&view=results"
        WriteLog -Message "Pipeline has been queued. Please see '$pipelineViewUrl' for execution status."

        $script:pipelineInvocationResult["BuildId"] = $buildresponse.Id

        # Create last-run.svg file
        $lastRunFileName = "last-run.svg"
        $filePath = Join-Path $badgesFolderPath $lastRunFileName
        $label = if ($PipelineDefinition.Type -eq "Build") { "Last build time" } else { "Last test run time" }
        NewBadge -Label $label -Content $invocationTime -Color "lightgrey" -FilePath $filePath
        
        $script:pipelineInvocationResult["ExecutionTime"] = $invocationTime
    }
    catch
    {
        $message = "Failed to queue pipeline. Exception information: $_"
        WriteLog -Message $message -Throw
    }

    $pipelineResult = WaitForPipelineToComplete -BuildUrl $buildStatusUrl

    $summary = "Pipeline $($pipelineDefinition.Type) "
    $summary += if ($pipelineResult.status -eq "completed" -and $pipelineResult.result -eq "succeeded") { "completed successfully!" } else { "failed." }
    WriteLog -Message $summary

    # Create pipeline result badge
    $pipelineResultFileName = "pipeline-result.svg"
    $filePath = Join-Path $badgesFolderPath $pipelineResultFileName
    $label = "Build id: $($buildresponse.Id)"
    $content = if ($pipelineResult.result -eq "succeeded") { "succeeded" } else { "failed" }
    $color = if ($pipelineResult.result -eq "succeeded") { "Brightgreen" } else { "red" }
    $script:pipelineInvocationResult["Status"] = $content
    NewBadge -Label $label -Content $content -Color $color -FilePath $filePath

    # Create tests results badge
    $filePath = Join-Path $badgesFolderPath "test-results.svg"
    $buildUrl = $projectUrl + "/_apis/test/ResultSummaryByBuild?buildId=$($buildresponse.Id)"
    NewTestResultBadge -BuildUrl $buildUrl -FilePath $filePath

    # Save the pipeline information
    $filePath = Join-Path $badgesFolderPath "pipeline-results.json"
    Set-Content -Path $filePath -Value $pipelineViewUrl -Force | Out-Null

    $script:pipelineInvocationResult["BuildUrl"] = $pipelineViewUrl
    $script:pipelineInvocationResult | ConvertTo-Json -Depth 5 | Set-Content -Path $filePath -Force | Out-Null

    # Save the BuildUrl and build id in a txt file
    $filePath = Join-Path $badgesFolderPath "Build-url.txt"
    Set-Content -Path $filePath -Value $pipelineViewUrl -Force | Out-Null

    $filePath = Join-Path $badgesFolderPath "Build-id.txt"
    Set-Content -Path $filePath -Value $buildresponse.Id -Force | Out-Null

    UploadFilesToStorageAccount -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey -SourcePath $badgesFolderPath -FunctionsVersion $FunctionsVersion

    if ($pipelineResult.result -ne "succeeded")
    {
        WriteLog -Message "Pipeline execution was not successful. Pipeline status: $($pipelineResult.result). For more information, please see $($pipelineViewUrl)" -Throw
    }
}

<#
    The URL is of the form
    https://${OrganizationName}.visualstudio.com/${ProjectName}/_apis/test/ResultSummaryByBuild?buildId=$id,
    where $id is the build id
#>
function NewTestResultBadge
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [String]
        $BuildUrl,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [String]
        $FilePath
    )

    WriteLog "Check if '$BuildUrl' has any published tests results"
    $results = Invoke-RestMethod $BuildUrl -MaximumRetryCount 3 -RetryIntervalSec 1 -ErrorAction Stop

    if (-not $results.aggregatedResultsAnalysis.resultsByOutcome)
    {
        WriteLog "Response does not contain any aggregated results analysis"
        return
    }

    $total = $results.aggregatedResultsAnalysis.totalTests
    $passed = $results.aggregatedResultsAnalysis.resultsByOutcome.Passed.Count
    $failed = $results.aggregatedResultsAnalysis.resultsByOutcome.Failed.Count
    $skipped = $total - $passed - $failed

    $color = if ($failed -gt 0) { "red" } else { "Brightgreen" }

    if ($total -eq 0)
    {
        WriteLog "No tests results are available for this build"
        $content = "not available"
        $color = "red"
    }
    else
    {
        $values = @()
        $valuesHashTable = @{}

        if ($passed -gt 0)
        {
            $values += "$passed passed"
            $valuesHashTable["passed"] = $passed
        }

        if ($failed -gt 0)
        {
            $values += "$failed failed"
            $valuesHashTable["failed"] = $failed
        }

        if ($skipped -gt 0)
        {
            $values += "$skipped skipped"
            $valuesHashTable["skipped"] = $skipped
        }

        $script:pipelineInvocationResult["TestResults"] = $valuesHashTable

        WriteLog "Create test results badge"
        $content = $values -join " | "
    }

    NewBadge -Label "Tests" -Content $content -Color $color -FilePath $FilePath
}

function NewBadge
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [String]
        $Label,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [String]
        $Content,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [String]
        $Color,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [String]
        $FilePath
    )

    if (-not $FilePath.EndsWith(".svg"))
    {
        WriteLog -Message "The file extension must be .svg" -Throw
    }

    # If the directory does not exits, create it
    $folderPath = Split-Path $FilePath -Parent
    if (-not (test-path $folderPath))
    {
        New-Item -Path $folderPath -Force -ItemType Directory | Out-Null 
    }

    if (test-path $FilePath)
    {
        Remove-Item $FilePath -Force | Out-Null
    }
    
    Invoke-RestMethod https://img.shields.io/badge/$Label-$Content-$Color.svg -OutFile $FilePath -MaximumRetryCount 3 -RetryIntervalSec 1 -ErrorAction Stop
}

# Get the date in Pacific Standard Time
#
function GetDatePST
{
    $now = Get-Date
    $timeZoneInfo  = [TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
    $date = [TimeZoneInfo]::ConvertTime($now, $timeZoneInfo)
    return $date
}

function UploadFilesToStorageAccount
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $StorageAccountName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $StorageAccountKey,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $SourcePath,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $FunctionsVersion
    )

    if (-not (Test-Path $SourcePath))
    {
        WriteLog -Message "SourcePath '$SourcePath' does not exist." -Throw
    }

    WriteLog "Enumerating svg files... in '$SourcePath'"
    $filesToUpload = @(Get-ChildItem -Path "$SourcePath/*" -Include "*.txt", "*.svg", "*.json" | ForEach-Object {$_.FullName})
    if ($filesToUpload.Count -eq 0)
    {
        WriteLog -Message "'$SourcePath' does not contain any svg or text files to upload." -Throw
    }

    # Install the storage module if needed
    if (-not (Get-command New-AzStorageContext -ea SilentlyContinue))
    {
        WriteLog "Installing Az.Storage."
        Install-Module Az.Storage -Force -Verbose -AllowClobber -Scope CurrentUser
    }

    $context = $null
    try
    {
        WriteLog "Connecting to storage account..."
        $context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey -ErrorAction Stop
    }
    catch
    {
        $message = "Failed to authenticate with Azure. Please verify the StorageAccountName and StorageAccountKey. Exception information: $_"
        WriteLog -Message $message -Throw
    }

    $CONTAINER_NAME = "pipelineresults"
    $destinationPath = $null

    foreach ($file in $filesToUpload)
    {
        $fileName = Split-Path $file -Leaf
        $pipelineFolderName = Split-Path (Split-Path $file -Parent) -Leaf
        $destinationPath = [IO.Path]::Combine($FunctionsVersion, $pipelineFolderName, $fileName)

        $contentType = GetContentType -FilePath $file

        try
        {
            WriteLog -Message "Uploading '$fileName' to '$destinationPath'."

            Set-AzStorageBlobContent -File $file `
                                     -Container $CONTAINER_NAME `
                                     -Blob $destinationPath `
                                     -Context $context `
                                     -StandardBlobTier Hot `
                                     -ErrorAction Stop `
                                     -Properties  @{"ContentType" = $contentType; "CacheControl" = "no-cache"} `
                                     -Force | Out-Null
        }
        catch
        {
            WriteLog -Message "Failed to upload file '$file' to storage account. Exception information: $_" -Throw
        }
    }
}

function GetContentType
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $FilePath
    )

    $fileExtension =  [System.IO.Path]::GetExtension($FilePath)

    switch ($fileExtension)
    {
        ".json" { "application/json" }
        ".txt" { "text/plain" }
        ".svg" { "image/svg+xml" }
        default { "application/octet-stream"}
    }
}

Class PipelineDefinition {
    [String]$Name
    [String]$DisplayName
    [String]$Owner
    [Hashtable]$RequestBody
    [String]$Id
    [String]$Type
}

# Validate input parameters
foreach ($varibleName in @("PipelineName", "DisplayName", "Owner", "PipelineDefinitionId", "SourceBranch", "PipelineType"))
{
    $result = Get-Variable $varibleName -ErrorAction SilentlyContinue
    if (-not $result.Value)
    {
        WriteLog -Message "Variable name '$varibleName' cannot be null or empty." -Throw
    }
}

# Validate $PipelineType
$validPipelineType = @("Build", "Test")
if (-not $validPipelineType.Contains($PipelineType))
{
    $options = $validPipelineType -join ", "
    WriteLog -Message "'PipelineType' is invalid. Valid inputs are: $options" -Throw
}

# Create the request body with the pipeline parameters
$pipelineParams = $null

if ($PipelineParameters)
{
    $pipelineParams = ParsePipelineParameters -PipelineParameters $PipelineParameters
}
else
{
    $pipelineParams = @{}    
}

# For the Core Tools pipeline, add/replace the value for the IntegrationBuildNumber
if ($PipelineDefinitionId -eq 11)
{
    $parameterName = "IntegrationBuildNumber"
    $integrationBuildNumber = "PreRelease" + (GetDatePST).ToString("yyMMdd-HHmm")

    $pipelineParams[$parameterName] = $integrationBuildNumber
}

$requestBody = @{
    parameters = ( $pipelineParams | ConvertTo-Json )
    definition = @{
        id = $PipelineDefinitionId
    }
    sourceBranch = $SourceBranch
}

$pipelineDefinition = [PipelineDefinition]::new()
$pipelineDefinition.Name = $PipelineName
$pipelineDefinition.DisplayName = $DisplayName
$pipelineDefinition.Owner = $Owner
$pipelineDefinition.RequestBody = $requestBody
$pipelineDefinition.Id = $PipelineDefinitionId
$pipelineDefinition.Type = $PipelineType

# This is used to hold the information results of the pipeline which gets written to a json file.
$script:pipelineInvocationResult = @{
    Name = $PipelineName
    DisplayName = $DisplayName
    Type = $PipelineType
    SourceBranch = $SourceBranch
    ExecutionTime = $null
    Status = $null
    TestResults = $null
    BuildUrl = $null
    BuildId = $null
}

InvokeDevOpsPipeline -PipelineDefinition $pipelineDefinition -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey -FunctionsVersion $FunctionsVersion
