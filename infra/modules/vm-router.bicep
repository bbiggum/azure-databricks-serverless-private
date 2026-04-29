// ============================================================================
// vm-router.bicep - Router VM with IP Forwarding, IPTables NAT, NGINX
// ============================================================================

@description('Azure region')
param location string

@description('Backend subnet ID')
param subnetId string

@description('Load Balancer backend pool ID')
param lbBackendPoolId string

@description('VM admin username')
param adminUsername string = 'azureuser'

@description('SSH public key')
@secure()
param sshPublicKey string

@description('VM name suffix (e.g., 01, 02)')
param vmSuffix string = '01'

@description('Availability zone')
param availabilityZone string = '1'

@description('VM size')
param vmSize string = 'Standard_B2s'

var vmName = 'vm-router-${vmSuffix}'
var nicName = '${vmName}-nic'

// ── cloud-init script for IP forwarding, iptables, nginx + SNI proxy ─────────
var cloudInitScript = '''#cloud-config
package_update: true
package_upgrade: true

packages:
  - nginx
  - iptables-persistent
  - net-tools
  - tcpdump
  - conntrack
  - libnginx-mod-stream

write_files:
  - path: /etc/sysctl.d/99-ip-forward.conf
    content: |
      net.ipv4.ip_forward=1
    owner: root:root
    permissions: '0644'

  - path: /etc/nginx/sites-available/health-probe
    content: |
      server {
          listen 8082;
          server_name _;
          location / {
              return 200 'healthy';
              add_header Content-Type text/plain;
          }
      }
    owner: root:root
    permissions: '0644'

  - path: /etc/nginx/stream-sni-proxy.conf
    content: |
      stream {
          resolver 168.63.129.16 valid=30s;
          resolver_timeout 5s;

          log_format sni_log '$remote_addr [$time_local] '
                             'SNI=$ssl_preread_server_name '
                             'upstream=$upstream_addr '
                             'bytes_sent=$bytes_sent bytes_received=$bytes_received '
                             'session_time=$session_time';

          access_log /var/log/nginx/sni-proxy-access.log sni_log;

          map $ssl_preread_server_name $target_backend {
              default $ssl_preread_server_name:443;
          }

          server {
              listen 443;
              ssl_preread on;
              proxy_pass $target_backend;
              proxy_connect_timeout 10s;
              proxy_timeout 30s;
          }
      }
    owner: root:root
    permissions: '0644'

  - path: /opt/setup-iptables.sh
    content: |
      #!/bin/bash
      set -e
      IFACE=$(ip -o -4 route show to default | awk '{print $5}')
      iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
      iptables -A FORWARD -i $IFACE -j ACCEPT
      iptables -A FORWARD -o $IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
      netfilter-persistent save
    owner: root:root
    permissions: '0755'

runcmd:
  - sysctl -p /etc/sysctl.d/99-ip-forward.conf
  - ln -sf /etc/nginx/sites-available/health-probe /etc/nginx/sites-enabled/health-probe
  - rm -f /etc/nginx/sites-enabled/default
  # Add stream SNI proxy include to nginx.conf (before the last closing brace or at end)
  - grep -q 'stream-sni-proxy' /etc/nginx/nginx.conf || echo 'include /etc/nginx/stream-sni-proxy.conf;' >> /etc/nginx/nginx.conf
  - nginx -t && systemctl restart nginx
  - systemctl enable nginx
  - /opt/setup-iptables.sh
'''

// ── NIC with IP Forwarding + LB Backend Pool ───────────────────────────────
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          loadBalancerBackendAddressPools: [
            {
              id: lbBackendPoolId
            }
          ]
        }
      }
    ]
  }
}

// ── Router VM ───────────────────────────────────────────────────────────────
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  zones: [
    availabilityZone
  ]
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInitScript)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
output vmId string = vm.id
output vmName string = vm.name
output vmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output nicId string = nic.id
