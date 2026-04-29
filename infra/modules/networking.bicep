// ============================================================================
// networking.bicep - VNets, Subnets, Peering, NSG, Route Table
// ============================================================================

@description('Azure region for all resources')
param location string

@description('Azure Firewall private IP for UDR next hop')
param firewallPrivateIp string

@description('Admin source IP range for SSH access')
param adminSourceAddress string = '10.0.0.0/8'

// ── VNET A: Databricks Landing Zone ─────────────────────────────────────────
resource vnetDatabricks 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-databricks'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-lb-frontend'
        properties: {
          addressPrefix: '10.0.2.0/26'
        }
      }
      {
        name: 'snet-lb-backend'
        properties: {
          addressPrefix: '10.0.2.64/26'
          networkSecurityGroup: {
            id: nsgBackend.id
          }
          routeTable: {
            id: rtBackendToFirewall.id
          }
          privateLinkServiceNetworkPolicies: 'Disabled'
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// ── VNET B: Hub / Connectivity Landing Zone ─────────────────────────────────
resource vnetHub 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-hub'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.1.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: '10.1.0.0/26'
        }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: '10.1.0.64/26'
        }
      }
    ]
  }
}

// ── VNet Peering ────────────────────────────────────────────────────────────
resource peerDatabricksToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: vnetDatabricks
  name: 'peer-databricks-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: vnetHub.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peerHubToDatabricks 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: vnetHub
  name: 'peer-hub-to-databricks'
  properties: {
    remoteVirtualNetwork: {
      id: vnetDatabricks.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ── NSG for Backend Subnet ──────────────────────────────────────────────────
resource nsgBackend 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-backend'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceAddress
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-AzureLB'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-HealthProbe'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8082'
        }
      }
      {
        name: 'Allow-HTTP'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-HTTPS'
        properties: {
          priority: 140
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ── Route Table (UDR): Backend → Firewall ───────────────────────────────────
resource rtBackendToFirewall 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-backend-to-firewall'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'route-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
output vnetDatabricksId string = vnetDatabricks.id
output vnetDatabricksName string = vnetDatabricks.name
output vnetHubId string = vnetHub.id
output vnetHubName string = vnetHub.name
output snetLbFrontendId string = vnetDatabricks.properties.subnets[0].id
output snetLbBackendId string = vnetDatabricks.properties.subnets[1].id
output azureFirewallSubnetId string = vnetHub.properties.subnets[0].id
output azureFirewallMgmtSubnetId string = vnetHub.properties.subnets[1].id
output nsgBackendId string = nsgBackend.id
output routeTableId string = rtBackendToFirewall.id
