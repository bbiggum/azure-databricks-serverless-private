// ============================================================================
// loadbalancer.bicep - Internal Standard Load Balancer
// ============================================================================

@description('Azure region')
param location string

@description('Frontend subnet ID (snet-lb-frontend)')
param frontendSubnetId string

// ── Internal Standard Load Balancer ─────────────────────────────────────────
resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: 'lb-databricks-internal'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-databricks'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: frontendSubnetId
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'be-router-pool'
      }
    ]
    probes: [
      {
        name: 'hp-router-8082'
        properties: {
          protocol: 'Http'
          port: 8082
          requestPath: '/'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-ha-ports'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', 'lb-databricks-internal', 'fe-databricks')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'lb-databricks-internal', 'be-router-pool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', 'lb-databricks-internal', 'hp-router-8082')
          }
          protocol: 'All'
          frontendPort: 0
          backendPort: 0
          enableFloatingIP: false
          enableTcpReset: true
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
        }
      }
    ]
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
output lbId string = lb.id
output lbName string = lb.name
output frontendIpConfigId string = lb.properties.frontendIPConfigurations[0].id
output backendPoolId string = lb.properties.backendAddressPools[0].id
output backendPoolName string = lb.properties.backendAddressPools[0].name
