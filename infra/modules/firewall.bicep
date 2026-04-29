// ============================================================================
// firewall.bicep - Azure Firewall + Firewall Policy
// ============================================================================

@description('Azure region')
param location string

@description('Azure Firewall Subnet ID')
param firewallSubnetId string

@description('Azure Firewall Management Subnet ID')
param firewallMgmtSubnetId string

@description('Backend subnet CIDR for firewall rules source')
param backendSubnetCidr string = '10.0.2.64/26'

// ── Public IPs ──────────────────────────────────────────────────────────────
resource pipFirewall 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-afw-hub'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource pipFirewallMgmt 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-afw-hub-mgmt'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// ── Firewall Policy ─────────────────────────────────────────────────────────
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: 'afwp-hub'
  location: location
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
  }
}

// ── Application Rule Collection Group ───────────────────────────────────────
resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: firewallPolicy
  name: 'rcg-databricks'
  properties: {
    priority: 100
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'rc-databricks-allowed'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-Microsoft'
            sourceAddresses: [
              backendSubnetCidr
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.microsoft.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-Azure-Storage'
            sourceAddresses: [
              backendSubnetCidr
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.blob.core.windows.net'
              '*.dfs.core.windows.net'
              '*.table.core.windows.net'
              '*.queue.core.windows.net'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-Databricks'
            sourceAddresses: [
              backendSubnetCidr
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.azuredatabricks.net'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-AAD'
            sourceAddresses: [
              backendSubnetCidr
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              'login.microsoftonline.com'
              'graph.microsoft.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-ifconfig'
            sourceAddresses: [
              backendSubnetCidr
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
              {
                protocolType: 'Http'
                port: 80
              }
            ]
            targetFqdns: [
              'ifconfig.me'
              'api.ipify.org'
              'ipinfo.io'
              'checkip.amazonaws.com'
              'httpbin.org'
            ]
            description: 'IP 확인용 외부 서비스 (테스트 목적)'
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'rc-apt-repos'
        priority: 150
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-Ubuntu-Apt'
            sourceAddresses: [
              backendSubnetCidr
            ]
            protocols: [
              {
                protocolType: 'Http'
                port: 80
              }
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.ubuntu.com'
              'azure.archive.ubuntu.com'
              'archive.ubuntu.com'
              'security.ubuntu.com'
            ]
            description: 'Ubuntu apt 저장소 접근 (NGINX 설치용)'
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'rc-databricks-network'
        priority: 200
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-SQL'
            sourceAddresses: [
              backendSubnetCidr
            ]
            destinationAddresses: [
              'Sql'
            ]
            destinationPorts: [
              '1433'
            ]
            ipProtocols: [
              'TCP'
            ]
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-DNS'
            sourceAddresses: [
              backendSubnetCidr
            ]
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '53'
            ]
            ipProtocols: [
              'UDP'
              'TCP'
            ]
          }
        ]
      }
    ]
  }
}

// ── Azure Firewall ──────────────────────────────────────────────────────────
resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: 'afw-hub'
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          publicIPAddress: {
            id: pipFirewall.id
          }
          subnet: {
            id: firewallSubnetId
          }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'fw-mgmt-ipconfig'
      properties: {
        publicIPAddress: {
          id: pipFirewallMgmt.id
        }
        subnet: {
          id: firewallMgmtSubnetId
        }
      }
    }
  }
  dependsOn: [
    ruleCollectionGroup
  ]
}

// ── Diagnostic Settings (Log Analytics) ─────────────────────────────────────
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-afw-hub'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'fw-diagnostics'
  scope: firewall
  properties: {
    workspaceId: logAnalytics.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output firewallName string = firewall.name
output firewallPublicIp string = pipFirewall.properties.ipAddress
output logAnalyticsWorkspaceId string = logAnalytics.id
output firewallPolicyName string = firewallPolicy.name
