using 'main.bicep'

param location = 'koreacentral'
param sshPublicKey = readEnvironmentVariable('SSH_PUBLIC_KEY', '')
param adminUsername = 'azureuser'
param adminSourceAddress = '10.0.0.0/8'
param databricksWorkspaceName = 'adb-serverless-test'
param deploySecondRouterVm = false
param vmSize = 'Standard_D2s_v3'
