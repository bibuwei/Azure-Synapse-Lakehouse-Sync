#!/bin/bash
#
# This script is in two parts; Environment Deployment and Post-Deployment Configuration. While there appears
# to be alot going on here, it's mostly error handling for various scenarios that can arise. We're really
# just deploying the environment via Bicep, running a few queries against Synapse, and deploying a few
# Synapse pipeline and Databricks artifacts.
#
#   Part 1: Environment Deployment
#
#       This performs a Bicep template deployment if it wasn't done manually. The Bicep template creates a 
#       Databricks Workspace, Azure Data Lake Storage Gen2, and a Synapse Analytics Workspace.
#
#   Part 2: Post-Deployment Configuration
#
#       These are post-deployment configurations done at the data plan level which is beyond the scope of what  
#       Bicep is capable of managing or would normally manage. Database settings are made, sample data is copied, 
#       notebooks are copied, and pipelines are created.
#
#       These steps to make use of other dependencies such as Azure CLI and sqlcmd hence why it's easier to 
#       execute via the Azure Cloud Shell.
#
#   This script should be executed via the Azure Cloud Shell (https://shell.azure.com):
#
#       @Azure:~/Azure-Synapse-Lakehouse-Sync$ bash deploySynapseSync.sh
#

#
# Part 1: Environment Deployment
#

bicepDeploymentName="Azure-Synapse-Lakehouse-Sync"
deploymentLogFile="deploySynapseSync.log"

checkBicepDeploymentState () {
    bicepDeploymentCheck=$(az deployment sub show --name $bicepDeploymentName --query properties.provisioningState --output tsv 2>&1 | sed 's/[[:space:]]*//g')
    if [ "$bicepDeploymentCheck" = "Succeeded" ]; then
        echo "Succeeded"
    elif [ "$bicepDeploymentCheck" = "Failed" ] || [ "$bicepDeploymentCheck" = "Canceled" ]; then
        echo "$(date) [ERROR] It looks like a Bicep deployment was attempted but failed." | tee -a $deploymentLogFile
        exit 1;
    elif [[ $bicepDeploymentCheck == *"DeploymentNotFound"* ]]; then
        echo "DeploymentNotFound"
    fi
}

# User output formatting
boldText=$(tput bold)
normalText=$(tput sgr0)

echo "$(date) [INFO] Starting deploySynapseSync.sh" >> $deploymentLogFile

# Try and determine if we're executing from within the Azure Cloud Shell
if [ ! "${AZUREPS_HOST_ENVIRONMENT}" = "cloud-shell/1.0" ]; then
    echo "$(date) [ERROR] It doesn't appear you are executing this from the Azure Cloud Shell. Please use the Azure Cloud Shell at https://shell.azure.com" | tee -a $deploymentLogFile
    exit 1;
fi

# Try and get a token to validate that we're logged into Azure CLI
aadToken=$(az account get-access-token --resource=https://dev.azuresynapse.net --query accessToken --output tsv 2>&1 | sed 's/[[:space:]]*//g')
if [[ $aadToken == *"ERROR"* ]]; then
    echo "$(date) [ERROR] You don't appear to be logged in to Azure CLI. Please login to the Azure CLI using 'az login'" | tee -a $deploymentLogFile
    exit 1;
fi

# Get environment details
azureSubscriptionName=$(az account show --query name --output tsv 2>&1 | sed 's/[[:space:]]*//g')
echo "$(date) [INFO] Azure Subscription: $azureSubscriptionName" >> $deploymentLogFile
azureSubscriptionID=$(az account show --query id --output tsv 2>&1 | sed 's/[[:space:]]*//g')
echo "$(date) [INFO] Azure Subscription ID: $azureSubscriptionID" >> $deploymentLogFile
azureUsername=$(az account show --query user.name --output tsv 2>&1 | sed 's/[[:space:]]*//g')
echo "$(date) [INFO] Azure AD Username: $azureUsername" >> $deploymentLogFile
azureUsernameObjectId=$(az ad user show --id $azureUsername --query id --output tsv 2>&1 | sed 's/[[:space:]]*//g')
echo "$(date) [INFO] Azure AD User Object Id: $azureUsernameObjectId" >> $deploymentLogFile

# Display some environment details to the user
echo "${boldText}Azure Subscription:${normalText} ${azureSubscriptionName}"
echo "${boldText}Azure Subscription ID:${normalText} ${azureSubscriptionID}"
echo "${boldText}Azure AD Username:${normalText} ${azureUsername}"

# Update a Bicep variable if it isn't configured by the user. This allows Bicep to add the user Object Id
# to the Storage Blob Data Contributor role on the Azure Data Lake Storage Gen2 account, which allows Synapse
# Serverless SQL to query files on storage.
sed -i "s/REPLACE_SYNAPSE_AZURE_AD_ADMIN_OBJECT_ID/${azureUsernameObjectId}/g" Bicep/main.parameters.json 2>&1

# Check to see if the Bicep deployment was already completed manually. If not, lets do it.
if [ $(checkBicepDeploymentState) = "DeploymentNotFound" ]; then
    # Get the Azure Region from the Bicep main.parameters.json
    bicepAzureRegion=$(jq -r .parameters.azureRegion.value Bicep/main.parameters.json 2>&1 | sed 's/[[:space:]]*//g')

    # Bicep deployment via Azure CLI
    echo ""
    echo "Deploying environment via Bicep. This will take several minutes..."
    echo ""
    echo "$(date) [INFO] Starting Bicep deployment" >> $deploymentLogFile
    bicepDeploy=$(az deployment sub create --template-file Bicep/main.bicep --parameters Bicep/main.parameters.json --name $bicepDeploymentName --location $bicepAzureRegion 2>&1 | tee -a $deploymentLogFile)
else
    echo "$(date) [INFO] It appears the Bicep deployment was done manually. Skipping..." >> $deploymentLogFile
fi

# Make sure the Bicep deployment was successful 
echo "${boldText}Bicep Deployment:${normalText}" $(checkBicepDeploymentState)

#
# Part 2: Post-Deployment Configuration
#

# Get the output variables from the Bicep deployment
resourceGroup=$(az deployment sub show --name ${bicepDeploymentName} --query properties.parameters.resourceGroupName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
synapseAnalyticsWorkspaceName=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.synapseAnalyticsWorkspaceName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
synapseAnalyticsSQLPoolName=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.synapseSQLPoolName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
synapseAnalyticsSQLAdmin=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.synapseSQLAdministratorLogin.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
databricksWorkspaceName=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.databricksWorkspaceName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
databricksWorkspaceUrl=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.databricksWorkspaceUrl.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
databricksWorkspaceId=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.databricksWorkspaceId.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
datalakeName=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.datalakeName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
keyVaultVaultUri=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.keyVaultVaultUri.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
keyVaultId=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.keyVaultId.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')

# Get the Synapse AQL Administrator Login Password from the Bicep main.parameters.json
synapseSQLAdministratorLoginPassword=$(jq -r .parameters.synapseSQLAdministratorLoginPassword.value Bicep/main.parameters.json 2>&1 | sed 's/[[:space:]]*//g')

# Display the environment details to the user
echo "${boldText}Resource Group:${normalText} ${resourceGroup}"
echo "$(date) [INFO] Resource Group: $resourceGroup" >> $deploymentLogFile
echo "${boldText}Synapse Analytics Workspace:${normalText} ${synapseAnalyticsWorkspaceName}"
echo "$(date) [INFO] Synapse Analytics Workspace: $synapseAnalyticsWorkspaceName" >> $deploymentLogFile
echo "${boldText}Synapse Analytics SQL Admin:${normalText} ${synapseAnalyticsSQLAdmin}"
echo "$(date) [INFO] Synapse Analytics SQL Admin: $synapseAnalyticsSQLAdmin" >> $deploymentLogFile
echo "${boldText}Databricks Workspace:${normalText} ${databricksWorkspaceName}"
echo "$(date) [INFO] Databricks Workspace: $databricksWorkspaceName" >> $deploymentLogFile
echo "${boldText}Data Lake Name:${normalText} ${datalakeName}"
echo "$(date) [INFO] Data Lake Name: $datalakeName" >> $deploymentLogFile
echo ""

# Enable the Synapse Dedicated SQL Result Set Cache
echo "Enabling the Synapse Dedicated SQL Result Set Caching..."
echo "$(date) [INFO] Enabling the Synapse Dedicated SQL Result Set Caching..." >> $deploymentLogFile
synapseResultSetCache=$(sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseSQLAdministratorLoginPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d master -I -Q "ALTER DATABASE ${synapseAnalyticsSQLPoolName} SET RESULT_SET_CACHING ON;" 2>&1)

# Validate the Synapse Dedicated SQL Pool is running and we were able to establish a connection
if [[ $synapseResultSetCache == *"Cannot connect to database when it is paused"* ]]; then
    echo "$(date) [ERROR] The Synapse Dedicated SQL Pool is paused. Please resume the pool and run this script again." | tee -a $deploymentLogFile
    exit 1;
elif [[ $synapseResultSetCache == *"Login timeout expired"* ]]; then
    echo "$(date) [ERROR] Unable to connect to the Synapse Dedicated SQL Pool. The exact reason is unknown." | tee -a $deploymentLogFile
    exit 1;
fi

# Enable the Synapse Dedicated SQL Query Store
echo "Enabling the Synapse Dedicated SQL Query Store..."
echo "$(date) [INFO] Enabling the Synapse Dedicated SQL Query Store..." >> $deploymentLogFile
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseSQLAdministratorLoginPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d ${synapseAnalyticsSQLPoolName} -I -Q "ALTER DATABASE ${synapseAnalyticsSQLPoolName} SET QUERY_STORE = ON;"

# Create the Resource Class Users for the Auto Loader
echo "Creating the Synapse Dedicated SQL Resource Class Users..."
echo "$(date) [INFO] Creating the Synapse Dedicated SQL Resource Class Users..." >> $deploymentLogFile
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseSQLAdministratorLoginPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d ${synapseAnalyticsSQLPoolName} -I -i "../Azure Synapse Lakehouse Sync/Synapse/Queries/Create_Resource_Class_Users.sql"

# Create the LS_Synapse_Managed_Identity Linked Service.
echo "Creating the Synapse Workspace Linked Service..."
echo "$(date) [INFO] Creating the Synapse Workspace Linked Service..." >> $deploymentLogFile
az synapse linked-service create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name LS_Synapse_Managed_Identity --file @"../Azure Synapse Lakehouse Sync/Synapse/LS_Synapse_Managed_Identity.json"

# Create the DS_Synapse_Managed_Identity Dataset.
echo "Creating the Synapse Workspace Dataset..."
echo "$(date) [INFO] Creating the Synapse Workspace Dataset..." >> $deploymentLogFile
az synapse dataset create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name DS_Synapse_Managed_Identity --file @"../Azure Synapse Lakehouse Sync/Synapse/Datasets/DS_Synapse_Managed_Identity.json"

# Create the Synapse Pipelines
echo "Creating the Synapse Lakehouse Sync Pipelines..."
echo "$(date) [INFO] Creating the Synapse Lakehouse Sync Pipelines..." >> $deploymentLogFile
synapsePipelines=("SynapseLakehouseSyncTableLoad", "SynapseLakehouseSync", "SynapseLakehouseSync_Tutorial")
for synapsePipelineName in ${synapsePipelines[@]}; do
    cp "../Azure Synapse Lakehouse Sync/Synapse/Pipelines/$synapsePipelineName.json" "../Azure Synapse Lakehouse Sync/Synapse/Pipelines/$synapsePipelineName.json.tmp" 2>&1
    sed -i "s/REPLACE_DATALAKE_NAME/${datalakeName}/g" "../Azure Synapse Lakehouse Sync/Synapse/Pipelines/$synapsePipelineName.json.tmp"
    sed -i "s/REPLACE_SYNAPSE_ANALYTICS_SQL_POOL_NAME/${synapseAnalyticsSQLPoolName}/g" "../Azure Synapse Lakehouse Sync/Synapse/Pipelines/$synapsePipelineName.json.tmp"
    az synapse pipeline create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name "$synapsePipelineName" --file @"../Azure Synapse Lakehouse Sync/Synapse/Pipelines/$synapsePipelineName.json.tmp" >> $deploymentLogFile 2>&1
    rm "../Azure Synapse Lakehouse Sync/Synapse/Pipelines/$synapsePipelineName.json.tmp"
done

# Generate a SAS for the data lake so we can upload some files
tomorrowsDate=$(date --date="tomorrow" +%Y-%m-%d)
destinationStorageSAS=$(az storage container generate-sas --account-name ${datalakeName} --name data --permissions rwal --expiry ${tomorrowsDate} --only-show-errors --output tsv 2>&1 | sed 's/[[:space:]]*//g')
sampleDataStorageSAS="?sv=2021-06-08&st=2022-08-01T04%3A00%3A00Z&se=2023-08-01T04%3A00%3A00Z&sr=c&sp=rl&sig=DjC4dPo5AKYkNFplik2v6sH%2Fjhl2k1WTzna%2F1eV%2BFv0%3D"

# Copy sample data
echo "Copying the sample data..."
echo "$(date) [INFO] Copying the sample data..." >> $deploymentLogFile
az storage copy -s 'https://synapseanalyticspocdata.blob.core.windows.net/sample/Synapse Lakehouse Sync/AdventureWorks_changes/'$sampleDataStorageSAS -d 'https://'$datalakeName'.blob.core.windows.net/data/Sample?'$destinationStorageSAS --recursive >> $deploymentLogFile 2>&1
az storage copy -s 'https://synapseanalyticspocdata.blob.core.windows.net/sample/Synapse Lakehouse Sync/AdventureWorks_parquet/'$sampleDataStorageSAS -d 'https://'$datalakeName'.blob.core.windows.net/data/Sample?'$destinationStorageSAS --recursive >> $deploymentLogFile 2>&1

# Update the Auto Loader Metadata file template with the correct storage account and then upload it
sed -i "s/REPLACE_DATALAKE_NAME/${datalakeName}/g" "../Azure Synapse Lakehouse Sync/Synapse/Synapse_Lakehouse_Sync_Metadata.csv"
az storage copy -s '../Azure Synapse Lakehouse Sync/Synapse/Synapse_Lakehouse_Sync_Metadata.csv' -d 'https://'"${datalakeName}"'.blob.core.windows.net/data?'"${destinationStorageSAS}" >> $deploymentLogFile 2>&1

# Get the Databricks Workspace Azure AD accessToken for authentication
echo "$(date) [INFO] Getting the Databricks Workspace Azure AD accessToken..." >> $deploymentLogFile
databricksAccessToken=$(az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --output tsv --query accessToken 2>&1 | sed 's/[[:space:]]*//g')

# Create the Databricks Cluster
echo "Creating the Databricks Workspace Cluster definition..."
echo "$(date) [INFO] Creating the Databricks Cluster definition..." >> $deploymentLogFile
createDatabricksCluster=$(az rest --method post --url https://${databricksWorkspaceUrl}/api/2.0/clusters/create --body "@../Azure Synapse Lakehouse Sync/Databricks/SynapseLakehouseSyncCluster.json" --headers "{\"Authorization\":\"Bearer $databricksAccessToken\"}" --query cluster_id --output tsv 2>&1 | sed 's/[[:space:]]*//g')

# Create the Azure Key Vault Scope
echo "Creating the Databricks Workspace Azure Key Vault Scope..."
echo "$(date) [INFO] Creating the Databricks Azure Key Vault Scope..." >> $deploymentLogFile
createDatabricksKeyVaultScope=$(az rest --method post --url https://${databricksWorkspaceUrl}/api/2.0/secrets/scopes/create --body "{ \"scope\": \"DataLakeStorageKey\", \"scope_backend_type\": \"AZURE_KEYVAULT\", \"backend_azure_keyvault\": { \"resource_id\": \"$keyVaultId\", \"dns_name\": \"$keyVaultVaultUri\" }, \"initial_manage_principal\": \"users\" }" --headers "{\"Authorization\":\"Bearer $databricksAccessToken\"}" 2>&1 | tee -a $deploymentLogFile)

# Create the Databricks Notebooks
# 
# We base64 encode the notebook DBC files because thats how they need to be uploaded to the 
# Databricks API. We're writing out to a temporary file and using that file to POST via 
# 'az rest' because of a WSL bug instead of trying to pass the base64 string as a parameter. 
# While this script should be executed from the Azure Cloud Shell anyway, we're trying to 
# maintain as much compatibility as possible for potential future updates.
echo "Creating the Databricks Workspace Notebooks..."
echo "$(date) [INFO] Creating the Databricks notebooks..." >> $deploymentLogFile
databricksNotebooks=("Synapse Lakehouse Sync/Synapse Lakehouse Sync ADLS", "Synapse Lakehouse Sync/Synapse Lakehouse Sync Functions", "Synapse Lakehouse Sync/Synapse Lakehouse Sync Tracking Table Log Success", "Synapse Lakehouse Sync/Synapse Lakehouse Sync Tracking Table Optimize", "Synapse Lakehouse Sync Tutorial/Convert Parquet to Delta Tables - AdventureWorks", "Synapse Lakehouse Sync Tutorial/Simulate Data Changes - AdventureWorks")
for databricksNotebookName in ${databricksNotebooks[@]}; do
    databricksNotebookBase64=$(base64 -w 0 "../Azure Synapse Lakehouse Sync/Databricks/$databricksNotebookName.dbc" 2>&1 | sed 's/[[:space:]]*//g')
    echo "{\"path\":\"/$databricksNotebookName\",\"content\":\"$databricksNotebookBase64\", \"format\": \"DBC\" }" > "../Azure Synapse Lakehouse Sync/Databricks/$databricksNotebookName.json.tmp"
    databricksNotebookCreate=$(az rest --method post --url https://${databricksWorkspaceUrl}/api/2.0/workspace/import --body "@../Azure Synapse Lakehouse Sync/Databricks/$databricksNotebookName.json.tmp" --headers "{\"Authorization\":\"Bearer $databricksAccessToken\",\"Content-Type\":\"application/json\"}" 2>&1 | tee -a $deploymentLogFile)
    rm "../Azure Synapse Lakehouse Sync/Databricks/$databricksNotebookName.json.tmp"
done

# Create the LS_AzureDatabricks_Managed_Identity Synapse Linked Service.
echo "Creating the Databricks Workspace Linked Service..."
echo "$(date) [INFO] Creating the Databricks Workspace Linked Service..." >> $deploymentLogFile
#databricksClusterId=$(az rest --method get --url https://${databricksWorkspaceUrl}/api/2.0/clusters/list --headers "{\"Authorization\":\"Bearer $databricksAccessToken\"}" --query clusters[0].cluster_id --output tsv 2>&1 | sed 's/[[:space:]]*//g')
cp "../Azure Synapse Lakehouse Sync/Synapse/Linked Services/LS_AzureDatabricks_Managed_Identity.json" "../Azure Synapse Lakehouse Sync/Synapse/Linked Services/LS_AzureDatabricks_Managed_Identity.json.tmp" 2>&1
sed -i "s/REPLACE_DATABRICKS_WORKSPACE_URL/${databricksWorkspaceUrl}/g" "../Azure Synapse Lakehouse Sync/Synapse/Linked Services/LS_AzureDatabricks_Managed_Identity.json.tmp"
sed -i "s/REPLACE_DATABRICKS_WORKSPACE_ID/${databricksWorkspaceId}/g" "../Azure Synapse Lakehouse Sync/Synapse/Linked Services/LS_AzureDatabricks_Managed_Identity.json.tmp"
sed -i "s/REPLACE_DATABRICKS_CLUSTER_ID/${createDatabricksCluster}/g" "../Azure Synapse Lakehouse Sync/Synapse/Linked Services/LS_AzureDatabricks_Managed_Identity.json.tmp"
az synapse linked-service create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name LS_AzureDatabricks_Managed_Identity --file @"../Azure Synapse Lakehouse Sync/Synapse/Linked Services/LS_AzureDatabricks_Managed_Identity.json.tmp"
rm "../Azure Synapse Lakehouse Sync/Synapse/Linked Services/LS_AzureDatabricks_Managed_Identity.json.tmp"


echo "Deployment Complete!"
echo "$(date) [INFO] Deployment Complete" >> $deploymentLogFile
