# Variables used below
$subscriptionId = "<Azure Subscription Id>"
$tenantId = "<Azure Tenant Id>"
$resourceGroupName = "<Resource Group Name>"
$resourceGroupLocation = "<Region>"
$adminUserName = "<Admin User>"
$adminWindowsPassword = "<Admin Password>"
$sshPublicKey="ssh-rsa <public key>"
$acsEnginePath="<path to acs-engine.exe>"

#################################################################
# Don't modify anything below unless you know what you're doing.
#################################################################
$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

$kubernetesJsonPath="$PSScriptRoot\kubernetes.json"

$azureSession = Login-AzureRmAccount -Subscription $subscriptionId -TenantId $tenantId
Write-Host "Creating resource group '$resourceGroupName' in '$resourceGroupLocation'" -ForegroundColor Yellow
$resourceGroup = New-AzureRmResourceGroup -Name $resourceGroupName -Location $resourceGroupLocation -Force
$ticks = [DateTime]::UtcNow.Ticks

$clusterDNSName = $($resourceGroup.ResourceGroupName) + "-" + $ticks

# Create an Azure AD App registration
$azureADAppName = "$($resourceGroup.ResourceGroupName)-" + $ticks
$azureADAppHomePage = "https://" + $azureADAppName
Write-Host "Creating an Azure AD application registration '$azureADAppName'" -ForegroundColor Yellow
$azureADApp = New-AzureRmADApplication -DisplayName $azureADAppName -HomePage $azureADAppHomePage `
                -IdentifierUris $azureADAppHomePage

# Create a new client secret / credential for the Azure AD App registration
$bytes = New-Object Byte[] 32
$rand = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rand.GetBytes($bytes)
$clientSecret = [System.Convert]::ToBase64String($bytes)
$clientSecretSecured = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
$endDate = [System.DateTime]::Now.AddYears(1)
Write-Host "- Adding a client secret / credential for the application" -ForegroundColor Yellow
New-AzureRmADAppCredential -ApplicationId $azureADApp.ApplicationId -Password $clientSecretSecured -EndDate $endDate

# Create an Azure AD Service Principal associated with the Azure AD App
Write-Host "Creating service principal for Azure AD application '$($azureADApp.ApplicationId)'" -ForegroundColor Yellow
$azureADSP = New-AzureRmADServicePrincipal -ApplicationId $azureADApp.ApplicationId

# Need to pause after creaeting the service principal or you may get an error on the next call indicating the SP doesn't exist.
Start-Sleep -Seconds 60

# Assign the service principal to the Contributor role for the resource group
Write-Host "Adding service principal '$($azureADSP.Id)' to the Contributor role for the resource group." -ForegroundColor Yellow
New-AzureRmRoleAssignment -RoleDefinitionName "Contributor" `
    -Scope "/subscriptions/$subscriptionId/resourcegroups/$($resourceGroup.ResourceGroupName)" -ObjectId $azureADSP.Id

# Create a new cluster definition file
$clusterJson = Get-Content $kubernetesJsonPath | Out-String | ConvertFrom-Json
$clusterJson.properties.masterProfile.dnsPrefix = $clusterDNSName
$clusterJson.properties.servicePrincipalProfile.clientId = $azureADSP.Id
$clusterJson.properties.servicePrincipalProfile.secret = $clientSecret
$clusterJson.properties.windowsProfile.adminUserName = $adminUserName
$clusterJson.properties.windowsProfile.adminPassword = $adminWindowsPassword
$clusterJson.properties.linuxProfile.adminUsername = $adminUserName
$clusterJson.properties.linuxProfile.ssh.publicKeys[0].keyData = $sshPublicKey

$kubernetesJsonFileName = Split-Path $kubernetesJsonPath -Leaf
$newKubernetesJsonFile = "new_$kubernetesJsonFileName"
$newKubernetesJsonPath = (Split-Path $kubernetesJsonPath) + "\$newKubernetesJsonFile"

$clusterJson | ConvertTo-Json -Depth 100 -Compress | Out-File $PSScriptRoot\$newKubernetesJsonFile -Encoding ascii
$acsEngineOutputPath = (Split-Path $acsEnginePath) + "\_output\$clusterDNSName"

# Execute acs-engine to generate deployment templates and artifacts
Write-Host "Executing acs-engine to generate cluster deployment templates and artifacts." -ForegroundColor Yellow
$acsEngineArgs = "generate $newKubernetesJsonPath --output-directory $acsEngineOutputPath"
Start-Process -FilePath $acsEnginePath -ArgumentList $acsEngineArgs -Wait

# Start a new resource group deployment
Write-Host "Deploying mixed cluster to Azure in resource group '$resourceGroupName'" -ForegroundColor Yellow
New-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroup.ResourceGroupName `
    -TemplateFile "$acsEngineOutputPath\azuredeploy.json" `
    -TemplateParameterFile "$acsEngineOutputPath\azuredeploy.parameters.json"

Write-Host "Successfully deployed!" -ForegroundColor Green