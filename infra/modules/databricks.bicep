// ============================================================================
// databricks.bicep - Azure Databricks Workspace (Premium)
// ============================================================================

@description('Azure region')
param location string

@description('Databricks workspace name')
param workspaceName string = 'adb-serverless-test'

// ── Azure Databricks Workspace ──────────────────────────────────────────────
resource databricksWorkspace 'Microsoft.Databricks/workspaces@2024-05-01' = {
  name: workspaceName
  location: location
  sku: {
    name: 'premium'
  }
  properties: {
    managedResourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', 'rg-databricks-${workspaceName}-managed')
    parameters: {
      enableNoPublicIp: {
        value: false
      }
    }
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
output workspaceId string = databricksWorkspace.id
output workspaceName string = databricksWorkspace.name
output workspaceUrl string = databricksWorkspace.properties.workspaceUrl
