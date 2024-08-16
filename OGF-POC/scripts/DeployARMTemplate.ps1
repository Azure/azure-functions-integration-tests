

# 1) Login to Azure
# 2) Make sure you have PowerShell 7.4 installed
# 3) Make sure you have the latest version of the Az Module. If not, run the following command:
#    Install-Module -Name Az -AllowClobber -Scope CurrentUser
# Select the correct subscription
# Select-AzSubscription -SubscriptionName "Visual Studio Enterprise" | Set-AzContext # or
# Select-AzSubscription -SubscriptionId <id> | Set-AzContext

# To check if you are in the correct subscription, run the following command:
# Get-AzContext

# Variables
$resourceGroupName = "EP-PowerShell-CentralUS-Test1"
# $templateFilePath = "C:\GH\azure-functions-integration-tests\OGF-POC\ARMTemplates\azuredeploy.json"
$templateFilePath = "<path to\azuredeploy.json>"
$location = "Central US"

# Create a new resource group
New-AzResourceGroup -Name $resourceGroupName -Location $location

# Start a new deployement
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile $templateFilePath