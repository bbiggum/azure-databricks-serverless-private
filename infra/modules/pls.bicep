// ============================================================================
// pls.bicep - Private Link Service
// ============================================================================

@description('Azure region')
param location string

@description('Load Balancer Frontend IP Configuration ID')
param lbFrontendIpConfigId string

@description('Backend subnet ID for Source NAT')
param backendSubnetId string

// ── Private Link Service ────────────────────────────────────────────────────
resource pls 'Microsoft.Network/privateLinkServices@2024-05-01' = {
  name: 'pls-databricks'
  location: location
  properties: {
    loadBalancerFrontendIpConfigurations: [
      {
        id: lbFrontendIpConfigId
      }
    ]
    ipConfigurations: [
      {
        name: 'pls-ipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: backendSubnetId
          }
          primary: true
        }
      }
    ]
    visibility: {
      subscriptions: []
    }
    autoApproval: {
      subscriptions: []
    }
    enableProxyProtocol: false
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
output plsId string = pls.id
output plsName string = pls.name
output plsResourceId string = pls.id
