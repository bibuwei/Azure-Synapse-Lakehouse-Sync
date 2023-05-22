/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Azure Synapse Lakehouse Sync Tutorial: Bicep Template
//
//    Deploy via Azure Cloud Shell (https://shell.azure.com):
//      az deployment sub create --template-file bicep/main.bicep --parameters bicep/main.parameters.json --name Azure-Synapse-Lakehouse-Sync --location eastus
//
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

targetScope='subscription'

@allowed([
  'yes'
  'no'
])
@description('Synapse deployment flag for Synapse only solution.')
param synapseOnlyDeployFlag string = 'no'

@description('Region to create all the resources in.')
param azureRegion string

@description('Resource Group for all related Azure services.')
param resourceGroupName string

@description('Name of the Dedicated SQL Pool to create.')
param synapseSQLPoolName string

@description('Name of the second Dedicated SQL Pool to create.')
param synapseSQLSecondPoolName string

@description('Name of the Spark Pool used to sync the delta changes.')
param synapseSparkPoolName string

@description('Native SQL account for administration.')
param synapseSQLAdministratorLogin string

@description('Password for the native SQL admin account above.')
@secure()
param synapseSQLAdministratorLoginPassword string

@description('Object ID (GUID) for the Azure AD administrator of Synapse. This can also be a group, but only one value can be specified. (i.e. XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXXXXXXX). "az ad user show --id "sochotny@microsoft.com" --query id --output tsv"')
param synapseAzureADAdminObjectId string

// Add a random suffix to ensure global uniqueness among the resources created
//   Bicep: https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-functions-string#uniquestring
var resourceSuffix = substring(uniqueString(subscription().subscriptionId, deployment().name), 0, 4)

// Create the Resource Group
resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-01-01' = {
  name: resourceGroupName
  location: azureRegion
  tags: {
    Environment: 'PoC'
    Application: 'Azure Synapse Analytics'
    Purpose: 'Azure Synapse Lakehouse Sync'
  }
}

// Create the Azure Data Lake Storage Gen2 Account
module storageAccounts 'modules/storageAccounts.bicep' = {
  name: 'storageAccounts'
  scope: resourceGroup
  params: {
    resourceSuffix: resourceSuffix
    azureRegion: azureRegion
  }
}

// Create the Azure Key Vault
module keyVault 'modules/keyVault.bicep' = if (synapseOnlyDeployFlag == 'no') {
  name: 'keyVault'
  scope: resourceGroup
  params: {
    resourceSuffix: resourceSuffix
    azureRegion: azureRegion
    synapseAzureADAdminObjectId: synapseAzureADAdminObjectId
  }

  dependsOn: [
    storageAccounts
  ]
}

// Create the Synapse Analytics Workspace
module synapseAnalytics 'modules/synapseAnalytics.bicep' = {
  name: 'synapseAnalytics'
  scope: resourceGroup
  params: {
    synapseOnlyDeployFlag: synapseOnlyDeployFlag
    resourceSuffix: resourceSuffix
    azureRegion: azureRegion
    synapseSQLPoolName: synapseSQLPoolName
    synapseSQLSecondPoolName: synapseSQLSecondPoolName
    synapseSparkPoolName: synapseSparkPoolName
    synapseSQLAdministratorLogin: synapseSQLAdministratorLogin
    synapseSQLAdministratorLoginPassword: synapseSQLAdministratorLoginPassword
    synapseAzureADAdminObjectId: synapseAzureADAdminObjectId
  }

  dependsOn: (synapseOnlyDeployFlag == 'no') ? [
    storageAccounts
    databricksWorkspace
  ] : [
    storageAccounts
  ]
} 

// Create the Databricks Workspace
module databricksWorkspace 'modules/databricksWorkspace.bicep' = if (synapseOnlyDeployFlag == 'no') {
  name: 'databricksWorkspace'
  scope: resourceGroup
  params: {
    resourceSuffix: resourceSuffix
    azureRegion: azureRegion
  }

  dependsOn: [
    storageAccounts
  ]
}

// Outputs for reference in the deploySynapseSync.sh Post-Deployment Configuration
output resourceGroup string = resourceGroup.name
output synapseAnalyticsWorkspaceName string = synapseAnalytics.outputs.synapseAnalyticsWorkspaceName
output synapseStorageAccountName string = storageAccounts.outputs.synapseStorageAccountName
output enterpriseDataLakeStorageAccountName string = storageAccounts.outputs.enterpriseDataLakeStorageAccountName
output synapseSQLPoolName string = synapseSQLPoolName
output synapseSQLSecondPoolName string = synapseSQLSecondPoolName
output synapseSparkPoolName string = synapseSparkPoolName
output synapseSQLAdministratorLogin string = synapseSQLAdministratorLogin
output databricksWorkspaceName string = (synapseOnlyDeployFlag == 'yes') ? 'NA' : databricksWorkspace.outputs.databricksWorkspaceName
output databricksWorkspaceUrl string = (synapseOnlyDeployFlag == 'yes') ? 'NA' : databricksWorkspace.outputs.databricksWorkspaceUrl
output databricksWorkspaceId string = (synapseOnlyDeployFlag == 'yes') ? 'NA' : databricksWorkspace.outputs.databricksWorkspaceId
output keyVaultName string = (synapseOnlyDeployFlag == 'yes') ? 'NA' : keyVault.outputs.keyVaultName
output keyVaultVaultUri string = (synapseOnlyDeployFlag == 'yes') ? 'NA' : keyVault.outputs.keyVaultVaultUri
output keyVaultId string = (synapseOnlyDeployFlag == 'yes') ? 'NA' : keyVault.outputs.keyVaultId
