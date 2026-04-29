// ============================================================================
// main.bicep - Azure Databricks Serverless 네트워크 구성
// ============================================================================
//
// 아키텍처:
//   ADB Serverless → NCC → Private Endpoint → PLS → LB → Router VM → Azure Firewall → Internet
//
// VNET A (vnet-databricks, 10.0.0.0/16): Proxy 전용, PLS, LB, Router VM
// VNET B (vnet-hub, 10.1.0.0/16): Azure Firewall
// VNet Peering: VNET A ↔ VNET B
//
// ============================================================================

targetScope = 'resourceGroup'

// ── Parameters ──────────────────────────────────────────────────────────────
@description('Azure region for all resources')
param location string = resourceGroup().location

@description('SSH public key for Router VM authentication')
@secure()
param sshPublicKey string

@description('VM admin username')
param adminUsername string = 'azureuser'

@description('Admin source IP/CIDR for SSH access to Router VM (e.g., your bastion or VPN range)')
param adminSourceAddress string = '10.0.0.0/8'

@description('Databricks workspace name')
param databricksWorkspaceName string = 'adb-serverless-test'

@description('Deploy second Router VM for HA')
param deploySecondRouterVm bool = false

@description('Router VM size')
param vmSize string = 'Standard_B2s'

// ── Step 1: Azure Firewall (deploy first to get private IP) ─────────────────
// We need the firewall private IP for UDR, but firewall needs the VNet.
// Solution: Deploy firewall VNet first, then firewall, then databricks VNet.

// Hub VNet (for Firewall)
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

// Azure Firewall
module firewall 'modules/firewall.bicep' = {
  name: 'deploy-firewall'
  params: {
    location: location
    firewallSubnetId: vnetHub.properties.subnets[0].id
    firewallMgmtSubnetId: vnetHub.properties.subnets[1].id
    backendSubnetCidr: '10.0.2.64/26'
  }
}

// ── Step 2: Networking (VNet A, Peering, NSG, UDR) ──────────────────────────
// NSG and Route Table
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
          nextHopIpAddress: firewall.outputs.firewallPrivateIp
        }
      }
    ]
  }
}

// Databricks VNet (with NSG and UDR)
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

// VNet Peering: Databricks ↔ Hub
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

// ── Step 3: Load Balancer ───────────────────────────────────────────────────
module lb 'modules/loadbalancer.bicep' = {
  name: 'deploy-loadbalancer'
  params: {
    location: location
    frontendSubnetId: vnetDatabricks.properties.subnets[0].id
  }
}

// ── Step 4: Router VM(s) ────────────────────────────────────────────────────
module routerVm1 'modules/vm-router.bicep' = {
  name: 'deploy-router-vm-01'
  params: {
    location: location
    subnetId: vnetDatabricks.properties.subnets[1].id
    lbBackendPoolId: lb.outputs.backendPoolId
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    vmSuffix: '01'
    availabilityZone: '1'
    vmSize: vmSize
  }
}

module routerVm2 'modules/vm-router.bicep' = if (deploySecondRouterVm) {
  name: 'deploy-router-vm-02'
  params: {
    location: location
    subnetId: vnetDatabricks.properties.subnets[1].id
    lbBackendPoolId: lb.outputs.backendPoolId
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    vmSuffix: '02'
    availabilityZone: '2'
    vmSize: vmSize
  }
}

// ── Step 5: Private Link Service ────────────────────────────────────────────
module pls 'modules/pls.bicep' = {
  name: 'deploy-pls'
  params: {
    location: location
    lbFrontendIpConfigId: lb.outputs.frontendIpConfigId
    backendSubnetId: vnetDatabricks.properties.subnets[1].id
  }
}

// ── Step 6: Azure Databricks Workspace ──────────────────────────────────────
module databricks 'modules/databricks.bicep' = {
  name: 'deploy-databricks'
  params: {
    location: location
    workspaceName: databricksWorkspaceName
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
output firewallPrivateIp string = firewall.outputs.firewallPrivateIp
output firewallPublicIp string = firewall.outputs.firewallPublicIp
output plsResourceId string = pls.outputs.plsResourceId
output plsName string = pls.outputs.plsName
output routerVm1PrivateIp string = routerVm1.outputs.vmPrivateIp
output routerVm2PrivateIp string = deploySecondRouterVm ? routerVm2!.outputs.vmPrivateIp : 'N/A'
output databricksWorkspaceUrl string = databricks.outputs.workspaceUrl
output databricksWorkspaceName string = databricks.outputs.workspaceName
output logAnalyticsWorkspaceId string = firewall.outputs.logAnalyticsWorkspaceId
output lbName string = lb.outputs.lbName

// ── 수동 설정 안내 ──────────────────────────────────────────────────────────
// 배포 완료 후 다음 단계를 수동으로 진행해야 합니다:
//
// 1. Databricks Account Console (https://accounts.azuredatabricks.net/)에서:
//    a. NCC (Network Connectivity Configuration) 생성
//    b. Private Endpoint Rule 추가 (PLS Resource ID 사용)
//    c. Domain Names 설정
//
// 2. Azure Portal에서:
//    a. Private Link Service > Private endpoint connections에서 PE 승인
//
// 3. Databricks Account Console에서:
//    a. PE 상태가 ESTABLISHED 확인
//    b. NCC를 Workspace에 연결
//
// 자세한 내용은 README.md를 참조하세요.
