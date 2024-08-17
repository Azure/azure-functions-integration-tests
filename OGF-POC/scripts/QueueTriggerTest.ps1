function WriteLog
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Message,

        [Switch]
        $Throw
    )

    $Message = (Get-Date -Format G)  + " -- $Message"

    if ($Throw)
    {
        throw $Message
    }

    Write-Host $Message
}

function ValidateMessageProcessedByTheFunction
{
    param
    (
        $StorageContext,
        [String]
        [ValidateNotNullOrEmpty()]        
        $QueueName,
        [String]
        [ValidateNotNullOrEmpty()]
        $ExpectedMessage
    )

    $queue = Get-AzStorageQueue -Name $QueueName -Context $StorageContext

    $visibilityTimeout = [System.TimeSpan]::FromSeconds(10)
    $queueMessage = $queue.QueueClient.ReceiveMessage($visibilityTimeout)
    
    if (-not $queueMessage)
    {
        WriteLog "No message found in the queue" -Throw
    }

    $messageContent = [System.Text.Encoding]::UTF8.GetString([convert]::FromBase64String($queueMessage.Value.MessageText))
    WriteLog "Expected message: $ExpectedMessage"
    WriteLog "Actual   message: $messageContent"

    if ($messageContent -ne $ExpectedMessage)
    {
        WriteLog "Expected message: $ExpectedMessage. Actual message: $messageContent" -Throw
    }

    # Remove the message from the queue
    $queueMessage = $queue.QueueClient.DeleteMessage($queueMessage.Value.MessageId, $queueMessage.Value.PopReceipt)
}

function AddMessageToFunctionQueue
{
    param
    (
        $StorageContext,
        [String]
        [ValidateNotNullOrEmpty()]        
        $QueueName,
        [String]
        [ValidateNotNullOrEmpty()]
        $MessageContent
    )
    
    $queue = Get-AzStorageQueue -Name $QueueName -Context $StorageContext
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($messageContent)
    $queueMessage = [Convert]::ToBase64String($bytes)
    $queue.QueueClient.SendMessage($queueMessage) | Out-Null

    WriteLog "Message added to the queue"
}

function NewAzStorageContext
{
    param
    (
        [String]
        $StorageAccountName,
        [String]
        $StorageAccountKey
    )

    $storageContext = $null
    try
    {
        $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey -ErrorAction Stop
    }
    catch
    {
        $message = "Failed to authenticate with Azure. Please verify the StorageAccountName and StorageAccountKey. Exception information: $_"
        WriteLog $message -Throw
    }

    return $storageContext
}

if (-not (Get-Module -ListAvailable Az.Storage))
{
    WriteLog "This script requires Az.Storage. To install it, run: 'Install-Module -Name Az.Storage -Force -AllowClobber'" -Throw
}

# 1) Login to Azure
# 2) Make sure you have PowerShell 7.4 installed
# 3) Make sure you have the latest version of the Az Module. If not, run the following command:
#    Install-Module -Name Az -Force
# Select the correct subscription
Get-azsubscription -SubscriptionId <id> | Set-AzContext

# Test case description
WriteLog "This test case validates the Azure Function that processes messages from a queue."
WriteLog "The function is triggered by a message in the queue and outputs the message to a validation queue."

# After the app is created, we configured the queue trigger to output the message to a validation queue.

# Define parameters
$storageAccountName = "<storage account name>"
$functionQueueName = "ps-queue-items"
$StorageAccountKey = "<storage account key>"

# Create storage account context using the connection string
WriteLog "Creating storage account context"
$storageContext = NewAzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $StorageAccountKey

WriteLog "Make sure both queues are empty"
foreach ($queueName in @("ps-queue-items", "validation-queue-items"))
{
    $queue = Get-AzStorageQueue -Name $queueName -Context $storageContext
    $queue.QueueClient.ClearMessages() | Out-Null
}

WriteLog "Adding message to the queue for the function to process"
$expectedMessage = "Hello, " + (New-Guid).Guid
AddMessageToFunctionQueue -StorageContext $storageContext -QueueName $functionQueueName -MessageContent $expectedMessage

# Test case validation
# Validate the message was inserted into the queue and processed by the function
WriteLog "Validating the message was processed by the function"
$queueName = "validation-queue-items"
ValidateMessageProcessedByTheFunction -StorageContext $storageContext -QueueName $queueName -ExpectedMessage $expectedMessage

WriteLog "Test case completed successfully"