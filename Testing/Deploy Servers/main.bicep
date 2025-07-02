// Create a Network Security Group for Windows VMs (allow TCP 3369 only)
resource nsgWindows 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-windows'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-3389'
        properties: {
          priority: 1001
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Create a Network Security Group for Linux VMs (allow TCP 22 only)
resource nsgLinux 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-linux'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-22'
        properties: {
          priority: 1001
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}
// main.bicep
// Deploys 1 to N Windows and/or Linux VMs based on a configuration file

param location string = resourceGroup().location
param vmConfig object

// Loop for Windows VMs

resource windowsVms 'Microsoft.Compute/virtualMachines@2023-03-01' = [for (win, i) in vmConfig.windows: {
  name: win.name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: win.vmSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: win.image.offer
        sku: win.image.sku
        version: win.image.version
      }
    }
    osProfile: {
      computerName: win.name
      adminUsername: win.adminUsername
      adminPassword: win.adminPassword
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
        }
      ]
    }
  }
  dependsOn: [
    nics[i]
  ]
}]

// Loop for Linux VMs
resource linuxVms 'Microsoft.Compute/virtualMachines@2023-03-01' = [for (lin, i) in vmConfig.linux: {
  name: lin.name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: lin.vmSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
      imageReference: {
        publisher: 'Canonical'
        offer: lin.image.offer
        sku: lin.image.sku
        version: lin.image.version
      }
    }
    osProfile: {
      computerName: lin.name
      adminUsername: lin.adminUsername
      adminPassword: lin.adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[length(vmConfig.windows) + i].id
        }
      ]
    }
  }
  dependsOn: [
    nics[length(vmConfig.windows) + i]
  ]
}]

// Create Public IPs for all VMs
resource publicIps 'Microsoft.Network/publicIPAddresses@2023-05-01' = [for vm in union(vmConfig.windows, vmConfig.linux): {
  name: '${vm.name}-pip'
  location: location
  properties: {
    publicIPAllocationMethod: 'Dynamic'
  }
}]

// Create NICs for all VMs, associate with public IPs and correct NSG
resource nics 'Microsoft.Network/networkInterfaces@2023-05-01' = [for (vm, i) in union(vmConfig.windows, vmConfig.linux): {
  name: '${vm.name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', 'vnet', 'default')
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIps[i].id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: i < length(vmConfig.windows) ? nsgWindows.id : nsgLinux.id
    }
  }
}]

// Create a VNet and subnet if not exists
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: 'vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}
